import SwiftUI

struct SettingsAIView: View {
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @ObservedObject private var configuration: AIConfigurationStore
    private let keyLoader: (String) throws -> String
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @State private var selectedEndpoint: UUID?
    @State private var draft = AIEndpointConfiguration(name: "", baseURL: "", models: [.init(modelID: "")])
    @State private var apiKey = ""
    @State private var status: Result<String, Error>?
    private func LS(_ key: String) -> String { SimPleview.L.s(key, appLanguage) }

    init(configuration: AIConfigurationStore = .shared,
         keyLoader: @escaping (String) throws -> String = { try APIKeyStore.load(account: $0) }) {
        _configuration = ObservedObject(wrappedValue: configuration)
        self.keyLoader = keyLoader
    }

    var body: some View {
        VStack(spacing: 0) {
            // API 切换仅占顶部一行，把窗口宽度留给地址与模型 ID。
            // “添加 API”直接创建任意接口；服务商模板只是可选的填表捷径。
            HStack(spacing: 12) {
                Picker(LS("Edit API"), selection: $selectedEndpoint) {
                    Text(LS("New API (Unsaved)")).tag(nil as UUID?)
                    ForEach(configuration.endpoints) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ai.endpointPicker")
                Button(LS("Add API"), systemImage: "plus") { addCustomEndpoint() }
                    .accessibilityIdentifier("ai.addEndpoint")
                Menu(LS("Add from Template")) {
                    Button("DeepSeek") { newEndpoint(.deepSeek()) }
                    Button("OpenAI") {
                        newEndpoint(.init(name: "OpenAI", baseURL: "https://api.openai.com/v1", models: [.init(modelID: "")]))
                    }
                    Button(LS("Other Compatible API…")) { addCustomEndpoint() }
                }
            }
            .padding(20)
            Divider()

            // 只有这一层负责滚动，不再把带滚动行为的 Form 嵌套进 ScrollView。
            // 内容没有固定高度；缩小窗口时可滚动，拉高窗口时增加可见编辑区域。
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LS("Connect Your AI")).font(.title2.weight(.semibold))
                        Text(LS("AI Connection Introduction"))
                            .foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent(LS("API Name")) {
                                TextField(LS("API Name Placeholder"), text: $draft.name)
                                    .accessibilityIdentifier("ai.endpointName")
                            }
                            LabeledContent("Base URL") {
                                TextField("https://your-provider.example/v1", text: $draft.baseURL)
                                    .accessibilityIdentifier("ai.baseURL")
                            }
                            LabeledContent("API Key") {
                                SecureField(LS("Enter the API key for this connection"), text: $apiKey)
                            }
                            Text(LS("AI Connection Help"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.textFieldStyle(.roundedBorder).padding(8)
                    } label: { Label(LS("Connection Details"), systemImage: "network") }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach($draft.models) { $model in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        TextField(LS("Exact Model ID"), text: $model.modelID)
                                            .textFieldStyle(.roundedBorder)
                                        Button(role: .destructive) {
                                            let id = model.id
                                            draft.models.removeAll { $0.id == id }
                                        } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.borderless).help(LS("Remove This Model"))
                                    }
                                    Toggle(LS("Supports Images and PDF Reading"), isOn: $model.supportsVision)
                                        .font(.callout)
                                    DisclosureGroup(LS("Context Budget") + ": \(model.contextBudget)") {
                                        Stepper(LS("Adjust Budget"), value: $model.contextBudget, in: 4096...1_000_000, step: 4096)
                                            .font(.caption)
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                            Button(LS("Add Model"), systemImage: "plus") { draft.models.append(.init(modelID: "")) }
                            Text(LS("Exact Model ID Help"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    } label: { Label(LS("Models for This API"), systemImage: "sparkles") }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(LS("Toggle AI Assistant"))
                                Spacer()
                                ShortcutRecorderView(shortcut: $shortcutManager.toggleAIChat, onSave: {
                                    ShortcutManager.shared.saveToDefaults()
                                }).frame(width: 100)
                            }
                            Divider()
                            Button { openGlobalMemoryFile() } label: {
                                Label(LS("Open Global Memory in Finder"), systemImage: "folder")
                            }
                            Text(LS("Global Memory Description")).font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    } label: { Text(LS("Chat Preferences")) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            // 保存按钮固定在底部，模型较多时不必滚到底部才能保存配置。
            HStack(spacing: 12) {
                if configuration.endpoints.contains(where: { $0.id == draft.id }) {
                    Button(LS("Delete API"), role: .destructive) { deleteEndpoint() }
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button(LS("Save"), action: saveEndpoint).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai.saveEndpoint")
            }.padding(16)
        }
        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity,
               minHeight: 500, idealHeight: 720, maxHeight: .infinity)
        .onAppear {
            selectedEndpoint = configuration.endpoints.first?.id
            if selectedEndpoint == nil { addCustomEndpoint() } else { loadEndpoint() }
        }
        .onChange(of: selectedEndpoint) { _, newValue in
            if newValue == nil {
                // 从菜单主动选择“新 API”时不能仍编辑旧接口，避免误覆盖。
                // newEndpoint 已设置新草稿时则保持该草稿（含模板）。
                if configuration.endpoints.contains(where: { $0.id == draft.id }) { addCustomEndpoint() }
            } else { loadEndpoint() }
        }
    }

    // 状态保留消息键/原始错误，在显示时翻译，切换语言后已有提示也立即更新。
    private var statusText: String {
        switch status {
        case .success(let key): return LS(key)
        case .failure(let error):
            let native = error as NSError
            if native.domain == NSOSStatusErrorDomain {
                return String(format: LS("Keychain access failed (code %@)."), String(native.code))
            }
            return LS(error.localizedDescription)
        case nil: return ""
        }
    }

    private func addCustomEndpoint() {
        newEndpoint(.init(name: LS("New API"), baseURL: "", models: [.init(modelID: "")]))
    }

    private func deleteEndpoint() {
        do {
            try configuration.remove(draft.id)
            if let endpoint = configuration.endpoints.first {
                selectedEndpoint = endpoint.id
                loadEndpoint()
            } else { addCustomEndpoint() }
        } catch { status = .failure(error) }
    }

    private func newEndpoint(_ endpoint: AIEndpointConfiguration) {
        selectedEndpoint = nil
        var endpoint = endpoint
        // 同一模板可以配置多组密钥，自动提供可区分的名称供用户修改。
        let name = endpoint.name
        var suffix = 2
        while configuration.endpoints.contains(where: { $0.name.caseInsensitiveCompare(endpoint.name) == .orderedSame }) {
            endpoint.name = "\(name) \(suffix)"; suffix += 1
        }
        draft = endpoint
        apiKey = ""
        status = .success("Save the configuration, then select a model in chat.")
    }
    private func loadEndpoint() {
        guard let endpoint = configuration.endpoints.first(where: { $0.id == selectedEndpoint }) else { return }
        draft = endpoint
        apiKey = ""
        do { apiKey = try keyLoader(endpoint.keyAccount); status = nil }
        catch { status = .failure(error) }
    }
    private func saveEndpoint() {
        do {
            let endpoint = try configuration.validated(draft)
            try APIKeyStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: endpoint.keyAccount)
            try configuration.save(endpoint)
            draft = endpoint
            selectedEndpoint = endpoint.id
            status = .success("Saved. Choose the API and model in the model picker.")
        } catch { status = .failure(error) }
    }

    private func openGlobalMemoryFile() {
        let dir = DirectoryManager.shared.appRootDirectory
        let fileURL = dir.appendingPathComponent("GlobalMemory.md")
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let initialContent = LS("Default AI Memory")
            try? initialContent.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: dir.path)
    }
}
