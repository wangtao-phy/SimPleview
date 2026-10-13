import AppKit
import PDFKit
import Combine
import SwiftUI
import os

/// 会话只保存路径、分组和界面参数，不读取或复制 PDF 内容。
/// 使用本机 Application Support，串行原子替换；异常中断不会留下半份 JSON。
@MainActor
final class WindowSessionStore {
    private let fileURL: URL
    private let writer = DispatchQueue(label: "com.simpleview.window-session", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private var lastQueuedData: Data?

    init(fileURL: URL = URL.applicationSupportDirectory.appendingPathComponent("SimPleview/WindowSession.json")) {
        self.fileURL = fileURL
    }

    func load() -> [SavedGroup]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([SavedGroup].self, from: data)
    }

    /// 结构变化立即排队；尚未开始的旧写入可取消，始终优先保存最新完整状态。
    func save(_ groups: [SavedGroup], synchronously: Bool = false) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(groups) else { return false }
        if !synchronously, data == lastQueuedData { return true }
        lastQueuedData = data
        pendingWrite?.cancel()
        let url = fileURL
        if synchronously {
            pendingWrite = nil
            let saved = writer.sync { @Sendable in Self.write(data, to: url) }
            if !saved { lastQueuedData = nil }
            return saved
        }
        // DispatchWorkItem 的旧接口不会检查 actor 隔离；显式 Sendable 避免继承主 actor。
        let work = DispatchWorkItem { @Sendable [weak self] in
            if !Self.write(data, to: url) {
                Task { @MainActor [weak self] in
                    if self?.lastQueuedData == data { self?.lastQueuedData = nil }
                }
            }
        }
        pendingWrite = work
        writer.async(execute: work)
        return true
    }

    nonisolated private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Logger.view.error("Window session save failed: \(error.localizedDescription)")
            return false // 写入失败保留上一次完整记录，不弹窗打断阅读。
        }
    }
}

struct SavedReaderState: Codable, Sendable {
    let page: Int
    let zoom: Double
    let autoScales: Bool
    let leftTab: Int
    let rightTab: Int
    let showRightSidebar: Bool
    let hideLeftSidebar: Bool
}

extension WindowRegistry {
    /// 高频变化最多每半秒合并一次；持续滚动也会记录，无变化时不轮询或渲染。
    func scheduleSessionCheckpoint() {
        guard !isRestoringSession, sessionCheckpoint == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.checkpointSession() }
        sessionCheckpoint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @discardableResult
    func checkpointSession(synchronously: Bool = false) -> Bool {
        guard !isRestoringSession else { return true }
        sessionCheckpoint?.cancel(); sessionCheckpoint = nil
        return sessionStore.save(sessionSnapshot(), synchronously: synchronously)
    }

    func sessionSnapshot() -> [SavedGroup] {
        var result: [SavedGroup] = []
        var visited = Set<ObjectIdentifier>()
        for controller in controllers {
            guard controller is AppWindowController, let window = controller.window,
                  visited.insert(ObjectIdentifier(window)).inserted else { continue }
            let members = tabs(in: window).filter { $0.windowController is AppWindowController }
            var paths: [String] = [], states: [SavedReaderState] = []
            for member in members {
                visited.insert(ObjectIdentifier(member))
                guard let reader = member.windowController as? AppWindowController,
                      let url = reader.appState?.fileURL ?? reader.documentURL else { continue }
                paths.append(url.path)
                let state = reader.appState, ui = reader.uiState
                states.append(reader.restoration ?? SavedReaderState(page: state?.liveState.currentPageIndex ?? 0,
                    zoom: Double(state?.pdfView.scaleFactor ?? 1), autoScales: state?.pdfView.autoScales ?? true,
                    leftTab: ui?.leftSidebarTab ?? 0, rightTab: ui?.rightSidebarTab ?? 0,
                    showRightSidebar: ui?.showRightSidebar ?? false,
                    hideLeftSidebar: ui?.columnVisibility == .detailOnly))
            }
            guard !paths.isEmpty else { continue }
            let first = members.first ?? window
            let name = UserDefaults.standard.string(forKey: "CustomGroupName_\(first.windowNumber)") ?? "未命名分组"
            var group = SavedGroup(name: name, urls: paths)
            group.states = states
            group.frame = NSStringFromRect(window.frame)
            let selected = window.tabGroup?.selectedWindow ?? window
            group.selectedIndex = members.firstIndex(where: { $0 === selected })
            group.isKeyGroup = members.contains(where: { $0.isKeyWindow })
            result.append(group)
        }
        result += emptyGroups.map { SavedGroup(name: $0.name, urls: []) }
        return result
    }
}

extension AppWindowController {
    /// 每个控制器只安装一次。仅订阅需要恢复的状态，悬浮窗、动画和鼠标移动不写盘。
    func observeSessionState() {
        guard sessionObservers.isEmpty, let state = appState, let ui = uiState else { return }
        let changes: [AnyPublisher<Void, Never>] = [
            state.liveState.pageIndexSubject.map { _ in () }.eraseToAnyPublisher(),
            state.documentManager.$fileURL.map { _ in () }.eraseToAnyPublisher(),
            ui.$leftSidebarTab.map { _ in () }.eraseToAnyPublisher(),
            ui.$rightSidebarTab.map { _ in () }.eraseToAnyPublisher(),
            ui.$showRightSidebar.map { _ in () }.eraseToAnyPublisher(),
            ui.$columnVisibility.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: state.pdfView)
                .map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes).receive(on: DispatchQueue.main)
            .sink { _ in WindowRegistry.shared.scheduleSessionCheckpoint() }.store(in: &sessionObservers)
    }

    /// 文档解析和 SwiftUI 窗口绑定谁先完成都可以，双方均调用此方法，只应用一次。
    func applyPendingRestoration() {
        guard let saved = restoration, let state = appState, let ui = uiState,
              let document = state.pdfView.document, document.pageCount > 0 else { return }
        restoration = nil
        ui.leftSidebarTab = max(0, min(1, saved.leftTab))
        ui.rightSidebarTab = max(0, min(3, saved.rightTab))
        ui.showRightSidebar = saved.showRightSidebar
        ui.columnVisibility = saved.hideLeftSidebar ? .detailOnly : .all
        state.goToPage(saved.page, recordHistory: false)
        state.pdfView.autoScales = saved.autoScales
        if !saved.autoScales, saved.zoom.isFinite, saved.zoom > 0 {
            state.pdfView.scaleFactor = max(state.pdfView.minScaleFactor,
                                           min(state.pdfView.maxScaleFactor, CGFloat(saved.zoom)))
        }
    }
}
