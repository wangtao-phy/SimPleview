import SwiftUI
#if os(macOS)
import AppKit

/// [教程注释：历史记录窗口大内总管]
/// 这个类用于独立管理历史记录窗口的生命周期。为了避免 SwiftUI 场景的自动弹出 bug，我们采用了原生的 NSWindow。
class HistoryWindowManager {
    static let shared = HistoryWindowManager()
    private var windowController: NSWindowController?
    private var closeObserver: NSObjectProtocol?
    
    func open() {
        // 如果窗口已经打开了，那么就让它激活并置于前台
        if let wc = windowController, let window = wc.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = HistoryWindowView()
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.title = SimPleview.L.s("History", UserDefaults.standard.string(forKey: "appLanguage") == "en" ? .en : .zh)
        
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 800, height: 600))
        window.center()
        
        // 关闭时释放窗口资源（避免常驻内存）；下次 open 会重新创建
        window.isReleasedWhenClosed = true
        // 彻底禁用 macOS 烦人的窗口位置记忆
        window.isRestorable = false
        
        let wc = NSWindowController(window: window)
        self.windowController = wc
        
        // 窗口关闭时释放 windowController 引用，让窗口与视图树真正释放内存
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.windowController = nil
        }
        
        wc.showWindow(nil)
    }
}
#endif
