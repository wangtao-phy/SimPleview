import SwiftUI
import UniformTypeIdentifiers

/// [教程注释：通用设置面板 (GeneralSettingsView)]
/// 这个页面负责整个应用程序最基础的核心配置：语言、行为逻辑、外部浏览器等。
/// 所有这里被修改的变量，都会像树根一样，通过 UserDefaults 渗透进 App 的每个角落。
struct GeneralSettingsView: View {
    // [AppStorage: 最纯粹的硬盘绑定]
    // 当你在界面上切换这些变量的值时，SwiftUI 会以毫秒级的速度把它们直接写死在设备的硬盘上。
    // 这也是为什么你杀后台重启，所有的设置依然原封不动的核心原因。
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @AppStorage("memoryMode") var memoryMode: MemoryMode = .saving
    @AppStorage("hibernationTimeoutStr") var hibernationTimeoutStr: String = "20"

    @AppStorage("externalBrowser") var externalBrowser: ExternalBrowser = .defaultBrowser
    @AppStorage("customBrowserPath") var customBrowserPath: String = ""
    @AppStorage("enableReadingRecord") var enableReadingRecord: Bool = false
    
    @State private var selectedImageFormat: String = "All"
    
    // 我们把多语言翻译函数作为外包传入，让这个视图不用关心它是怎么被翻译的，只管显示就行
    let LS: (String) -> String
    
    var body: some View {
        // [原生化重构] 采用 SwiftUI 原生表单布局并配合 Section 完美分组
        Form {
            Section {
                // [设置项 1：切换多国语言]
                Picker(selection: $appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: {
                    Text(LS("Switch Language") + ":")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .pickerStyle(.menu)
                .padding(.vertical, 4)
                
                // [设置项 1.1：自动检查更新]
                Toggle(LS("Automatically check for updates"), isOn: AppStorage(wrappedValue: true, "autoCheckUpdates").projectedValue)
                    .padding(.vertical, 4)
            }
            
            Section {
                // [设置项 1.5：内存运行模式]
                HStack {
                    Text(LS("Memory Mode") + ":")
                    Spacer()
                    // 调整这里的宽度或 Spacer() 就能控制右侧间距。
                    // 之前的定宽可能限制了它的伸缩。现在去掉 frame 限制，让它自由贴在最右边。
                    Picker("", selection: $memoryMode) {
                        ForEach(MemoryMode.allCases, id: \.self) { mode in
                            Text(LS(mode == .performance ? "Performance" : "Saving")).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .id(appLanguage)
                }
                .padding(.vertical, 4)
                
                // [设置项 2：休眠断电超时设定]
                Picker(selection: $hibernationTimeoutStr) {
                    Text(LS("15 Minutes")).tag("15")
                    Text(LS("30 Minutes")).tag("30")
                    Text(LS("60 Minutes")).tag("60")
                    Text(LS("Never")).tag("0")
                } label: {
                    Text(LS("Hibernation Timeout") + ":")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .pickerStyle(.menu)
                .padding(.vertical, 4)
            }
            
            Section {
                // [设置项 4：外部跳转的浏览器]
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: $externalBrowser) {
                        ForEach(ExternalBrowser.allCases) { browser in
                            Text(LS(browser.displayName)).tag(browser)
                        }
                    } label: {
                        Text(LS("External Browser") + ":")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: externalBrowser) { _, newValue in
                        if newValue == .other {
                            #if os(macOS)
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            panel.canCreateDirectories = false
                            panel.allowedContentTypes = [UTType.application]
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            
                            if panel.runModal() == .OK, let url = panel.url {
                                customBrowserPath = url.path
                            } else {
                                if customBrowserPath.isEmpty {
                                    externalBrowser = .defaultBrowser
                                }
                            }
                            #endif
                        }
                    }
                    
                    if externalBrowser == .other && !customBrowserPath.isEmpty {
                        Text(URL(fileURLWithPath: customBrowserPath).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 150)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section {
                // [设置项 5：阅读记录总开关]
                Toggle(isOn: $enableReadingRecord) {
                    Text(LS("Enable Reading Record"))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, 4)
            }
            
            #if os(macOS)
            Section {
                HStack(spacing: 8) {
                    Picker("", selection: $selectedImageFormat) {
                        Text(LS("All Supported Formats")).tag("All")
                        Text("PDF").tag("PDF")
                        Text("PNG").tag("PNG")
                        Text("JPEG").tag("JPEG")
                        Text("TIFF").tag("TIFF")
                    }
                    .frame(width: 160)
                    .labelsHidden()
                    
                    Button(LS("Set as Default Viewer")) {
                        var types: [UTType] = []
                        switch selectedImageFormat {
                        case "All": types = [.pdf, .png, .jpeg, .tiff]
                        case "PDF": types = [.pdf]
                        case "PNG": types = [.png]
                        case "JPEG": types = [.jpeg]
                        case "TIFF": types = [.tiff]
                        default: types = [.pdf, .png, .jpeg, .tiff]
                        }
                        setDefaultApplication(for: types)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            #endif
        }
        #if os(macOS)
        .formStyle(.grouped) // 使用 macOS 系统原生的分组表单样式
        #endif
        .frame(width: 420, height: 480) // 固定原生宽度和高度，缩小宽度让它看起来更精致
        .background(
            // [黑科技修复] 彻底解决带有 TextField 的 Form 启动时白屏闪烁的系统级 Bug：
            // 添加 .textFieldStyle(.plain) 和 .focusEffectDisabled() 确保焦点被吸收的同时绝对不绘制任何背景白框
            TextField("", text: .constant(""))
                .textFieldStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                #if os(macOS)
                .focusEffectDisabled()
                #endif
        )
    }
    
    #if os(macOS)
    private func setDefaultApplication(for contentTypes: [UTType]) {
        let myURL = Bundle.main.bundleURL
        
        Task { @MainActor in
            var errorMessages = [String]()
            
            for type in contentTypes {
                let error: Error? = await withCheckedContinuation { continuation in
                    NSWorkspace.shared.setDefaultApplication(at: myURL, toOpen: type) { error in
                        continuation.resume(returning: error)
                    }
                }
                
                if let error = error {
                    errorMessages.append("\(type.identifier): \(error.localizedDescription)")
                }
            }
            
            let alert = NSAlert()
            if errorMessages.isEmpty {
                alert.messageText = "设置成功"
                alert.informativeText = "已成功将 SimPleview 设为相关文件类型的默认应用。"
                alert.alertStyle = .informational
            } else {
                alert.messageText = "部分设置失败"
                alert.informativeText = errorMessages.joined(separator: "\n")
                alert.alertStyle = .warning
            }
            alert.runModal()
        }
    }
    #endif
}
