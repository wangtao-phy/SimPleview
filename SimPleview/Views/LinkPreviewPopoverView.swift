import SwiftUI
import PDFKit
import AppKit

/// 图像由可重启的专属进程生成；独立裁剪 PDF 保留原生文字层，选择、复制
/// 交给 PDFView，不把已有文字重新交给系统 OCR，也不持有主阅读器的文档。
struct LinkPreviewPopoverView: NSViewRepresentable {
    let document: PDFDocument
    let preview: LinkPreviewRenderer.Preview

    func makeNSView(context: Context) -> LinkPreviewPDFView {
        let view = LinkPreviewPDFView(preview: preview, bounds: document.page(at: 0)?.bounds(for: .mediaBox) ?? .zero)
        view.displayMode = .singlePage
        view.displayBox = .mediaBox
        view.displaysPageBreaks = false
        view.backgroundColor = .white
        view.document = document
        view.autoScales = true
        return view
    }

    func updateNSView(_ view: LinkPreviewPDFView, context: Context) {}

    static func dismantleNSView(_ view: LinkPreviewPDFView, coordinator: ()) {
        view.clearSelection()
        view.document = nil
    }
}

/// PDFKit 的瓦片只显示已完成的图像，避免在弹窗内再次启动复杂页面解码。
/// 文本的坐标和复制内容仍来自同尺寸的原生 PDF，而非图片识别服务。
final class LinkPreviewPDFView: PDFView {
    nonisolated private let preview: LinkPreviewRenderer.Preview
    nonisolated private let pageBounds: CGRect

    init(preview: LinkPreviewRenderer.Preview, bounds: CGRect) {
        self.preview = preview
        pageBounds = bounds
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }

    nonisolated override func draw(_ page: PDFPage, to context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(pageBounds)
        context.draw(preview.image, in: pageBounds)
        context.restoreGState()
    }
}
