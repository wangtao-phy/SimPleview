import AppKit
import Combine
import PDFKit
import SwiftUI

/// 阅读窗口由 AppKit 管理。菜单的目标、可用状态和快捷键也交给 AppKit，
/// 避免仅有 Settings 场景时，SwiftUI Commands 缓存初始窗口状态。
@MainActor
final class ReaderCommandRouter: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = ReaderCommandRouter()
    private var observers = Set<AnyCancellable>()
    private var preferenceSignature = ""
    private var menuRepairScheduled = false
    var sectionsByMenu: [NSMenuItem] = []
    var currentLanguage: AppLanguage { language }
    private var state: AppState? { (NSApp.keyWindow?.windowController as? AppWindowController)?.appState }
    private var ui: UIState? { (NSApp.keyWindow?.windowController as? AppWindowController)?.uiState }
    private var language: AppLanguage {
        UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .zh
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshMenus() }.store(in: &observers)
        }
        // Settings 场景会重新创建系统菜单。仅检查几个固定 ID，缺失时延后恢复，
        // 不在事件处理过程中修改菜单，也不在每次 UI 更新时遍历全部动作。
        center.publisher(for: NSApplication.didUpdateNotification)
            .sink { [weak self] _ in self?.restoreMenusIfNeeded() }.store(in: &observers)
        // 文本输入及撤销分组会改变编辑菜单可用性；只更新两个编辑动作，
        // 不让逐字输入触发整个阅读菜单的遍历。
        for name in [NSText.didChangeNotification, Notification.Name.NSUndoManagerDidUndoChange,
                     Notification.Name.NSUndoManagerDidRedoChange, Notification.Name.NSUndoManagerDidCloseUndoGroup] {
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshEditingCommands() }.store(in: &observers)
        }
        FeaturePreferences.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenus() }.store(in: &observers)
        ShortcutManager.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenus() }.store(in: &observers)
        center.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // 翻页也会写偏好；只有菜单相关的偏好变化才遍历菜单。
                let signature = "\(self.language.rawValue)|\(self.recordEnabled)|\(self.todoEnabled)"
                if signature != self.preferenceSignature { self.preferenceSignature = signature; self.refreshMenus() }
            }.store(in: &observers)
        DispatchQueue.main.async { [weak self] in self?.installMenus() }
    }

    private func restoreMenusIfNeeded() {
        guard !menuRepairScheduled, let menu = NSApp.mainMenu,
              sectionsByMenu.count != 4 || sectionsByMenu.contains(where: {
                  $0.menu !== menu || $0.submenu?.items.contains(where: {
                      $0.identifier?.rawValue.hasPrefix("simpleview.command.") == true
                  }) != true
              }) else { return }
        menuRepairScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuRepairScheduled = false
            self.installMenus()
        }
    }

    private var recordEnabled: Bool { UserDefaults.standard.bool(forKey: "enableReadingRecord") }
    private var todoEnabled: Bool { UserDefaults.standard.object(forKey: "enableTodo") as? Bool ?? true }
    private func visible(_ action: ShortcutAction) -> Bool {
        switch action {
        case .toggleAIChat: return FeaturePreferences.shared.ai
        case .windowManagement: return FeaturePreferences.shared.windowManagement
        case .pomodoro: return FeaturePreferences.shared.pomodoro
        case .eyeCare: return FeaturePreferences.shared.eyeCare
        case .todo: return todoEnabled
        case .history: return recordEnabled
        default: return true
        }
    }
    private func enabled(_ action: ShortcutAction) -> Bool {
        if NSApp.modalWindow != nil || NSApp.keyWindow is NSSavePanel
            || NSApp.keyWindow?.sheetParent != nil || NSApp.keyWindow?.attachedSheet != nil {
            if action == .open, AppDelegate.isOpeningDocument { return true }
            // 文件面板中的文本编辑仍使用标准快捷键，其余阅读命令不能叠加新弹窗。
            switch action {
            case .undo, .redo:
                guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
            default: return false
            }
        }
        guard visible(action) else { return false }
        switch action {
        case .undo where NSApp.keyWindow?.firstResponder is NSTextView:
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo == true
        case .redo where NSApp.keyWindow?.firstResponder is NSTextView:
            return (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo == true
        case .open, .newDocument, .authors, .history: return true
        case .closeWindow, .pomodoro: return NSApp.keyWindow != nil
        default: return state?.fileURL != nil && state?.isClosed == false
        }
    }

    /// 菜单只保存稳定动作 ID；执行时读取 keyWindow，不持有 PDF 或旧窗口。
    func refreshMenus() {
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                let prefix = "simpleview.command."
                let action = item.identifier.flatMap { id in
                    id.rawValue.hasPrefix(prefix) ? ShortcutAction(rawValue: String(id.rawValue.dropFirst(prefix.count))) : nil
                }
                if let action {
                    let shortcut = ShortcutManager.shared[action]
                    item.identifier = NSUserInterfaceItemIdentifier(prefix + action.rawValue)
                    item.target = self; item.action = #selector(invoke(_:))
                    item.title = L.s(action.definition.title, language)
                    // AppKit 的 Shift 字母按生成字符匹配，用大写字符避免落到不带 Shift 的动作。
                    item.keyEquivalent = shortcut.modifiers.contains(.shift) ? shortcut.key.uppercased() : shortcut.key
                    var modifiers: NSEvent.ModifierFlags = []
                    if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
                    if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
                    if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
                    if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
                    item.keyEquivalentModifierMask = modifiers
                    item.isHidden = !visible(action)
                    item.isEnabled = enabled(action)

                }
                if let id = item.identifier?.rawValue, id.hasPrefix("simpleview.standard.") {
                    item.title = L.s(String(id.dropFirst("simpleview.standard.".count)), language)
                }
                if item.identifier?.rawValue == "simpleview.language" {
                    item.title = L.s("Switch Language", language)
                    for choice in item.submenu?.items ?? [] {
                        choice.state = choice.representedObject as? String == language.rawValue ? .on : .off
                    }
                }
                if item.identifier?.rawValue == "simpleview.recent" { item.title = L.s("Open Recent", language) }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
        for (item, key) in zip(sectionsByMenu, ["File", "Edit", "View", "Reading Tools"]) {
            item.title = L.s(key, language); item.submenu?.title = item.title
        }
    }

    private func refreshEditingCommands() {
        guard let edit = sectionsByMenu.dropFirst().first?.submenu else { return }
        for action in [ShortcutAction.undo, .redo] {
            let item = edit.items.first { $0.identifier?.rawValue == "simpleview.command." + action.rawValue }
            item?.isEnabled = enabled(action)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.identifier?.rawValue.split(separator: ".").last,
              let action = ShortcutAction(rawValue: String(id)) else { return true }
        return enabled(action)
    }
    @objc private func invoke(_ item: NSMenuItem) {
        guard let id = item.identifier?.rawValue.split(separator: ".").last,
              let action = ShortcutAction(rawValue: String(id)) else { return }
        perform(action)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs.prefix(20) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url
            menu.addItem(item)
        }
    }
    @objc func openRecent(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSApp.openSwiftUIWindow(for: url)
    }
    @objc func selectLanguage(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, AppLanguage(rawValue: raw) != nil else { return }
        UserDefaults.standard.set(raw, forKey: "appLanguage")
    }
    @objc func checkUpdates(_ item: NSMenuItem) { UpdateManager.shared.checkForUpdates(manual: true) }

    func perform(_ action: ShortcutAction) {
        guard enabled(action) else { return }
        defer { refreshEditingCommands() }
        switch action {
        case .open: AppDelegate.openDocumentDialog()
        case .newDocument: NotificationCenter.default.post(name: Notification.Name("GlobalNewDocument"), object: nil)
        case .save: state?.save(immediate: true)
        case .closeWindow: NSApp.keyWindow?.performClose(nil)
        case .revealInFinder: state?.revealInFinder()
        case .burnIn: if let state { state.documentManager.burnInAnnotations(pdfView: state.pdfView) }
        case .printDocument: state?.printDocument()
        case .undo:
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() }
            else { state?.undo() }
        case .redo:
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() }
            else { state?.redo() }
        case .search: ui?.triggerSearchFocus(state: state)
        case .toggleLeftSidebar: ui?.toggleLeftSidebar(state: state)
        case .toggleRightSidebar: ui?.toggleRightSidebar(state: state)
        case .compareView: state?.openCompareWindow()
        case .slideshow: ui?.isSlideshowActive.toggle()
        case .goBack: state?.goBack()
        case .previousPage: state?.goToPage((state?.liveState.currentPageIndex ?? 0) - 1)
        case .nextPage: state?.goToPage((state?.liveState.currentPageIndex ?? 0) + 1)
        case .zoomIn: state?.pdfView.zoomIn(nil)
        case .zoomOut: state?.pdfView.zoomOut(nil)
        case .actualSize: state?.pdfView.autoScales = false; state?.pdfView.scaleFactor = 1
        case .fitPage: state?.pdfView.autoScales = true
        case .rotateLeft: state?.rotateSelectedPagesLeft()
        case .rotateRight:
            if let state { state.rotatePages(at: state.selectedIndices.isEmpty ? [state.liveState.currentPageIndex] : state.selectedIndices, clockwise: true) }
        case .highlight: state?.activeType = .highlight
        case .underline: state?.activeType = .underline
        case .strikeout: state?.activeType = .strikeout
        case .none: state?.activeType = .none
        case .ink: state?.activeType = .ink
        case .signature: ui?.isShowingSignaturePopover.toggle()
        case .toggleAnnotations: state?.areAnnotationsVisible.toggle()
        case .history: HistoryWindowManager.shared.open()
        case .authors: AuthorsWindowManager.shared.open()
        case .openInBrowser: state?.openInBrowser()
        case .toggleAIChat: ui?.isAIChatPresented.toggle()
        case .windowManagement: ui?.isShowingTabGroupsPopover.toggle()
        case .pomodoro: FocusSessionManager.shared.toggleForCurrentWindow()
        case .eyeCare:
            if let state {
                let values = PDFPageBackgroundColor.allCases
                let index = values.firstIndex(of: state.pageBackgroundColor) ?? 0
                state.pageBackgroundColor = values[(index + 1) % values.count]
            }
        case .todo:
            if let ui {
                if ui.showRightSidebar && ui.rightSidebarTab == 2 { ui.toggleRightSidebar(state: state) }
                else { ui.rightSidebarTab = 2; if !ui.showRightSidebar { ui.toggleRightSidebar(state: state) } }
            }
        }
    }
}
