import AppKit
import PDFKit

extension CustomPDFView {
    /// 单独命中链接，避免后来加的高亮标注挡住其下方的原始链接。
    func internalLink(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.reversed().first {
            $0.type == "Link" && $0.bounds.contains(point) && $0.url == nil && !($0.action is PDFActionURL)
        }
    }

    /// 预览与点击共用当前文档中的目标；不把 Fit/XYZ 的空坐标哨兵传给滚动引擎。
    func linkDestination(for annotation: PDFAnnotation) -> PDFDestination? {
        guard let document, annotation.page?.document === document else { return nil }
        for candidate in [annotation.destination, (annotation.action as? PDFActionGoTo)?.destination].compactMap({ $0 }) {
            guard let page = candidate.page, page.document === document else { continue }
            let bounds = page.bounds(for: .cropBox), point = candidate.point
            guard !bounds.isEmpty, bounds.minX.isFinite, bounds.maxX.isFinite,
                  bounds.minY.isFinite, bounds.maxY.isFinite else { continue }
            let x = point.x.isFinite && (bounds.minX...bounds.maxX).contains(point.x) ? point.x : bounds.minX
            let y = point.y.isFinite && (bounds.minY...bounds.maxY).contains(point.y) ? point.y : bounds.maxY
            let destination = PDFDestination(page: page, at: CGPoint(x: x, y: y))
            if candidate.zoom.isFinite && candidate.zoom > 0 { destination.zoom = candidate.zoom }
            return destination
        }
        return nil
    }

    func resetLinkPreview() {
        // 滚动会频繁经过这里。没有悬停状态时，不触发同步快照或局部重绘。
        guard hoverTask != nil || hoverPopover != nil || currentHoveredLink != nil || isHoveringLinkPreview else { return }
        hoverTask?.cancel(); hoverTask = nil
        let old = hoverPopover
        hoverPopover = nil
        isHoveringLinkPreview = false
        updateHoveredLink(nil)
        // 关闭承载视图会取消 SwiftUI .task，进而结束专属预览进程。
        old?.close()
        old?.contentViewController = nil
    }

    /// 点击直接跳转，不等待预览或文字识别；拖离链接则取消本次点击。
    func trackInternalLink(_ annotation: PDFAnnotation, on page: PDFPage) -> Bool {
        guard linkDestination(for: annotation) != nil, let window else { return false }
        resetLinkPreview()
        clearSelection()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            guard annotation.page === page, page.document === document else { return true }
            if next.type == .leftMouseUp {
                let point = convert(convert(next.locationInWindow, from: nil), to: page)
                if annotation.bounds.contains(point), let destination = linkDestination(for: annotation) {
                    go(to: destination)
                }
                return true
            }
        }
        return true
    }
}
