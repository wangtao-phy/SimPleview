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
              let inkList = self.value(forAnnotationKey: inkListKey) as? NSArray,
              inkList.count > 0 else {
            // 如果连 /InkList 都没有（极其罕见），只能让系统自己去画位图了
            self.hd_draw(with: box, in: context)
            return
        }
        
        // 既然我们自己接管了绘制，绝对不再调用系统的 hd_draw，彻底消灭模糊位图！
        // [线程安全修复]：PDFKit 会在后台线程 (NSOperationQueue) 异步生成缩略图并调用此绘制方法！
        // 绝对不能使用 NSGraphicsContext、NSBezierPath 或 NSColor.setStroke()，否则会触发 _dispatch_assert_queue_fail。
        // 必须全程使用 100% 线程安全的底层 CoreGraphics (CGContext)！
        context.saveGState()
        
        context.setStrokeColor(self.color.cgColor)
        let lineWidth = max(1.0, self.border?.lineWidth ?? 3.0)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        for item in inkList {
            guard let stroke = item as? NSArray, stroke.count >= 2 else { continue }
            
            // InkList 里面是平铺的坐标：[x1, y1, x2, y2, x3, y3...]
            if let startX = stroke[0] as? NSNumber, let startY = stroke[1] as? NSNumber {
                context.move(to: CGPoint(x: CGFloat(startX.doubleValue), y: CGFloat(startY.doubleValue)))
                
                for i in stride(from: 2, to: stroke.count - 1, by: 2) {
                    if let x = stroke[i] as? NSNumber, let y = stroke[i+1] as? NSNumber {
                        context.addLine(to: CGPoint(x: CGFloat(x.doubleValue), y: CGFloat(y.doubleValue)))
                    }
                }
            }
            
            context.strokePath()
        }
        
        context.restoreGState()
    }
}
#endif
