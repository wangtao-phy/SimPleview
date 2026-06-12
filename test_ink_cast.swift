import Foundation
import PDFKit

let annot = PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
annot.setValue([[ [10.0, 10.0] ]], forAnnotationKey: PDFAnnotationKey(rawValue: "/InkList"))

if let inkList = annot.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/InkList")) as? [[CGFloat]] {
    print("Success")
} else {
    print("Cast failed")
}
