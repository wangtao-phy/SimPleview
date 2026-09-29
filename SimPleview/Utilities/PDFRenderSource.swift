import Foundation
import PDFKit

/// 打开文件时的不可变字节只保留一份，正文预热与缩略图共用。
/// 只复用最初没有可见标注、且页面内容与几何未变的页面；编辑页仍取实时快照。
/// 以弱页面身份定位原始页码，重排、插页后不能按当前页码读取旧文件。
final class PDFRenderSource {
    private struct Original {
        weak var page: PDFPage?
        let index: Int
        let bounds: CGRect
        let rotation: Int
    }
    private weak var document: PDFDocument?
    private let data: Data
    private var originals: [ObjectIdentifier: Original] = [:]

    init(document: PDFDocument, data: Data) {
        self.document = document
        self.data = data
        guard !document.isEncrypted else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page.annotations.allSatisfy({ $0.type == "Link" && $0.border?.lineWidth == 0 }) else { continue }
            originals[ObjectIdentifier(page)] = Original(page: page, index: index,
                bounds: page.bounds(for: .cropBox), rotation: page.rotation)
        }
    }

    func snapshot(for page: PDFPage) -> PDFPageRenderInput? {
        guard let document, page.document === document, let original = originals[ObjectIdentifier(page)],
              original.page === page, page.annotations.allSatisfy({ $0.type == "Link" && $0.border?.lineWidth == 0 }),
              page.bounds(for: .cropBox) == original.bounds, page.rotation == original.rotation else { return nil }
        return PDFPageRenderInput(data: data, index: original.index)
    }
}

/// 后台只接收值，不接收活动文档的 PDFPage/CGPDFDocument。
nonisolated struct PDFPageRenderInput: Sendable {
    let data: Data
    let index: Int

    @MainActor static func capture(_ page: PDFPage, source: PDFRenderSource?) -> Self? {
        if let snapshot = source?.snapshot(for: page) { return snapshot }
        guard let data = StandardInk.exportData(of: page) else { return nil }
        return Self(data: data, index: 0)
    }
}
