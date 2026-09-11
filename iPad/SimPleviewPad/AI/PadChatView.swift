import SwiftUI
import WebKit

struct PadChatView: View {
    @ObservedObject var session: NotebookSession
    @ObservedObject private var configuration = AIConfigurationStore.shared
    @ObservedObject private var gate = AIRequestGate.shared
    @StateObject private var model: PadChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var settings = false
    @State private var readAll = false
    init(session: NotebookSession) {
        self.session = session
        _model = StateObject(wrappedValue: PadChatModel(url: session.url))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("当前模型", selection: Binding(get: { configuration.selectedModelID }, set: { configuration.select($0) })) {
                    Text("请选择模型").tag(nil as UUID?)
                    ForEach(configuration.routes) { Text($0.label).tag(Optional($0.id)) }
                }.disabled(gate.isBusy).padding(.horizontal)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? "我" : message.requestedModel ?? "AI").font(.caption).foregroundStyle(.secondary)
                                if message.content.isEmpty { Text("正在等待回答…").foregroundStyle(.secondary) }
                                else { PadMarkdownView(markdown: message.content) }
                                if message.generationState == "paused" { Text("已暂停，收到的内容已保留").font(.caption).foregroundStyle(.secondary) }
                            }.padding().background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding()
                }
                if !model.progress.isEmpty { Text(model.progress).font(.caption).padding(4) }
                HStack(alignment: .bottom) {
                    TextField("提问，或填写阅读 PDF 的要求", text: $input, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                    if model.running { Button("暂停", systemImage: "pause.fill") { model.stop() } }
                    else { Button("发送", systemImage: "arrow.up.circle.fill") { send() }.disabled(gate.isBusy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.padding()
                HStack {
                    Button("读取当前页") {
                        model.send(input.isEmpty ? "请解释本页内容。" : input, session: session, pages: [session.pageIndex])
                    }
                    Button("读取整份 PDF") { readAll = true }
                    if model.canResumePDF {
                        Button("继续读取") { model.resumePDF(session: session) }
                    } else if model.messages.last?.generationState == "paused" {
                        Button("继续回答") { model.send("请从刚才中断处继续回答，不要重复已有内容。", session: session) }
                    }
                    Spacer()
                    Text("页面图像发送到所选 API").font(.caption).foregroundStyle(.secondary)
                }.disabled(gate.isBusy).padding([.horizontal,.bottom])
            }
            .navigationTitle("AI 对话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.stop(); dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("API 设置", systemImage: "gearshape") { settings = true } }
            }
        }
        .sheet(isPresented: $settings) { PadAISettings() }
        .alert("读取整份 PDF", isPresented: $readAll) {
            Button("取消", role: .cancel) {}
            Button("开始") { model.send(input.isEmpty ? "请逐页阅读并整理全文要点和公式。" : input, session: session, pages: Array(0..<(session.document?.pageCount ?? 0))) }
        } message: { Text("将分批发送全部页面到所选 API，可能产生较多用量；可随时暂停。") }
        .alert("AI 请求未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onDisappear { model.stop() }
    }
    private func send() {
        let text = input
        model.send(text, session: session)
        if model.running { input = "" }
    }
}

struct PadAISettings: View {
    @ObservedObject private var store = AIConfigurationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AIEndpointConfiguration?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("兼容 Chat Completions 的接口") {
                    ForEach(store.endpoints) { endpoint in
                        Button { editing = endpoint } label: {
                            VStack(alignment: .leading) { Text(endpoint.name); Text(endpoint.baseURL).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.onDelete { offsets in
                        let ids = offsets.map { store.endpoints[$0].id }
                        do { for id in ids { try store.remove(id) } } catch { self.error = error.localizedDescription }
                    }
                    Button("添加 API", systemImage: "plus") {
                        editing = AIEndpointConfiguration(name: "", baseURL: "https://", models: [.init(modelID: "")])
                    }
                }
                Text("每个 API 独立保存密钥。模型 ID 按原样发送，不自动替换型号。密钥保存在此 iPad 的钥匙串中。").font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("AI 设置").toolbar { Button("完成") { dismiss() } }
        }
        .sheet(item: $editing) { endpoint in PadEndpointEditor(endpoint: endpoint) }
        .alert("设置未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct PadEndpointEditor: View {
    @State var endpoint: AIEndpointConfiguration
    @State private var key = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("接口") {
                    TextField("API 名称", text: $endpoint.name)
                    TextField("Base URL", text: $endpoint.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                ForEach($endpoint.models) { $model in
                    Section("模型") {
                        TextField("精确的模型 ID", text: $model.modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("支持图片输入", isOn: $model.supportsVision)
                        TextField("上下文预算", value: $model.contextBudget, format: .number).keyboardType(.numberPad)
                        Button("移除此模型", role: .destructive) { endpoint.models.removeAll { $0.id == model.id } }
                    }
                }
                Button("添加模型") { endpoint.models.append(.init(modelID: "")) }
            }.navigationTitle("API 配置")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do {
                                let value = try AIConfigurationStore.shared.validated(endpoint)
                                try APIKeyStore.save(key, account: value.keyAccount)
                                try AIConfigurationStore.shared.save(value)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
        }
        .task { do { key = try APIKeyStore.load(account: endpoint.keyAccount) } catch { self.error = error.localizedDescription } }
        .alert("设置未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct PadMarkdownView: View {
    let markdown: String
    @State private var height: CGFloat = 60
    var body: some View { PadMarkdownWebView(markdown: markdown, height: $height).frame(height: height) }
}

private struct PadMarkdownWebView: UIViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        if let resources = Bundle.main.url(forResource: "ChatRenderer", withExtension: "bundle") {
            view.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self; context.coordinator.render(view) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stopped = true; view.stopLoading(); view.navigationDelegate = nil }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PadMarkdownWebView
        var loaded = false, busy = false, stopped = false
        var rendered: String?
        init(_ parent: PadMarkdownWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; render(webView) }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["https","http"].contains(url.scheme ?? "") { await UIApplication.shared.open(url) }
                return .cancel
            }
            return !loaded && action.request.url?.isFileURL == true ? .allow : .cancel
        }
        func render(_ view: WKWebView) {
            guard loaded, !busy, !stopped, rendered != parent.markdown else { return }
            busy = true; rendered = parent.markdown
            view.callAsyncJavaScript("return renderContent(markdown);", arguments: ["markdown":parent.markdown], in: nil, in: .page) { [weak self, weak view] result in
                guard let self, !self.stopped else { return }
                self.busy = false
                if case .success(let value) = result, let number = value as? NSNumber, number.doubleValue.isFinite {
                    self.parent.height = min(30000,max(30,CGFloat(number.doubleValue)))
                }
                if let view { self.render(view) }
            }
        }
    }
}
