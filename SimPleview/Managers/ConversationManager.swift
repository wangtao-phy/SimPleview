import Foundation

struct ConversationSession: Identifiable, Codable {
    var id: UUID
    var documentID: String
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var messages: [ChatMessage]
}

class ConversationManager {
    static let shared = ConversationManager()
    
    private var baseDirectory: URL {
        let dir = DirectoryManager.shared.appRootDirectory.appendingPathComponent("Conversation")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    private func directory(for documentID: String) -> URL {
        let safeID = documentID.replacingOccurrences(of: "/", with: "-")
        let dir = baseDirectory.appendingPathComponent(safeID)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    func saveSession(_ session: ConversationSession) {
        let dir = directory(for: session.documentID)
        let fileURL = dir.appendingPathComponent("\(session.id.uuidString).json")
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save conversation session: \(error)")
        }
    }
    
    func loadSessions(for documentID: String) -> [ConversationSession] {
        let dir = directory(for: documentID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var sessions: [ConversationSession] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let session = try? JSONDecoder().decode(ConversationSession.self, from: data) {
                sessions.append(session)
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    func deleteSession(id: UUID, documentID: String) {
        let dir = directory(for: documentID)
        let fileURL = dir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
