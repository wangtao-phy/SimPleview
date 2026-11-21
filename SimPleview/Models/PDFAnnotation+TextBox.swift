import AppKit
import PDFKit

extension PDFAnnotation {
    private static let textBoxPrefix = "SimPleview.TextBox."
    private static let textBoxStyleKey = PDFAnnotationKey(rawValue: "/SimPleTextBoxStyle")

    var isAppTextBox: Bool {
        type == "FreeText" && (userName?.hasPrefix(Self.textBoxPrefix) == true || textBoxStyleData != nil)
    }

    var textBoxStyleData: String? { value(forAnnotationKey: Self.textBoxStyleKey) as? String }

    var textBoxStyle: (font: NSFont, color: NSColor)? {
        guard let fields = textBoxStyleData?.components(separatedBy: "\n"), fields.count == 5,
              let size = Double(fields[1]), (6...144).contains(size),
              let red = Double(fields[2]), let green = Double(fields[3]), let blue = Double(fields[4]),
              [red, green, blue].allSatisfy({ (0...1).contains($0) }) else { return nil }
        return (NSFont(name: fields[0], size: size) ?? .systemFont(ofSize: size),
                NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    }

    func assignTextBoxIdentifier() { userName = Self.textBoxPrefix + UUID().uuidString }

    /// 标准 FreeText 会把文字和样式写进 PDF 的外观流，其 Contents 即页面上的文字。
    static func textBox(_ text: String, font: NSFont, color: NSColor, at point: CGPoint, within page: CGRect,
                        rotation: Int = 0) -> PDFAnnotation? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              page.width > 16, page.height > 16 else { return nil }
        // PDFKit 会根据页旋转将 FreeText 保持正向。先在阅读坐标里排版，
        // 再转回 PDF 坐标；否则 90° 或 270° 的页面会把框高误当成行宽。
        let upright = textBoxUprightTransform(rotation: rotation)
        let area = page.applying(upright)
        let anchor = point.applying(upright)
        let wrapWidth = min(area.width, max(190, area.width * 0.6))
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: wrapWidth - 12, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        )
        let width = min(wrapWidth, max(36, ceil(measured.width) + 12))
        let height = ceil(measured.height) + 12
        guard height <= area.height else { return nil }

        // 点击处作为左上角；贴近页面边缘时把整个框移回页内，避免截断内容。
        let x = min(max(anchor.x, area.minX), area.maxX - width)
        let y = min(max(anchor.y - height, area.minY), area.maxY - height)
        let frame = CGRect(x: x, y: y, width: width, height: height).applying(upright.inverted())
        let annotation = PDFAnnotation(bounds: frame,
                                       forType: .freeText, withProperties: nil)
        annotation.assignTextBoxIdentifier()
        annotation.modificationDate = Date()
        annotation.contents = text
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        annotation.font = font
        annotation.fontColor = rgb
        annotation.setValue("\(font.fontName)\n\(font.pointSize)\n\(rgb.redComponent)\n\(rgb.greenComponent)\n\(rgb.blueComponent)",
                            forAnnotationKey: Self.textBoxStyleKey)
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        return annotation
    }

    static func textBoxUprightTransform(rotation: Int) -> CGAffineTransform {
        switch (rotation % 360 + 360) % 360 {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        case 180: CGAffineTransform(scaleX: -1, y: -1)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        default: .identity
        }
    }
}
