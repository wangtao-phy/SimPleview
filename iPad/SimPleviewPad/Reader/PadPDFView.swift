import SwiftUI
import PDFKit
import PencilKit

struct PadPDFView: UIViewRepresentable {
    @ObservedObject var session: NotebookSession
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.pageOverlayViewProvider = context.coordinator
        view.document = session.document
        session.pdfView = view
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== session.document { view.document = session.document }
        if view.isInMarkupMode != session.writing { view.isInMarkupMode = session.writing }
        context.coordinator.update()
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stop()
        view.pageOverlayViewProvider = nil
        view.document = nil
    }

    // PDFKit 的覆盖视图回调来自 UI 线程，但 SDK 协议尚未标注 MainActor。
    @MainActor final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate, PKToolPickerObserver {
        let session: NotebookSession
        // 只开放已定义矢量几何的笔刷；荧光效果使用半透明实线笔。
        let picker = PKToolPicker(toolItems: [
            PKToolPickerInkingItem(type: .monoline, color: .black, width: 2),
            PKToolPickerInkingItem(type: .monoline, color: UIColor.systemYellow.withAlphaComponent(0.3), width: 14, identifier: "highlight"),
            PKToolPickerEraserItem(type: .vector), PKToolPickerLassoItem()
        ])
        var canvases: [ObjectIdentifier: (PDFPage, PKCanvasView)] = [:]
        var observers: [NSObjectProtocol] = []
        var scrollObservation: NSKeyValueObservation?
        var visibility: Bool?
        private var writingEnabled = false
        private var selectedToolIdentifier: String?
        init(_ session: NotebookSession) {
            self.session = session
            super.init()
            picker.showsDrawingPolicyControls = false
            picker.stateAutosaveName = "SimPleviewPadTools"
            selectedToolIdentifier = picker.selectedToolItemIdentifier
            picker.addObserver(self)
        }
        func observe(_ view: PDFView) {
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewVisiblePagesChanged] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        guard let self, let view else { return }
                        if name == .PDFViewPageChanged, let page = view.currentPage, let document = view.document {
                            self.session.pageIndex = document.index(for: page)
                            self.update()
                        } else { self.updateLayouts() }
                    }
                })
            }
        }
        func observeScrolling(_ view: PDFView) {
            guard scrollObservation == nil else { return }
            // 只观察公开的 UIScrollView.contentOffset，不依赖 PDFKit 私有类或字段。
            var ancestor = view.documentView?.superview
            while let current = ancestor, current !== view {
                if let scroll = current as? UIScrollView {
                    scrollObservation = scroll.observe(\.contentOffset) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.updateLayouts() }
                    }
                    break
                }
                ancestor = current.superview
            }
        }
        func updateLayouts() {
            for (_, canvas) in canvases.values { (canvas.superview as? PageInkOverlay)?.updateViewport() }
        }
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let overlay = PageInkOverlay(pageSize: page.bounds(for: .cropBox).size)
            let canvas = overlay.canvas
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.drawing = session.drawing(for: page)
            canvas.delegate = self
            canvases[ObjectIdentifier(page)] = (page, canvas)
            picker.addObserver(canvas)
            configure(canvas)
            observeScrolling(view)
            return overlay
        }
        func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            // PDFKit 可复用离屏覆盖视图；离屏时已拆除的委托和工具观察者
            // 必须在重新显示时恢复，不能假设一定再次调用 overlayViewFor。
            if let canvas = (overlayView as? PageInkOverlay)?.canvas,
               canvases[ObjectIdentifier(page)]?.1 !== canvas {
                canvases[ObjectIdentifier(page)] = (page, canvas)
                canvas.delegate = self
                picker.addObserver(canvas)
            }
            observeScrolling(view)
            update()
        }
        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = (overlayView as? PageInkOverlay)?.canvas else { return }
            picker.removeObserver(canvas)
            canvas.delegate = nil
            if session.canvas === canvas {
                session.canvas = nil
                session.isUsingTool = false
            }
            if canvases[ObjectIdentifier(page)]?.1 === canvas {
                canvases.removeValue(forKey: ObjectIdentifier(page))
            }
        }
        func configure(_ canvas: PKCanvasView) {
            let policy: PKCanvasViewDrawingPolicy = session.fingerDrawing ? .anyInput : .pencilOnly
            let enabled = session.writing && session.annotationsVisible
            if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
            if canvas.isUserInteractionEnabled != enabled { canvas.isUserInteractionEnabled = enabled }
            if canvas.isHidden == session.annotationsVisible { canvas.isHidden = !session.annotationsVisible }
            if !enabled, canvas.isFirstResponder {
                picker.setVisible(false, forFirstResponder: canvas)
                canvas.resignFirstResponder()
            }
        }
        func update() {
            let enabled = session.writing && session.annotationsVisible
            let writingChanged = enabled != writingEnabled
            writingEnabled = enabled
            updateLayouts()
            if visibility != session.annotationsVisible, let doc = session.document {
                for index in 0..<doc.pageCount { doc.page(at: index)?.displaysAnnotations = session.annotationsVisible }
                visibility = session.annotationsVisible
                session.pdfView?.setNeedsDisplay()
            }
            for (_, canvas) in canvases.values { configure(canvas) }
            if !session.isUsingTool, let page = session.pdfView?.currentPage, let (_, canvas) = canvases[ObjectIdentifier(page)] {
                let canvasChanged = session.canvas !== canvas
                session.canvas = canvas
                // 只在进入书写或切换画布时转移焦点。笔迹/保存状态更新
                // 不重开工具栏，也不能抢走弹窗或文本输入框的焦点。
                if enabled && (writingChanged || canvasChanged) {
                    picker.setVisible(true, forFirstResponder: canvas)
                    canvas.becomeFirstResponder()
                }
            }
        }
        func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
            let identifier = toolPicker.selectedToolItemIdentifier
            guard identifier != selectedToolIdentifier else { return }
            selectedToolIdentifier = identifier
            // 工具面板可能临时取得焦点。明确换笔后立即归还当前画布，不能等
            // 下次翻页或保存触发 update；同一工具的颜色/粗细编辑不抢文本焦点。
            guard session.writing, session.annotationsVisible,
                  let canvas = session.canvas, canvas.window != nil else { return }
            if !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let (page, _) = canvases.values.first(where: { $0.1 === canvasView }) else { return }
            session.update(canvasView.drawing, on: page)
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            session.isUsingTool = true
            // 连续阅读时，实际落笔页不一定是 PDFKit 的 currentPage。
            // 工具栏和撤销应跟随正在使用的画布，而不是仍可见的上一页。
            if session.canvas !== canvasView {
                session.canvas = canvasView
                picker.setVisible(true, forFirstResponder: canvasView)
                canvasView.becomeFirstResponder()
            }
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            session.isUsingTool = false; session.scheduleSave()
        }
        func stop() {
            picker.removeObserver(self)
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            scrollObservation?.invalidate(); scrollObservation = nil
            for (_,canvas) in canvases.values { picker.removeObserver(canvas); canvas.delegate = nil }
            canvases.removeAll(); session.canvas = nil; session.isUsingTool = false; session.pdfView = nil
        }
    }
}

/// PDFKit 缩放外层覆盖视图时，PencilKit 不会因此改变自身的绘制分辨率。
/// 令画布内部 zoomScale = s，外层变换为 1/s，抵消重复几何缩放；笔迹坐标
/// 仍是 PDF 点，而 PencilKit 会按当前屏幕像素密度重绘，不拉伸旧的纹理。
@MainActor final class PageInkOverlay: UIView {
    let canvas = PKCanvasView()
    private let pageSize: CGSize
    private var updating = false
    init(pageSize: CGSize) {
        self.pageSize = pageSize
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        clipsToBounds = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.bounces = false
        canvas.bouncesZoom = false
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() { super.layoutSubviews(); updateViewport() }
    override func didMoveToWindow() { super.didMoveToWindow(); updateViewport() }

    func updateViewport() {
        guard !updating, let window, bounds.width > 0, bounds.height > 0 else { return }
        let unit = convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: window)
        let scale = max(unit.width, unit.height)
        guard scale.isFinite, scale > 0 else { return }
        let visible = bounds.intersection(convert(window.bounds, from: window))
        guard !visible.isNull, !visible.isEmpty else { return }
        updating = true
        defer { updating = false }
        if canvas.contentScaleFactor != window.screen.scale { canvas.contentScaleFactor = window.screen.scale }
        // 画布只覆盖当前窗口内的页片段，放大时不分配整页巨幅纹理。
        // contentOffset 把此视口映射回原始笔迹坐标，翻页/缩放不修改 PKDrawing。
        let size = CGSize(width: visible.width * scale, height: visible.height * scale)
        let offset = CGPoint(x: visible.minX * scale, y: visible.minY * scale)
        let transform = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        if canvas.transform != transform { canvas.transform = transform }
        if canvas.bounds.size != size { canvas.bounds.size = size }
        let minimum = min(0.1, scale), maximum = max(16, scale)
        if canvas.minimumZoomScale != minimum { canvas.minimumZoomScale = minimum }
        if canvas.maximumZoomScale != maximum { canvas.maximumZoomScale = maximum }
        if abs(canvas.zoomScale - scale) > 0.0001 { canvas.setZoomScale(scale, animated: false) }
        let contentSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        if canvas.contentOffset != offset { canvas.setContentOffset(offset, animated: false) }
        // UIScrollView 会把偏移量对齐到像素。补偿该舍入，避免非整数倍率下
        // 笔迹相对 PDF 内容产生小幅位移；不通过移动原始笔迹来修正显示误差。
        let center = CGPoint(x: visible.midX + (canvas.contentOffset.x - offset.x) / scale,
                             y: visible.midY + (canvas.contentOffset.y - offset.y) / scale)
        if canvas.center != center { canvas.center = center }
    }
}
