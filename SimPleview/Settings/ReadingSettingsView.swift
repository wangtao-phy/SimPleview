import SwiftUI

/// 一个原生表单承载标注与阅读记录，避免多层 ScrollView/Form 争夺高度和滚动。
struct ReadingSettingsView: View {
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @AppStorage("enableReadingRecord") private var readingRecord = false

    var body: some View {
        Form {
            AnnotationSettingsView()
            RecordSettingsView().disabled(!readingRecord)
            if !readingRecord {
                Text(L.s("Reading Record Disabled Help", language))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 设置页统一转换已有的命名色和十六进制色，保留旧版本保存的颜色。
@MainActor
enum SettingsColorBinding {
    static func make(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: {
            if let color = NSColor(hex: value.wrappedValue) { return Color(nsColor: color) }
            switch value.wrappedValue {
            case "Blue": return .blue
            case "Red": return .red
            case "Yellow": return .yellow
            case "Green": return .green
            case "Purple": return .purple
            default: return .clear
            }
        }, set: { value.wrappedValue = NSColor($0).hexString })
    }
}
