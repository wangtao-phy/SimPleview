import AppKit
import PDFKit

extension CustomPDFView {
    /// 普通阅读模式：点击笔迹选择，框内拖动，四角缩放；文字选择和签名走原有入口。
    func trackInkTransform(with event: NSEvent, page: PDFPage, point: CGPoint) -> Bool {
        guard activeType == .none, let manager else { return false }
        let scale = max(scaleFactor, 0.1), inset: CGFloat = 8 / scale
        let candidates = page.annotations.filter(InkEditSession.canEdit)
        var selected = candidates.filter { currentSelectedBatchID != nil && $0.userName == currentSelectedBatchID }
        var corner: Int?
        var box = selected.reduce(CGRect.null) { $0.union($1.bounds) }
        if !selected.isEmpty {
            corner = InkEditSession.corners(box.insetBy(dx: -inset, dy: -inset)).firstIndex {
                hypot(point.x-$0.x, point.y-$0.y) <= 9 / scale
            }
        }
        if corner == nil && (selected.isEmpty || !box.contains(point)) {
            // 未选中时按实际描边命中，避免大面积空白选框吞掉 PDF 文字选择。
            guard let hit = candidates.reversed().first(where: { annotation in
                StandardInk.pagePaths(of: annotation).contains {
                    $0.cgPath.copy(strokingWithWidth: max(annotation.border?.lineWidth ?? 1, 8 / scale),
                                  lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
                }
            }) else { return false }
            selected = candidates.filter { $0 === hit || (hit.userName != nil && $0.userName == hit.userName) }
            box = selected.reduce(CGRect.null) { $0.union($1.bounds) }
        }
        guard !selected.isEmpty, !box.isNull, let window else { return false }
        clearSelection()
        currentSelectedBatchID = selected[0].userName
        onAnnotationSelected?(selected[0])
        currentPopover?.close()
        let session = InkEditSession(page: page, selected: selected)
        inkEditSession = session
        setNeedsDisplay(convert(box.insetBy(dx: -30/scale, dy: -30/scale), from: page))
        defer {
            inkEditSession = nil
            setNeedsDisplay(convert(box.union(box.applying(session.transform)).insetBy(dx: -30/scale, dy: -30/scale), from: page))
        }
        var finished = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            if next.type == .keyDown {
                if next.keyCode == 53 { break } // Escape 取消，不改文档或历史。
                continue
            }
            guard page.document === document, window.isVisible else { break }
            let current = convert(convert(next.locationInWindow, from: nil), to: page)
            if hypot(current.x-point.x, current.y-point.y) * scale >= 3 || !session.transform.isIdentity {
                let old = box.applying(session.transform)
                session.transform = InkEditSession.transform(bounds: box, start: point, end: current, corner: corner)
                setNeedsDisplay(convert(old.union(box.applying(session.transform)).insetBy(dx: -30/scale, dy: -30/scale), from: page))
            }
            if next.type == .leftMouseUp { finished = true; break }
        }
        guard finished, !session.transform.isIdentity, let document, page.document === document else { return true }
        do {
            let (old, replacement) = try session.replacements()
            let index = document.index(for: page)
            inkEditSession = nil
            manager.replaceInk(old, with: replacement, on: page)
            manager.record(.replaceInk(current: replacement, previous: old, pageIndex: index))
            onAnnotationSelected?(replacement.first { $0.userName == currentSelectedBatchID })
            onAnnotationPagesChanged?([index])
            onSaveRequired?()
        } catch {
            // 出错时旧标注仍在原页，取消预览即可完整恢复。
            NSAlert(error: error).beginSheetModal(for: window)
        }
        return true
    }
}
