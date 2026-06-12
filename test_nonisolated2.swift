import Foundation
import AppKit
import PDFKit

extension PDFAnnotation {
    @objc dynamic nonisolated func hd_draw(with box: PDFDisplayBox, in context: CGContext) {
        let _ = self.type
    }
}
