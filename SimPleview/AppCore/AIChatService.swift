import Foundation

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String // "user" or "assistant"
    var content: String
    var thinking: String? // Optional thinking process for models like deepseek-reasoner
}

class AIChatService {
    static let shared = AIChatService()
    
    // A simplified stream parser for OpenAI chunk format
    func streamOpenAI(
        apiKey: String,
        baseURL: String,
        model: String,
        messages: [ChatMessage],
        onUpdate: @escaping (String, String) -> Void // content, thinking
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
            "stream": true
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
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }
            
            // Deepseek uses "reasoning_content" for thinking
            if let reasoning = delta["reasoning_content"] as? String {
                thinkingAcc += reasoning
                onUpdate(contentAcc, thinkingAcc)
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
                onUpdate(contentAcc, thinkingAcc)
            }
        }
    }
}
