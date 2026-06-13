import Foundation
import PDFKit

let doc = PDFDocument()
let page = PDFPage()
let annot1 = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 100, height: 100), forType: .square, withProperties: nil)
annot1.color = .red
page.addAnnotation(annot1)

let annot2 = PDFAnnotation(bounds: NSRect(x: 10, y: 150, width: 100, height: 100), forType: .circle, withProperties: nil)
annot2.color = .blue
page.addAnnotation(annot2)

// Selectively flatten ONLY annot1
let data = NSMutableData()
var mediaBox = page.bounds(for: .mediaBox)
guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { exit(1) }

context.beginPDFPage(nil)
context.drawPDFPage(page.pageRef!)
annot1.draw(with: .mediaBox, in: context)
context.endPDFPage()
context.closePDF()

guard let newDoc = PDFDocument(data: data as Data),
      let newPage = newDoc.page(at: 0) else { exit(1) }

// Add annot2 back
if let copy2 = annot2.copy() as? PDFAnnotation {
    newPage.addAnnotation(copy2)
}

let finalDoc = PDFDocument()
finalDoc.insert(newPage, at: 0)
let outUrl = URL(fileURLWithPath: "/tmp/final_data.pdf")
finalDoc.write(to: outUrl)
print("Data Flattening Success")
