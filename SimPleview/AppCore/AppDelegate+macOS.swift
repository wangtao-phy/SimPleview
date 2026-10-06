import UniformTypeIdentifiers

import SwiftUI
import Combine
import PDFKit

#if os(macOS)

// 为了获得 Window 对象的控制权，我们写一个透明的 NSView。
// 当这个假想的 view 被真正贴到屏幕上的窗口里时，它就能往上攀爬，顺藤摸瓜抓住它的“宿主窗口”。
class WindowAccessorView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(self.window)
    }
}

// 封装成 NSViewRepresentable 让 SwiftUI 认为它是个合法的纯净 SwiftUI 视图
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        // 斩断强引用循环：我们不捕获结构体 self，而是捕获轻量级的 Binding 和弱引用的 state
        let windowBinding = $window
        view.onWindow = { [weak state, weak uiState] newWindow in
            DispatchQueue.main.async {
                windowBinding.wrappedValue = newWindow
                state?.hostingWindow = newWindow
                if let wc = newWindow?.windowController as? AppWindowController, let state = state {
                    wc.appState = state
                    wc.uiState = uiState
                    ReaderCommandRouter.shared.refreshMenus()
                }
                if newWindow?.isKeyWindow == true { state?.updateReadingTracking() }
                
                // [P0 级核心修复：后台标签页休眠丢失 Bug]
                // 场景：App 启动时恢复了 10 个标签页，或者用户在后台新开了一个标签页。
                // 这些标签页在创建时默认就是“非活跃”状态，因此它们永远不会触发 didResignKeyNotification。
                // 导致它们永远无法进入休眠逻辑，内存一直被占满。
                // 修复：当视图刚被挂载到窗口时，如果发现自己不是焦点窗口，立刻强制启动休眠倒计时！
                if let window = newWindow, !window.isKeyWindow {
                    state?.scheduleHibernation()
                }
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: WindowAccessorView, context: Context) {}
    
    // [专家级内存优化：斩断闭包循环引用]
    // SwiftUI 会缓存 NSViewRepresentable 的底层视图。
    // 如果不在拆卸时清空闭包，闭包里捕获的 state 就会永远滞留在内存里！
    static func dismantleNSView(_ nsView: WindowAccessorView, coordinator: ()) {
        nsView.onWindow = nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private static var openPanel: NSOpenPanel?
    static var isOpeningDocument: Bool { openPanel != nil }
    private var isTerminating = false
    private var hasCompletedStartup = false
    
    // 新增：保持对新建窗口的强引用，防止闪退或自动销毁异常
    var newDocumentWindowController: NSWindowController?
    
    // App 完全启动后的回调
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI App.init 时 NSApp 可能尚未创建，访问窗口的服务必须在此启动。
        UpdateManager.shared.startMonitoring()
        FocusSessionManager.shared.startService()
        ReaderCommandRouter.shared.start()
        // 标准 InkList 交给 PDFKit 渲染，避免全局交换系统方法影响导出与其他文档。
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("GlobalNewDocument"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                self.openNewDocumentDialog()
            }
        }
        
        // [逻辑流程]
        // 由于我们没有默认窗口，启动后如果发现没有任何可见的文档窗口，就自动弹出一个文件选择器（NSOpenPanel）。
        // 使用 DispatchQueue.main.async 确保是在下一个事件循环弹出，不阻塞系统绘制。
        DispatchQueue.main.async {
            // 系统可能先请求打开无标题文档；恢复判断完成之前不能先弹文件选择器。
            defer { self.hasCompletedStartup = true }
            // [新特性：恢复上次强退或正常退出前打开的窗口组]
            if let savedData = UserDefaults.standard.data(forKey: "SavedWindowGroups"),
               let savedGroups = try? JSONDecoder().decode([SavedGroup].self, from: savedData) {
                var restoredAny = false
                
                for group in savedGroups {
                    if group.urls.isEmpty {
                        // 空分组
                        let emptyGroup = EmptyGroup(name: group.name)
                        WindowRegistry.shared.emptyGroups.append(emptyGroup)
                    } else {
                        // 实体分组
                        var firstWindow: NSWindow? = nil
                        for path in group.urls {
                            let url = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: path) {
                                // 按实际成功打开的首个文件建组。原首文件丢失时，
                                // 后续文件也不能被自动加入上一个恢复的分组。
                                let window = NSApp.openSwiftUIWindow(for: url, independent: true)
                                if let first = firstWindow { first.addTabbedWindow(window, ordered: .above) }
                                else { firstWindow = window }
                                restoredAny = true
                            }
                        }
                        // 恢复自定义分组名称
                        if let first = firstWindow, group.name != "未命名分组" && group.name != "Untitled Group" {
                            let key = "CustomGroupName_\(first.windowNumber)"
                            UserDefaults.standard.set(group.name, forKey: key)
                        }
                    }
                }
                
                // 恢复完毕后清空，避免干扰下次正常打开
                UserDefaults.standard.removeObject(forKey: "SavedWindowGroups")
                if restoredAny {
                    return // 成功恢复了老窗口，不再弹出空文件选择器
                }
            }
            
            // 到实际展示时再判断，Finder 打开文件可能已在这一轮恢复期间创建窗口。
            // 空分组没有可操作的阅读窗口，不能因此阻止首次文件选择器出现。
            let hasDocumentWindows = WindowRegistry.shared.controllers.contains {
                $0 is AppWindowController && $0.window != nil
            }
            if !hasDocumentWindows {
                Self.openDocumentDialog()
            }
        }
    }
    
    // 用户点击 Dock 栏图标（应用如果已经在后台运行）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = WindowRegistry.shared.controllers.first(where: { $0 is AppWindowController })?.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                _ = applicationShouldOpenUntitledFile(sender)
            }
        }
        return true
    }
    
    // 拦截“打开无标题新文件”（Cmd+N）
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // 回调也可能晚于恢复完成；已有阅读窗口时无需再选择文件。⌘O 使用独立入口。
        guard hasCompletedStartup, !WindowRegistry.shared.controllers.contains(where: {
            $0 is AppWindowController && $0.window != nil
        }) else { return false }
        Self.openDocumentDialog()
        return false // 返回 false 阻止系统自动生成一个傻乎乎的空白窗口
    }

    /// SwiftUI 会代理 NSApp.delegate，菜单不能通过向下转换寻找此对象。
    /// 启动、Dock 与快捷键共用此入口；异步面板只保留一个，取消后释放。
    static func openDocumentDialog() {
        if let panel = openPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard NSApp.modalWindow == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = false
        openPanel = panel
        panel.begin { response in
            openPanel = nil
            if response == .OK, let url = panel.url { NSApp.openSwiftUIWindow(for: url) }
        }
    }
    
    // 打开“新建文档”弹窗
    func openNewDocumentDialog() {
        guard NSApp.modalWindow == nil else { return }
        // 防止打开多个
        if let wc = newDocumentWindowController, let window = wc.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        
        let newDocView = NewDocumentWindow(onClose: { [weak self] in
            self?.newDocumentWindowController?.close()
            self?.newDocumentWindowController = nil
        })
        
        let hostingController = NSHostingController(rootView: newDocView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.title = SimPleview.L.s("New Blank Document", UserDefaults.standard.string(forKey: "appLanguage") == "en" ? .en : .zh)
        window.tabbingMode = .disallowed
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 480, height: 420)) // 强制锁定内容尺寸，防止被 NSHostingController 初始的 0x0 尺寸给拉瘪
        window.center() // 此时由于尺寸已被强制锁定为真实大小，这句系统级居中代码终于能完美生效了
        
        window.isReleasedWhenClosed = false // 交由 Controller 管理生命周期，防止闪退
        window.isRestorable = false // 彻底禁用 macOS 的窗口位置记忆功能，防止被强制恢复到之前的位置
        
        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = false // 防止被系统默认的叠放逻辑推到屏幕顶部
        self.newDocumentWindowController = wc
        
        // 确保在显示前清空可能存在的自动保存名
        window.setFrameAutosaveName("")
        
        wc.showWindow(nil)
    }
    
    // 拦截通过 Finder 双击 PDF 文件启动的事件
    func application(_ application: NSApplication, open urls: [URL]) {
        // Finder 的打开事件可晚于启动回调到达，不能留下一个多余的启动选择器。
        if !urls.isEmpty { Self.openPanel?.cancel(nil) }
        for url in urls {
            NSApp.openSwiftUIWindow(for: url)
        }
    }
    
    // 拦截 Cmd+Q (彻底退出程序) 的瞬间
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 不能在保存/打印确认尚未结束时嵌套第二次退出事务。
        guard !isTerminating, NSApp.modalWindow == nil else { return .terminateCancel }
        isTerminating = true
        defer { isTerminating = false }
        NotificationCenter.default.post(name: Notification.Name("FlushAIConversations"), object: nil)
        guard ConversationManager.shared.flush() else {
            let alert = NSAlert()
            alert.messageText = "对话尚未保存，已取消退出"
            alert.informativeText = "请检查存储位置和磁盘空间后重试。"
            alert.runModal()
            return .terminateCancel
        }
        // 通知状态引擎结算阅读进度。
        AppState.isAppExiting = true
        // 清理由于打开 PDF 产生的临时缓存权限签标
        
        // [新特性：Cmd+Q 强制落盘所有未保存文档，并持久化记录当前打开的窗口组]
        var savedGroups: [SavedGroup] = []
        var processedWindowIDs = Set<ObjectIdentifier>()
        let appWindows = WindowRegistry.shared.controllers.compactMap { $0.window }
        
        for window in appWindows {
            // 首先保存脏数据
            if let wc = window.windowController as? AppWindowController, let state = wc.appState, state.hasUnsavedChanges {
                guard state.save(sync: true) else {
                    AppState.isAppExiting = false
                    return .terminateCancel
                }
            }
            
            let winID = ObjectIdentifier(window)
            if processedWindowIDs.contains(winID) { continue }
            
            let tabs = WindowRegistry.shared.tabs(in: window)
            var urls: [String] = []
            
            for w in tabs {
                processedWindowIDs.insert(ObjectIdentifier(w))
                if let wc = w.windowController as? AppWindowController, let url = wc.appState?.fileURL {
                    urls.append(url.path)
                }
            }
            
            if !urls.isEmpty {
                let savedName = UserDefaults.standard.string(forKey: "CustomGroupName_\(tabs.first!.windowNumber)") ?? "未命名分组"
                savedGroups.append(SavedGroup(name: savedName, urls: urls))
            }
        }
        
        // 把空分组也存进去
        for emptyGroup in WindowRegistry.shared.emptyGroups {
            savedGroups.append(SavedGroup(name: emptyGroup.name, urls: []))
        }
        
        // 这些数据此前是纯异步写入，terminateNow 会让尚未开始的任务直接丢失。
        let recordsSaved = ReadingTracker.shared.saveAllRecords(sync: true)
        let authorsSaved = GlobalAuthorManager.shared.saveAuthors(sync: true)
        guard recordsSaved && authorsSaved else {
            AppState.isAppExiting = false
            let alert = NSAlert()
            alert.messageText = "阅读记录或作者库尚未保存，已取消退出"
            alert.informativeText = "请检查记录存储目录与磁盘空间后重试，内存中的修改已保留。"
            alert.runModal()
            return .terminateCancel
        }
        guard FocusSessionManager.shared.prepareForTermination() else {
            AppState.isAppExiting = false
            let alert = NSAlert()
            alert.messageText = FocusSessionManager.shared.text("Focus Save Before Quit")
            alert.informativeText = FocusSessionManager.shared.recorder.lastError ?? ""
            alert.runModal()
            return .terminateCancel
        }
        // 所有保存门槛通过后才提交退出元数据；取消退出保留现有权限与恢复信息。
        UserDefaults.standard.removeObject(forKey: "OpenedPDFBookmarks")
        if let data = try? JSONEncoder().encode(savedGroups) {
            UserDefaults.standard.set(data, forKey: "SavedWindowGroups")
        }
        return .terminateNow
    }
    
    // 拦截“关闭最后一个窗口后”的行为
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // 返回 false，关闭最后一个窗口不杀后台（这是标准 macOS 程序的规矩）
    }
}

class AppWindowController: NSWindowController {
    var appState: AppState?
    weak var uiState: UIState?
}

struct EmptyGroup: Identifiable, Codable {
    var id = UUID()
    var name: String = "未命名分组"
}

struct SavedGroup: Codable {
    let name: String
    let urls: [String]
}

/// [教程注释：自定义窗口池管理者]
/// 在 SwiftUI 结合 AppKit 时，由于 ARC（自动引用计数）的存在，
/// 自己创建的窗口一旦没有强引用就会被系统立马销毁。
/// 所以我们需要一个静态单例来“死死抱住”这些窗口。
class WindowRegistry: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = WindowRegistry()
    @Published var controllers: [NSWindowController] = []
    @Published var emptyGroups: [EmptyGroup] = []
    private var closingWindows = Set<ObjectIdentifier>()
    
    func add(_ controller: NSWindowController) {
        controllers.append(controller)
        controller.window?.delegate = self
    }

    /// tabbedWindows 在标签栏隐藏时会返回 nil，不能用来判断是否只剩一页。
    /// 关闭判断、管理面板与退出保存共用原生分组成员，不额外缓存窗口引用。
    func tabs(in window: NSWindow) -> [NSWindow] {
        window.tabGroup?.windows ?? [window]
    }
    
    // [新特性：拦截窗口/标签页关闭，未保存提示]
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let identity = ObjectIdentifier(sender)
        guard sender.attachedSheet == nil, closingWindows.insert(identity).inserted else { return false }
        defer { closingWindows.remove(identity) }
        if let wc = sender.windowController as? AppWindowController, let state = wc.appState {
            NotificationCenter.default.post(name: Notification.Name("FlushAIConversations"), object: state)
            guard ConversationManager.shared.flush() else {
                let alert = NSAlert()
                alert.messageText = "对话尚未保存，已取消关闭"
                alert.informativeText = "请检查存储位置和磁盘空间后重试。未保存的内容仍保留在内存中。"
                alert.runModal()
                return false
            }
            if state.hasUnsavedChanges {
                let alert = NSAlert()
                alert.messageText = "是否保存对文档的更改？"
                alert.informativeText = "如果不保存，您的更改将会丢失。"
                alert.addButton(withTitle: "保存")
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "不保存")
                
                let response = alert.runModal()
                
                if response == .alertFirstButtonReturn {
                    guard state.save(sync: true) else { return false }
                } else if response == .alertSecondButtonReturn {
                    return false
                }
            }
            
            // 保存弹窗可能运行嵌套事件循环；在最终关闭前读取实际成员。
            // 关闭普通标签不删除组，禁用窗口管理时也不显示组删除确认。
            if FeaturePreferences.shared.windowManagement, tabs(in: sender).count == 1 {
                let language = UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .zh
                let groupAlert = NSAlert()
                groupAlert.messageText = L.s("Delete This Group?", language)
                groupAlert.informativeText = L.s("Closing Window Removes Group", language)
                groupAlert.addButton(withTitle: L.s("Delete", language))
                groupAlert.addButton(withTitle: L.s("Cancel", language))
                
                let response = groupAlert.runModal()
                return response == .alertFirstButtonReturn
            }
        }
        
        return true
    }
    
    // 监听窗口被点击红叉关闭的事件
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            // 对比窗口没有 AppState.cleanup，也要主动卸下文档和预热缓存。
            // 原生视图可能被 AppKit 暂存，不能让它继续持有整本 PDF。
            if let view = (window.windowController as? CompareWindowController)?.pdfView {
                view.prepareForDocumentReplacement()
                view.document = nil
                view.removeFromSuperview()
            }
            if let wc = window.windowController as? AppWindowController, let state = wc.appState {
                state.cleanup()
            }
            
            window.delegate = nil
            // [极其重要的内存泄漏修复]
            DispatchQueue.main.async {
                // 确保无论是匹配上的，还是因为某种原因 window 已经变 nil 的游离 Controller，全部删掉！
                self.controllers.removeAll { $0.window === window || $0.window == nil }
                // 清空根视图引用，释放界面持有的文档及图像。
                window.contentViewController = nil
                
                // willClose 之后由 AppKit 完成关闭，不再次 close 产生重复通知。
            }
        }
    }
}

/// [教程注释：手动把 SwiftUI 的 View 包裹进 macOS 原生窗口]
extension NSApplication {
    @discardableResult
    func openSwiftUIWindow(for url: URL, independent: Bool = false) -> NSWindow {
        let contentView = ContentView(url: url)
        
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.isReleasedWhenClosed = true
        
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
        
        window.title = url.lastPathComponent
        window.contentViewController = hostingController
        
        if independent {
            window.tabbingMode = .disallowed
        } else {
            window.tabbingMode = .preferred
        }
        
        window.minSize = NSSize(width: 800, height: 600)
        
        let autosaveName = url.path
        window.setFrameAutosaveName(autosaveName)
        if window.setFrameUsingName(autosaveName) == false {
            window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: true)
            window.center()
        }
        
        let windowController = AppWindowController(window: window)
        WindowRegistry.shared.add(windowController)
        
        windowController.showWindow(nil)
        
        if independent {
            window.tabbingMode = .preferred
        }
        
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return window
    }
}
#endif
