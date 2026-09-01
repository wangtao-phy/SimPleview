import Foundation
import Combine
import SwiftUI
import PDFKit

@MainActor
class AIChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] {
        didSet {
            let totalChars = messages.reduce(0) { $0 + $1.content.count + ($1.thinking?.count ?? 0) }
            estimatedContextTokens = totalChars / 2
            UserDefaults.standard.set(estimatedContextTokens, forKey: "estimatedContextTokens")
            
            // Auto save if we have a documentID and aren't actively streaming, or just simple debounce
            // We'll manually save when generation finishes or when a user message is added
        }
    }
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false {
        didSet {
            if !isGenerating {
                saveCurrentSession()
            }
        }
    }
    @Published var estimatedContextTokens: Int = 0
    
    // Conversation Management
    @Published var availableSessions: [ConversationSession] = []
    @Published var currentSessionID: UUID?
    private var documentID: String?
    
    func configure(with documentID: String) {
        guard self.documentID != documentID else { return }
        self.documentID = documentID
        
        // Load sessions
        availableSessions = ConversationManager.shared.loadSessions(for: documentID)
        if let lastSession = availableSessions.first {
            switchSession(to: lastSession.id)
        } else {
            createNewSession()
        }
    }
    
    func createNewSession() {
        guard let docID = documentID else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let title = "对话 " + formatter.string(from: Date())
        
        let newSession = ConversationSession(
            id: UUID(),
            documentID: docID,
            createdAt: Date(),
            updatedAt: Date(),
            title: title,
            messages: []
        )
        
        availableSessions.insert(newSession, at: 0)
        currentSessionID = newSession.id
        messages = []
        saveCurrentSession()
    }
    
    func switchSession(to id: UUID) {
        if let session = availableSessions.first(where: { $0.id == id }) {
            currentSessionID = session.id
            messages = session.messages
        }
    }
    
    func saveCurrentSession() {
        guard let docID = documentID, let sessionID = currentSessionID else { return }
        if let index = availableSessions.firstIndex(where: { $0.id == sessionID }) {
            availableSessions[index].messages = messages
            availableSessions[index].updatedAt = Date()
            ConversationManager.shared.saveSession(availableSessions[index])
        }
    }
    
    func sendMessage(appState: AppState?) {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        var contextPrefix = ""
        if let selection = appState?.pdfView.currentSelection?.string, !selection.isEmpty {
            contextPrefix = "关于以下引用的 PDF 原文选段：\n\"\"\"\n\(selection)\n\"\"\"\n\n"
        }
        
        let userMessageContent = contextPrefix + inputText
        let userMessage = ChatMessage(role: "user", content: userMessageContent)
        messages.append(userMessage)
        saveCurrentSession() // Save user message immediately
        
        inputText = ""
        isGenerating = true
        
        // Add a placeholder assistant message
        messages.append(ChatMessage(role: "assistant", content: "", thinking: ""))
        let assistantIndex = messages.count - 1
        
        let provider = UserDefaults.standard.string(forKey: "aiProvider") ?? "OpenAI"
        let apiKey = UserDefaults.standard.string(forKey: "aiAPIKey") ?? ""
        let baseURL = UserDefaults.standard.string(forKey: "aiBaseURL") ?? "https://api.openai.com/v1"
        let model = UserDefaults.standard.string(forKey: "aiModel_v2") ?? "gpt-5.5"
        
        Task {
            do {
                if provider == "OpenAI" || provider == "DeepSeek" {
                    var finalMessages = Array(messages.dropLast())
                    let memoryURL = DirectoryManager.shared.appRootDirectory.appendingPathComponent("GlobalMemory.md")
                    let systemPrompt = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
                    if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let sysMsg = ChatMessage(role: "system", content: systemPrompt)
                        finalMessages.insert(sysMsg, at: 0)
                    }
                    
                    try await AIChatService.shared.streamOpenAI(
                        apiKey: apiKey,
                        baseURL: baseURL,
                        model: model,
                        messages: finalMessages
                    ) { content, thinking in
                        DispatchQueue.main.async {
                            self.messages[assistantIndex].content = content
                            self.messages[assistantIndex].thinking = thinking.isEmpty ? nil : thinking
                        }
                    }
                } else {
                    // Implement Gemini or other fallback
                    DispatchQueue.main.async {
                        self.messages[assistantIndex].content = "Provider \(provider) is not yet fully implemented in stream format."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.messages[assistantIndex].content = "Error: \(error.localizedDescription)"
                }
            }
            
            DispatchQueue.main.async {
                self.isGenerating = false
            }
        }
    }
}
