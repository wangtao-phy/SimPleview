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
    
    var body: some View {
        // [滚动容器] 设置项太多的时候保证不会因为屏幕太小而截断
        ScrollView {
            // [注释/COMMENT] 控制整个阅读记录设置界面的宽度与居中
            VStack {
                // 上半部分：热力图相关的纯 UI 设定
                Form {
                    Section {
                        // [文件保存路径选择器]
                        LabeledContent(LS("Save Location") + ":") {
                            HStack {
                                // .truncationMode(.middle): 如果路径长得像 /Users/xxx/.../Records，中间用省略号折叠，保留头尾
                                Text(tracker.saveDirectoryURL.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundColor(.secondary)
                                
                                Button(LS("Change...")) {
                                    changeSaveDirectory()
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        
                        // [热力图粒度调整器]
                        LabeledContent(LS("Heatmap Granularity") + ":") {
                            HStack {
                                // Slider 就是一个可以左右拖拽的滑块。范围 10 到 100，每次格进 10
                                Slider(value: $heatmapSegments, in: 10...100, step: 10)
                                Text("\(Int(heatmapSegments))")
                                // [注释/COMMENT] 热点图精度后面的数字显示宽度
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 10)
                        
                        // [图表颜色选择]
                        HStack(spacing: 40) {
                            ColorPickerRow(title: LS("Heatmap Color"), selection: $heatmapColorTheme, colors: colors, colorMapper: swiftColor, LS: LS)
                            ColorPickerRow(title: LS("Rating Chart Color"), selection: $ratingChartColorTheme, colors: colors, colorMapper: swiftColor, LS: LS)
                        }
                        .offset(x: 110) // 💡 如果您觉得这一行太靠左或靠右，可以修改这个数字 (正数向右，负数向左)
                    }
                    .frame(maxWidth: 400).offset(x: -30) // 💡 您可以自己调整 450 这个数值，数字越小，这一块看起来就会越聚拢、越窄
                }
                
                // 下半部分：极其复杂的作者大内总管界面
                Form{
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LS("Global Authors Library"))
                                .font(.headline)
                                .padding(.top, 8)
                            
                            // 直接把刚才我们写的那个极其复杂的两列布局大组件给嵌进来！
                            GlobalAuthorsSettingsView(LS: LS)
                        }
                        .offset(x: 20)// 负数代表向左移动（例如 -20），正数代表向右移动（例如 20），0 为不动
                    }
                }
                // [注释/COMMENT] 表单的最大物理宽度
                // 我帮您把这里的宽度从 550 放宽到了 750，这样底部的作者库界面会有极其宽阔的空间
                .frame(maxWidth: 650)
            }
            // 1. padding: 控制包裹上下的留白间距，目前上下留白 40
            .padding(.vertical, 20)
            
            // ==========================================
            // [左右间距/位置微调]
            // 如果您觉得视觉上没有居中，想把它整体向左或向右挪动一点：
            // 修改这里的 x 值：比如 x: -50 就是整体向左移动 50 像素，x: 50 就是向右移动 50 像素
            // ==========================================
            .offset(x: 0)
            
            // 2. alignment: .center 控制包裹在当前界面（无限大的空间）中默认“绝对居中”
            .frame(maxWidth: .infinity, minHeight: 350, alignment: .center)
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
