import SwiftUI
import PDFKit

#if os(macOS)
import AppKit

private nonisolated(unsafe) var inkPathAssociatedKey: UInt8 = 0

extension PDFAnnotation {
    nonisolated var cachedInkBezierPath: NSBezierPath? {
        get { objc_getAssociatedObject(self, &inkPathAssociatedKey) as? NSBezierPath }
        set { objc_setAssociatedObject(self, &inkPathAssociatedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

extension CustomPDFView {
    // MARK: - macOS Custom Menu Logic
    
    /// 确保在视图被销毁时清理所有 KVO 和通知监听器，防止僵尸回调崩溃
    func cleanupMenuObservers() {
        colorObserver?.invalidate()
        colorObserver = nil
        if let obs = menuObserver {
            NotificationCenter.default.removeObserver(obs)
            menuObserver = nil
        }
        currentPopover?.close()
        currentPopover = nil
    }
    
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            cleanupMenuObservers()
        }
    }
    
    // MARK: - Native Rendering Engine (macOS)
    
    /// macOS 专属的底层绘制管线接管方法。
    ///
    /// [Swift 6 并发模型关键修复]
    /// PDFKit 的瓦片渲染引擎 (`PDFTilePool.workQueue`) 会在非主线程的后台队列中调用此方法。
    /// 由于 `PDFView.draw(_:to:)` 是 ObjC API，Swift 6 在 `DefaultActorIsolation=MainActor` 模式下
    /// 会隐式检查主线程，若不加 `nonisolated` 标记，将在真机上触发 `dispatch_assert_queue_fail` 致命崩溃。
    nonisolated override func draw(_ page: PDFPage, to context: CGContext) {
        // [核心性能修复] 我们必须调用原生的 super.draw 以利用 PDFKit 的瓦片缓存渲染，
        // 否则如果用 page.draw(with:to:) 会强制从头解析整个矢量页面，导致手绘时巨幅掉帧（一卡一卡、一段一段）。
        // 由于在 Swift 6 下，PDFView 是 @MainActor，而此方法由 PDFKit 的后台线程调用，不能直接 super.draw。
        // 我们利用底层 ObjC 消息机制，绕过 Swift 6 编译器的强制检查：
        let sel = #selector(PDFView.draw(_:to:))
        let imp = class_getMethodImplementation(class_getSuperclass(CustomPDFView.self), sel)
        typealias DrawFunc = @convention(c) (AnyObject, Selector, PDFPage, CGContext) -> Void
        let drawFunc = unsafeBitCast(imp, to: DrawFunc.self)
        drawFunc(self, sel, page, context)
        
        // 【性能优化】：将主题色获取提取到循环外
        let accentColor: NSColor
        if #available(macOS 10.14, *) {
            accentColor = NSColor.controlAccentColor
        } else {
            accentColor = NSColor.systemBlue
        }
        let strokeColor = accentColor.withAlphaComponent(0.8)
        let tintColor = accentColor.withAlphaComponent(0.85)
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        
        // 提前全量获取一次 annotations，避免在循环中重复触发 PDFKit 内部可能存在的数组重构和跨语言调用开销
        let allAnnotations = page.annotations
        
        let batchID = self._threadSafeBatchID ?? ""
        
        // 第一次遍历：查找最底部的批注
        var lowestAnnotation: PDFAnnotation? = nil
        var currentLowestY: CGFloat = .greatestFiniteMagnitude
        for a in allAnnotations where a.userName == batchID {
            let y = a.bounds.minY
            if y < currentLowestY {
                currentLowestY = y
                lowestAnnotation = a
            }
        }
        
        // [P1优化] 使用缓存的 SF Symbol 图标，避免在高频 draw 方法中每帧重新创建
        if _cachedNoteIcon == nil {
            if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil) {
                if #available(macOS 12.0, *) {
                    let config = NSImage.SymbolConfiguration(hierarchicalColor: tintColor)
                    _cachedNoteIcon = image.withSymbolConfiguration(config) ?? image
                } else {
                    _cachedNoteIcon = image
                }
            }
        }
        let noteIcon = _cachedNoteIcon
        
        let isSignature = batchID.hasPrefix("S-")
        
        // 第二次遍历：绘制所有线框
        for a in allAnnotations where a.userName == batchID {
            let generousBounds = a.bounds.insetBy(dx: -4, dy: -4)
            
            if isSignature {
                // 利用底层 ObjC 消息机制，绕过 Swift 6 @MainActor 的隔离检查读取 scaleFactor
                let sfGetter = class_getInstanceMethod(PDFView.self, #selector(getter: PDFView.scaleFactor))!
                let sfImp = method_getImplementation(sfGetter)
                typealias GetterType = @convention(c) (AnyObject, Selector) -> CGFloat
                let getScaleFactor = unsafeBitCast(sfImp, to: GetterType.self)
                let sf = getScaleFactor(self, #selector(getter: PDFView.scaleFactor))
                
                // 恢复最初的实线圆角边框
                let visualInset: CGFloat = 8.0 / sf
                let generousBounds = a.bounds.insetBy(dx: -visualInset, dy: -visualInset)
                let path = NSBezierPath(roundedRect: generousBounds, xRadius: 4, yRadius: 4)
                path.lineWidth = 1.5 / sf
                strokeColor.setStroke()
                path.stroke()
                
                // 四个角落的蓝色拖拽圆点
                let handleSize: CGFloat = 8.0 / sf
                let handleRadius = handleSize / 2.0
                let corners = [
                    NSPoint(x: generousBounds.minX, y: generousBounds.minY),
                    NSPoint(x: generousBounds.maxX, y: generousBounds.minY),
                    NSPoint(x: generousBounds.minX, y: generousBounds.maxY),
                    NSPoint(x: generousBounds.maxX, y: generousBounds.maxY)
                ]
                
                NSColor.white.setFill()
                strokeColor.setStroke()
                for corner in corners {
                    let rect = NSRect(x: corner.x - handleRadius, y: corner.y - handleRadius, width: handleSize, height: handleSize)
                    let circle = NSBezierPath(ovalIn: rect)
                    circle.lineWidth = 1.0 / sf
                    circle.fill()
                    circle.stroke()
                }
            } else {
                // 按照用户要求：选区范围稍微扩大，线框本身不需太粗，不带填充
                let path = NSBezierPath(roundedRect: generousBounds, xRadius: 4, yRadius: 4)
                path.lineWidth = 1.5 // 恢复优雅的细线
                
                // 绘制边框
                strokeColor.setStroke()
                path.stroke()
                
                // 只要一个是属于最底部的块，我们就在它的右下角绘制唯一的便签图标
                if a === lowestAnnotation {
                    if let finalIcon = noteIcon {
                        let iconSize: CGFloat = 20.0
                        let padding: CGFloat = 6.0
                        let iconRect = NSRect(
                            x: generousBounds.maxX + padding,
                            y: generousBounds.minY - (iconSize - generousBounds.height) / 2,
                            width: iconSize,
                            height: iconSize
                        )
                        finalIcon.draw(in: iconRect)
                    }
                }
            }
        }
        
        // 2. 实时渲染当前正在拖拽产生的、还没有被 PDFDocument 真正收录为 Annotation 的平滑手绘轨迹
        if self._threadSafeActiveType == .ink,
           let path = self._threadSafeDrawingPath,
           let drawingPage = self._threadSafeDrawingPage,
           drawingPage == page {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            
            self._threadSafeInkColor.setStroke()
            path.lineWidth = self._threadSafeLineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            
            NSGraphicsContext.restoreGraphicsState()
        }
        
        // 2.5 实时渲染尚未成组的草稿线条集合
        if self._threadSafeActiveType == .ink,
           !self._threadSafeDraftInkPaths.isEmpty,
           let draftPage = self._threadSafeDraftInkPage, // 此处直接读取即可
           draftPage == page {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            
            self._threadSafeInkColor.setStroke()
            for draftPath in self._threadSafeDraftInkPaths {
                draftPath.lineWidth = self._threadSafeLineWidth
                draftPath.lineCapStyle = .round
                draftPath.lineJoinStyle = .round
                draftPath.stroke()
            }
            
            NSGraphicsContext.restoreGraphicsState()
        }

        // 3. [核心黑科技] 渲染那些由于 macOS PDFKit Bug 无法写入 /InkList 的自定义笔迹！
        // [超级性能优化]：使用 cachedInkBezierPath 彻底消灭 O(N) 字符串切分，实现 0 allocation 60FPS 渲染！
        for annot in allAnnotations where (annot.type ?? "") == "Ink" {
            let bPath: NSBezierPath
            if let cached = annot.cachedInkBezierPath {
                bPath = cached
            } else {
                var pathStr = ""
                var chunkIndex = 0
                while true {
                    let keyStr = chunkIndex == 0 ? "/SimPlePath" : "/SimPlePath\(chunkIndex)"
                    if let chunk = annot.value(forAnnotationKey: PDFAnnotationKey(rawValue: keyStr)) as? String {
                        pathStr += chunk
                        chunkIndex += 1
                    } else {
                        break
                    }
                }
                
                if pathStr.isEmpty { continue }
                
                let pairs = pathStr.split(separator: ";")
                guard !pairs.isEmpty else { continue }
                
                let newPath = NSBezierPath()
                for (i, pair) in pairs.enumerated() {
                    let coords = pair.split(separator: ",")
                    if coords.count == 3 {
                        let type = coords[0]
                        if let x = Double(coords[1]), let y = Double(coords[2]) {
                            let point = NSPoint(x: x, y: y)
                            if type == "M" { newPath.move(to: point) }
                            else if type == "L" { newPath.line(to: point) }
                        }
                    } else if coords.count == 2 {
                        if let x = Double(coords[0]), let y = Double(coords[1]) {
                            let point = NSPoint(x: x, y: y)
                            if i == 0 { newPath.move(to: point) }
                            else { newPath.line(to: point) }
                        }
                    }
                }
                annot.cachedInkBezierPath = newPath
                bPath = newPath
            }
            
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            annot.color.setStroke()
            bPath.lineWidth = annot.border?.lineWidth ?? 3.0
            bPath.lineCapStyle = .round
            bPath.lineJoinStyle = .round
            bPath.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.restoreGraphicsState()
    }
    
    // 【核心碰撞算法】：判断鼠标是否精准点击了边框的边缘地带或右下角图标
    func showAnnotationPopover(for annotation: PDFAnnotation, at viewPoint: NSPoint, in view: NSView) {
        // 先彻底关闭并释放前一个 popover，防止僵尸悬浮窗残留或重叠
        currentPopover?.close()
        currentPopover = nil
        
        // 每次点击边框必定新建！保证完美的初始尺寸计算和原生的毛玻璃穿透
        let popoverView = AnnotationPopoverView(annotation: annotation) { [weak self] annot, newText in
            guard let self = self else { return }
            annot.simPleNote = newText
            self.onAnnotationContentsChanged?(annot, newText)
        }
        
        // 【稳健第一】：为了彻底根除 SwiftUI 视图在多次复用中出现的排版歪斜 Bug，
        // 我们每次点击都创建全新的原生 NSPopover 和 NSHostingController，
        // 对于现代 Mac 来说这点开销完全可以忽略不计，但换来的是 100% 稳定的原生排版！
        let popover = NSPopover()
        popover.behavior = .transient // 失去焦点自动隐藏
        popover.delegate = self       // 监听关闭事件
        // 恢复原生优雅的系统弹出动画，不再强制关闭
        
        let host = NSHostingController(rootView: popoverView)
        
        // 按照用户指示：直接写死固定尺寸，杜绝 SwiftUI 动态布局导致的乱飞现象
        let fixedSize = NSSize(width: 280, height: 160)
        host.view.frame = NSRect(origin: .zero, size: fixedSize)
        popover.contentSize = fixedSize
        
        popover.contentViewController = host
        currentPopover = popover
        
        // 构造鼠标点击点的基准坐标
        let rect = NSRect(x: viewPoint.x - 1, y: viewPoint.y - 1, width: 2, height: 2)
        
        // 尺寸被绝对固定后，原生的 NSPopover 会自己找到最完美的锚点弹出，不会再发生因为尺寸渐变导致的跳跃！
        currentPopover?.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }
    
    // [劫持原生右键菜单]
    func popoverDidClose(_ notification: Notification) {
        // 不需要做任何额外清理，回归纯粹的原生管理
    }
    
}

extension CustomPDFView: NSPopoverDelegate {}

struct PDFKitRepresentable: NSViewRepresentable {
    let pdfView: CustomPDFView
    @Binding var activeType: AnnotationType
    var inkColor: PlatformColor
    var selectedBatchID: String?
    
    func makeNSView(context: Context) -> CustomPDFView {
        pdfView.autoScales = true
        
        // [UI 优化] 原生逻辑：移除内部 ScrollView 获得焦点时的系统默认蓝色高亮外框
        pdfView.focusRingType = .none
        if let scrollView = pdfView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            scrollView.focusRingType = .none
        }
        
        let policy = MemoryMode.current.policy
        pdfView.interpolationQuality = policy.interpolationQuality
        pdfView.pageShadowsEnabled = policy.pageShadowsEnabled
        
        // [极致节约]：如果在节约模式下，取消页面边缘的额外绘制缓冲
        if !MemoryMode.isPerformance {
            pdfView.displaysPageBreaks = false
        } else {
            pdfView.displaysPageBreaks = true
        }
        
        return pdfView
    }
    
    func updateNSView(_ nsView: CustomPDFView, context: Context) {
        nsView.activeType = activeType
        nsView.inkColor = inkColor
        nsView.currentSelectedBatchID = selectedBatchID
    }
    
    // [专家级内存优化：强制拆卸缓存]
    // SwiftUI 有极其强烈的视图重用缓存机制（Reuse Pool）。
    // 如果不显式手写 dismantleNSView，SwiftUI 会将这几百兆的 PDFView 缓存到系统池中永不释放！
    // 加上这个方法，当窗口或视图被销毁时，系统才会真正彻底地释放底层图形内存。
    static func dismantleNSView(_ nsView: CustomPDFView, coordinator: ()) {
        nsView.document = nil
        nsView.removeFromSuperview()
    }
}
#endif
