import UniformTypeIdentifiers

import SwiftUI
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
    
    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        // 斩断强引用循环：我们不捕获结构体 self，而是捕获轻量级的 Binding 和弱引用的 state
        let windowBinding = $window
        view.onWindow = { [weak state] newWindow in
            DispatchQueue.main.async {
                windowBinding.wrappedValue = newWindow
                state?.hostingWindow = newWindow
                if let wc = newWindow?.windowController as? AppWindowController, let state = state {
                    wc.appState = state
                }
                
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
    
    // 新增：保持对新建窗口的强引用，防止闪退或自动销毁异常
    var newDocumentWindowController: NSWindowController?
    
    // App 完全启动后的回调
    func applicationDidFinishLaunching(_ notification: Notification) {
        // [静态挂载 Method Swizzling]
        let _ = PDFAnnotation.swizzleDrawMethod
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("GlobalNewDocument"), object: nil, queue: .main) { _ in
            self.openNewDocumentDialog()
        }
        
        // [逻辑流程]
        // 由于我们没有默认窗口，启动后如果发现没有任何可见的文档窗口，就自动弹出一个文件选择器（NSOpenPanel）。
        // 使用 DispatchQueue.main.async 确保是在下一个事件循环弹出，不阻塞系统绘制。
        DispatchQueue.main.async {
            let hasDocumentWindows = NSApp.windows.contains { $0.titleVisibility == .hidden }
            
            // [新特性：恢复上次强退或正常退出前打开的窗口]
            if let savedURLs = UserDefaults.standard.stringArray(forKey: "SavedOpenWindows"), !savedURLs.isEmpty {
                var restoredAny = false
                for path in savedURLs {
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: path) {
                        NSApp.openSwiftUIWindow(for: url)
                        restoredAny = true
                    }
                }
                // 恢复完毕后清空，避免干扰下次正常打开
                UserDefaults.standard.removeObject(forKey: "SavedOpenWindows")
                if restoredAny {
                    return // 成功恢复了老窗口，不再弹出空文件选择器
                }
            }
            
            if !hasDocumentWindows {
                _ = self.applicationShouldOpenUntitledFile(NSApp)
            }
        }
    }
    
    // 用户点击 Dock 栏图标（应用如果已经在后台运行）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            _ = applicationShouldOpenUntitledFile(sender)
        }
        return true
    }
    
    // 拦截“打开无标题新文件”（Cmd+N）
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType.pdf, UTType.image]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                NSApp.openSwiftUIWindow(for: url)
            }
        }
        return false // 返回 false 阻止系统自动生成一个傻乎乎的空白窗口
    }
    
    // 打开“新建文档”弹窗
    func openNewDocumentDialog() {
        // 防止打开多个
        if let wc = newDocumentWindowController, let window = wc.window, window.isVisible {
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
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false // 交由 Controller 管理生命周期，防止闪退
        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = false // 防止被系统默认的叠放逻辑推到屏幕顶部
        self.newDocumentWindowController = wc
        window.center() // 恢复原生居中代码
        wc.showWindow(nil)
    }
    
    // 拦截通过 Finder 双击 PDF 文件启动的事件
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NSApp.openSwiftUIWindow(for: url)
        }
    }
    
    // 拦截 Cmd+Q (彻底退出程序) 的瞬间
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 通知我们的状态引擎：程序要挂了，赶紧保存阅读进度！
        AppState.isAppExiting = true
        // 清理由于打开 PDF 产生的临时缓存权限签标
        UserDefaults.standard.removeObject(forKey: "OpenedPDFBookmarks")
        
        // [新特性：Cmd+Q 强制落盘所有未保存文档，并持久化记录当前打开的窗口]
        var openURLs: [String] = []
        for controller in WindowRegistry.shared.controllers {
            if let wc = controller as? AppWindowController, let state = wc.appState {
                if state.isDirty {
                    state.save(sync: true) // 强制同步保存
                }
                if let url = state.fileURL {
                    openURLs.append(url.path)
                }
            }
        }
        
        // 将最后还在看的文件路径持久化到磁盘，以便下次启动满血复活
        UserDefaults.standard.set(openURLs, forKey: "SavedOpenWindows")
        // 这些数据此前是纯异步写入，terminateNow 会让尚未开始的任务直接丢失。
        ReadingTracker.shared.saveAllRecords(sync: true)
        GlobalAuthorManager.shared.saveAuthors(sync: true)
        
        return .terminateNow
    }
    
    // 拦截“关闭最后一个窗口后”的行为
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // 返回 false，关闭最后一个窗口不杀后台（这是标准 macOS 程序的规矩）
    }
}

class AppWindowController: NSWindowController {
    var appState: AppState?
}

/// [教程注释：自定义窗口池管理者]
/// 在 SwiftUI 结合 AppKit 时，由于 ARC（自动引用计数）的存在，
/// 自己创建的窗口一旦没有强引用就会被系统立马销毁。
/// 所以我们需要一个静态单例来“死死抱住”这些窗口。
class WindowRegistry: NSObject, NSWindowDelegate {
    static let shared = WindowRegistry()
    var controllers: [NSWindowController] = []
    
    func add(_ controller: NSWindowController) {
        controllers.append(controller)
        controller.window?.delegate = self
    }
    
    // [新特性：拦截窗口/标签页关闭，未保存提示]
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 提取该窗口的底层引擎
        if let wc = sender.windowController as? AppWindowController, let state = wc.appState {
            // 如果内容有变动，跳出原生警告对话框
            if state.isDirty {
                let alert = NSAlert()
                // 使用极其优雅的 Mac 原生提示语
                alert.messageText = "是否保存对文档的更改？"
                alert.informativeText = "如果不保存，您的更改将会丢失。"
                alert.addButton(withTitle: "保存")
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "不保存")
                
                // 为了完美兼容多窗口并发情况，我们将 Alert 作为 Sheet 挂载在当前窗口上
                // 但如果嫌麻烦，直接 runModal 也是标准做法，会阻塞当前 UI 线程等待用户选择
                let response = alert.runModal()
                
                if response == .alertFirstButtonReturn {
                    // 用户选择“保存”
                    // 窗口随后会销毁 PDFView；必须在允许关闭前完成写入。
                    state.save(sync: true)
                    return true
                } else if response == .alertSecondButtonReturn {
                    // 用户选择“取消”，阻止关闭
                    return false
                } else if response == .alertThirdButtonReturn {
                    // 用户选择“不保存”，不作处理直接放行
                    return true
                }
            }
        }
        return true
    }
    
    // 监听窗口被点击红叉关闭的事件
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if let wc = window.windowController as? AppWindowController, let state = wc.appState {
                
                // 【终极斩杀】：拔掉 PDF 引擎
                state.cleanup()
                
                // 触发智能保存
                if let url = state.fileURL {
                    state.autoTagDocumentIfCompleted(url: url)
                }
                for doc in state.documents {
                    state.autoTagDocumentIfCompleted(url: doc.url)
                }
            }
            
            window.delegate = nil
            // [极其重要的内存泄漏修复]
            DispatchQueue.main.async {
                // 确保无论是匹配上的，还是因为某种原因 window 已经变 nil 的游离 Controller，全部删掉！
                self.controllers.removeAll { $0.window === window || $0.window == nil }
                // 清空根视图引用，强制打破循环，并触发底层 NSWindow 彻底释放图形缓存（IOSurface）
                window.contentViewController = nil
                
                // [强制释放窗口]
                window.close()
            }
        }
    }
}

/// [教程注释：手动把 SwiftUI 的 View 包裹进 macOS 原生窗口]
extension NSApplication {
    func openSwiftUIWindow(for url: URL) {
        let contentView = ContentView(url: url)
        
        // 使用 NSHostingController 作为 SwiftUI 和原生 AppKit 的“桥梁”
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        // 关键修复：恢复 AppKit 默认的闭窗即释放行为
        // 之前设置为 false 是怕跟 WindowRegistry 冲突，但 false 会导致即使我们移除了引用，
        // 底层 NSApp.windows 仍有可能扣留它作为隐藏窗口。设为 true 能确保内存层面的彻底销毁！
        window.isReleasedWhenClosed = true
        
        // UI 魔法：透明标题栏，让应用看起来极度现代化
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
        
        window.title = url.lastPathComponent
        window.contentViewController = hostingController
        
        // 多标签页行为支持（是否在同一个窗口内以 Tab 形式打开新 PDF）
        let useTab = UserDefaults.standard.bool(forKey: "openInTab")
        window.tabbingMode = useTab ? .preferred : .disallowed
        
        // 防止用户把窗口缩得太小导致 UI 崩溃错位
        window.minSize = NSSize(width: 800, height: 600)
        
        // [逻辑流程：记忆窗口位置]
        // 每次我们都把文件的完整路径作为窗口的“存档名字”。系统下次打开这个文件时，会自动恢复到上次放置的屏幕坐标。
        let autosaveName = url.path
        window.setFrameAutosaveName(autosaveName)
        if window.setFrameUsingName(autosaveName) == false {
            window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: true)
            window.center()
        }
        
        let windowController = AppWindowController(window: window)
        WindowRegistry.shared.add(windowController)
        
        windowController.showWindow(nil)
        
        // 把这个文件加入到苹果原生的“最近打开”历史列表中
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}
#endif
