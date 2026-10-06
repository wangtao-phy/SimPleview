import SwiftUI

/// 阅读记录的存放位置和图表设置，作为阅读设置页的一组表单项。
struct RecordSettingsView: View {
    // [AppStorage 数据源绑定]
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @AppStorage("heatmapSegments") var heatmapSegments: Double = 50.0
    @AppStorage("heatmapColorTheme") var heatmapColorTheme: String = "Red"
    @AppStorage("ratingChartColorTheme") var ratingChartColorTheme: String = "Blue"
    
    // [ObservedObject 内存管理绑定]
    // 追踪器和作者大总管
    @ObservedObject var tracker = ReadingTracker.shared
    
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }

    // 与阅读图表使用相同的有限值检查，不能直接 Int(NaN/Infinity)。
    private var segmentCount: Int { ValidatedLimits.count(heatmapSegments, fallback: 50, range: 10...100) }
    
    var body: some View {
        Section(LS("Reading Record Settings")) {
            LabeledContent(LS("Save Location")) {
                HStack {
                    Text(tracker.saveDirectoryURL.path)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button(LS("Change...")) { changeSaveDirectory() }
                }
            }
            LabeledContent(LS("Heatmap Granularity")) {
                HStack {
                    Slider(value: Binding(get: { Double(segmentCount) }, set: { heatmapSegments = $0 }), in: 10...100, step: 10)
                        .frame(maxWidth: 200)
                        .accessibilityLabel(LS("Heatmap Granularity"))
                    Text("\(segmentCount)").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
            ColorPicker(LS("Heatmap Color"), selection: SettingsColorBinding.make($heatmapColorTheme), supportsOpacity: false)
            ColorPicker(LS("Rating Chart Color"), selection: SettingsColorBinding.make($ratingChartColorTheme), supportsOpacity: false)
        }
    }

    // [底层交互：修改阅读记录存放在硬盘里的哪一层文件夹]
    private func changeSaveDirectory() {
        let panel = NSOpenPanel()
        // 禁止选具体的文件
        panel.canChooseFiles = false
        // 只能选一个“文件夹”
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = LS("Select")
        
        if panel.runModal() == .OK, let url = panel.url {
            // 先保存旧目录的记录，再切换目录；原记录不会自动搬迁。
            tracker.customDirectoryURL = url
        }
    }
}
