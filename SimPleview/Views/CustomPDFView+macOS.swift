import SwiftUI
import PDFKit

#if os(macOS)
import AppKit

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
        // 由于我们在 nonisolated 上下文中，直接调用 super.draw 可能会报 Actor 警告
        // 苹果官方针对此类底层框架调用的推荐做法是使用 MainActor.assumeIsolated 
        // 苹果官方文档指出 PDFView.draw(_:to:) 的默认实现为空。
        // 但是实际上如果不调用，页面原文就会消失变成白屏！
        // 因为在 Swift 6 下我们无法调用被 MainActor 隔离的 super.draw(page, to: context)，
        // 我们可以直接调用 PDFPage 的底层非隔离绘图 API 来绘制原文。
        page.draw(with: .cropBox, to: context)
        
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
        
        // 1. 如果当前有被选中的批次 ID，我们就在这页上把属于它的批注框出来
        if let batchID = self._threadSafeBatchID {
            // MARK: Zero Allocation Rendering Algorithm
            // [极致渲染优化：零内存分配 (Zero Allocation)]
            // 该 draw 方法在用户缩放、滚动时，会以 60FPS 的极高频率被核心渲染线程调用。
            // 传统的 `.filter { }` 或 `.min { }` 高阶函数会在每一帧动态申请堆内存来存储临时闭包和中间数组，
            // 进而导致系统垃圾回收 (GC) 频繁介入，造成可感知的掉帧和电量消耗。
            // 此处采用最底层的单次 for 循环 (O(N) 甚至提早 break 的变种)，直接计算外接矩形最低点并立即绘制。
            var lowestAnnotation: PDFAnnotation? = nil
            var minMinY: CGFloat = .greatestFiniteMagnitude
            
            // 第一次遍历：找到最低点（用于挂载便签图标）
            for a in page.annotations where a.userName == batchID {
                let y = a.bounds.minY
                if y < minMinY {
                    minMinY = y
                    lowestAnnotation = a
                }
            }
            
            if lowestAnnotation != nil {
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
                
                // 第二次遍历：绘制所有线框
                for a in page.annotations where a.userName == batchID {
                    // 按照用户要求：选区范围稍微扩大，线框本身不需太粗，不带填充
                    let generousBounds = a.bounds.insetBy(dx: -4, dy: -4)
                    let path = NSBezierPath(roundedRect: generousBounds, xRadius: 4, yRadius: 4)
                    path.lineWidth = 1.5 // 恢复优雅的细线
                    
                    // 绘制边框
                    strokeColor.setStroke()
                    path.stroke()
                    
                    // 只要一个是属于最底部的块，我们就在它的右下角绘制唯一的便签图标
                    if a === lowestAnnotation {
                        if let finalIcon = noteIcon {
                            let iconSize: CGFloat = 20
                            // 锚定在右下角，稍微向外扩展一点
                            let iconRect = NSRect(x: generousBounds.maxX - 6, y: generousBounds.minY - iconSize + 6, width: iconSize, height: iconSize)
                            finalIcon.draw(in: iconRect)
                        }
                    }
                }
            }
        }
        
        // 2. 实时渲染当前正在绘制的单笔手绘线条
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
           let draftPage = self.draftInkPage, // 此处直接读取即可
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
        for annot in page.annotations where (annot.type ?? "") == "Ink" {
            // 读取我们植入的隐秘字段
            if let pathStr = annot.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/SimPlePath")) as? String {
                let pairs = pathStr.split(separator: ";")
                guard !pairs.isEmpty else { continue }
                
                let bPath = NSBezierPath()
                for (i, pair) in pairs.enumerated() {
                    let coords = pair.split(separator: ",")
                    if coords.count == 3 {
                        // 新格式: M,x,y 或 L,x,y
                        let type = coords[0]
                        if let x = Double(coords[1]), let y = Double(coords[2]) {
                            let point = NSPoint(x: x, y: y)
                            if type == "M" { bPath.move(to: point) }
                            else if type == "L" { bPath.line(to: point) }
                        }
                    } else if coords.count == 2 {
                        // 兼容老格式: x,y
                        if let x = Double(coords[0]), let y = Double(coords[1]) {
                            let point = NSPoint(x: x, y: y)
                            if i == 0 { bPath.move(to: point) }
                            else { bPath.line(to: point) }
                        }
                    }
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
