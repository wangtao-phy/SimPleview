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
        let inverse: UndoAction
        var affectedPages: Set<Int> = []
        var navigateTo: Int? = nil
    }

    private func performHistory(isUndo: Bool, in document: PDFDocument?, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void, onPageChange: (Int) -> Void) -> Bool {
        guard let document, let action = isUndo ? batchStack.last : redoStack.last,
              let change = applyHistoryAction(action, to: document) else { return false }
        finishHistory(isUndo: isUndo, inverse: change.inverse)
        if let index = change.navigateTo {
            onThumbnailUpdate(-1)
            onPageChange(index)
        } else {
            for index in change.affectedPages { onThumbnailUpdate(index) }
        }
        // 本次编辑只属于当前窗口；该入口同时更新其矢量快照，无需刷新所有窗口。
        pdfView?.setPlatformNeedsDisplay()
        if case .replaceInk = action, let view = pdfView as? CustomPDFView,
           let id = view.currentSelectedBatchID {
            let selected = change.affectedPages.compactMap { document.page(at: $0) }
                .flatMap { $0.annotations }.first { $0.userName == id }
            view.onAnnotationSelected?(selected)
        }
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
            removeFromSidebar(removed)
            return HistoryChange(inverse: .deleteAnnotation(annotations: removed, pageIndices: pageIndices), affectedPages: Set(pageIndices))

        case .deleteAnnotation(let annotations, let indices):
            guard !annotations.isEmpty, annotations.count == indices.count,
                  indices.allSatisfy({ (0..<document.pageCount).contains($0) }),
                  let batchID = annotations.first?.userName,
                  annotations.allSatisfy({ $0.userName == batchID }) else { return nil }
            for (annotation, index) in zip(annotations, indices) {
                document.page(at: index)?.addAnnotation(annotation)
            }
            for annotation in annotations { register(annotation, in: document) }
            return HistoryChange(inverse: .annotation(batchID: batchID, pageIndices: Set(indices)), affectedPages: Set(indices))

        case .replaceInk(let current, let previous, let index):
            guard let page = document.page(at: index), !current.isEmpty, !previous.isEmpty,
                  current.allSatisfy({ $0.page === page }), previous.allSatisfy({ $0.page == nil }) else { return nil }
            replaceInk(current, with: previous, on: page)
            return HistoryChange(inverse: .replaceInk(current: previous, previous: current, pageIndex: index), affectedPages: [index])

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

        case .rotatePages(let indices, let rotations):
            guard !indices.isEmpty, indices.count == rotations.count,
                  Set(indices).count == indices.count,
                  indices.allSatisfy({ (0..<document.pageCount).contains($0) }) else { return nil }
            let pages = indices.compactMap { document.page(at: $0) }
            guard pages.count == indices.count else { return nil }
            let previous = pages.map(\.rotation)
            for (page, rotation) in zip(pages, rotations) { page.rotation = rotation }
            return HistoryChange(inverse: .rotatePages(indices: indices, rotations: previous), affectedPages: Set(indices))

        case .movePages(let sources, let destinations):
            let count = sources.count
            guard count > 0, count == destinations.count,
                  Set(sources).count == count, Set(destinations).count == count,
                  (sources + destinations).allSatisfy({ (0..<document.pageCount).contains($0) }) else { return nil }
            let pages = sources.compactMap { document.page(at: $0) }
            guard pages.count == count else { return nil }
            // 先逆序移出，再按最终位置升序插入；交换两组索引即得到逆操作。
            for index in sources.sorted(by: >) { document.removePage(at: index) }
            for (page, index) in zip(pages, destinations).sorted(by: { $0.1 < $1.1 }) {
                document.insert(page, at: index)
            }
            return HistoryChange(inverse: .movePages(from: destinations, to: sources), navigateTo: destinations.min())
        }
    }

    /// 完成一次拖拽或执行历史时才替换标注；预览不改文档，不反复触发自动保存。
    func replaceInk(_ current: [PDFAnnotation], with replacement: [PDFAnnotation], on page: PDFPage) {
        guard let document = page.document else { return }
        for annotation in current { page.removeAnnotation(annotation) }
        for annotation in replacement { page.addAnnotation(annotation) }
        removeFromSidebar(current)
        for annotation in replacement { register(annotation, in: document) }
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

}
