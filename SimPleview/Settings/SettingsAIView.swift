import SwiftUI

struct SettingsAIView: View {
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    
    private func LS(_ key: String) -> String {
        return SimPleview.L.s(key, appLanguage)
    }
    @AppStorage("aiProvider") private var aiProvider: String = "OpenAI"
    @AppStorage("aiAPIKey") private var aiAPIKey: String = ""
    @AppStorage("aiBaseURL") private var aiBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("aiAvailableModels_v2") private var aiAvailableModels: String = "gpt-5.5,gpt-5.6"
    @AppStorage("aiModel_v2") private var aiModel: String = "gpt-5.5"
    
    let providers = ["OpenAI", "Gemini", "DeepSeek"]
    
    var body: some View {
        ScrollView {
            Form {
                Section(header: Text(LS("AI Basic Configuration")).font(.headline)) {
                    Picker(LS("API Protocol"), selection: $aiProvider) {
                        ForEach(providers, id: \.self) { provider in
                            Text(provider).tag(provider)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.bottom, 8)
                    .onChange(of: aiProvider) { _, newValue in
                        if newValue == "OpenAI" {
                            aiBaseURL = "https://api.openai.com/v1"
                            aiAvailableModels = "gpt-5.5,gpt-5.6"
                            aiModel = "gpt-5.5"
                        } else if newValue == "DeepSeek" {
                            aiBaseURL = "https://api.deepseek.com"
                            aiAvailableModels = "deepseek-v4-flash,deepseek-v4-pro,deepseek-v4-flash-vision-exp"
                            aiModel = "deepseek-v4-flash"
                        } else if newValue == "Gemini" {
                            aiBaseURL = "https://generativelanguage.googleapis.com/v1beta"
                            aiAvailableModels = "gemini-3.1-pro,gemini-3.7-flash"
                            aiModel = "gemini-3.1-pro"
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                        TextField("", text: $aiAPIKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL")
                        TextField("", text: $aiBaseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(LS("Base URL Description"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                
                Section(header: Text(LS("Model List")).font(.headline)) {
                    TextField(LS("Comma Separated"), text: $aiAvailableModels)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .labelsHidden()
                    
                    Text(LS("Model List Description"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                

                Section(header: Text(LS("Shortcut Configuration")).font(.headline)) {
                    HStack {
                        Text(LS("Toggle AI Assistant"))
                        Spacer()
                        ShortcutRecorderView(shortcut: $shortcutManager.toggleAIChat, onSave: {
                            ShortcutManager.shared.saveToDefaults()
                        })
                        .frame(width: 100)
                    }
                    Text(LS("Shortcut Description"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                

                Section(header: Text(LS("Global Memory")).font(.headline)) {
                    Button(action: {
                        openGlobalMemoryFile()
                    }) {
                        HStack {
                            Image(systemName: "folder")
                            Text(LS("Open Global Memory in Finder"))
                        }
                    }
                    Text(LS("Global Memory Description"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .frame(width: 600, height: 500)
    }
    
    private func openGlobalMemoryFile() {
        let dir = DirectoryManager.shared.appRootDirectory
        let fileURL = dir.appendingPathComponent("GlobalMemory.md")
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let initialContent = "你是一个理论物理学家。请用物理学家的口吻回答，并尽量使用数学公式。"
            try? initialContent.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: dir.path)
    }
}
