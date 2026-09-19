import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import os

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
        guard let documentData = StandardInk.exportData(of: document) else { return }
        Task.detached(priority: .userInitiated) {
            let accessing = targetURL.startAccessingSecurityScopedResource()
            defer { if accessing { targetURL.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Self.burnInData(documentData)
                // 原子写入失败保留已有目标文件，不把半成品当作导出成功。
                try data.write(to: targetURL, options: .atomic)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([targetURL]) }
            } catch {
                await MainActor.run { _ = NSAlert(error: error).runModal() }
            }
        }
    }

    /// 只接收不可变数据，在调用方的后台执行器中解析独立 PDF。
    /// 每页独立设置尺寸，并将旋转落入绘图变换；页面和标注始终保持矢量。
    nonisolated static func burnInData(_ data: Data) throws -> Data {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var expectedSizes: [CGSize] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let reference = page.pageRef else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let transform = page.transform(for: .mediaBox)
            let bounds = page.bounds(for: .mediaBox).applying(transform).standardized
            guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
                  bounds.width > 0, bounds.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
            var box = CGRect(origin: .zero, size: bounds.size)
            // kCGPDFContextMediaBox 要求 CGRect 的二进制 CFData，不能传 NSValue。
            let media = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: media] as CFDictionary)
            context.saveGState()
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.saveGState()
            context.concatenate(transform)
            context.drawPDFPage(reference)
            context.restoreGState()
            // PDFAnnotation.draw 会应用所属页的旋转；只给原始 CGPDFPage
            // 额外乘页面变换，不能让标注被旋转两次。
            for annotation in page.annotations {
                annotation.draw(with: .mediaBox, in: context)
            }
            context.restoreGState()
            context.endPDFPage()
            expectedSizes.append(box.size)
        }
        context.closePDF()
        guard let verification = PDFDocument(data: output as Data), verification.pageCount == document.pageCount else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (index, size) in expectedSizes.enumerated() {
            guard let page = verification.page(at: index) else { throw CocoaError(.fileWriteUnknown) }
            let actual = page.bounds(for: .mediaBox).size
            guard abs(actual.width - size.width) < 0.01, abs(actual.height - size.height) < 0.01 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return output as Data
    }
}
