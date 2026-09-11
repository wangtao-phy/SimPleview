import Foundation

nonisolated struct ChatMessage: Identifiable, Codable, Sendable {
    var id = UUID()
    var role: String
    var content: String
    var thinking: String?
    // 可选字段向后兼容旧会话 JSON；请求身份/状态单独保存，不混入模型正文。
    var routeID: UUID?
    var apiName: String?
    var requestedModel: String?
    var responseModel: String?
    var requestEndpoint: String?
    var generationState: String?
    var errorMessage: String?
}
nonisolated struct TokenUsage: Codable, Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int
}
nonisolated struct AIImageInput: Sendable {
    var pageNumber: Int
    var jpeg: Data
}
nonisolated struct AIStreamUpdate: Sendable {
    var content: String
    var thinking: String = ""
    var usage: TokenUsage?
    var responseModel: String?
    var complete = false
}

@MainActor
protocol AIChatTransport: Sendable {
    func stream(route: AIRoute, apiKey: String, messages: [ChatMessage], images: [AIImageInput],
                onUpdate: @escaping @MainActor @Sendable (AIStreamUpdate) -> Void) async throws
}

@MainActor
final class AIChatService: AIChatTransport {
    static let shared = AIChatService()
    nonisolated let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    nonisolated static func makeRequest(route: AIRoute, apiKey: String, messages: [ChatMessage], images: [AIImageInput] = []) throws -> URLRequest {
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw AIConfigurationError.message("API Key 为空或含有换行等无效字符，请重新保存密钥。")
        }
        guard let url = URL(string: route.endpoint.baseURL + "/chat/completions"), url.host != nil,
              ["https", "http"].contains(url.scheme ?? "") else { throw URLError(.badURL) }
        guard images.isEmpty || route.model.supportsVision else { throw AIConfigurationError.message("所选模型未启用图片输入，请选择视觉模型。") }
        var bodyMessages = messages.filter { !$0.content.isEmpty }.map { ["role": $0.role, "content": $0.content] as [String: Any] }
        if !images.isEmpty {
            guard let last = bodyMessages.last, last["role"] as? String == "user" else { throw AIConfigurationError.message("图片必须附在本轮用户请求中。") }
            var parts: [[String: Any]] = [["type": "text", "text": last["content"] as? String ?? ""]]
            for image in images {
                parts.append(["type": "text", "text": "PDF 第 \(image.pageNumber) 页"])
                parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.jpeg.base64EncodedString(), "detail": "high"]])
            }
            bodyMessages[bodyMessages.count - 1]["content"] = parts
        }
        // model 只取这次值快照中的精确 ID；n=1 只请求一条回答，无 fallback。
        let body: [String: Any] = ["model": route.model.modelID, "messages": bodyMessages,
                                   "stream": true, "n": 1, "stream_options": ["include_usage": true]]
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 24 * 1024 * 1024 else { throw AIConfigurationError.message("请求超过 24 MiB，请减少单批图片或上下文。") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// 网络与 SSE 解析在并发执行器上运行；只把有序的值更新交回主执行器。
    /// 不使用 result.lines 的无界行缓存，对未带换行的异常响应同样限流。
    @concurrent
    func stream(route: AIRoute, apiKey: String, messages: [ChatMessage], images: [AIImageInput] = [],
                onUpdate: @escaping @MainActor @Sendable (AIStreamUpdate) -> Void) async throws {
        do {
            let request = try Self.makeRequest(route: route, apiKey: apiKey, messages: messages, images: images)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                var body = Data()
                for try await byte in bytes { try Task.checkCancellation(); if body.count >= 64_000 { break }; body.append(byte) }
                throw AIConfigurationError.message("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)：\(String(decoding: body, as: UTF8.self))")
            }
            var accumulator = AIStreamAccumulator(route: route)
            var line = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                if byte == 10 {
                    if let update = try accumulator.consume(String(decoding: line, as: UTF8.self)) {
                        await onUpdate(update)
                    }
                    line.removeAll(keepingCapacity: true)
                    if accumulator.done { break }
                } else {
                    guard line.count < 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                    line.append(byte)
                }
            }
            if !line.isEmpty, !accumulator.done,
               let update = try accumulator.consume(String(decoding: line, as: UTF8.self)) { await onUpdate(update) }
            try Task.checkCancellation()
            accumulator.finishText()
            guard accumulator.sawContent else { throw AIConfigurationError.message("API 未返回有效回答，请检查模型与接口配置。") }
            guard accumulator.done || accumulator.finished else { throw AIConfigurationError.message("连接提前结束，已保留收到的内容，可以继续回答。") }
            var final = accumulator.update
            final.complete = true
            await onUpdate(final)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // 某些网关会在错误中回显请求头；错误最终会持久化到会话，必须脱敏。
            let message = apiKey.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: apiKey, with: "[密钥已隐藏]")
            throw AIConfigurationError.message(message)
        }
    }
}

/// 可单独回归的流解析器：先验证服务返回的 model，再接受任何正文；
/// 即使多个 choice 出现在异常响应中，也只读取 index=0 的这一条。
nonisolated struct AIStreamAccumulator {
    let route: AIRoute
    var update = AIStreamUpdate(content: "")
    var done = false
    var finished = false
    var sawContent = false
    private var decoder = AIThinkingDecoder()
    private var reasoning = ""
    init(route: AIRoute) { self.route = route }

    mutating func finishText() {
        decoder.finish()
        update.content = decoder.content
        update.thinking = reasoning + decoder.thinking
        sawContent = !update.content.isEmpty || !update.thinking.isEmpty
    }
    mutating func consume(_ line: String) throws -> AIStreamUpdate? {
        guard line.hasPrefix("data:") else { return nil }
        let text = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "[DONE]" { done = true; return nil }
        guard !text.isEmpty else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        if let error = json["error"] as? [String: Any] { throw AIConfigurationError.message(error["message"] as? String ?? "API 返回错误") }
        if let model = json["model"] as? String {
            try route.validateReportedModel(model)
            update.responseModel = model
        }
        if let usage = json["usage"] as? [String: Any] {
            update.usage = TokenUsage(promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                completionTokens: usage["completion_tokens"] as? Int ?? 0,
                cachedTokens: usage["prompt_cache_hit_tokens"] as? Int ?? (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0)
        }
        if let choices = json["choices"] as? [[String: Any]],
           let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) {
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                guard reason == "stop" else { throw AIConfigurationError.message("回答未完整结束（\(reason)），已保留内容。") }
                finished = true
            }
            if let delta = choice["delta"] as? [String: Any] {
                reasoning += delta["reasoning_content"] as? String ?? ""
                decoder.append(delta["content"] as? String ?? "")
            }
        }
        update.content = decoder.content
        update.thinking = reasoning + decoder.thinking
        sawContent = sawContent || !update.content.isEmpty || !update.thinking.isEmpty
        guard update.content.utf8.count + update.thinking.utf8.count <= 4_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        return update
    }
}

nonisolated struct AIThinkingDecoder {
    private var pending = ""
    private var inside = false
    private(set) var content = ""
    private(set) var thinking = ""
    mutating func append(_ text: String) {
        pending += text
        while !pending.isEmpty {
            let delimiter = inside ? "</think>" : "<think>"
            if let range = pending.range(of: delimiter) {
                emit(String(pending[..<range.lowerBound]))
                pending = String(pending[range.upperBound...]); inside.toggle()
            } else {
                let count = (1..<delimiter.count).reversed().first { pending.hasSuffix(delimiter.prefix($0)) } ?? 0
                emit(String(pending.dropLast(count)))
                pending = String(pending.suffix(count)); break
            }
        }
    }
    mutating func finish() { emit(pending); pending = "" }
    private mutating func emit(_ text: String) { if inside { thinking += text } else { content += text } }
}
