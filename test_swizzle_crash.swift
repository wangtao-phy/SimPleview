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
        guard self.type == "Ink" else {
            self.hd_draw(with: box, in: context)
            return
        }
        self.hd_draw(with: box, in: context)
    }
}

let _ = PDFAnnotation.swizzleDrawMethod

let annot = PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
let cgContext = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

annot.draw(with: .cropBox, in: cgContext)
print("Done")
