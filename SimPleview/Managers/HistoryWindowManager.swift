import SwiftUI
#if os(macOS)
import AppKit

/// [教程注释：历史记录窗口大内总管]
/// 这个类用于独立管理历史记录窗口的生命周期。为了避免 SwiftUI 场景的自动弹出 bug，我们采用了原生的 NSWindow。
class HistoryWindowManager {
    static let shared = HistoryWindowManager()
    private var windowController: NSWindowController?
    
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
        
        // 将生命周期交还给 Manager 避免崩溃
        window.isReleasedWhenClosed = false
        // 彻底禁用 macOS 烦人的窗口位置记忆
        window.isRestorable = false
        
        let wc = NSWindowController(window: window)
        self.windowController = wc
        wc.showWindow(nil)
    }
}
#endif
