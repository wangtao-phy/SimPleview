import Foundation
import AppKit
import PDFKit

extension PDFAnnotation {
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
        print("hd_draw called for type: \(self.type ?? "nil")")
        guard self.type == "Ink" else {
            self.hd_draw(with: box, in: context)
            return
        }
        print("Falling back to original for Ink because no inkList")
        self.hd_draw(with: box, in: context)
    }
}

let _ = PDFAnnotation.swizzleDrawMethod

let annot = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 100, height: 100), forType: .highlight, withProperties: nil)
let cgContext = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

print("Calling draw on non-ink...")
annot.draw(with: .cropBox, in: cgContext)

let inkAnnot = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 100, height: 100), forType: .ink, withProperties: nil)
print("Calling draw on ink...")
inkAnnot.draw(with: .cropBox, in: cgContext)
print("Finished!")
