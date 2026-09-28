import SwiftUI
import PDFKit
import PencilKit

struct PadPDFView: UIViewControllerRepresentable {
    @ObservedObject var session: NotebookSession
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeUIViewController(context: Context) -> PDFReaderController {
        let view = ReadingPDFView()
        view.session = session
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.pageOverlayViewProvider = context.coordinator
        view.document = session.document
        session.pdfView = view
        context.coordinator.observe(view)
        return PDFReaderController(pdfView: view, session: session)
    }
    func updateUIViewController(_ controller: PDFReaderController, context: Context) {
        if controller.pdfView.document !== session.document { controller.pdfView.document = session.document }
        context.coordinator.update()
        controller.update()
    }
    static func dismantleUIViewController(_ controller: PDFReaderController, coordinator: Coordinator) {
        controller.stop()
        coordinator.stop()
        controller.pdfView.pageOverlayViewProvider = nil
        controller.pdfView.document = nil
    }

    // PDFKit 的覆盖视图回调来自 UI 线程，但 SDK 协议尚未标注 MainActor。
    @MainActor final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate {
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
        private weak var scrollingView: UIScrollView?
        private var appendOnRelease = false
        var visibility: Bool?
        private var transformingInk = false
        private weak var selectedOverlay: PageInkOverlay?
        private lazy var inkPress: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(selectInk(_:)))
            gesture.minimumPressDuration = 0.45
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.delegate = self
            return gesture
        }()
        private lazy var annotationTap: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(tapAnnotation(_:)))
            gesture.delegate = self
            gesture.require(toFail: inkPress)
            return gesture
        }()
        private lazy var dismissInk: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(clearInkSelection))
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            return gesture
        }()
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
            session.drawingDidChange = { [weak self] page, drawing in
                guard let canvas = self?.canvases[ObjectIdentifier(page)]?.1 else { return }
                if canvas.drawing != drawing { canvas.drawing = drawing }
                (canvas.superview as? PageInkOverlay)?.transformView.refreshSelection()
            }
            view.addGestureRecognizer(inkPress)
            view.addGestureRecognizer(dismissInk)
            view.addGestureRecognizer(annotationTap)
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
                    scrollingView = scroll
                    if session.isNotebook { scroll.alwaysBounceVertical = true }
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(handlePagePull(_:)))
                    scrollObservation = scroll.observe(\.contentOffset) { [weak self] scroll, _ in
                        MainActor.assumeIsolated {
                            self?.updateLayouts()
                            self?.updatePagePull(scroll)
                        }
                    }
                    break
                }
                ancestor = current.superview
            }
        }
        /// 仅观察 PDFKit 自己的滚动手势，不接管 delegate，也不增加会抢笔迹的手势。
        /// 只记录手指拖动时的越界量，惯性和回弹不触发；拉回阈值内即可取消。
        func updatePagePull(_ scroll: UIScrollView) {
            guard scroll.isDragging else { return }
            let bottom = max(-scroll.adjustedContentInset.top,
                             scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            appendOnRelease = session.isNotebook && session.pdfView?.displayMode == .singlePageContinuous
                && !session.isUsingTool && !scroll.isZooming
                && scroll.contentOffset.y - bottom >= 96
                && scroll.panGestureRecognizer.translation(in: scroll).y < -96
        }

        @objc private func handlePagePull(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .cancelled, .failed:
                appendOnRelease = false
            case .ended:
                let shouldAppend = appendOnRelease
                appendOnRelease = false
                guard shouldAppend, let document = session.document,
                      let lastPage = document.page(at: document.pageCount - 1) else { return }
                // 等本轮触摸事件分发完成再改页树；每次拖动只提交一次。
                Task { @MainActor [weak self, weak lastPage] in
                    guard let lastPage else { return }
                    self?.session.appendBlankPage(after: lastPage)
                }
            default: break
            }
        }

        private func inkTarget(at point: CGPoint) -> (PageInkOverlay, CGPoint)? {
            guard let view = session.pdfView, session.annotationsVisible, !session.isUsingTool,
                  !(session.writing && session.fingerDrawing) else { return nil }
            for (_, canvas) in canvases.values {
                guard let overlay = canvas.superview as? PageInkOverlay, overlay.window != nil else { continue }
                let local = overlay.convert(point, from: view)
                if overlay.bounds.contains(local), overlay.transformView.stroke(at: local) != nil {
                    return (overlay, local)
                }
            }
            return nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === annotationTap {
                guard !session.writing, !session.adjustingInk, !session.isReadOnly else { return false }
                let point = touch.location(in: session.pdfView)
                return annotationTarget(at: point) != nil || inkTarget(at: point) != nil
            }
            if gestureRecognizer === inkPress {
                return inkTarget(at: touch.location(in: session.pdfView)) != nil
            }
            if gestureRecognizer === dismissInk, session.adjustingInk, let overlay = selectedOverlay {
                return !overlay.transformView.point(inside: touch.location(in: overlay.transformView), with: nil)
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 只有按在真实笔迹上才参与仲裁；普通文字的 PDFKit 长按不需要等待。
            if gestureRecognizer === annotationTap { return otherGestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer !== dismissInk }
            return gestureRecognizer === inkPress && otherGestureRecognizer is UILongPressGestureRecognizer
        }

        private func annotationTarget(at point: CGPoint) -> (PDFPage, PDFAnnotation)? {
            guard session.annotationsVisible, let view = session.pdfView,
                  let page = view.page(for: point, nearest: false),
                  let annotation = page.annotation(at: view.convert(point, to: page)),
                  annotation.shouldDisplay,
                  ["Highlight", "Underline", "StrikeOut", "Squiggly", "Ink", "Text", "FreeText", "Square", "Circle", "Line", "Polygon", "PolyLine", "Stamp", "Caret"].contains(annotation.type ?? "") else { return nil }
            // 链接与表单控件继续由 PDFKit 处理，不把它们当成可删除的阅读标注。
            return (page, annotation)
        }

        @objc private func tapAnnotation(_ gesture: UITapGestureRecognizer) {
            guard let view = session.pdfView as? ReadingPDFView else { return }
            let point = gesture.location(in: view)
            if let (page, annotation) = annotationTarget(at: point) {
                view.showAnnotationMenu(in: view.convert(annotation.bounds, from: page), addText: { [weak self, weak page, weak annotation] in
                    guard let page, let annotation else { return }
                    self?.session.textRequest = AnnotationTextRequest(page: page, annotation: annotation, bounds: annotation.bounds)
                }, delete: { [weak self, weak page, weak annotation] in
                    guard let page, let annotation else { return }
                    self?.session.deleteAnnotation(annotation, on: page)
                })
            } else if let (overlay, point) = inkTarget(at: point) {
                activateInk(overlay, at: point)
                overlay.transformView.presentMenu()
            }
        }

        private func activateInk(_ overlay: PageInkOverlay, at point: CGPoint) {
            selectedOverlay?.transformView.reset()
            selectedOverlay = overlay
            session.pdfView?.clearSelection()
            session.adjustingInk = true
            session.canvas = overlay.canvas
            update()
            overlay.transformView.select(at: point)
        }

        @objc private func selectInk(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let (overlay, point) = inkTarget(at: gesture.location(in: session.pdfView)) else { return }
            activateInk(overlay, at: point)
        }

        @objc private func clearInkSelection() {
            selectedOverlay?.transformView.reset()
            selectedOverlay = nil
            session.adjustingInk = false
            update()
        }

        func updateLayouts() {
            for (_, canvas) in canvases.values { (canvas.superview as? PageInkOverlay)?.updateViewport() }
        }
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            let overlay = PageInkOverlay(pageSize: page.bounds(for: .cropBox).size)
            let canvas = overlay.canvas
            canvas.editingUndoManager = session.editingUndoManager
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.drawing = session.drawing(for: page)
            canvas.delegate = self
            canvases[ObjectIdentifier(page)] = (page, canvas)
            overlay.transformView.onBegin = { [weak self, weak canvas] in
                self?.session.canvas = canvas
                self?.transformingInk = true
                self?.session.isUsingTool = true
            }
            overlay.transformView.onCommit = { [weak self, weak page] _, new in
                guard let self, let page else { return }
                self.transformingInk = false; self.session.isUsingTool = false
                self.session.update(new, on: page)
            }
            overlay.transformView.onCancel = { [weak self] in
                self?.transformingInk = false; self?.session.isUsingTool = false
                if self?.session.dirty == true { self?.session.scheduleSave() }
            }
            overlay.transformView.onMenu = { [weak self, weak overlay, weak page] bounds in
                guard let self, let overlay, let page, let view = self.session.pdfView as? ReadingPDFView else { return }
                let pageBounds = page.bounds(for: .cropBox)
                let noteBounds = CGRect(x: pageBounds.minX + bounds.minX,
                    y: pageBounds.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
                view.showAnnotationMenu(in: overlay.convert(bounds, to: view), addText: { [weak self, weak page] in
                    guard let page else { return }
                    self?.session.textRequest = AnnotationTextRequest(page: page, annotation: nil, bounds: noteBounds)
                }, delete: { [weak self, weak overlay] in
                    overlay?.transformView.deleteSelection()
                    self?.clearInkSelection()
                })
            }
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
            if selectedOverlay === overlayView {
                clearInkSelection()
            }
            finishDrawing(canvas)
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
            let enabled = session.writing && session.annotationsVisible && !session.adjustingInk
            if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
            // 不能只禁用画布：透明的外层 UIView 仍会命中触摸，挡住 PDFKit 长按选字。
            let adjusting = session.adjustingInk && session.annotationsVisible
                && selectedOverlay === canvas.superview
            if let overlay = canvas.superview as? PageInkOverlay {
                overlay.isUserInteractionEnabled = enabled || adjusting
                if overlay.transformView.isHidden != !adjusting {
                    overlay.transformView.reset()
                    overlay.transformView.isHidden = !adjusting
                }
            }
            if canvas.isUserInteractionEnabled != enabled { canvas.isUserInteractionEnabled = enabled }
            if canvas.isHidden == session.annotationsVisible { canvas.isHidden = !session.annotationsVisible }
            if !enabled, canvas.isFirstResponder {
                picker.setVisible(false, forFirstResponder: canvas)
                canvas.resignFirstResponder()
            }
        }
        func update() {
            let enabled = session.writing && session.annotationsVisible && !session.adjustingInk
            let writingChanged = enabled != writingEnabled
            writingEnabled = enabled
            if writingChanged && !enabled {
                // 撤销/工具取消不保证再收到一次 didEndUsingTool。退出书写必须主动
                // 结束笔画状态，并在交还 PDFKit 触摸之前收取画布的最终内容。
                session.isUsingTool = false
                if let canvas = session.canvas,
                   let (page, _) = canvases.values.first(where: { $0.1 === canvas }),
                   canvas.drawing != session.drawing(for: page) {
                    session.update(canvas.drawing, on: page)
                }
                if session.dirty { session.scheduleSave() }
            }
            if !session.adjustingInk || !session.annotationsVisible {
                selectedOverlay?.transformView.reset()
                selectedOverlay = nil
                if session.adjustingInk { session.adjustingInk = false }
            }
            updateLayouts()
            if visibility != session.annotationsVisible, let doc = session.document {
                for index in 0..<doc.pageCount { doc.page(at: index)?.displaysAnnotations = session.annotationsVisible }
                visibility = session.annotationsVisible
                session.pdfView?.setNeedsDisplay()
            }
            for (page, canvas) in canvases.values {
                // 离屏复用的画布也从会话取最新内容；编辑期间不得用旧模型盖掉预览。
                if !session.isUsingTool, canvas.drawing != session.drawing(for: page) {
                    canvas.drawing = session.drawing(for: page)
                    (canvas.superview as? PageInkOverlay)?.transformView.refreshSelection()
                }
                configure(canvas)
            }
            // 先停用画布并释放工具焦点，再切换 PDFKit 的原生手势状态；避免撤销后
            // 仍活跃的 PencilKit 手势与阅读模式抢同一轮触摸。
            if let view = session.pdfView {
                let markup = enabled
                if view.isInMarkupMode != markup { view.isInMarkupMode = markup }
            }
            if !session.isUsingTool, !session.adjustingInk, let page = session.pdfView?.currentPage, let (_, canvas) = canvases[ObjectIdentifier(page)] {
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
            guard !transformingInk, !session.isUsingTool else { return }
            guard let (page, _) = canvases.values.first(where: { $0.1 === canvasView }) else { return }
            session.update(canvasView.drawing, on: page)
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            guard session.writing, session.annotationsVisible, canvasView.isUserInteractionEnabled else { return }
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
            guard session.canvas === canvasView else { return }
            finishDrawing(canvasView)
        }
        private func finishDrawing(_ canvas: PKCanvasView) {
            guard !transformingInk,
                  let (page, _) = canvases.values.first(where: { $0.1 === canvas }) else { return }
            // 一次落笔/擦除提交一次，预览过程不制造大量撤销记录。
            session.isUsingTool = false
            session.update(canvas.drawing, on: page)
            if session.dirty { session.scheduleSave() }
        }
        func stop() {
            selectedOverlay?.transformView.reset()
            selectedOverlay = nil
            session.adjustingInk = false
            annotationTap.view?.removeGestureRecognizer(annotationTap)
            inkPress.view?.removeGestureRecognizer(inkPress)
            dismissInk.view?.removeGestureRecognizer(dismissInk)
            picker.removeObserver(self)
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            scrollObservation?.invalidate(); scrollObservation = nil
            scrollingView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePagePull(_:)))
            scrollingView = nil
            appendOnRelease = false
            for (_,canvas) in canvases.values {
                finishDrawing(canvas)
                picker.removeObserver(canvas); canvas.delegate = nil
            }
            session.drawingDidChange = nil
            canvases.removeAll(); session.canvas = nil; session.isUsingTool = false; session.pdfView = nil
        }
    }
}

/// PDFKit 缩放外层覆盖视图时，PencilKit 不会因此改变自身的绘制分辨率。
/// 令画布内部 zoomScale = s，外层变换为 1/s，抵消重复几何缩放；笔迹坐标
/// 仍是 PDF 点，而 PencilKit 会按当前屏幕像素密度重绘，不拉伸旧的纹理。
@MainActor final class PageInkOverlay: UIView {
    let canvas = NotebookCanvasView()
    let transformView = InkTransformView()
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
        transformView.canvas = canvas
        transformView.isHidden = true
        addSubview(transformView)
    }
    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 选择框之外不让透明容器挡住 PDFKit；原生画布启用时仍正常接笔。
        return hit === self ? nil : hit
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        transformView.frame = bounds
        updateViewport()
    }
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

/// 覆盖视图可以销毁或复用，UndoManager 始终由文档会话持有。
@MainActor final class NotebookCanvasView: PKCanvasView {
    weak var editingUndoManager: UndoManager?
    override var undoManager: UndoManager? { editingUndoManager }
}
