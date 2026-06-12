import Foundation
import AppKit
import PDFKit

extension PDFAnnotation {
    @objc dynamic func test_mainactor() {
        print("Success")
    }
}

let annot = PDFAnnotation()
DispatchQueue.global().async {
    annot.test_mainactor()
    print("Done background")
    exit(0)
}
RunLoop.main.run()
