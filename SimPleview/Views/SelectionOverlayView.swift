import SwiftUI
import PDFKit

#if os(macOS)
import AppKit

/// 这是一个绝对透明的遮罩层，盖在 PDFView.documentView 上。
/// 它的作用是专门负责绘制“选中时的蓝色边框”和“右下角的便签图标”，
/// 完全不干扰 PDF 原生的高清渲染，也完全不阻挡用户的鼠标事件。
class SelectionOverlayView: NSView {
    
    weak var pdfView: CustomPDFView?
    
    // 必须返回 true，因为 PDFView.documentView 是 flipped 的（原点在左上角，Y轴向下）。
    // 只有这样，在这个 View 中用 NSBezierPath 绘制的坐标才能完美匹配 documentView 的坐标系。
    override var isFlipped: Bool { return true }
    
    // 穿透所有鼠标事件，让底层的 PDFView 正常响应
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let pdfView = self.pdfView,
              let document = pdfView.document,
              let batchID = pdfView._threadSafeBatchID else {
            return
        }
        
        let accentColor: NSColor
        if #available(macOS 10.14, *) {
            accentColor = NSColor.controlAccentColor
        } else {
            accentColor = NSColor.systemBlue
        }
        let strokeColor = accentColor.withAlphaComponent(0.8)
        let tintColor = accentColor.withAlphaComponent(0.85)
        
        var lowestAnnotation: PDFAnnotation? = nil
        // 因为坐标系是 flipped（Y轴向下），物理位置最靠下（最贴近屏幕底部）的批注会有最大的 maxY！
        var maxMaxY: CGFloat = -.greatestFiniteMagnitude
        var pageForLowest: PDFPage? = nil
        
        // 第一次遍历：找到物理位置最靠下的批注，用于挂载便签图标
        for page in pdfView.visiblePages {
            for a in page.annotations where a.userName == batchID {
                let rectInPage = a.bounds
                let rectInView = pdfView.convert(rectInPage, from: page)
                let rectInDoc = pdfView.documentView?.convert(rectInView, from: pdfView) ?? rectInView
                
                if rectInDoc.maxY > maxMaxY {
                    maxMaxY = rectInDoc.maxY
                    lowestAnnotation = a
                    pageForLowest = page
                }
            }
        }
        
        if lowestAnnotation != nil {
            // 获取或缓存 SF Symbol 便签图标
            if pdfView._cachedNoteIcon == nil {
                if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil) {
                    if #available(macOS 12.0, *) {
                        let config = NSImage.SymbolConfiguration(hierarchicalColor: tintColor)
                        pdfView._cachedNoteIcon = image.withSymbolConfiguration(config) ?? image
                    } else {
                        pdfView._cachedNoteIcon = image
                    }
                }
            }
            let noteIcon = pdfView._cachedNoteIcon
            
            // 第二次遍历：绘制所有的细线边框
            for page in pdfView.visiblePages {
                for a in page.annotations where a.userName == batchID {
                    let generousBounds = a.bounds.insetBy(dx: -4, dy: -4)
                    let rectInView = pdfView.convert(generousBounds, from: page)
                    let rectInDoc = pdfView.documentView?.convert(rectInView, from: pdfView) ?? rectInView
                    
                    let path = NSBezierPath(roundedRect: rectInDoc, xRadius: 4, yRadius: 4)
                    path.lineWidth = 1.5
                    strokeColor.setStroke()
                    path.stroke()
                    
                    // 为最底部的区域绘制便签图标
                    if a === lowestAnnotation {
                        if let finalIcon = noteIcon {
                            let iconSize: CGFloat = 20
                            // Flipped 坐标系中，rectInDoc.maxY 是盒子的下边缘。
                            // 图标 y 设为 maxY - 6，这样图标的顶部在盒子内侧 6pt 处，其余部分垂在盒子下方，符合原本的视觉设计。
                            let iconRect = NSRect(
                                x: rectInDoc.maxX - 6,
                                y: rectInDoc.maxY - 6,
                                width: iconSize,
                                height: iconSize
                            )
                            finalIcon.draw(in: iconRect)
                        }
                    }
                }
            }
        }
    }
}
#endif
