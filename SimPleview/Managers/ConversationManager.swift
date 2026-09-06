import Foundation
import Combine
import os

nonisolated struct ConversationSession: Identifiable, Codable, Sendable {
    var id: UUID
    var documentID: String
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var messages: [ChatMessage]
}

@MainActor
class ConversationManager: ObservableObject {
    @Published var lastError: String?
    private let writer = DispatchQueue(label: "com.simpleview.conversations", qos: .utility)
    private let failures = OSAllocatedUnfairLock(initialState: [URL: String]())
    // 写入失败时保留值快照；关闭聊天视图后仍可重试，不能只保留错误字符串。
    private let failedWrites = OSAllocatedUnfairLock(initialState: [URL: ConversationSession]())
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
    
    /// 迁移整个旧标题目录，并保留原始 JSON 备份。新目录完整写入后才移动旧目录，
    /// 不把同名旧会话反复复制给后续打开的其他路径文档。
    func migrateLegacySessions(named name: String, to documentID: String) {
        let legacy = baseDirectory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        let destination = baseDirectory.appendingPathComponent(documentID)
        guard legacy != destination, FileManager.default.fileExists(atPath: legacy.path),
              !FileManager.default.fileExists(atPath: destination.path) else { return }
        writer.sync {}
        let staging = baseDirectory.appendingPathComponent(".migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "json" {
                var session = try Self.readSession(at: file)
                session.documentID = documentID
                try JSONEncoder().encode(session).write(to: staging.appendingPathComponent(file.lastPathComponent), options: .atomic)
            }
            // 整个目录准备成功才发布。失败不会留下半成品目录阻止下次重试。
            try FileManager.default.moveItem(at: staging, to: destination)
            let backup = baseDirectory.appendingPathComponent("Legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: legacy, to: backup.appendingPathComponent(UUID().uuidString))
        } catch { lastError = "聊天迁移失败，原始记录已保留：" + error.localizedDescription }
    }

    func saveSession(_ session: ConversationSession) {
        let directory = directory(for: session.documentID)
        let failures = failures
        let failedWrites = failedWrites
        writer.async { [weak self] in
            let url = directory.appendingPathComponent("\(session.id.uuidString).json")
            do {
                // 先原子写正文，再写小型元数据。启动时按正文文件列举，元数据缺失可重建，
                // 因此崩溃在两次写之间也不会把会话从列表中永久丢掉。
                try JSONEncoder().encode(session).write(to: url, options: .atomic)
                var metadata = session
                metadata.messages = []
                try JSONEncoder().encode(metadata).write(to: url.appendingPathExtension("meta"), options: .atomic)
                _ = failures.withLock { $0.removeValue(forKey: url) }
                _ = failedWrites.withLock { $0.removeValue(forKey: url) }
            } catch {
                let message = error.localizedDescription
                failures.withLock { $0[url] = message }
                failedWrites.withLock { $0[url] = session }
                Task { @MainActor [weak self] in self?.lastError = "对话保存失败：" + message }
            }
        }
    }

    /// 列表只驻留标题/时间；正文仅在选择该会话时加载。旧数据的元数据逐个重建，
    /// 不把所有会话正文同时留在 availableSessions 中。
    func loadSessions(for documentID: String) -> [ConversationSession] {
        writer.sync {}
        let directory = directory(for: documentID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            autoreleasepool {
                do {
                    let metaURL = url.appendingPathExtension("meta")
                    let originalDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                    let metaDate = (try? metaURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if metaDate >= originalDate, let data = try? Data(contentsOf: metaURL),
                       var metadata = try? JSONDecoder().decode(ConversationSession.self, from: data) {
                        metadata.messages = []; return metadata
                    }
                    var metadata = try Self.readSession(at: url)
                    metadata.messages = []
                    try JSONEncoder().encode(metadata).write(to: metaURL, options: .atomic)
                    return metadata
                } catch { lastError = "无法读取部分对话：" + error.localizedDescription; return nil }
            }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadSession(id: UUID, documentID: String) throws -> ConversationSession {
        writer.sync {}
        return try Self.readSession(at: directory(for: documentID).appendingPathComponent("\(id.uuidString).json"))
    }

    nonisolated private static func readSession(at url: URL) throws -> ConversationSession {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(ConversationSession.self, from: Data(contentsOf: url))
    }

    func flush() -> Bool {
        writer.sync {}
        // 已排队的新版本会先完成；仅重试最后失败的版本，避免旧快照回滚新内容。
        let retry = failedWrites.withLock { Array($0.values) }
        for session in retry { saveSession(session) }
        writer.sync {}
        let error = failures.withLock { $0.values.first }
        if let error { lastError = "对话保存失败：" + error }
        return error == nil
    }

    func deleteSession(id: UUID, documentID: String) {
        writer.sync {}
        let url = directory(for: documentID).appendingPathComponent("\(id.uuidString).json")
        do {
            try FileManager.default.removeItem(at: url)
            _ = failures.withLock { $0.removeValue(forKey: url) }
            _ = failedWrites.withLock { $0.removeValue(forKey: url) }
            try? FileManager.default.removeItem(at: url.appendingPathExtension("meta"))
        } catch { lastError = error.localizedDescription }
    }
}
