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
doc.insert(page, at: 0)

// 1. Create base flattened PDF
let tempUrl = URL(fileURLWithPath: "/tmp/flat_base.pdf")
var mediaBox = page.bounds(for: .mediaBox)
guard let context = CGContext(tempUrl as CFURL, mediaBox: &mediaBox, nil) else { exit(1) }

context.beginPDFPage(nil)
context.drawPDFPage(page.pageRef!) // Draw original page (no annots)
annot1.draw(with: .mediaBox, in: context) // Flatten annot1 (red square)
context.endPDFPage()
context.closePDF()

// 2. Read it back
guard let flatDoc = PDFDocument(url: tempUrl) else { exit(1) }
guard let flatPage = flatDoc.page(at: 0) else { exit(1) }

// 3. Add back annot2 (blue circle)
// Must clone annot2 because it belongs to the old page?
// Let's try deep copy by archive/unarchive or just create a new one, but PDFKit annotations can be copied via NSCopying
if let annotCopy = annot2.copy() as? PDFAnnotation {
    flatPage.addAnnotation(annotCopy)
} else {
    // Fallback if copy() fails
    flatPage.addAnnotation(annot2)
}

let outUrl = URL(fileURLWithPath: "/tmp/final_mixed.pdf")
flatDoc.write(to: outUrl)
print("Success")
