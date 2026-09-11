import SwiftUI
import CryptoKit
import PDFKit

private struct PDFReadJob {
    let route: AIRoute
    let pages: [Int]
    let prompt: String
    let revision: Int
    var completed = 0
    var notes: [ChatMessage] = []
}

@MainActor final class PadChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var running = false
    @Published var error: String?
    @Published var progress = ""
    private var task: Task<Void, Never>?
    private let file: URL
    private let transport: any AIChatTransport
    private var rawResponse = ""
    private var activeAnswer: UUID?
    @Published private var pendingRead: PDFReadJob?
    var canResumePDF: Bool { pendingRead != nil && !running }
    func resumePDF(session: NotebookSession) {
        guard let job = pendingRead else { return }
        send(job.prompt, session: session, pages: job.pages, resuming: true)
    }
    init(url: URL, transport: any AIChatTransport = AIChatService.shared) {
        self.transport = transport
        let hash = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Chat", isDirectory: true)
        file = directory.appendingPathComponent(hash + ".json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) { messages = try JSONDecoder().decode([ChatMessage].self, from: Data(contentsOf: file)) }
        } catch { self.error = "会话读取失败：" + error.localizedDescription }
    }
    func stop() { task?.cancel() }
    func send(_ prompt: String, session: NotebookSession, pages: [Int]? = nil, resuming: Bool = false) {
        guard !running, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let route = try AIConfigurationStore.shared.requireRoute()
            let key = try APIKeyStore.load(account: route.endpoint.keyAccount)
            guard !key.isEmpty else { throw AIConfigurationError.message("请先保存所选 API 的密钥。") }
            if pages != nil && !route.model.supportsVision { throw AIConfigurationError.message("所选模型未启用图片输入。") }
            let snapshot = pages == nil ? nil : try session.snapshot()
            if resuming {
                guard let job = pendingRead, job.revision == session.revision, job.route == route else {
                    throw PadError.message("继续读取需要原来的模型配置和未修改的 PDF；请重新选择原模型，或重新开始读取。")
                }
            }
            let token = try AIRequestGate.shared.acquire(label: route.label)
            if !resuming {
                pendingRead = pages.map { PDFReadJob(route: route, pages: $0, prompt: prompt, revision: session.revision) }
            }
            running = true
            task = Task { [self] in
                defer {
                    running = false; task = nil; progress = ""
                    AIRequestGate.shared.release(token)
                    persist()
                }
                do {
                    if let snapshot, var job = pendingRead {
                        // 完整收到一批回答才推进游标。暂停后只重试未完成批次，
                        // 已完成的笔记继续用于全文汇总，不重复发送对应页面。
                        while job.completed < job.pages.count {
                            try Task.checkCancellation()
                            guard session.revision == job.revision else { throw PadError.message("PDF 已发生修改，已停止读取，避免混用不同版本。") }
                            let end = min(job.completed+2, job.pages.count)
                            let batch = Array(job.pages[job.completed..<end])
                            progress = "正在读取 \(job.completed+1)–\(end) / \(job.pages.count) 页"
                            let images = try await session.storage.images(snapshot, pages: batch)
                            let question = "\(prompt)\n请阅读 PDF 第 \(batch.map { String($0+1) }.joined(separator: "、")) 页，保留公式和关键信息。"
                            let answer = try await respond(question, route: route, key: key, context: [], images: images)
                            job.notes.append(ChatMessage(role: "user", content: "第 \(batch.map { String($0+1) }.joined(separator: "、")) 页笔记：\n" + answer))
                            job.completed = end
                            pendingRead = job
                        }
                        if job.pages.count > 2 {
                            progress = "正在整理全文笔记"
                            let context = try await bounded(job.notes, route: route, key: key)
                            _ = try await respond("根据这些逐页笔记，回应我的要求：\(prompt)。请说明笔记不足以判断的部分。", route: route, key: key, context: context)
                        }
                        pendingRead = nil
                    } else {
                        let context = try await bounded(messages.filter { !$0.content.isEmpty }, route: route, key: key)
                        _ = try await respond(prompt, route: route, key: key, context: context)
                    }
                } catch {
                    // 摘要或图片准备失败时还没有新回答，不能覆盖上一条已完成的消息。
                    if let activeAnswer, let index = messages.firstIndex(where: { $0.id == activeAnswer }) {
                        messages[index].content = rawResponse
                        messages[index].generationState = Task.isCancelled ? "paused" : "failed"
                    }
                    activeAnswer = nil
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func bounded(_ messages: [ChatMessage], route: AIRoute, key: String) async throws -> [ChatMessage] {
        try await AIContextBuilder.prepare(messages, budget: max(2048, route.model.contextBudget-4096)) { chunk in
            var text = ""
            try await self.transport.stream(route: route, apiKey: key,
                messages: [ChatMessage(role: "system", content: "请压缩为简短的中文摘要，保留公式、事实和未决问题。")] + chunk, images: []) { text = $0.content }
            return text
        }
    }
    private func respond(_ prompt: String, route: AIRoute, key: String, context: [ChatMessage], images: [AIImageInput] = []) async throws -> String {
        try Task.checkCancellation()
        let question = ChatMessage(role: "user", content: prompt)
        guard AIContextBuilder.cost(context + [question]) < route.model.contextBudget else {
            throw AIConfigurationError.message("问题与上下文超过当前模型预算，请缩短输入或提高已确认的预算。")
        }
        messages.append(question)
        var answer = ChatMessage(role: "assistant", content: "")
        answer.routeID = route.id; answer.apiName = route.endpoint.name; answer.requestedModel = route.model.modelID
        answer.requestEndpoint = route.endpoint.baseURL; answer.generationState = "running"
        messages.append(answer)
        activeAnswer = answer.id
        let index = messages.count-1
        rawResponse = ""
        try await transport.stream(route: route, apiKey: key, messages: context + [question], images: images) { [self] update in
            rawResponse = update.content
            messages[index].content = AISentencePresentation.text(update.content, final: update.complete)
            messages[index].responseModel = update.responseModel
        }
        messages[index].generationState = "complete"
        activeAnswer = nil
        persist()
        return rawResponse
    }
    private func persist() {
        do { try JSONEncoder().encode(messages).write(to: file, options: .atomic) }
        catch { self.error = "会话保存失败：" + error.localizedDescription }
    }
}
