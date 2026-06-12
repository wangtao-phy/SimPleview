import AppKit
import PDFKit

let doc = PDFDocument()
let page = PDFPage()
let annot = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 100, height: 100), forType: .ink, withProperties: nil)
page.addAnnotation(annot)
doc.insert(page, at: 0)
doc.write(to: URL(fileURLWithPath: "test_ink.pdf"))
