import SwiftUI
import PDFKit
import os

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
        
        hoverTask?.cancel()
        hoverTask = nil
        hoverPopover?.close()
        hoverPopover = nil
    }
    
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            scanCache.removeAll()
            cleanupMenuObservers()
            if let renderObserver { NotificationCenter.default.removeObserver(renderObserver) }
            renderObserver = nil
        } else if renderObserver == nil {
            renderObserver = NotificationCenter.default.addObserver(forName: .PDFViewVisiblePagesChanged,
                object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishRenderSnapshot() }
            }
        }
    }
    
    // MARK: - Mouse Tracking (Hover)
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        
        // We only care about tracking when mouse moves or exits within our visible bounds.
        // We track activeInActiveApp so hover works while app is active.
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
        
        if let area = trackingArea {
            addTrackingArea(area)
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        handleMouseLeaveLink()
    }
    
    // MARK: - Native Rendering Engine (macOS)
    
    /// macOS 专属的底层绘制管线接管方法。
    ///
    /// [Swift 6 并发模型关键修复]
    /// PDFKit 的瓦片渲染引擎 (`PDFTilePool.workQueue`) 会在非主线程的后台队列中调用此方法。
    /// 由于 `PDFView.draw(_:to:)` 是 ObjC API，Swift 6 在 `DefaultActorIsolation=MainActor` 模式下
    /// 会隐式检查主线程，若不加 `nonisolated` 标记，将在真机上触发 `dispatch_assert_queue_fail` 致命崩溃。
    nonisolated override func draw(_ page: PDFPage, to context: CGContext) {
        // PDFKit 从瓦片线程调用 ObjC 渲染钩子。super 的实现由 PDFKit 管理；
        // 自定义部分只读取一次锁保护快照，不访问主线程的数组、批注或路径。
        let selector = #selector(PDFView.draw(_:to:))
        let implementation = class_getMethodImplementation(PDFView.self, selector)
        typealias Draw = @convention(c) (AnyObject, Selector, PDFPage, CGContext) -> Void
        let snapshot = renderSnapshot.withLock { $0 }
        // 先绘制页面及其余原生批注，再仅绘制一次手绘矢量路径。若不屏蔽
        // 本次调用中的原生手绘，半透明笔迹会加深，边缘也会出现缓存重影。
        let scan = snapshot.pages[ObjectIdentifier(page)]?.scan
        let scale = max(hypot(context.ctm.a, context.ctm.b), hypot(context.ctm.c, context.ctm.d))
        // 只服务屏幕瓦片的位图上下文；PDF/打印上下文保持原生绘制。
        if context.width > 0, context.height > 0, let scan,
           let image = scanCache.image(for: scan, scale: scale) {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(image, in: scan.displayBounds)
            context.restoreGState()
        } else {
            VectorInkDrawingScope.perform(suppressing: snapshot.pages[ObjectIdentifier(page)]?.vectorInkIDs ?? []) {
                unsafeBitCast(implementation, to: Draw.self)(self, selector, page, context)
            }
        }
        guard let content = snapshot.pages[ObjectIdentifier(page)] else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(content.transform)
        context.setShouldAntialias(true)
        if snapshot.background != 0 {
            context.saveGState()
            switch snapshot.background {
            case 1:
                context.setFillColor(CGColor(red: 0.78, green: 0.93, blue: 0.8, alpha: 1))
                context.setBlendMode(.multiply)
            case 2:
                context.setFillColor(CGColor(red: 0.96, green: 0.9, blue: 0.75, alpha: 1))
                context.setBlendMode(.multiply)
            default:
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.setBlendMode(.difference)
            }
            context.fill(content.bounds)
            context.restoreGState()
        }
        for stroke in content.strokes {
            context.saveGState()
            context.addPath(stroke.path)
            if stroke.fill {
                context.setFillColor(stroke.color)
                context.fillPath()
            } else {
                context.setStrokeColor(stroke.color)
                context.setLineWidth(max(0.1, stroke.width))
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
            }
            context.restoreGState()
        }
        for icon in content.noteIcons {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(icon.image, in: icon.rect)
            context.restoreGState()
        }
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
    
    // [修复 macOS 14+ 侧边栏伸缩导致触控板缩放失效的 Bug]
    override func magnify(with event: NSEvent) {
        // 强制保障缩放范围，防止 PDFKit 在多次开关 autoScales 后将 min/max 锁死
        if self.minScaleFactor > 0.1 { self.minScaleFactor = 0.1 }
        if self.maxScaleFactor < 10.0 { self.maxScaleFactor = 10.0 }
        
        // 原生 PDFView 在 autoScales=true 且遭遇布局变动时，可能会“吞掉”触控板的放大事件
        if self.autoScales {
            self.autoScales = false
        }
        super.magnify(with: event)
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
