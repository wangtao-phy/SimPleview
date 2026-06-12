import Foundation
import PDFKit

#if os(macOS)
import AppKit

extension PDFAnnotation {
    
    // [专家级拦截：静态挂载点]
    // 确保整个 App 生命周期只执行一次 Swizzling
    static let swizzleDrawMethod: Void = {
        let originalSelector = #selector(draw(with:in:))
        let swizzledSelector = #selector(hd_draw(with:in:))
        
        guard let originalMethod = class_getInstanceMethod(PDFAnnotation.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(PDFAnnotation.self, swizzledSelector) else {
            return
        }
        
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    
    @objc dynamic func hd_draw(with box: PDFDisplayBox, in context: CGContext) {
        // 如果不是手绘批注，原样放行（此时 hd_draw 已经被替换为原始的 draw 实现）
        guard self.type == "Ink" else {
            self.hd_draw(with: box, in: context)
            return
        }
        
        // 核心突破：直接从底层字典中生吃 /InkList 坐标，绕开 PDFKit 对 /AP 的重度依赖！
        guard let inkListKey = PDFAnnotationKey(rawValue: "/InkList") as PDFAnnotationKey?,
              let inkList = self.value(forAnnotationKey: inkListKey) as? [[CGFloat]],
              !inkList.isEmpty else {
            // 如果连 /InkList 都没有（极其罕见），只能让系统自己去画位图了
            self.hd_draw(with: box, in: context)
            return
        }
        
        // 既然我们自己接管了绘制，绝对不再调用系统的 hd_draw，彻底消灭模糊位图！
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        
        self.color.setStroke()
        let lineWidth = max(1.0, self.border?.lineWidth ?? 3.0)
        
        for stroke in inkList {
            guard stroke.count >= 2 else { continue }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            
            // InkList 里面是平铺的坐标：[x1, y1, x2, y2, x3, y3...]
            path.move(to: NSPoint(x: stroke[0], y: stroke[1]))
            for i in stride(from: 2, to: stroke.count - 1, by: 2) {
                path.line(to: NSPoint(x: stroke[i], y: stroke[i+1]))
            }
            
            path.stroke()
        }
        
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
