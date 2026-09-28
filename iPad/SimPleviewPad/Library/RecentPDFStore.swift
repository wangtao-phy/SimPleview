import Foundation
import Combine

struct RecentPDF: Codable, Identifiable {
    let id: UUID
    var title: String
    var bookmark: Data
    var lastOpened: Date
}

/// 仅保存原文件的授权书签，不复制 PDF；从记录移除不会删除文件。
@MainActor final class RecentPDFStore: ObservableObject {
    @Published private(set) var entries: [RecentPDF] = []
    @Published var error: String?
    private let defaults: UserDefaults
    private let key = "padRecentPDFs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([RecentPDF].self, from: data) {
            entries = Array(saved.prefix(100))
        }
    }
    func url(for entry: RecentPDF) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: entry.bookmark, options: [], bookmarkDataIsStale: &stale)
        return url
    }
    func record(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark)
            let index = entries.firstIndex { (try? self.url(for: $0).standardizedFileURL) == url.standardizedFileURL }
            let id = index.map { entries[$0].id } ?? UUID()
            if let index { entries.remove(at: index) }
            entries.insert(RecentPDF(id: id, title: url.deletingPathExtension().lastPathComponent,
                                     bookmark: bookmark, lastOpened: Date()), at: 0)
            entries = Array(entries.prefix(100))
            persist()
        } catch { self.error = "无法记住此文件，下次可重新从“打开文件”选择。\n\(error.localizedDescription)" }
    }
    func remove(_ entry: RecentPDF) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
