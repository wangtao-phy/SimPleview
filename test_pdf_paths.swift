import Foundation
import AppKit
import PDFKit

let page = PDFPage()
let doc = PDFDocument()
doc.insert(page, at: 0)

let path = NSBezierPath()
path.move(to: .zero)
path.line(to: NSPoint(x: 50, y: 50))
let annot = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 100, height: 100), forType: .ink, withProperties: nil)
annot.add(path)
page.addAnnotation(annot)

let data = doc.dataRepresentation()!
let doc2 = PDFDocument(data: data)!
let loadedAnnot = doc2.page(at: 0)!.annotations[0]
print(loadedAnnot.paths?.count ?? 0)
