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
    
    // --- 签名交互控制引擎 ---
    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context) // 必须先让底层把 PDF 原文画完
        
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
        if let batchID = self.currentSelectedBatchID {
            // 过滤掉 Stamp (签名)，因为签名有自己的专属拖拽边框渲染逻辑
            let annots = page.annotations.filter { $0.userName == batchID && $0.type != "Stamp" }
            if !annots.isEmpty {
        
                // 找到该批注组中最靠下（在 PDF 坐标系中 minY 最小）的块，用于挂载悬浮窗便签图标
                let lowestAnnotation = annots.min { $0.bounds.minY < $1.bounds.minY }
        
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
        
        for a in annots {
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
        
        // 2. 渲染被选中的 SignatureAnnotation
        if let sig = self.activeSignature, sig.page == page {
            let generousBounds = sig.bounds.insetBy(dx: -4, dy: -4)
            
            // 系统默认颜色的圆角实线边框
            let path = NSBezierPath(roundedRect: generousBounds, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            strokeColor.setStroke()
            path.stroke()
            
            // 四个角落的蓝色拖拽圆点
            let handleSize: CGFloat = 8.0
            let handleRadius = handleSize / 2.0
            let corners = [
                NSPoint(x: generousBounds.minX, y: generousBounds.minY),
                NSPoint(x: generousBounds.maxX, y: generousBounds.minY),
                NSPoint(x: generousBounds.minX, y: generousBounds.maxY),
                NSPoint(x: generousBounds.maxX, y: generousBounds.maxY)
            ]
            
            NSColor.white.setFill()
            for corner in corners {
                let rect = NSRect(x: corner.x - handleRadius, y: corner.y - handleRadius, width: handleSize, height: handleSize)
                let circle = NSBezierPath(ovalIn: rect)
                circle.fill()
                strokeColor.setStroke()
                circle.lineWidth = 1.0
                circle.stroke()
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
            annot.contents = newText
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
