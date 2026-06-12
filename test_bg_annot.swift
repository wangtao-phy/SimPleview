import Foundation
import AppKit
import PDFKit

let doc = PDFDocument()
let page = PDFPage()
let annot = PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
page.addAnnotation(annot)
doc.insert(page, at: 0)

DispatchQueue.global(qos: .background).async {
    let t = annot.type
    let c = annot.color
    let b = annot.border
    let v = annot.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/InkList"))
    print("Type: \(t ?? "nil")")
    print("Color: \(c)")
    print("Border: \(String(describing: b))")
    print("Value: \(String(describing: v))")
    exit(0)
}
RunLoop.main.run()
