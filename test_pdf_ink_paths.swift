import Foundation
import PDFKit
import AppKit

let annot = PDFAnnotation(bounds: NSRect(x: 0, y: 0, width: 100, height: 100), forType: .ink, withProperties: nil)
let path = NSBezierPath()
path.move(to: NSPoint(x: 10, y: 10))
path.line(to: NSPoint(x: 90, y: 90))
annot.add(path)

print("Paths count: \(annot.paths?.count ?? 0)")
