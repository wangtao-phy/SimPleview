import UIKit
import PencilKit

/// 长按笔迹后显示选择框：拖动框内移动，拖动四角等比缩放。
/// 坐标与 PDF 页上的 PencilKit 笔迹一致；变形仍保存为原生矢量笔画。
@MainActor final class InkTransformView: UIView, UIGestureRecognizerDelegate {
    weak var canvas: PKCanvasView?
    var onBegin: (() -> Void)?
    var onCommit: ((PKDrawing, PKDrawing) -> Void)?
    var onCancel: (() -> Void)?
    var onMenu: ((CGRect) -> Void)?
    private let border = CAShapeLayer()
    private let handle = CAShapeLayer()
    private var selected: [Int] = []
    private var original: PKDrawing?
    private var start = CGPoint.zero
    private var originalBounds = CGRect.null
    private var resizing: Int?
    private var appliedTransform: CGAffineTransform?
    private var screenScale: CGFloat {
        let unit = convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: window)
        return max(0.1, unit.width)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        border.strokeColor = UIColor.systemBlue.cgColor; border.fillColor = UIColor.clear.cgColor
        handle.strokeColor = UIColor.white.cgColor; handle.fillColor = UIColor.systemBlue.cgColor
        layer.addSublayer(border); layer.addSublayer(handle)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(transformStroke(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(showMenu))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews(); refreshSelection() }
    func reset() {
        if let original { canvas?.drawing = original; onCancel?() }
        original = nil; selected = []; refreshSelection()
    }
    private var selectedBounds: CGRect {
        guard let strokes = canvas?.drawing.strokes else { return .null }
        return selected.filter { strokes.indices.contains($0) }.reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }
    }
    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    private func handleCenters(in rect: CGRect, scale: CGFloat) -> [CGPoint] {
        guard !rect.isNull else { return [] }
        let inset = min(22 / scale, min(bounds.width, bounds.height) / 2)
        let safe = bounds.insetBy(dx: inset, dy: inset)
        // 贴近页边的手柄向页内让出命中区，避免被 PDFKit 的页覆盖视图裁掉。
        return corners(of: rect).map {
            CGPoint(x: min(safe.maxX, max(safe.minX, $0.x)), y: min(safe.maxY, max(safe.minY, $0.y)))
        }
    }
    private func resizeHandle(at point: CGPoint) -> Int? {
        let scale = screenScale
        let centers = handleCenters(in: selectedBounds, scale: scale)
        guard let index = centers.indices.min(by: {
            hypot(point.x - centers[$0].x, point.y - centers[$0].y)
                < hypot(point.x - centers[$1].x, point.y - centers[$1].y)
        }) else { return nil }
        let center = centers[index], radius = 22 / scale
        return abs(point.x - center.x) <= radius && abs(point.y - center.y) <= radius ? index : nil
    }

    func refreshSelection() {
        // 一次刷新只读取一次笔迹边界和屏幕倍率；避免手柄布局反复遍历笔迹。
        let rect = selectedBounds, scale = screenScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        border.lineWidth = 1.5 / scale
        border.lineDashPattern = [4, 3]
        border.path = rect.isNull ? nil : CGPath(rect: rect, transform: nil)
        handle.lineWidth = 1 / scale
        let handles = CGMutablePath(), side = 14 / scale
        for center in handleCenters(in: rect, scale: scale) {
            handles.addEllipse(in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        }
        handle.path = handles
        CATransaction.commit()
    }
    /// 外框内的空白可用于拖动；框外必须透传给 PDFKit 的滚动和选字。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        resizeHandle(at: point) != nil || selectedBounds.contains(point)
    }

    @discardableResult func select(at point: CGPoint) -> Bool {
        guard let index = stroke(at: point) else { return false }
        selected = [index]
        refreshSelection()
        return true
    }

    func stroke(at point: CGPoint) -> Int? {
        guard let canvas else { return nil }
        let margin = 10 / screenScale
        // 先用包围盒排除大多数笔画，再检测实际曲线。不能把圆圈内部的
        // 空白也当作笔迹，否则长按选字会被一个很大的手绘框拦截。
        let strokes = canvas.drawing.strokes
        return strokes.indices.reversed().first { index in
            let stroke = strokes[index]
            guard stroke.renderBounds.insetBy(dx: -margin, dy: -margin).contains(point) else { return false }
            let scale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
            for sample in stroke.path.interpolatedPoints(by: .distance(max(0.5, margin / max(scale, 0.01) / 2))) {
                let position = sample.location.applying(stroke.transform)
                let radius = margin + max(sample.size.width, sample.size.height) * scale / 2
                if hypot(position.x - point.x, position.y - point.y) <= radius { return true }
            }
            return false
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 开始识别 pan 时 translation 可能已被系统归零；必须在落指时
        // 记录位置，不能事后反推，否则手柄会被误判成框内移动。
        start = touch.location(in: self)
        resizing = resizeHandle(at: start)
        return resizing != nil || selectedBounds.contains(start)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        resizeHandle(at: start) != nil || selectedBounds.contains(start)
    }
    @objc private func transformStroke(_ gesture: UIPanGestureRecognizer) {
        guard let canvas else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            original = canvas.drawing; originalBounds = selectedBounds
            appliedTransform = .identity
            onBegin?()
            // began 已经包含识别阈值内累积的位移，立即显示，不等下一次 changed。
            fallthrough
        case .changed, .ended:
            guard let original, !originalBounds.isNull else { return }
            let transform: CGAffineTransform
            if let resizing {
                let corners = corners(of: originalBounds)
                let anchor = corners[(resizing + 2) % 4], corner = corners[resizing]
                let dx = corner.x - anchor.x, dy = corner.y - anchor.y
                // 沿原对角线投影位移。手柄因页边避让而偏移时，缩放也不会跳变。
                let scale = min(10, max(0.1, 1 + ((point.x - start.x) * dx + (point.y - start.y) * dy) / max(1, dx * dx + dy * dy)))
                transform = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
            } else {
                transform = CGAffineTransform(translationX: point.x-start.x, y: point.y-start.y)
            }
            // ended 或合并后的触摸事件可能重复同一位置；跳过相同几何，
            // 避免再次创建笔画并要求 PencilKit 重绘。结束时仍正常提交历史。
            if appliedTransform != transform {
                canvas.drawing = Self.transformed(original, indices: selected, by: transform)
                appliedTransform = transform
                refreshSelection()
            }
            // 快速拖动的最后一段位移可能只出现在 ended；先应用落点，
            // 再提交一次撤销记录，不能把最后一帧丢掉。
            if gesture.state == .ended {
                self.original = nil
                onCommit?(original, canvas.drawing)
            }
        case .cancelled, .failed:
            if let original { canvas.drawing = original }
            original = nil; onCancel?(); refreshSelection()
        default: break
        }
    }
    @objc private func showMenu() {
        guard !selectedBounds.isNull else { return }
        presentMenu()
    }
    func presentMenu() {
        guard !selectedBounds.isNull else { return }
        onMenu?(selectedBounds)
    }
    func deleteSelection() {
        guard let canvas, !selected.isEmpty, original == nil else { return }
        let old = canvas.drawing, indices = Set(selected)
        onBegin?()
        canvas.drawing = PKDrawing(strokes: old.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
        selected = []; refreshSelection()
        onCommit?(old, canvas.drawing)
    }

    static func transformed(_ drawing: PKDrawing, indices: [Int], by transform: CGAffineTransform) -> PKDrawing {
        guard !transform.isIdentity else { return drawing }
        var strokes = drawing.strokes
        for index in indices where strokes.indices.contains(index) {
            let stroke = strokes[index]
            // 创建新的笔画身份和渲染状态。直接改旧笔画的 transform 可能只
            // 更新 renderBounds，原生画布仍复用旧纹理，形成“框动、笔迹不动”。
            // 路径按值共享，不重采样、不栅格化，也不重建未选中的笔画。
            strokes[index] = PKStroke(ink: stroke.ink, path: stroke.path,
                transform: stroke.transform.concatenating(transform), mask: stroke.mask,
                randomSeed: stroke.randomSeed)
        }
        return PKDrawing(strokes: strokes)
    }
}
