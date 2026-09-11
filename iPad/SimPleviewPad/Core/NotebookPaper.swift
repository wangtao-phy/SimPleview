import Foundation
import CoreGraphics
import PDFKit

enum NotebookPaper: String, CaseIterable, Identifiable {
    case blank = "空白", ruled = "横线", grid = "方格", dots = "点阵"
    var id: String { rawValue }

    /// 用 PDF 绘图指令生成纸张，背景不占用整页位图。
    func page(size: CGSize = CGSize(width: 595, height: 842)) throws -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PadError.message("无法创建笔记纸张。")
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.setStrokeColor(CGColor(gray: 0.82, alpha: 1)); context.setLineWidth(0.4)
        context.setFillColor(CGColor(gray: 0.72, alpha: 1))
        let step: CGFloat = 20
        if self == .ruled || self == .grid {
            for y in stride(from: step, to: size.height, by: step) {
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        if self == .grid {
            for x in stride(from: step, to: size.width, by: step) {
                context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        context.strokePath()
        if self == .dots {
            for y in stride(from: step, to: size.height, by: step) {
                for x in stride(from: step, to: size.width, by: step) {
                    context.fillEllipse(in: CGRect(x: x-0.6, y: y-0.6, width: 1.2, height: 1.2))
                }
            }
        }
        context.endPDFPage(); context.closePDF()
        guard let page = PDFDocument(data: data as Data)?.page(at: 0) else { throw PadError.message("无法读取新建纸张。") }
        return page
    }
}
