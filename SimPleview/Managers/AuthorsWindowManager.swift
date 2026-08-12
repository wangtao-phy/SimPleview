import SwiftUI
#if os(macOS)
import AppKit

/// [教程注释：全局作者库窗口大内总管]
/// 独立管理“全局作者库”独立窗口生命周期。采用原生的 NSWindow。
class AuthorsWindowManager {
    static let shared = AuthorsWindowManager()
    private var windowController: NSWindowController?
    
    func open() {
        // 如果窗口已经打开了，那么就让它激活并置于前台
        if let wc = windowController, let window = wc.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        
        let appLanguage: AppLanguage = UserDefaults.standard.string(forKey: "appLanguage") == "en" ? .en : .zh
        let title = SimPleview.L.s("Global Authors Library", appLanguage)
        
        // Use GlobalAuthorsSettingsView directly but supply the LS closure
        let view = GlobalAuthorsSettingsView { key in
            return SimPleview.L.s(key, appLanguage)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
        
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.title = title
        
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
