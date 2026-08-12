import SwiftUI
#if os(macOS)
import AppKit

class HistoryWindowManager {
    static let shared = HistoryWindowManager()
    private var windowController: NSWindowController?
    
    func open() {
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
        
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        
        let wc = NSWindowController(window: window)
        self.windowController = wc
        wc.showWindow(nil)
    }
}
#endif
