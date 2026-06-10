import SwiftUI
import PDFKit
#if os(iOS)
import PencilKit

extension CustomPDFView: PKCanvasViewDelegate {}

extension CustomPDFView {
    // MARK: - iOS PencilKit Handwriting logic (iOS 手写逻辑)
    
    func updateHandwritingState() {
        if activeType == .ink {
            // [第一次进手写模式：创建画布]
            if canvasView == nil {
                let canvas = PKCanvasView(frame: self.bounds)
                canvas.backgroundColor = .clear // 必须透明，不然遮住下面的 PDF 了
                canvas.isOpaque = false
                canvas.drawingPolicy = .pencilOnly // 只认 Apple Pencil，手指滑动算是滚动 PDF
                canvas.isScrollEnabled = false // 禁止画布自己滚动
                
                // 关键优化：强行锁死这块画布在系统的渲染树里永远在最顶层 (1000)
                canvas.layer.zPosition = 1000 
                
                self.addSubview(canvas)
                canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.canvasView = canvas
                
                // 唤出原生的画笔选择器
                let picker = toolPicker ?? PKToolPicker()
                picker.addObserver(canvas)
                self.toolPicker = picker
            }
            
            canvasView?.isHidden = false
            canvasView?.isUserInteractionEnabled = true
            canvasView?.tool = PKInkingTool(.pen, color: inkColor, width: 3)
            
            if let canvas = canvasView {
                toolPicker?.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            }
        } else {
            // 退出手写模式
            toolPicker?.setVisible(false, forFirstResponder: canvasView ?? self)
            canvasView?.isUserInteractionEnabled = false
            // 延迟一点点隐藏画布，因为底层的“烘焙”操作需要零点几秒，太快隐藏会让屏幕闪烁
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard self?.activeType != .ink else { return }
                self?.canvasView?.isHidden = true
            }
        }
    }

    // [点击事件黑客拦截 (Hit Testing)]
    // 当笔尖碰到屏幕的那一刻，iOS 会问：“我该把这个触摸事件发给谁？”
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if activeType == .ink, let canvas = canvasView {
            let target = canvas.hitTest(point, with: event)
            // 如果 hitTest 命中了 canvas（说明是 Pencil），则直接返回 canvas
            // 这意味着 PDF 视图完全“瞎”了，它不会知道你在屏幕上写字，也就不会触发文本选择。
            if target != nil { return target }
        }
        return super.hitTest(point, with: event)
    }

    /// [超级黑科技：将 Apple Pencil 动态笔迹烘焙成 PDF 永久批注]
    func bakeDrawingToPDF() {
        guard let canvas = canvasView, !canvas.drawing.bounds.isEmpty else { return }
        
        // 1. 把画布上的内容拿走，然后把画布清空
        let drawing = canvas.drawing
        canvas.drawing = PKDrawing() 
        
        // 生成一个唯一批次 ID。因为你写“Hello”这 5 个字母是由很多笔画组成的，
        // 烘焙进 PDF 后它们会被拆散，我们需要用这个 ID 标记它们“是一伙的”，将来删的时候才能一键删掉整个单词。
        let batchID = "B-INK-\(Int(Date().timeIntervalSince1970))"
        var pageStrokes: [PDFPage: [PKStroke]] = [:]
        
        // 2. 空间定位：算出每一笔到底写在了 PDF 的哪一页上
        for stroke in drawing.strokes {
            let center = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
            if let page = self.page(for: center, nearest: true) {
                pageStrokes[page, default: []].append(stroke)
            }
        }
        
        // 3. 坐标转换与生成：屏幕坐标 -> PDF 内置坐标系 (Y 轴是反的！)
        for (page, strokes) in pageStrokes {
            var pagePaths: [UIBezierPath] = []
            var unionBounds = CGRect.null
            
            for stroke in strokes {
                let path = UIBezierPath()
                let pts = stroke.path.map { $0.location }
                if let first = pts.first {
                    // self.convert: 就是神奇的坐标系转换器
                    path.move(to: self.convert(first, to: page))
                    for i in 1..<pts.count {
                        path.addLine(to: self.convert(pts[i], to: page))
                    }
                }
                pagePaths.append(path)
                unionBounds = unionBounds.union(path.bounds)
            }
            
            if unionBounds.isNull { continue }
            // 收缩一点点边界，防止 PDF 渲染引擎裁剪到边缘
            let finalBounds = unionBounds.insetBy(dx: -2, dy: -2)
            
            // 生成官方 PDF 规范承认的 .ink (墨水) 格式批注对象！
            let annot = PDFAnnotation(bounds: finalBounds, forType: .ink, withProperties: nil)
            annot.userName = batchID // 藏入我们自定义的批次 ID
            annot.contents = ""
            annot.color = self.manager?.pendingColorOverride ?? self.manager?.inkColor ?? UIColor.systemBlue
            
            // 归一化偏移量 (PDFKit 内部计算要求)
            let transform = CGAffineTransform(translationX: -finalBounds.origin.x, y: -finalBounds.origin.y)
            for path in pagePaths {
                path.apply(transform)
                annot.add(path)
            }
            page.addAnnotation(annot) // 永久写入文档
        }
        
        // 重绘 PDF 并通知外界
        for view in self.subviews {
            view.setNeedsDisplay()
        }
        // 4. 计算这些笔画分布在哪些页码上
        // [极客架构：为何必须是 Set<Int> 而不是 [Int]？]
        // 手写笔迹非常容易在同一页上堆叠上百条 Stroke。如果我们用数组记录页码，Undo 系统在撤销时，
        // 就会对同一页面连续下发上百次强制重绘 (setNeedsDisplay) 的指令，导致 iOS 主线程帧率雪崩。
        // 使用 Set<Int> 从物理数据结构上保证了：无论你在这一页写了多长的一笔，
        // 撤销时，这一页只会被精准触发一次刷新，达到了 O(K) (K=受影响的页数) 的顶级性能！
        let indices = pageStrokes.keys.compactMap { self.document?.index(for: $0) }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.manager?.batchStack.append(.annotation(batchID: batchID, pageIndices: Set(indices)))
            self.manager?.refreshAnnotations(in: self.document)
            self.manager?.pendingColorOverride = nil
            NotificationCenter.default.post(name: NSNotification.Name("PDFRefreshAnnotations"), object: nil)
            self.onSaveRequired?() // 触发自动保存
        }
    }

    // [iOS 16+ 手势与菜单拦截重构]
    func setupCustomInteractions() {
        // 1. 挂载我们自己最高优先级的手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleCustomTap(_:)))
        tapGesture.delegate = self
        tapGesture.name = "CustomPDFTap"
        self.addGestureRecognizer(tapGesture)
        
        // 2. 挂载现代 iOS 16+ 的弹出菜单交互
        let interaction = UIEditMenuInteraction(delegate: self)
        self.addInteraction(interaction)
        self.editMenuInteraction = interaction
    }
    
    @objc func handleCustomTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        var hitAnnotation = false
        
        if let page = page(for: location, nearest: false) {
            let pagePoint = convert(location, to: page)
            let supportedTypes = ["Highlight", "Underline", "StrikeOut", "Ink"]
            
            var targetAnnotation: PDFAnnotation? = nil
            let radius: CGFloat = 15.0 // 增加点击识别半径，使得更容易点中
            let points = [
                pagePoint,
                CGPoint(x: pagePoint.x - radius, y: pagePoint.y),
                CGPoint(x: pagePoint.x + radius, y: pagePoint.y),
                CGPoint(x: pagePoint.x, y: pagePoint.y - radius),
                CGPoint(x: pagePoint.x, y: pagePoint.y + radius),
                CGPoint(x: pagePoint.x - radius, y: pagePoint.y - radius),
                CGPoint(x: pagePoint.x + radius, y: pagePoint.y + radius),
                CGPoint(x: pagePoint.x + radius, y: pagePoint.y - radius),
                CGPoint(x: pagePoint.x - radius, y: pagePoint.y + radius)
            ]
            
            for pt in points {
                if let annot = page.annotation(at: pt) {
                    if annot.userName == "SYSTEM_BORDER" {
                        // 如果点到了替身边框，等同于再次点中了当前选中的批次！
                        if let batchID = self.currentSelectedBatchID,
                           let realAnnot = page.annotations.first(where: { $0.userName == batchID }) {
                            targetAnnotation = realAnnot
                            break
                        }
                    } else if supportedTypes.contains(annot.type ?? "") {
                        targetAnnotation = annot
                        break
                    }
                }
            }
            
            if let targetAnnotation = targetAnnotation {
                hitAnnotation = true
                let isSecondTap = (self.currentSelectedBatchID == targetAnnotation.userName)
                
                self.currentSelectedBatchID = targetAnnotation.userName
                onAnnotationSelected?(targetAnnotation)
                
                if isSecondTap {
                    self.allowMenuForCurrentSelection = true
                    let rect = self.convert(targetAnnotation.bounds, from: page)
                    let configuration = UIEditMenuConfiguration(identifier: "DeleteAnnotationMenu" as NSString, sourcePoint: CGPoint(x: rect.midX, y: rect.minY))
                    self.editMenuInteraction?.presentEditMenu(with: configuration)
                } else {
                    self.allowMenuForCurrentSelection = false
                    self.editMenuInteraction?.dismissMenu()
                }
            }
        }
        
        if !hitAnnotation {
            self.allowMenuForCurrentSelection = false
            self.currentSelectedBatchID = nil
            onAnnotationSelected?(nil)
            self.editMenuInteraction?.dismissMenu()
            
            if self.currentSelection != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.onMouseUp?()
                }
            }
        }
    }
    
    // [批量删除拦截]
    override func delete(_ sender: Any?) {
        guard let batchID = self.currentSelectedBatchID, let doc = self.document else {
            super.delete(sender)
            return
        }
        
        var targetAnnot: PDFAnnotation?
        // 【极简优化】：删除菜单弹出时，批注必然在当前屏幕的可视页中
        for page in self.visiblePages {
            if let found = page.annotations.first(where: { $0.userName == batchID }) {
                targetAnnot = found
                break
            }
        }
        
        if let target = targetAnnot {
            self.allowMenuForCurrentSelection = false
            self.currentSelectedBatchID = nil
            self.editMenuInteraction?.dismissMenu()
            onAnnotationDeleted?(target) // 这会直接调用 AppState 的批量删除！
        } else {
            super.delete(sender)
        }
    }
    
    // [屏蔽老接口遗留菜单]
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let name = action.description.lowercased()
        if name.contains("note") || name.contains("comment") || name.contains("highlight") {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
    
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        let name = action.description.lowercased()
        if name.contains("highlight") || name.contains("note") || name.contains("comment") { return nil }
        return super.target(forAction: action, withSender: sender)
    }
}

// [手势与菜单代理实现]
extension CustomPDFView: UIEditMenuInteractionDelegate {
    
    // 强制干掉 PDFKit 的原生点击手势（如果点到了我们的批注）
    override public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer.name == "CustomPDFTap" {
            let location = gestureRecognizer.location(in: self)
            if let page = page(for: location, nearest: false) {
                let pagePoint = convert(location, to: page)
                let supportedTypes = ["Highlight", "Underline", "StrikeOut", "Ink"]
                let radius: CGFloat = 15.0
                let points = [
                    pagePoint,
                    CGPoint(x: pagePoint.x - radius, y: pagePoint.y),
                    CGPoint(x: pagePoint.x + radius, y: pagePoint.y),
                    CGPoint(x: pagePoint.x, y: pagePoint.y - radius),
                    CGPoint(x: pagePoint.x, y: pagePoint.y + radius),
                    CGPoint(x: pagePoint.x - radius, y: pagePoint.y - radius),
                    CGPoint(x: pagePoint.x + radius, y: pagePoint.y + radius),
                    CGPoint(x: pagePoint.x + radius, y: pagePoint.y - radius),
                    CGPoint(x: pagePoint.x - radius, y: pagePoint.y + radius)
                ]
                
                for pt in points {
                    if let annot = page.annotation(at: pt) {
                        if annot.userName == "SYSTEM_BORDER" || supportedTypes.contains(annot.type ?? "") {
                            return true // 点中批注或边框，让原生手势失效！
                        }
                    }
                }
            }
        }
        return false
    }
    
    // 渲染 iOS 16+ 的纯净现代菜单
    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        if self.allowMenuForCurrentSelection {
            let deleteAction = UIAction(title: "删除标注", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.delete(nil)
            }
            return UIMenu(options: .displayInline, children: [deleteAction])
        }
        return nil
    }
}

struct PDFKitRepresentable: UIViewRepresentable {
    let pdfView: CustomPDFView
    @Binding var activeType: AnnotationType
    var inkColor: PlatformColor
    var selectedBatchID: String?
    
    func makeUIView(context: Context) -> CustomPDFView {
        pdfView.autoScales = true
        
        let policy = MemoryMode.current.policy
        pdfView.interpolationQuality = policy.interpolationQuality
        pdfView.pageShadowsEnabled = policy.pageShadowsEnabled
        // iOS 性能模式独占：开启仿真翻页感引擎，让滑动如纸质书般顺滑
        pdfView.usePageViewController(!policy.delaysNavigationJumps, withViewOptions: nil)
        
        pdfView.setupCustomInteractions()
        return pdfView
    }
    
    // 当 SwiftUI 外界的变量发生改变时，这里会将新值“注射”进旧组件里
    func updateUIView(_ uiView: CustomPDFView, context: Context) {
        if uiView.inkColor != inkColor { uiView.inkColor = inkColor }
        if uiView.activeType != activeType { uiView.activeType = activeType }
        uiView.currentSelectedBatchID = selectedBatchID
    }
    
    // [专家级内存优化：强制拆卸缓存]
    // 防止 SwiftUI 重用池死锁 PDFView 导致的严重内存泄漏。
    static func dismantleUIView(_ uiView: CustomPDFView, coordinator: ()) {
        uiView.document = nil
        uiView.removeFromSuperview()
    }
}
#endif
