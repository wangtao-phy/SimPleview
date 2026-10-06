import SwiftUI
import AppKit

/// 标注设置作为 Form 的分组复用，滚动统一交给外层阅读设置页。
struct AnnotationSettingsView: View {
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @AppStorage("annotationRevertTimeoutStr") private var revertTimeout = "15"
    @AppStorage("defaultLineWidth") private var lineWidth = 3.0
    @AppStorage("defaultHighlightColor") private var highlight = "Yellow"
    @AppStorage("defaultUnderlineColor") private var underline = "Blue"
    @AppStorage("defaultStrikeoutColor") private var strikeout = "Red"
    @AppStorage("defaultInkColor") private var ink = "Blue"

    private func text(_ key: String) -> String { L.s(key, language) }

    var body: some View {
        Section(text("Annotation Defaults")) {
            ColorPicker(text("Highlight Default Color"), selection: SettingsColorBinding.make($highlight), supportsOpacity: false)
            ColorPicker(text("Underline Default Color"), selection: SettingsColorBinding.make($underline), supportsOpacity: false)
            ColorPicker(text("Strikeout Default Color"), selection: SettingsColorBinding.make($strikeout), supportsOpacity: false)
            ColorPicker(text("Ink Default Color"), selection: SettingsColorBinding.make($ink), supportsOpacity: false)
            LabeledContent(text("Default Line Weight")) {
                HStack(spacing: 12) {
                    Slider(value: Binding(get: { Double(AnnotationDefaults.lineWidth()) }, set: { lineWidth = $0 }), in: AnnotationDefaults.lineWidthRange, step: 0.5)
                        .frame(maxWidth: 200)
                        .accessibilityLabel(text("Default Line Weight"))
                    Text(String(format: "%.1f pt", Double(AnnotationDefaults.lineWidth())))
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Text(text("Default Line Weight Help")).font(.caption).foregroundStyle(.secondary)
            Label(text("Drawing Width Toolbar Help"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(text("Annotation Behavior")) {
            LabeledContent(text("Return to Selection When Idle")) {
                HStack(spacing: 8) {
                    TextField("", text: $revertTimeout)
                        .labelsHidden()
                        .accessibilityLabel(text("Return to Selection When Idle"))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .onSubmit { revertTimeout = String(Int(ValidatedLimits.seconds(revertTimeout).rounded(.up))) }
                    Text(text("Seconds"))
                }
            }
            Text(text("Annotation Revert Help")).font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: highlight) { _, _ in colorsChanged() }
        .onChange(of: underline) { _, _ in colorsChanged() }
        .onChange(of: strikeout) { _, _ in colorsChanged() }
        .onChange(of: ink) { _, _ in colorsChanged() }
    }

    private func colorsChanged() {
        NotificationCenter.default.post(name: NSNotification.Name("DefaultColorsChanged"), object: nil)
    }
}

/// 兼容已保存的 RGB/RGBA 十六进制颜色，写入时统一为 RGB。
extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        let r, g, b, a: CGFloat
        
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else {
            return nil
        }

        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
