import Foundation
import PDFKit

let doc = PDFDocument()
let page = PDFPage()
doc.insert(page, at: 0)

// Let's create a raw Ink annotation dictionary
// Actually we don't have a real PDF. I'll just see if value(forAnnotationKey) works if I get the annotation from QuickLook Markup.
