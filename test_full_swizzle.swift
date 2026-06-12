import Foundation
import AppKit
import PDFKit

extension PDFAnnotation {
    static let swizzleDrawMethod: Void = {
        let originalSelector = #selector(draw(with:in:))
        let swizzledSelector = #selector(hd_draw(with:in:))
        
        guard let originalMethod = class_getInstanceMethod(PDFAnnotation.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(PDFAnnotation.self, swizzledSelector) else {
            print("Swizzle failed to find methods")
            return
        }
        
        method_exchangeImplementations(originalMethod, swizzledMethod)
        print("Swizzled!")
    }()
    
    @objc dynamic func hd_draw(with box: PDFDisplayBox, in context: CGContext) {
        print("hd_draw called!")
        guard self.type == "Ink" else {
            self.hd_draw(with: box, in: context)
            return
        }
        
        guard let inkListKey = PDFAnnotationKey(rawValue: "/InkList") as PDFAnnotationKey?,
              let inkList = self.value(forAnnotationKey: inkListKey) as? [[CGFloat]],
              !inkList.isEmpty else {
            print("No inklist")
            self.hd_draw(with: box, in: context)
            return
        }
        
        print("Drawing inklist!")
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
            
            path.move(to: NSPoint(x: stroke[0], y: stroke[1]))
            for i in stride(from: 2, to: stroke.count - 1, by: 2) {
                path.line(to: NSPoint(x: stroke[i], y: stroke[i+1]))
            }
            path.stroke()
        }
        
        NSGraphicsContext.restoreGraphicsState()
    }
}

let _ = PDFAnnotation.swizzleDrawMethod

let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

let annot = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 100, height: 100), forType: .ink, withProperties: nil)
annot.setValue([[ [10.0, 10.0], [90.0, 90.0] ]], forAnnotationKey: PDFAnnotationKey(rawValue: "/InkList"))
page.addAnnotation(annot)

let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
annot.draw(with: .cropBox, in: ctx)
print("Done")

