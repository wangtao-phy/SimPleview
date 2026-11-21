import AppKit
import CoreText
import PDFKit

/// 主线程排版，只缓存不可变字体和字形位置。文本框视图按当前缩放绘制，
/// PDFKit 的瓦片快照不持有编辑控件或活动批注。
nonisolated struct PDFTextBoxDrawing: @unchecked Sendable {
    private struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
    }

    private let text: String
    private let style: String
    let bounds: CGRect
    private let rotation: Int
    private let upright: CGAffineTransform
    private let color: CGColor
    private let runs: [Run]

    @MainActor static func capture(_ annotation: PDFAnnotation, rotation: Int, reusing old: Self?) -> Self? {
        guard let text = annotation.contents, !text.isEmpty, let style = annotation.textBoxStyleData else { return nil }
        let bounds = annotation.bounds
        if let old, old.text == text, old.style == style, old.bounds == bounds, old.rotation == rotation { return old }
        guard let format = annotation.textBoxStyle, !bounds.isEmpty else { return nil }

        let upright = PDFAnnotation.textBoxUprightTransform(rotation: rotation)
        let area = bounds.applying(upright).insetBy(dx: 2, dy: 2)
        guard !area.isEmpty else { return nil }
        let content = NSAttributedString(string: text, attributes: [.font: format.font])
        let typesetter = CTFramesetterCreateWithAttributedString(content)
        let frame = CTFramesetterCreateFrame(typesetter, CFRange(), CGPath(rect: area, transform: nil), nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        var runs: [Run] = []
        for (line, origin) in zip(lines, origins) {
            guard let lineRuns = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in lineRuns {
                let count = CTRunGetGlyphCount(run)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard count > 0, let font = attributes[kCTFontAttributeName] as? NSFont else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                for index in positions.indices {
                    positions[index].x += area.minX + origin.x
                    positions[index].y += area.minY + origin.y
                }
                runs.append(Run(font: font as CTFont, glyphs: glyphs, positions: positions))
            }
        }
        guard !runs.isEmpty else { return nil }
        return Self(text: text, style: style, bounds: bounds, rotation: rotation,
                    upright: upright, color: format.color.cgColor, runs: runs)
    }

    func draw(in context: CGContext, inverted: Bool = false) {
        context.saveGState()
        context.clip(to: bounds)
        context.concatenate(upright.inverted())
        context.setShouldAntialias(true)
        if inverted, let components = color.components, components.count == 4 {
            context.setFillColor(CGColor(red: 1 - components[0], green: 1 - components[1],
                                         blue: 1 - components[2], alpha: components[3]))
        } else {
            context.setFillColor(color)
        }
        context.setTextDrawingMode(.fill)
        context.textMatrix = .identity
        for run in runs { CTFontDrawGlyphs(run.font, run.glyphs, run.positions, run.glyphs.count, context) }
        context.restoreGState()
    }
}
