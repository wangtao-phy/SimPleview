import SwiftUI
#if os(macOS)
import AppKit

class AuthorsWindowManager {
    static let shared = AuthorsWindowManager()
    private var windowController: NSWindowController?
    
    func open() {
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
        
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        
        let wc = NSWindowController(window: window)
        self.windowController = wc
        wc.showWindow(nil)
    }
}
#endif
