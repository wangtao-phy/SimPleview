import PDFKit

/// 只保存批次 ID 和页码，不强引用 PDFPage/PDFAnnotation。
/// 打开或结构变更后按需重建；普通改色、改备注和删除只访问实际涉及的页。
final class AnnotationBatchIndex {
    private weak var document: PDFDocument?
    private var pagesByBatch: [String: Set<Int>] = [:]

    func invalidate() {
        document = nil
        pagesByBatch.removeAll()
    }

    func rebuild(in document: PDFDocument) {
        pagesByBatch.removeAll(keepingCapacity: true)
        self.document = document
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let id = annotation.userName, id.hasPrefix("B-") {
                    pagesByBatch[id, default: []].insert(index)
                }
            }
        }
    }

    func pages(for annotation: PDFAnnotation, in document: PDFDocument) -> Set<Int> {
        guard let page = annotation.page, page.document === document else { return [] }
        let index = document.index(for: page)
        guard index != NSNotFound else { return [] }
        guard let id = annotation.userName, id.hasPrefix("B-") else { return [index] }
        if self.document !== document || pagesByBatch[id] == nil { rebuild(in: document) }
        return pagesByBatch[id] ?? [index]
    }
}
