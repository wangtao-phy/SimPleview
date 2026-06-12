#if os(macOS)
import AppKit
import Quartz

class QuickLookHelper: NSObject, NSSharingServiceDelegate {
    static let shared = QuickLookHelper()
    var url: URL?
    
    func openMarkupService(for url: URL, document: PDFDocument?) {
        self.url = url
        
        // [极度关键]：在弹出底层的 Markup 面板之前，我们必须强制把当前内存里的 PDFDocument 写回硬盘！
        // 否则如果用户刚才在 App 里删除了某个批注但还没按 Cmd+S 保存，
        // 弹出的独立面板读取的是旧的硬盘文件，就会导致“删掉的批注还在”的幽灵现象！
        if let doc = document {
            doc.write(to: url)
        }
        
        // 恢复使用 NSSharingService 弹出底层的 Markup 面板
        if let service = NSSharingService(named: NSSharingService.Name(rawValue: "com.apple.MarkupUI.Markup")) {
            service.delegate = self
            service.perform(withItems: [url])
        }
    }
    
    // MARK: - NSSharingServiceDelegate
    
    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        // 从屏幕正中央弹出
        if let screen = NSScreen.main {
            let width: CGFloat = 1200
            let height: CGFloat = 800
            return NSRect(x: screen.frame.midX - width / 2, 
                          y: screen.frame.midY - height / 2, 
                          width: width, height: height)
        }
        return .zero
    }
    
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard let targetURL = self.url else { return }
        
        for item in items {
            if let data = item as? Data {
                try? data.write(to: targetURL, options: .atomic)
            } else if let url = item as? URL {
                do {
                    let data = try Data(contentsOf: url)
                    try data.write(to: targetURL, options: .atomic)
                } catch {}
            } else if let provider = item as? NSItemProvider {
                // 如果系统返回的是 NSItemProvider（通常用于沙盒环境下的安全数据交换）
                // 我们请求它的 PDF 数据表示形式
                provider.loadDataRepresentation(forTypeIdentifier: "com.adobe.pdf") { data, error in
                    if let modifiedData = data {
                        DispatchQueue.main.async {
                            try? modifiedData.write(to: targetURL, options: .atomic)
                            // 此时 FileMonitor 会自动监听到硬盘文件变化并触发热重载
                        }
                    } else if let err = error {
                        print("Failed to load data from NSItemProvider: \(err.localizedDescription)")
                    }
                }
            }
        }
    }
}
#endif
