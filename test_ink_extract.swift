import Foundation
import PDFKit

// Create a PDF manually with a raw dictionary containing /InkList
let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

let annot = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 100, height: 100), forType: .ink, withProperties: nil)
annot.setValue([[ [10, 10], [90, 90] ]], forAnnotationKey: PDFAnnotationKey(rawValue: "/InkList"))

print(annot.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/InkList")) ?? "nil")
