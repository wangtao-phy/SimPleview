import Foundation
import PDFKit

let url1 = URL(fileURLWithPath: "/tmp/test.pdf")
guard let doc1 = PDFDocument(url: url1) else { exit(1) }
guard let page1 = doc1.page(at: 0) else { exit(1) }

let outUrl = URL(fileURLWithPath: "/tmp/test_flattened.pdf")
var mediaBox = page1.bounds(for: .mediaBox)
guard let context = CGContext(outUrl as CFURL, mediaBox: &mediaBox, nil) else { exit(1) }

context.beginPDFPage(nil)
// Draw underlying page (no annotations natively)
context.drawPDFPage(page1.pageRef!)

// Now let's try to draw the annotation to check if it draws
for annot in page1.annotations {
    annot.draw(with: .mediaBox, in: context)
}

context.endPDFPage()
context.closePDF()
