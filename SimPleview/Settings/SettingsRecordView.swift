import SwiftUI

/// [教程注释：阅读记录与作者管理库的综合设置面板]
/// 为什么阅读记录（Record）和作者库（Authors）会放在一起？
/// 因为“阅读记录”的每一篇论文都需要“作者”署名，它们在底层数据结构上是高度耦合的。
struct RecordSettingsView: View {
    // [AppStorage 数据源绑定]
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @AppStorage("recordEnabled") var recordEnabled: Bool = true
    @AppStorage("heatmapSegments") var heatmapSegments: Double = 50.0
    @AppStorage("heatmapColorTheme") var heatmapColorTheme: String = "Red"
    @AppStorage("ratingChartColorTheme") var ratingChartColorTheme: String = "Blue"
    
    // [ObservedObject 内存管理绑定]
    // 追踪器和作者大总管
    @ObservedObject var tracker = ReadingTracker.shared
    @ObservedObject var globalManager = GlobalAuthorManager.shared
    
    let colors = ["Blue", "Red", "Yellow", "Green", "Purple"]
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    
    private func swiftColor(for name: String) -> Color {
        if name.hasPrefix("#") {
            #if os(macOS)
            return Color(nsColor: NSColor(hex: name) ?? .clear)
            #else
            return .clear
            #endif
        }
        switch name {
        case "Blue": return .blue
        case "Red": return .red
        case "Yellow": return .yellow
        case "Green": return .green
        case "Purple": return .purple
        default: return .clear
        }
    }
    
    // [原生化] 适配系统原生 ColorPicker
    private func colorBinding(for colorString: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { self.swiftColor(for: colorString.wrappedValue) },
            set: { newColor in
                #if os(macOS)
                colorString.wrappedValue = NSColor(newColor).hexString
                #else
                let uiColor = UIColor(newColor)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
                let red = Int(round(r * 255)), green = Int(round(g * 255)), blue = Int(round(b * 255))
                colorString.wrappedValue = String(format: "#%02X%02X%02X", red, green, blue)
                #endif
            }
        )
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 上半部分：热力图相关的纯 UI 设定
                Form {
                    Section(LS("General Options")) {
                        // [文件保存路径选择器]
                        LabeledContent(LS("Save Location") + ":") {
                            HStack {
                                Text(tracker.saveDirectoryURL.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundColor(.secondary)
                                
                                Button(LS("Change...")) {
                                    changeSaveDirectory()
                                }
                            }
                        }
                        
                        // [热力图粒度调整器]
                        LabeledContent(LS("Heatmap Granularity") + ":") {
                            HStack {
                                Slider(value: $heatmapSegments, in: 10...100, step: 10)
                                Text("\(Int(heatmapSegments))")
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                        
                        // [图表颜色选择]
                        ColorPicker(LS("Heatmap Color") + ":", selection: colorBinding(for: $heatmapColorTheme), supportsOpacity: false)
                        ColorPicker(LS("Rating Chart Color") + ":", selection: colorBinding(for: $ratingChartColorTheme), supportsOpacity: false)
                    }
                }
                #if os(macOS)
                .formStyle(.grouped)
                #endif
                .frame(maxWidth: 500)
                
                // 下半部分：极其复杂的作者大内总管界面
                VStack(alignment: .leading, spacing: 8) {
                    Text(LS("Global Authors Library"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    GlobalAuthorsSettingsView(LS: LS)
                }
                .frame(maxWidth: 700)
                .frame(minHeight: 400)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    
    // [底层交互：修改阅读记录存放在硬盘里的哪一层文件夹]
    private func changeSaveDirectory() {
        #if os(macOS)
        let panel = NSOpenPanel()
        // 禁止选具体的文件
        panel.canChooseFiles = false
        // 只能选一个“文件夹”
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = LS("Select")
        
        if panel.runModal() == .OK, let url = panel.url {
            // 如果选好了，告诉底层引擎切换写入目标。引擎会自动把老文件夹的东西搬去新文件夹。
            tracker.customDirectoryURL = url
        }
        #else
        // iOS Directory selection uses Document picker which is limited.
        // It's recommended to stick to the sandbox Documents folder on iOS.
        // Directory change is not supported on iOS directly due to sandboxing.
        #endif
    }
}
