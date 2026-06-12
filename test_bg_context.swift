import Foundation
import AppKit
import PDFKit

let doc = PDFDocument()
let page = PDFPage()
let annot = PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
page.addAnnotation(annot)
doc.insert(page, at: 0)

DispatchQueue.global(qos: .userInteractive).async {
    let img = NSImage(size: NSSize(width: 100, height: 100))
    img.lockFocus()
    let ctx = NSGraphicsContext.current?.cgContext
    
    // Simulate what Swizzle does
    let t = annot.type
    let c = annot.color
    let b = annot.border
    let v = annot.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/InkList"))
    let cgColor = c.cgColor
    
    print("All good!")
    img.unlockFocus()
    exit(0)
}
RunLoop.main.run()
