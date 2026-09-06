import SwiftUI

struct SettingsAIView: View {
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @ObservedObject private var configuration: AIConfigurationStore
    private let keyLoader: (String) throws -> String
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .zh
    @State private var selectedEndpoint: UUID?
    @State private var draft = AIEndpointConfiguration(name: "新 API", baseURL: "", models: [.init(modelID: "")])
    @State private var apiKey = ""
    @State private var status = ""
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
                Picker("编辑 API", selection: $selectedEndpoint) {
                    Text("新 API（未保存）").tag(nil as UUID?)
                    ForEach(configuration.endpoints) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ai.endpointPicker")
                Button("添加 API", systemImage: "plus") { addCustomEndpoint() }
                    .accessibilityIdentifier("ai.addEndpoint")
                Menu("从模板添加") {
                    Button("DeepSeek") { newEndpoint(.deepSeek()) }
                    Button("OpenAI") {
                        newEndpoint(.init(name: "OpenAI", baseURL: "https://api.openai.com/v1", models: [.init(modelID: "")]))
                    }
                    Button("其他兼容接口…") { addCustomEndpoint() }
                }
            }
            .padding(20)
            Divider()

            // 只有这一层负责滚动，不再把带滚动行为的 Form 嵌套进 ScrollView。
            // 内容没有固定高度；缩小窗口时可滚动，拉高窗口时增加可见编辑区域。
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("连接你的 AI").font(.title2.weight(.semibold))
                        Text("支持任意 OpenAI 兼容接口，可分别配置服务地址、密钥和模型。")
                            .foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent("API 名称") {
                                TextField("例如：工作接口、个人接口", text: $draft.name)
                                    .accessibilityIdentifier("ai.endpointName")
                            }
                            LabeledContent("Base URL") {
                                TextField("https://your-provider.example/v1", text: $draft.baseURL)
                                    .accessibilityIdentifier("ai.baseURL")
                            }
                            LabeledContent("API Key") {
                                SecureField("输入此接口的密钥", text: $apiKey)
                            }
                            Text("填写服务商的基础地址，不含 /chat/completions。各 API 的密钥独立保存在钥匙串。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.textFieldStyle(.roundedBorder).padding(8)
                    } label: { Label("连接信息", systemImage: "network") }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach($draft.models) { $model in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        TextField("精确模型 ID", text: $model.modelID)
                                            .textFieldStyle(.roundedBorder)
                                        Button(role: .destructive) {
                                            let id = model.id
                                            draft.models.removeAll { $0.id == id }
                                        } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.borderless).help("删除此模型")
                                    }
                                    Toggle("支持图片输入，可读取 PDF", isOn: $model.supportsVision)
                                        .font(.callout)
                                    DisclosureGroup("上下文预算：\(model.contextBudget)") {
                                        Stepper("调整预算", value: $model.contextBudget, in: 4096...1_000_000, step: 4096)
                                            .font(.caption)
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                            Button("添加模型", systemImage: "plus") { draft.models.append(.init(modelID: "")) }
                            Text("模型 ID 将原样发送给此 API。请按服务商提供的型号填写，并仅为支持图片的模型开启 PDF 阅读。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    } label: { Label("此 API 的模型", systemImage: "sparkles") }

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
                    } label: { Text("对话偏好") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            // 保存按钮固定在底部，模型较多时不必滚到底部才能保存配置。
            HStack(spacing: 12) {
                if configuration.endpoints.contains(where: { $0.id == draft.id }) {
                    Button("删除 API", role: .destructive) { deleteEndpoint() }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button("保存", action: saveEndpoint).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai.saveEndpoint")
            }.padding(16)
        }
        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity,
               minHeight: 500, idealHeight: 720, maxHeight: .infinity)
        .onAppear {
            selectedEndpoint = configuration.endpoints.first?.id
            loadEndpoint()
        }
        .onChange(of: selectedEndpoint) { _, newValue in
            if newValue == nil {
                // 从菜单主动选择“新 API”时不能仍编辑旧接口，避免误覆盖。
                // newEndpoint 已设置新草稿时则保持该草稿（含模板）。
                if configuration.endpoints.contains(where: { $0.id == draft.id }) { addCustomEndpoint() }
            } else { loadEndpoint() }
        }
    }

    private func addCustomEndpoint() {
        newEndpoint(.init(name: "新 API", baseURL: "", models: [.init(modelID: "")]))
    }

    private func deleteEndpoint() {
        do {
            try configuration.remove(draft.id)
            if let endpoint = configuration.endpoints.first {
                selectedEndpoint = endpoint.id
                loadEndpoint()
            } else { addCustomEndpoint() }
        } catch { status = error.localizedDescription }
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
        status = "填写后保存，再到聊天中选择模型。"
    }
    private func loadEndpoint() {
        guard let endpoint = configuration.endpoints.first(where: { $0.id == selectedEndpoint }) else { return }
        draft = endpoint
        apiKey = ""
        do { apiKey = try keyLoader(endpoint.keyAccount); status = "" }
        catch { status = error.localizedDescription }
    }
    private func saveEndpoint() {
        do {
            let endpoint = try configuration.validated(draft)
            try APIKeyStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: endpoint.keyAccount)
            try configuration.save(endpoint)
            draft = endpoint
            selectedEndpoint = endpoint.id
            status = "已保存；请在模型选择器中选择所需 API 和型号。"
        } catch { status = error.localizedDescription }
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
