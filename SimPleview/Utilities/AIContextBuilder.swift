import Foundation

/// 原始聊天记录永不被摘要覆盖。仅构造本次请求的有限上下文；UTF-8 字节数
/// 加消息开销作为保守估算，预算由用户配置，不能把固定 256k 当作所有模型上限。
@MainActor
enum AIContextBuilder {
    static func cost(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.utf8.count + 32 }
    }

    /// 普通问答只构造本地滑动窗口，不为压缩历史额外调用收费 API。
    /// 保留系统指令和最新完整轮次；超限时从最旧的轮次移除，原始记录不变。
    /// 本轮输入本身超限则明确报错，不能截断用户的问题后悄悄提交。
    static func replyContext(_ messages: [ChatMessage], budget: Int) throws -> [ChatMessage] {
        guard cost(messages) > budget else { return messages }
        let system = messages.prefix { $0.role == "system" }
        let conversation = Array(messages.dropFirst(system.count))
        guard let latest = conversation.lastIndex(where: { $0.role == "user" }),
              cost(Array(system) + conversation[latest...]) <= budget else {
            throw NSError(domain: "AIContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "本轮输入或系统指令超过上下文预算，请缩短选段或输入。未发送 API 请求。"])
        }
        var start = latest
        var used = cost(Array(system) + conversation[latest...])
        for index in conversation.indices.reversed() where index < latest && conversation[index].role == "user" {
            let added = cost(Array(conversation[index..<start]))
            guard used + added <= budget else { break }
            used += added; start = index
        }
        return Array(system) + conversation[start...]
    }

    static func prepare(_ messages: [ChatMessage], budget: Int,
                        summarize: ([ChatMessage]) async throws -> String) async throws -> [ChatMessage] {
        guard cost(messages) > budget else { return messages }
        let system = messages.first?.role == "system" ? [messages[0]] : []
        let conversation = system.isEmpty ? messages : Array(messages.dropFirst())
        let hot = Array(conversation.suffix(4))
        let room = budget - cost(system) - cost(hot) - 64
        guard room > 1024, conversation.count > hot.count else {
            throw NSError(domain: "AIContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "最近消息或选中文本超过上下文预算，请缩短输入或新建对话。"])
        }
        let summaryLimit = min(room, budget / 3)
        var summary = ""
        var chunk: [ChatMessage] = []
        // 单条历史消息也按 Unicode scalar 边界拆分，避免把一个巨大消息原样提交。
        let chunkLimit = max(512, (budget - summaryLimit) / 2 - 128)
        for message in conversation.dropLast(hot.count) {
            var text = ""
            var bytes = 0
            for scalar in message.content.unicodeScalars {
                let size = scalar.utf8.count
                if bytes + size > chunkLimit {
                    chunk.append(ChatMessage(role: message.role, content: text))
                    let input = (summary.isEmpty ? [] : [ChatMessage(role: "system", content: summary)]) + chunk
                    summary = try await summarize(input)
                    try Task.checkCancellation()
                    guard summary.utf8.count <= summaryLimit else { throw summaryTooLarge() }
                    chunk = []; text = ""; bytes = 0
                }
                text.unicodeScalars.append(scalar)
                bytes += size
            }
            if !text.isEmpty { chunk.append(ChatMessage(role: message.role, content: text)) }
            if cost(chunk) >= chunkLimit {
                summary = try await summarize((summary.isEmpty ? [] : [ChatMessage(role: "system", content: summary)]) + chunk)
                try Task.checkCancellation()
                guard summary.utf8.count <= summaryLimit else { throw summaryTooLarge() }
                chunk = []
            }
        }
        if !chunk.isEmpty {
            summary = try await summarize((summary.isEmpty ? [] : [ChatMessage(role: "system", content: summary)]) + chunk)
        }
        let result = system + [ChatMessage(role: "system", content: "历史摘要（原文保存在聊天记录中）：\n" + summary)] + hot
        guard cost(result) <= budget else { throw summaryTooLarge() }
        return result
    }

    private static func summaryTooLarge() -> Error {
        NSError(domain: "AIContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "摘要仍超过上下文预算，已保留完整原文，请新建对话或提高已确认的模型预算。"])
    }
}
