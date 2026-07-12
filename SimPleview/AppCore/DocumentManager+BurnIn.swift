import SwiftUI
import PDFKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

extension DocumentManager {
    
    /// 将所有标注“烧录”进新 PDF 并保存
    /// 烧录意味着标注被绘制到了 PDF 页面图形上下文中，不再是独立的 Annotations
    func burnInAnnotations(pdfView: PDFView?) {
        #if os(macOS)
        guard let document = pdfView?.document, let originalURL = self.fileURL else { return }
        
        let panel = NSSavePanel()
        let originalName = originalURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(originalName)_burned.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Burn & Save"
        panel.message = "Choose location to save the flattened PDF"
        
        panel.begin { response in
            if response == .OK, let targetURL = panel.url {
                self.performBurnIn(document: document, targetURL: targetURL)
            }
        }
        #endif
    }
    
    private func performBurnIn(document: PDFDocument, targetURL: URL) {
        // PDFKit 文档正被 PDFView 使用，不能把它直接交给 detached task。
        // 先在主线程取得快照，后台只操作自己的 PDFDocument 副本。
        guard let documentData = document.dataRepresentation() else { return }
        Task.detached(priority: .userInitiated) {
            guard let safeDoc = PDFDocument(data: documentData) else { return }
            let tempURL = targetURL.deletingLastPathComponent()
                .appendingPathComponent(".SimPleview-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            // 我们需要拿到第一页的大小来初始化 CGContext，虽然页面可以改变大小，
            // 但 PDFKit 创建上下文时需要一个初始的 MediaBox。
            guard let firstPage = safeDoc.page(at: 0) else { return }
            var initialBox = firstPage.bounds(for: .mediaBox)
            
            guard let context = CGContext(tempURL as CFURL, mediaBox: &initialBox, nil) else { return }
            
            for i in 0..<safeDoc.pageCount {
                guard let page = safeDoc.page(at: i) else { continue }
                let mediaBox = page.bounds(for: .mediaBox)
                
                // 开启新的一页
                context.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: mediaBox)] as CFDictionary)
                
                // 1. 绘制底层原生的 PDF 页面（这会自动忽略所有批注）
                if let pageRef = page.pageRef {
                    context.saveGState()
                    // CGContext 的坐标系有时候和 PDFPage 不太一致，但 drawPDFPage 已经做了基本映射
                    // 不过这里不用管它，因为底层直接把 pageRef 画进去。
                    context.drawPDFPage(pageRef)
                    context.restoreGState()
                }
                
                // 2. 将所有的批注显式地“画”在 Context 上
                // 这就是烧录的过程：批注的图形流被融合进了底层的 PDF 图形上下文中
                for annot in page.annotations {
                    annot.draw(with: .mediaBox, in: context)
                }
                
                context.endPDFPage()
            }
            
            context.closePDF()
            
            // 将临时文件移动到用户指定的目录
            do {
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: targetURL)
                }
                
                // 可选：烧录完成后在 Finder 中显示
                #if os(macOS)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                }
                #endif
            } catch {
                print("Failed to save burned PDF: \(error)")
            }
        }
    }
}
