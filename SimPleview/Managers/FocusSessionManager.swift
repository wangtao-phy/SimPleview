import AppKit
import SwiftUI
import Combine
@preconcurrency import EventKit

/// 全应用只有一个番茄钟。普通阅读按窗口/应用事件计时，不启动周期性计时器；
/// 番茄钟运行时每秒仅更新弹出框与菜单栏，结束后立即停止 Timer。
@MainActor
final class FocusSessionManager: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = FocusSessionManager()
    let recorder: FocusCalendarRecorder
    @Published private(set) var outcome = FocusSessionClock.Outcome.idle
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isStarting = false
    @Published private(set) var documentTitle: String?
    private var clock = FocusSessionClock()
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var popoverAnchor: NSView?
    private weak var popoverHostWindow: NSWindow?
    private var observers = Set<AnyCancellable>()
    private var isAwake = true
    private var isSessionActive = true
    private var contextUpdateScheduled = false
    private var serviceStarted = false

    init(recorder: FocusCalendarRecorder = FocusCalendarRecorder()) {
        self.recorder = recorder
        super.init()
    }

    isolated deinit {
        timer?.invalidate()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    var isRunning: Bool { clock.isRunning }
    var countdown: String { String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60) }
    func text(_ key: String) -> String {
        L.s(key, UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .zh)
    }
    var outcomeText: String {
        switch outcome {
        case .idle: return text("Focus Ready")
        case .running: return text("Focus Running")
        case .awaitingReturn: return text("Focus Awaiting Return")
        case .completed: return text("Focus Completed")
        case .failed: return text("Focus Failed")
        case .cancelled: return text("Focus Cancelled")
        }
    }

    func startService() {
        guard !serviceStarted else { return }
        serviceStarted = true
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.willResignActiveNotification)
            .map { _ in FocusMoment.now }.receive(on: DispatchQueue.main)
            .sink { [weak self] now in self?.deactivate(at: now) }.store(in: &observers)
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.scheduleContextUpdate()
                Task { @MainActor [weak self] in await self?.flushRecords() }
            }.store(in: &observers)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleContextUpdate() }.store(in: &observers)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .map { _ in FocusMoment.now }.receive(on: DispatchQueue.main)
            .sink { [weak self] now in self?.isAwake = false; self?.deactivate(at: now) }.store(in: &observers)
        workspace.publisher(for: NSWorkspace.didWakeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isAwake = true; self?.scheduleContextUpdate() }.store(in: &observers)
        workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .map { _ in FocusMoment.now }.receive(on: DispatchQueue.main)
            .sink { [weak self] now in self?.isSessionActive = false; self?.deactivate(at: now) }.store(in: &observers)
        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isSessionActive = true; self?.scheduleContextUpdate() }.store(in: &observers)
        Task { [weak self] in await self?.flushRecords() }
        scheduleContextUpdate()
    }

    /// 页面变化可以补齐初次挂接窗口时尚未出现的文档信息，与“阅读记录”开关无关。
    func updateReadingDocument(title: String) {
        guard NSApp.isActive, isAwake, isSessionActive else { return }
        let now = FocusMoment.now
        consume(clock.update(active: true, document: title, at: now))
        updateDisplay(at: now)
    }

    private func scheduleContextUpdate() {
        guard !contextUpdateScheduled else { return }
        contextUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.contextUpdateScheduled = false
            self.syncContext()
        }
    }

    private func syncContext() {
        let active = NSApp.isActive && isAwake && isSessionActive
        // 自己的计时弹出框不打断文档阅读；普通设置窗口等不计入阅读时长。
        let window = NSApp.keyWindow === popover?.contentViewController?.view.window ? popoverHostWindow : NSApp.keyWindow
        let state = (window?.windowController as? AppWindowController)?.appState
        let title = state?.isClosed == false ? state?.fileURL?.deletingPathExtension().lastPathComponent : nil
        let now = FocusMoment.now
        consume(clock.update(active: active, document: title, at: now))
        updateDisplay(at: now)
    }

    private func deactivate(at now: FocusMoment) {
        consume(clock.update(active: false, document: nil, at: now))
        updateDisplay(at: now)
    }

    func start(minutes: Int) async {
        guard !isRunning, !isStarting, (1...180).contains(minutes) else { return }
        isStarting = true
        defer { isStarting = false }
        // 首次开始时请求系统日历权限；拒绝不丢弃专注结果，之后可从面板补写。
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            await recorder.flush(requestAccess: true)
        }
        beginCountdown(minutes: minutes)
    }

    /// 权限流程与计时分开：系统授权弹窗的等待时间不占用本次专注。
    func beginCountdown(minutes: Int) {
        guard !isRunning, (1...180).contains(minutes) else { return }
        syncContext()
        let now = FocusMoment.now
        consume(clock.start(minutes: minutes, document: documentTitle, at: now))
        updateDisplay(at: now)
        guard timer == nil, clock.isRunning else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.15
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let now = FocusMoment.now
        consume(clock.advance(at: now))
        updateDisplay(at: now)
    }

    func cancel() {
        let now = FocusMoment.now
        consume(clock.advance(at: now))
        clock.cancel(at: now)
        updateDisplay(at: now)
    }

    private func flushRecords() async {
        let request = NSApp.isActive && isAwake && isSessionActive && recorder.pendingCount > 0 &&
            EKEventStore.authorizationStatus(for: .event) == .notDetermined
        await recorder.flush(requestAccess: request)
    }

    private func consume(_ records: [FocusRecord]) {
        guard !records.isEmpty else { return }
        recorder.enqueue(records)
        Task { [weak self] in await self?.flushRecords() }
    }

    private func updateDisplay(at now: FocusMoment) {
        let seconds = clock.remaining(at: now)
        if remainingSeconds != seconds { remainingSeconds = seconds }
        let outcomeChanged = outcome != clock.outcome
        if outcomeChanged { outcome = clock.outcome }
        if !clock.isRunning { timer?.invalidate(); timer = nil }
        guard outcome != .idle, clock.isRunning || outcomeChanged || statusItem != nil else { return }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: text("Pomodoro"))
            item.button?.imagePosition = .imageLeading
            item.button?.target = self; item.button?.action = #selector(showFromMenuBar)
            statusItem = item
        }
        statusItem?.button?.title = clock.isRunning ? countdown : (outcome == .completed ? "✓" : "—")
        statusItem?.button?.toolTip = outcomeText
    }

    /// 工具栏与菜单栏共用一个瞬时弹出框；点击外部自动关闭，不改变倒计时。
    func togglePopover(relativeTo anchor: NSView, documentTitle: String? = nil) {
        guard anchor.window != nil else { return }
        if let existing = popover {
            let sameAnchor = popoverAnchor === anchor
            existing.performClose(nil)
            if sameAnchor { return }
        }
        if let documentTitle, !isRunning { self.documentTitle = documentTitle }
        popoverHostWindow = anchor.window?.windowController is AppWindowController ? anchor.window : NSApp.mainWindow
        let content = NSHostingController(rootView: FocusTimerView(manager: self, recorder: recorder))
        content.sizingOptions = [.minSize, .preferredContentSize]
        let popup = NSPopover()
        popup.behavior = .transient
        // 内容高度随权限提示和错误变化；即时展开收起，避免布局动画期间关闭被延后。
        popup.animates = false
        popup.delegate = self
        popup.contentViewController = content
        popover = popup
        popoverAnchor = anchor
        NSApp.activate()
        popup.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc private func showFromMenuBar() {
        if let button = statusItem?.button { togglePopover(relativeTo: button) }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover else { return }
        closed.contentViewController = nil
        closed.delegate = nil
        guard closed === popover else { return }
        popover = nil; popoverAnchor = nil; popoverHostWindow = nil
        if !isRunning, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
    }

    /// 退出前同步保存待写记录，系统日历写入可以在下次启动重试。
    func prepareForTermination() -> Bool {
        let now = FocusMoment.now
        recorder.enqueue(clock.stop(at: now))
        updateDisplay(at: now)
        return recorder.persist()
    }
}
