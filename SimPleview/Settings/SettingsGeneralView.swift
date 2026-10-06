import SwiftUI
import UniformTypeIdentifiers

/// 通用偏好与模块开关；文件打开和导出偏好由 FileSettingsView 管理。
struct GeneralSettingsView: View {
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @AppStorage("memoryMode") var memoryMode: MemoryMode = .saving
    @AppStorage("hibernationTimeoutStr") var hibernationTimeoutStr: String = "20"

    @AppStorage("externalBrowser") var externalBrowser: ExternalBrowser = .defaultBrowser
    @AppStorage("customBrowserPath") var customBrowserPath: String = ""
    @AppStorage("enableReadingRecord") var enableReadingRecord: Bool = false
    @AppStorage("enableTodo") var enableTodo: Bool = true
    
    @ObservedObject private var features = FeaturePreferences.shared

    let LS: (String) -> String
    
    var body: some View {
        Form {
            Section(LS("Language and Updates")) {
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
                
                Toggle(LS("Automatically check for updates"), isOn: AppStorage(wrappedValue: true, "autoCheckUpdates").projectedValue)
                    .padding(.vertical, 4)
            }
            
            Section(LS("Performance Options")) {
                HStack {
                    Text(LS("Memory Mode") + ":")
                    Spacer()
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
                
                Picker(selection: $hibernationTimeoutStr) {
                    Text(LS("15 Minutes")).tag("15")
                    Text(LS("20 Minutes")).tag("20")
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
            
            Section(LS("External Applications")) {
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
            
            Section(LS("Optional Features")) {
                Toggle(LS("AI Assistant"), isOn: $features.ai)
                Toggle(LS("Window Management"), isOn: $features.windowManagement)
                Toggle(LS("Pomodoro"), isOn: $features.pomodoro)
                Text(LS("Pomodoro Module Help")).font(.caption).foregroundStyle(.secondary)
                Toggle(LS("Background Color"), isOn: $features.eyeCare)
                Toggle(isOn: $enableTodo) {
                    Text(LS("Enable Todo"))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, 4)

                Toggle(isOn: $enableReadingRecord) {
                    Text(LS("Enable Reading Record"))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, 4)
            }

        }
        #if os(macOS)
        .formStyle(.grouped) // 使用 macOS 系统原生的分组表单样式
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 保留无绘制的焦点接收器，避免 macOS Form 首次获得焦点时闪白。
        .background(
            TextField("", text: .constant(""))
                .textFieldStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                #if os(macOS)
                .focusEffectDisabled()
                #endif
        )
    }
    
}
