import AppKit
import PDFKit
import PencilKit

/// 一次鼠标操作持有原始几何。拖动只改变预览矩阵，松开才编解码、替换标注。
/// 旧标注留给撤销栈，避免连续拖动积累舍入误差或破坏原生笔迹附件。
@MainActor final class InkEditSession {
    let page: PDFPage
    let selected: [PDFAnnotation]
    let bounds: CGRect
    var transform = CGAffineTransform.identity

    init(page: PDFPage, selected: [PDFAnnotation]) {
        self.page = page; self.selected = selected
        bounds = selected.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    static func canEdit(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Ink" && StandardInk.isAppInk(annotation) &&
            !(annotation.userName ?? "").hasPrefix("S-") &&
            (annotation.shouldDisplay || StandardInk.isScreenHidden(annotation))
    }

    static func corners(_ rect: CGRect) -> [CGPoint] {
        [rect.origin, CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    /// 拖角在对角线方向上的投影决定等比缩放，横向、纵向拖动都有效。
    static func transform(bounds: CGRect, start: CGPoint, end: CGPoint, corner: Int?) -> CGAffineTransform {
        guard let corner else { return CGAffineTransform(translationX: end.x-start.x, y: end.y-start.y) }
        let points = corners(bounds), anchor = points[3-corner], handle = points[corner]
        let vx = handle.x-anchor.x, vy = handle.y-anchor.y, length = vx*vx+vy*vy
        guard length > 0 else { return .identity }
        let scale = min(50, max(0.05, 1 + ((end.x-start.x)*vx + (end.y-start.y)*vy)/length))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: anchor.x * (1-scale), ty: anchor.y * (1-scale))
    }

    func replacements() throws -> (originals: [PDFAnnotation], replacements: [PDFAnnotation]) {
        let peers = page.annotations, crop = page.bounds(for: .cropBox)
        let groups = Set(selected.compactMap { $0.value(forAnnotationKey: VectorInk.groupKey) as? String })
        // 原生附件每组只保存一次。编辑其中一笔时重写同组附件，未选中的笔迹
        // 保持原控制点；不能删掉附件所在的第一笔，让其余笔迹丢失原生编辑数据。
        let originals = peers.filter { annotation in
            selected.contains(annotation) || (annotation.type == "Ink" &&
                (annotation.value(forAnnotationKey: VectorInk.groupKey) as? String).map(groups.contains) == true)
        }
        let native = VectorInk.nativeOriginals(in: peers, bounds: crop)
        var strokes: [PKStroke] = [], owners: [PDFAnnotation] = []
        let toPage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: crop.minX, ty: crop.maxY)
        let nativeTransform = toPage.concatenating(transform).concatenating(toPage.inverted())
        for source in originals {
            guard let drawing = VectorInk.editableDrawing(for: source, originals: native, bounds: crop), !drawing.strokes.isEmpty else {
                throw VectorInk.Failure.message("此笔迹无法完整恢复，已保留原标注。")
            }
            let result = selected.contains(source) ? VectorInk.transformed(drawing, by: nativeTransform) : drawing
            strokes += result.strokes
            owners += Array(repeating: source, count: result.strokes.count)
        }
        let replacement = try VectorInk.annotations(drawing: PKDrawing(strokes: strokes), bounds: crop)
        guard replacement.count == owners.count else { throw VectorInk.Failure.message("笔迹数量校验失败，已保留原标注。") }
        for (annotation, owner) in zip(replacement, owners) {
            annotation.userName = owner.userName
            annotation.contents = owner.contents
            let subject = PDFAnnotationKey(rawValue: "/Subj")
            if let note = owner.value(forAnnotationKey: subject) as? String { annotation.setValue(note, forAnnotationKey: subject) }
            annotation.modificationDate = selected.contains(owner) ? Date() : owner.modificationDate
            // 保留外部软件设置的隐藏/打印标志；Mac 屏幕专用 Hidden 位不能写进文件。
            let flagsKey = StandardInk.isScreenHidden(owner)
                ? PDFAnnotationKey(rawValue: "/SimPleInkOriginalFlags") : .flags
            if let flags = owner.value(forAnnotationKey: flagsKey) as? NSNumber {
                annotation.setValue(flags, forAnnotationKey: .flags)
            }
            StandardInk.prepareForScreen(annotation)
        }
        return (originals, replacement)
    }
}
