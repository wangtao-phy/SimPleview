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
