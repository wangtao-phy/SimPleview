import Foundation
import Combine
import SwiftUI
import PDFKit

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isGenerating = false
    @Published var isCompressing = false
    @Published var isStopping = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var estimatedContextTokens = 0
    @Published var lastUsage: TokenUsage? {
        didSet {
            if let usage = lastUsage {
                UserDefaults.standard.set(usage.promptTokens, forKey: "lastPromptTokens")
                UserDefaults.standard.set(usage.completionTokens, forKey: "lastCompletionTokens")
                UserDefaults.standard.set(usage.cachedTokens, forKey: "lastCachedTokens")
            }
        }
    }
    @Published var availableSessions: [ConversationSession] = []
    @Published var currentSessionID: UUID?
    let configuration: AIConfigurationStore
    let gate: AIRequestGate
    let transport: any AIChatTransport
    let conversations: ConversationManager
    let keyLoader: (String) throws -> String
    private var documentID: String?
    var generationTask: Task<Void, Never>?
    var requestID = UUID()
    var taskToken: UUID?
    var activeAssistantID: UUID?
    var rawContent = ""
    var rawThinking = ""
    var rawStreamText = ""
    var pdfRun: PDFVisionRun?
    var canResume: Bool { !isGenerating && ["paused", "failed"].contains(messages.last?.generationState ?? "") }

    init(configuration: AIConfigurationStore = .shared, transport: any AIChatTransport = AIChatService.shared,
         conversations: ConversationManager = .shared, gate: AIRequestGate = .shared,
         keyLoader: @escaping (String) throws -> String = { try APIKeyStore.load(account: $0) }) {
        self.configuration = configuration; self.transport = transport
        self.conversations = conversations; self.gate = gate; self.keyLoader = keyLoader
    }
    deinit { generationTask?.cancel() }

    func owns(_ request: UUID, session: UUID) -> Bool { requestID == request && currentSessionID == session }

    /// 暂停取消实际网络 Task，保留已收到的半句话。旧回调先失去提交资格，
    /// 但生成名额仍由旧 Task 的 defer 释放，取消期间不会发出下一条请求。
    func pauseGeneration() {
        guard isGenerating, !isStopping else { return }
        requestID = UUID()
        isStopping = true
        if let id = activeAssistantID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = rawContent
            messages[index].thinking = rawThinking.isEmpty ? nil : rawThinking
            if messages[index].pdfProgress != nil {
                if messages[index].pdfSummary != nil { messages[index].pdfSummary = rawStreamText }
                else { messages[index].pdfLatestText = rawStreamText }
            }
            messages[index].generationState = "paused"
        }
        status = "正在暂停…"
        generationTask?.cancel()
        saveCurrentSession()
    }
    func cancelPendingWork() { pauseGeneration(); saveCurrentSession() }

    func configure(with documentID: String, legacyName: String? = nil) {
        guard self.documentID != documentID else { return }
        cancelPendingWork()
        pdfRun = nil
        self.documentID = documentID
        currentSessionID = nil
        messages = []
        if let legacyName { conversations.migrateLegacySessions(named: legacyName, to: documentID) }
        availableSessions = conversations.loadSessions(for: documentID)
        if let last = availableSessions.first { switchSession(to: last.id) } else { createNewSession() }
    }
    func createNewSession() {
        cancelPendingWork()
        guard let documentID else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
        let session = ConversationSession(id: UUID(), documentID: documentID, createdAt: Date(), updatedAt: Date(), title: "对话 " + formatter.string(from: Date()), messages: [])
        availableSessions.insert(session, at: 0); currentSessionID = session.id; messages = []
        saveCurrentSession()
    }
    func switchSession(to id: UUID) {
        cancelPendingWork()
        guard let documentID else { return }
        do {
            let session = try conversations.loadSession(id: id, documentID: documentID)
            currentSessionID = session.id; messages = session.messages
            // 上次进程意外结束的 running 消息只能续答，不能伪装成已完成。
            for index in messages.indices where messages[index].generationState == "running" { messages[index].generationState = "paused" }
        } catch { errorMessage = "读取对话失败：" + error.localizedDescription }
    }
    func saveCurrentSession() {
        guard let documentID, let id = currentSessionID,
              let index = availableSessions.firstIndex(where: { $0.id == id && $0.documentID == documentID }) else { return }
        availableSessions[index].updatedAt = Date()
        var snapshot = availableSessions[index]; snapshot.messages = messages
        conversations.saveSession(snapshot)
        estimatedContextTokens = AIContextBuilder.cost(messages) / 2
        UserDefaults.standard.set(estimatedContextTokens, forKey: "estimatedContextTokens")
    }

    func sendMessage(appState: AppState?) {
        guard !gate.isBusy, !isGenerating, currentSessionID != nil,
              !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let route = try configuration.requireRoute()
            var text = inputText
            if let selection = appState?.pdfView.currentSelection?.string, !selection.isEmpty {
                text = "关于以下 PDF 选段：\n\(selection)\n\n" + text
            }
            messages.append(ChatMessage(role: "user", content: text))
            inputText = ""
            let context = requestContext(messages)
            let assistant = newAssistant(route: route)
            messages.append(assistant)
            startTextRequest(route: route, context: context, assistantID: assistant.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func resumeAnswer() {
        guard canResume, !gate.isBusy, let message = messages.last, let routeID = message.routeID else { return }
        if message.pdfProgress != nil { resumePDFReading(); return }
        do {
            let route = try configuration.requireRoute(id: routeID)
            guard route.model.modelID == message.requestedModel, route.endpoint.baseURL == message.requestEndpoint else {
                throw AIConfigurationError.message("原回答的 API/模型配置已经改变，请重新发送问题；续答不会悄悄换用另一个模型。")
            }
            var context = requestContext(messages)
            context.append(ChatMessage(role: "user", content: "继续刚才未完成的回答，从已输出内容后接着回答，不要重复已有段落。"))
            startTextRequest(route: route, context: context, assistantID: message.id, prefix: message.content.isEmpty ? "" : message.content + "\n")
        } catch { errorMessage = error.localizedDescription }
    }

    func newAssistant(route: AIRoute) -> ChatMessage {
        ChatMessage(role: "assistant", content: "", thinking: "", routeID: route.id,
            apiName: route.endpoint.name, requestedModel: route.model.modelID,
            requestEndpoint: route.endpoint.baseURL, generationState: "running")
    }
    func requestContext(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result = messages.filter { !$0.content.isEmpty }
        let memory = DirectoryManager.shared.appRootDirectory.appendingPathComponent("GlobalMemory.md")
        if let size = try? memory.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256_000,
           let prompt = try? String(contentsOf: memory, encoding: .utf8), !prompt.isEmpty {
            result.insert(ChatMessage(role: "system", content: prompt), at: 0)
        }
        return result
    }

    func begin(route: AIRoute, assistantID: UUID, prefix: String = "") throws -> (UUID, UUID, String) {
        guard let session = currentSessionID else { throw AIConfigurationError.message("请先选择对话。") }
        let token = try gate.acquire(label: route.label)
        do {
            let key = try keyLoader(route.endpoint.keyAccount)
            guard !key.isEmpty else { throw AIConfigurationError.message("请先为 \(route.endpoint.name) 保存 API Key。") }
            requestID = token; taskToken = token; activeAssistantID = assistantID
            isGenerating = true; isStopping = false; rawContent = prefix; rawThinking = ""; rawStreamText = ""
            errorMessage = nil
            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[index].generationState = "running"; messages[index].errorMessage = nil
            }
            status = "正在使用 \(route.label)"
            return (token, session, key)
        } catch { gate.release(token); throw error }
    }

    func startTextRequest(route: AIRoute, context: [ChatMessage], assistantID: UUID, prefix: String = "") {
        do {
            let (token, session, key) = try begin(route: route, assistantID: assistantID, prefix: prefix)
            let transport = transport, gate = gate
            let budget = max(2048, route.model.contextBudget - min(8192, route.model.contextBudget / 4))
            saveCurrentSession()
            generationTask = Task { [weak self] in
                defer { gate.release(token); self?.finishTask(token) }
                do {
                    self?.isCompressing = AIContextBuilder.cost(context) > budget
                    let prepared = try await AIContextBuilder.prepare(context, budget: max(1024, budget - 256)) { batch in
                        try await Self.summarize(batch, route: route, key: key, transport: transport)
                    }
                    try Task.checkCancellation()
                    guard self?.owns(token, session: session) == true else { return }
                    self?.isCompressing = false
                    try await transport.stream(route: route, apiKey: key, messages: prepared, images: []) { [weak self] update in
                        guard let self, self.owns(token, session: session) else { return }
                        self.accept(update, assistantID: assistantID, prefix: prefix)
                    }
                    try Task.checkCancellation()
                    self?.complete(assistantID, token: token, session: session)
                } catch {
                    guard !Task.isCancelled, self?.owns(token, session: session) == true else { return }
                    self?.fail(assistantID, error: error)
                }
            }
        } catch { fail(assistantID, error: error) }
    }

    static func summarize(_ messages: [ChatMessage], route: AIRoute, key: String, transport: any AIChatTransport) async throws -> String {
        var input = messages
        input.append(ChatMessage(role: "user", content: "请精简总结以上上下文，保留重要事实、公式及页码。只返回摘要。"))
        var summary = ""
        try await transport.stream(route: route, apiKey: key, messages: input, images: []) { update in summary = update.content }
        return summary
    }
    func accept(_ update: AIStreamUpdate, assistantID: UUID, prefix: String = "") {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        rawContent = prefix + update.content; rawThinking = update.thinking; rawStreamText = update.content
        if messages[index].pdfProgress != nil { messages[index].pdfLatestText = AISentencePresentation.text(update.content, final: update.complete) }
        messages[index].content = prefix + AISentencePresentation.text(update.content, final: update.complete)
        messages[index].thinking = update.thinking.isEmpty ? nil : update.thinking
        if let model = update.responseModel { messages[index].responseModel = model }
        if let usage = update.usage { lastUsage = usage }
    }
    func complete(_ id: UUID, token: UUID, session: UUID) {
        guard owns(token, session: session), let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = rawContent
        messages[index].generationState = "completed"
        status = "回答完成"; saveCurrentSession()
    }
    func fail(_ id: UUID, error: Error) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            if activeAssistantID == id { messages[index].content = rawContent }
            messages[index].generationState = "failed"
            messages[index].errorMessage = error.localizedDescription
        }
        errorMessage = error.localizedDescription
        saveCurrentSession()
    }
    func finishTask(_ token: UUID) {
        guard taskToken == token else { return }
        taskToken = nil; generationTask = nil; activeAssistantID = nil
        isGenerating = false; isCompressing = false
        if isStopping { status = "已暂停，保留了收到的内容；可继续回答。" }
        isStopping = false
    }
}
