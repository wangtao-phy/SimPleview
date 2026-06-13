import Foundation
import PDFKit

let url1 = URL(fileURLWithPath: "/tmp/test.pdf")
guard let doc1 = PDFDocument(url: url1) else { exit(1) }
guard let page1 = doc1.page(at: 0) else { exit(1) }

let outUrl = URL(fileURLWithPath: "/tmp/test_flattened_2.pdf")
var mediaBox = page1.bounds(for: .mediaBox)
guard let context = CGContext(outUrl as CFURL, mediaBox: &mediaBox, nil) else { exit(1) }

context.beginPDFPage(nil)
// Only draw the page, see if the annotation comes with it
context.drawPDFPage(page1.pageRef!)

context.endPDFPage()
context.closePDF()

let doc2 = PDFDocument(url: outUrl)!
let page2 = doc2.page(at: 0)!
print("Annotations in flattened: \(page2.annotations.count)")
