import Foundation
import PDFKit

let page = PDFPage()
let annot1 = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 100, height: 100), forType: .square, withProperties: nil)
annot1.color = .red

if let copy = annot1.copy() as? PDFAnnotation {
    print("NSCopying supported")
} else {
    print("NSCopying not supported")
}
