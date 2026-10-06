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
    private var originalPages: [Original] = []

    init(document: PDFDocument, data: Data) {
        self.document = document
        self.data = data
        guard !document.isEncrypted else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let original = Original(page: page, index: index,
                bounds: page.bounds(for: .cropBox), rotation: page.rotation)
            originalPages.append(original)
            if page.annotations.allSatisfy({ $0.type == "Link" && $0.border?.lineWidth == 0 }) {
                originals[ObjectIdentifier(page)] = original
            }
        }
    }

    /// PDFKit 搜索页面文字，不搜索标注内容。仅增删标注时可共用原始字节；
    /// 页面身份、顺序、裁剪框或旋转改变时必须使用当前文档快照。
    /// 弱引用不延长页面寿命，此校验由搜索管理器按编辑版本执行一次。
    func searchData(for current: PDFDocument) -> Data? {
        guard current === document, current.pageCount == originalPages.count else { return nil }
        for original in originalPages {
            guard let page = original.page, current.page(at: original.index) === page,
                  page.rotation == original.rotation,
                  page.bounds(for: .cropBox) == original.bounds else { return nil }
        }
        return data
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
