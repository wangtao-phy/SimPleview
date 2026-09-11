import SwiftUI
import PDFKit

struct LibraryEntry: Identifiable {
    let url: URL
    let folder: Bool
    var id: URL { url }
    var title: String { folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
}

@MainActor final class NotebookLibrary: ObservableObject {
    @Published private(set) var root: URL
    @Published var revision = 0
    @Published var error: String?
    private var scoped: URL?
    init() {
        root = URL.documentsDirectory.appendingPathComponent("SimPleview 笔记", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: URL.documentsDirectory.appendingPathComponent("恢复的笔记",isDirectory:true), withIntermediateDirectories:true)
            if let bookmark = UserDefaults.standard.data(forKey: "padLibraryBookmark") {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw PadError.message("笔记目录访问权限失效，请重新选择目录。") }
                scoped = url; root = url
                if stale { UserDefaults.standard.set(try url.bookmarkData(options: .minimalBookmark), forKey: "padLibraryBookmark") }
            }
        } catch { self.error = error.localizedDescription }
    }
    func selectRoot(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark)
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            scoped?.stopAccessingSecurityScopedResource()
            scoped = accessed ? url : nil
            root = url
            UserDefaults.standard.set(bookmark, forKey: "padLibraryBookmark"); revision += 1
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            self.error = error.localizedDescription
        }
    }
    func entries(in directory: URL) throws -> [LibraryEntry] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            .compactMap { url in
                let folder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return folder || url.pathExtension.lowercased() == "pdf" ? LibraryEntry(url: url, folder: folder) : nil
            }.sorted { a,b in a.folder != b.folder ? a.folder : a.title.localizedStandardCompare(b.title) == .orderedAscending }
    }
    private func destination(name: String, in directory: URL, folder: Bool) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100, clean != ".", clean != "..", !clean.hasPrefix("."),
              !clean.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline || $0.asciiValue == 0 }) else {
            throw PadError.message("名称不能为空，不能以点开头或包含路径分隔符。")
        }
        var url = directory.appendingPathComponent(clean, isDirectory: folder)
        if !folder && url.pathExtension.lowercased() != "pdf" { url.appendPathExtension("pdf") }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PadError.message("同名文件已存在，请换一个名称。") }
        return url
    }
    func create(name: String, paper: NotebookPaper, folder: Bool, in directory: URL) throws -> URL {
        let url = try destination(name: name, in: directory, folder: folder)
        if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        else {
            let document = PDFDocument(); document.insert(try paper.page(), at: 0)
            guard let data = document.dataRepresentation() else { throw PadError.message("无法创建笔记本。") }
            try data.write(to: url, options: .withoutOverwriting)
        }
        revision += 1; return url
    }
    func rename(_ entry: LibraryEntry, to name: String) throws {
        let target = try destination(name: name, in: entry.url.deletingLastPathComponent(), folder: entry.folder)
        try move(entry, to: target)
    }
    func move(_ entry: LibraryEntry, into directory: URL) throws {
        guard !directory.standardizedFileURL.path.hasPrefix(entry.url.standardizedFileURL.path + "/"), directory != entry.url else {
            throw PadError.message("不能将文件夹移入自身。")
        }
        let target = try destination(name: entry.url.lastPathComponent, in: directory, folder: entry.folder)
        try move(entry, to: target)
    }
    private func move(_ entry: LibraryEntry, to target: URL) throws {
        var coordinatorError: NSError?, operationError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: entry.url, options: .forMoving, writingItemAt: target, options: [], error: &coordinatorError) { source,destination in
            do { try FileManager.default.moveItem(at: source, to: destination) } catch { operationError = error }
        }
        if let error = coordinatorError ?? operationError as NSError? { throw error }
        revision += 1
    }
    func remove(_ entry: LibraryEntry) throws {
        var coordinatorError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: entry.url, options: .forDeleting, error: &coordinatorError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { operationError = error }
        }
        if let error = coordinatorError ?? operationError as NSError? { throw error }
        revision += 1
    }
    func importPDF(_ source: URL, into directory: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let target = try destination(name: source.lastPathComponent, in: directory, folder: false)
        var coordinatorError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { url in
            do {
                guard PDFDocument(url: url) != nil else { throw PadError.message("所选文件不是可读取的 PDF。") }
                try FileManager.default.copyItem(at: url, to: target)
            } catch { operationError = error }
        }
        if let error = coordinatorError ?? operationError as NSError? { throw error }
        revision += 1
    }
}
