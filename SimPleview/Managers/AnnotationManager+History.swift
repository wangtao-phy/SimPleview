import PDFKit

extension AnnotationManager {
    /// 两个历史栈共用同一执行入口：执行动作后，将它的逆操作放入另一侧。
    /// 验证失败不弹栈、不修改文档；列表与 PDF 在同一主执行器调用中更新。
    @discardableResult
    func undo(in document: PDFDocument?, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void, onPageChange: (Int) -> Void) -> Bool {
        performHistory(isUndo: true, in: document, pdfView: pdfView, onThumbnailUpdate: onThumbnailUpdate, onPageChange: onPageChange)
    }

    @discardableResult
    func redo(in document: PDFDocument?, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void, onPageChange: (Int) -> Void) -> Bool {
        performHistory(isUndo: false, in: document, pdfView: pdfView, onThumbnailUpdate: onThumbnailUpdate, onPageChange: onPageChange)
    }

    private struct HistoryChange {
        let inverse: UndoAction?
        var affectedPages: Set<Int> = []
        var navigateTo: Int? = nil
    }

    private func performHistory(isUndo: Bool, in document: PDFDocument?, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void, onPageChange: (Int) -> Void) -> Bool {
        guard let document, let action = isUndo ? batchStack.last : redoStack.last,
              let change = applyHistoryAction(action, to: document) else { return false }
        if isUndo {
            batchStack.removeLast()
            if let inverse = change.inverse { redoStack.append(inverse) } else { redoStack.removeAll() }
        } else {
            redoStack.removeLast()
            if let inverse = change.inverse { batchStack.append(inverse) } else { batchStack.removeAll() }
        }
        if let index = change.navigateTo {
            onThumbnailUpdate(-1)
            onPageChange(index)
        } else {
            for index in change.affectedPages { onThumbnailUpdate(index) }
        }
        // 本次编辑只属于当前窗口；该入口同时更新其矢量快照，无需刷新所有窗口。
        pdfView?.setPlatformNeedsDisplay()
        return true
    }

    private func applyHistoryAction(_ action: UndoAction, to document: PDFDocument) -> HistoryChange? {
        switch action {
        case .annotation(let batchID, let indices):
            guard !indices.isEmpty, indices.allSatisfy({ (0..<document.pageCount).contains($0) }) else { return nil }
            var removed: [PDFAnnotation] = []
            var pageIndices: [Int] = []
            for index in indices.sorted() {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations where annotation.userName == batchID {
                    // 移出页面即可隐藏，不修改 shouldDisplay；矢量手绘和签名需要
                    // 保留原生外观隐藏标志，否则重做会重新叠上 PDFKit 的模糊底图。
                    page.removeAnnotation(annotation)
                    removed.append(annotation)
                    pageIndices.append(index)
                }
            }
            guard !removed.isEmpty else { return nil }
            let removedSet = Set(removed)
            allAnnotations.removeAll { removedSet.contains($0) }
            return HistoryChange(inverse: .deleteAnnotation(annotations: removed, pageIndices: pageIndices), affectedPages: Set(pageIndices))

        case .deleteAnnotation(let annotations, let indices):
            guard !annotations.isEmpty, annotations.count == indices.count,
                  indices.allSatisfy({ (0..<document.pageCount).contains($0) }),
                  let batchID = annotations.first?.userName,
                  annotations.allSatisfy({ $0.userName == batchID }) else { return nil }
            for (annotation, index) in zip(annotations, indices) {
                document.page(at: index)?.addAnnotation(annotation)
            }
            insertRestoredAnnotations(annotations)
            return HistoryChange(inverse: .annotation(batchID: batchID, pageIndices: Set(indices)), affectedPages: Set(indices))

        case .deletePage(let page, let index):
            return restorePages([page], at: [index], in: document)

        case .deletePages(let pages, let indices):
            return restorePages(pages, at: indices, in: document)

        case .insertPages(let count, let start):
            guard start >= 0, start <= document.pageCount, count > 0,
                  count <= document.pageCount - start else { return nil }
            return removePages(at: Array(start..<(start + count)), in: document)

        case .removePages(let indices):
            return removePages(at: indices, in: document)

        case .reorderPages(let originalIndices, let insertedAt):
            let count = originalIndices.count
            guard count > 0, insertedAt >= 0, insertedAt <= document.pageCount,
                  Set(originalIndices).count == count,
                  originalIndices.allSatisfy({ (0..<document.pageCount).contains($0) }) else { return nil }
            let offset = originalIndices.filter { $0 < insertedAt }.count
            let start = max(0, min(insertedAt - offset, document.pageCount - count))
            let pages = (start..<(start + count)).compactMap { document.page(at: $0) }
            guard pages.count == count else { return nil }
            for _ in pages { document.removePage(at: start) }
            for (page, index) in zip(pages, originalIndices).sorted(by: { $0.1 < $1.1 }) {
                document.insert(page, at: index)
            }
            // 沿用原有约定：重排可撤销，撤销后清空重做栈。
            return HistoryChange(inverse: nil, navigateTo: originalIndices.min())
        }
    }

    private func restorePages(_ pages: [PDFPage], at indices: [Int], in document: PDFDocument) -> HistoryChange? {
        guard !pages.isEmpty, pages.count == indices.count, Set(indices).count == indices.count else { return nil }
        let ordered = zip(pages, indices).sorted { $0.1 < $1.1 }
        // 在修改前检查所有位置，避免中途发现无效索引留下半次操作。
        guard ordered.enumerated().allSatisfy({ offset, item in
            item.1 >= 0 && item.1 <= document.pageCount + offset
        }) else { return nil }
        for (page, index) in ordered { document.insert(page, at: index) }
        // 记录真实页码，不能将非连续的恢复页面误写成一个连续区间。
        return HistoryChange(inverse: .removePages(indices: indices), navigateTo: indices.min())
    }

    private func removePages(at indices: [Int], in document: PDFDocument) -> HistoryChange? {
        guard !indices.isEmpty, Set(indices).count == indices.count,
              indices.allSatisfy({ (0..<document.pageCount).contains($0) }) else { return nil }
        let sorted = indices.sorted()
        let pages = sorted.compactMap { document.page(at: $0) }
        guard pages.count == sorted.count else { return nil }
        for index in sorted.reversed() { document.removePage(at: index) }
        return HistoryChange(inverse: .deletePages(pages: pages, indices: sorted), navigateTo: sorted.first)
    }

    private func insertRestoredAnnotations(_ annotations: [PDFAnnotation]) {
        for annotation in annotations {
            let id = annotation.userName ?? ""
            // 多行手绘/高亮只保留一个侧栏代表，普通外部标注按对象身份区分。
            guard !allAnnotations.contains(where: {
                $0 === annotation || (id.hasPrefix("B-") && $0.userName == id)
            }) else { continue }
            let key = Self.annotationSortKey(annotation)
            let index = allAnnotations.firstIndex { key < Self.annotationSortKey($0) } ?? allAnnotations.endIndex
            allAnnotations.insert(annotation, at: index)
        }
    }
}
