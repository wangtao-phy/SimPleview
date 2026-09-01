import Foundation

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: String // "user" or "assistant" or "system"
    var content: String
    var thinking: String? // Optional thinking process for models like deepseek-reasoner
}

struct TokenUsage: Codable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int
}

class AIChatService {
    static let shared = AIChatService()
    
    // A simplified stream parser for OpenAI chunk format
    func streamOpenAI(
        apiKey: String,
        baseURL: String,
        model: String,
        messages: [ChatMessage],
        onUpdate: @escaping (String, String, TokenUsage?) -> Void // content, thinking, usage
    ) async throws {
        let endpoint = baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var openAIMessages = messages.map { msg -> [String: String] in
            return ["role": msg.role, "content": msg.content]
        }
        
        let body: [String: Any] = [
            "model": model,
            "messages": openAIMessages,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (result, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in result.lines {
                errorBody += line
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw NSError(domain: "APIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode): \(errorBody)"])
        }
        
        var contentAcc = ""
        var thinkingAcc = ""
        var isThinking = false
        
        for try await line in result.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            var currentUsage: TokenUsage? = nil
            if let usageObj = json["usage"] as? [String: Any] {
                let promptTokens = usageObj["prompt_tokens"] as? Int ?? 0
                let completionTokens = usageObj["completion_tokens"] as? Int ?? 0
                var cachedTokens = 0
                
                // DeepSeek format
                if let deepseekCached = usageObj["prompt_cache_hit_tokens"] as? Int {
                    cachedTokens = deepseekCached
                } else if let details = usageObj["prompt_tokens_details"] as? [String: Any],
                          let openaiCached = details["cached_tokens"] as? Int {
                    cachedTokens = openaiCached
                }
                
                currentUsage = TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens, cachedTokens: cachedTokens)
                
                if json["choices"] == nil || (json["choices"] as? [Any])?.isEmpty == true {
                    // This is the final chunk that only contains usage
                    onUpdate(contentAcc, thinkingAcc, currentUsage)
                    continue
                }
            }
            
            guard let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }
            
            // Deepseek uses "reasoning_content" for thinking
            if let reasoning = delta["reasoning_content"] as? String {
                thinkingAcc += reasoning
                onUpdate(contentAcc, thinkingAcc, currentUsage)
            }
            
            if let content = delta["content"] as? String {
                // Sometime models output <think> in content
                let combined = contentAcc + content
                
                // Extremely simple <think> extraction if the model puts it in content
                if content.contains("<think>") {
                    isThinking = true
                }
                
                if isThinking {
                    thinkingAcc += content.replacingOccurrences(of: "<think>", with: "")
                    if content.contains("</think>") {
                        isThinking = false
                        let parts = thinkingAcc.components(separatedBy: "</think>")
                        if parts.count > 1 {
                            thinkingAcc = parts[0]
                            contentAcc += parts[1]
                        }
                    }
                } else {
                    contentAcc += content
                }
                onUpdate(contentAcc, thinkingAcc, currentUsage)
            }
        }
    
    }

    // 自动压缩/总结过长的对话历史
    func summarizeMessages(
        apiKey: String,
        baseURL: String,
        model: String,
        messagesToSummarize: [ChatMessage]
    ) async throws -> String {
        let endpoint = baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var openAIMessages = messagesToSummarize.map { ["role": $0.role, "content": $0.content] }
        // 添加总结指令
        openAIMessages.append([
            "role": "user",
            "content": "请对以上我们的所有对话进行极度精简的总结，提取出所有的核心概念、推导过程、物理物理定律和已达成的共识，作为接下来的前情提要。请不要遗漏关键的数学公式，以纯文本/Markdown返回。"
        ])
        
        let body: [String: Any] = [
            "model": model,
            "messages": openAIMessages,
            "stream": false
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIError", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: nil)
        }
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        
        throw URLError(.cannotParseResponse)
    }
}

