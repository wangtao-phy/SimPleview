import AppKit
import os

/// 只在主进程启动/正常结束时记录极小的运行标记。不安装信号处理器，
/// 不在已崩溃的进程里执行 AppKit 或保存 PDF；下次启动再读取系统诊断。
@MainActor final class CrashRecovery {
    static let shared = CrashRecovery()

    nonisolated struct Session: Codable, Sendable {
        let id: UUID
        let identity: CrashReportFinder.Identity
        let version: String
        let build: String
        let system: String
    }

    private let directory: URL
    private let reportDirectories: [URL]
    private var currentURL: URL?
    private var currentLaunchedAt: Date?
    private var pendingURLs: [URL] = []
    private(set) var previousSession: Session?
    private(set) var isEndingSession = false
    private var readyContinuation: CheckedContinuation<Bool, Never>?
    private var readyObservers: [NSObjectProtocol] = []

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("SimPleview/Diagnostics"),
         reportDirectories: [URL] = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]) {
        self.directory = directory
        self.reportDirectories = reportDirectories
    }

    /// 位于 worker 分流之后、SwiftUI 初始化之前，覆盖启动恢复期间的异常。
    /// 每个实例拥有独立文件；同时运行另一实例不会被当成崩溃或被本次退出清除。
    func beginSession() {
        guard currentURL == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
                where url.lastPathComponent.hasPrefix("Run-") && url.pathExtension == "json" {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 4096, let data = try? Data(contentsOf: url),
                      let session = try? JSONDecoder().decode(Session.self, from: data) else {
                    continue // 损坏的诊断标记不能阻止打开应用，也不能据此断言崩溃。
                }
                guard !isRunning(session) else { continue }
                pendingURLs.append(url)
                if session.identity.launchedAt > (previousSession?.identity.launchedAt ?? .distantPast) {
                    previousSession = session
                }
            }
            let bundle = Bundle.main
            let session = Session(id: UUID(), identity: .init(pid: ProcessInfo.processInfo.processIdentifier,
                launchedAt: NSRunningApplication.current.launchDate ?? Date(),
                executable: bundle.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName,
                bundleIdentifier: bundle.bundleIdentifier ?? "com.tau.SimPleview"),
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                system: ProcessInfo.processInfo.operatingSystemVersionString)
            let url = directory.appendingPathComponent("Run-\(session.id.uuidString).json")
            try JSONEncoder().encode(session).write(to: url, options: .atomic)
            currentURL = url
            currentLaunchedAt = session.identity.launchedAt
        } catch {
            Logger.view.error("Unable to record application run: \(error.localizedDescription)")
        }
    }

    private func isRunning(_ session: Session) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: session.identity.pid), !app.isTerminated,
              let launchedAt = app.launchDate else { return false }
        return app.bundleIdentifier == session.identity.bundleIdentifier &&
            abs(launchedAt.timeIntervalSince(session.identity.launchedAt)) < 2
    }

    /// 必须在 applicationWillTerminate 调用。取消退出/保存失败时标记仍保留。
    func finishSession() {
        isEndingSession = true
        if let currentURL {
            do { try FileManager.default.removeItem(at: currentURL) }
            catch { Logger.view.error("Unable to clear application run: \(error.localizedDescription)") }
        }
        currentURL = nil
        finishWaiting(ready: false)
    }

    /// 用户选择查看报告后不再立即弹出启动文件选择器，让 Finder 保持焦点。
    @discardableResult func presentIfNeeded() async -> Bool {
        guard let session = previousSession, !isEndingSession else { return true }
        let directories = reportDirectories, before = currentLaunchedAt ?? Date()
        let worker = Task.detached(priority: .utility) {
            // 系统报告可能晚于进程退出落盘。只在异常恢复时有限重试，不常驻轮询。
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return nil as CrashReportFinder.Report? }
                if let report = CrashReportFinder.latestReport(for: session.identity, in: directories, before: before) {
                    return report
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(500)) }
            }
            return nil
        }
        let report = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, !isEndingSession else { return false }
        // continuation 恢复到任务重新执行之间仍可能先打开文件面板，故最终展示前
        // 重新判断；等待不会消耗轮询资源，也不在其它面板上叠加新的模态窗口。
        while !readyForUI {
            guard await waitForReadyUI(), !Task.isCancelled, !isEndingSession else { return false }
        }
        let text = diagnosticText(for: session, report: report)
        let alert = makeAlert(text: text, hasReport: report != nil)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if response == .alertThirdButtonReturn {
            if let report { NSWorkspace.shared.activateFileViewerSelecting([report.url]) }
            else if let folder = directories.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                NSWorkspace.shared.open(folder)
            }
        }
        // 仅在提示已展示后确认旧记录；新的运行标记始终保留至真正退出。
        for url in pendingURLs { try? FileManager.default.removeItem(at: url) }
        pendingURLs.removeAll()
        previousSession = nil
        return response != .alertThirdButtonReturn
    }

    private var readyForUI: Bool {
        NSApp.isActive && NSApp.modalWindow == nil && !NSApp.windows.contains {
            $0.isVisible && ($0 is NSSavePanel || $0.attachedSheet != nil || $0.sheetParent != nil)
        }
    }

    /// 后台启动、文件选择器或其它 sheet 先出现时，等它结束再显示，避免叠加弹窗。
    /// 等待只订阅窗口事件，不创建定时器；退出时解除观察并恢复等待者。
    private func waitForReadyUI() async -> Bool {
        if isEndingSession { return false }
        if readyForUI { return true }
        return await withCheckedContinuation { continuation in
            readyContinuation = continuation
            for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification,
                         NSWindow.didEndSheetNotification, NSWindow.willCloseNotification] {
                readyObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.interfaceDidChange() }
                })
            }
        }
    }

    func interfaceDidChange() {
        guard readyContinuation != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.readyForUI else { return }
            self.finishWaiting(ready: true)
        }
    }

    private func finishWaiting(ready: Bool) {
        for observer in readyObservers { NotificationCenter.default.removeObserver(observer) }
        readyObservers.removeAll()
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume(returning: ready)
    }

    private func localized(_ key: String) -> String {
        L.s(key, UserDefaults.standard.string(forKey: "appLanguage") == "en" ? .en : .zh)
    }

    func diagnosticText(for session: Session, report: CrashReportFinder.Report?) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: UserDefaults.standard.string(forKey: "appLanguage") == "en" ? "en_US" : "zh_CN")
        date.dateStyle = .medium; date.timeStyle = .medium
        var text = "SimPleview \(session.version) (\(session.build))\n\(session.system)\n"
        text += "\(localized("Previous Launch")): \(date.string(from: session.identity.launchedAt))\nPID: \(session.identity.pid)\n\n"
        if let report {
            text += report.url.lastPathComponent + "\n\n" + report.text
            if report.isTruncated { text += "\n\n" + localized("Crash Report Truncated") }
        } else { text += localized("No Crash Report Help") }
        return text
    }

    func makeAlert(text: String, hasReport: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized(hasReport ? "Previous Crash Detected" : "Previous Run Interrupted")
        alert.informativeText = localized(hasReport ? "Crash Report Help" : "Interrupted Run Help")
        alert.addButton(withTitle: localized("Continue"))
        alert.addButton(withTitle: localized("Copy Diagnostics"))
        alert.addButton(withTitle: localized("Show Diagnostic Report"))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let content = NSTextView(frame: scroll.bounds)
        content.isEditable = false
        content.isSelectable = true
        content.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.string = text
        content.isVerticallyResizable = true
        content.autoresizingMask = [.width]
        content.textContainer?.widthTracksTextView = true
        scroll.documentView = content
        alert.accessoryView = scroll
        return alert
    }
}
