import Foundation
import SwiftUI
import Combine
import os

/// [教程注释：零开销时间追踪器 (ReadingTracker)]
/// 这是一个统计你看了一篇文献多久的神器。
/// 最大的亮点：它是“事件驱动(Event-driven)”的！
/// 一般新手做时间统计，会搞个 Timer 每一秒跑一次，非常耗电！
/// 我们的做法是：当你进来的这一秒，记录一个时间戳；当你翻页离开的瞬间，再拿当前时间减去刚才的时间戳，不耗费任何闲置 CPU。
@MainActor
class ReadingTracker: ObservableObject {
    
    // [内存层：数据源]
    /// 缓存了当前正在看的所有文档的记录。之所以放在内存里，是为了避免频繁去读取硬盘。
    @Published var recordsCache: [String: DocumentRecord] = [:]
    
    /// 脏标记(Dirty Flag)：用来记住哪些记录被人改过但还没存到硬盘上。
    var dirtyRecords: Set<String> = []
    @Published var lastError: String?
    private let writeFailures = OSAllocatedUnfairLock(initialState: [String: String]())
    
    /// 当前用户正在看的那个文件的记录，方便在全局 UI 里直接绑定展示。
    @Published var currentRecord: DocumentRecord?
    
    // [秒表引擎的心脏]
    private var currentDocumentID: String?
    private var trackingOwner: ObjectIdentifier?
    private var currentPageIndex: Int?
    private var sessionStartTime: Date? // 秒表按下的那一刻
    
    // [目录管理]
    // 默认存放到系统的 Document 文件夹
    private var defaultDirectoryURL: URL {
        return DirectoryManager.shared.getDirectory(for: "Reading Record")
    }
    
    // 用户可以在设置里覆盖为他自己选的文件夹（比如 iCloud）
    var customDirectoryURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "readingRecordCustomPath"), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            // 目录切换会清空内存，旧目录必须实际保存成功才能继续。
            guard saveAllRecords(sync: true), GlobalAuthorManager.shared.saveAuthors(sync: true) else { return }
            
            if let newValue = newValue {
                UserDefaults.standard.set(newValue.path, forKey: "readingRecordCustomPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "readingRecordCustomPath")
            }
            createDirectoryIfNeeded()
            recordsCache.removeAll() // 清空缓存，准备从新房子里拉取数据
            currentRecord = nil
            GlobalAuthorManager.shared.reload()
            
            if let activeID = currentDocumentID {
                self.currentRecord = loadRecord(for: activeID)
            }
        }
    }
    
    var saveDirectoryURL: URL {
        customDirectoryURL ?? defaultDirectoryURL
    }
    
    // 单例
    static let shared = ReadingTracker()
    
    private var observers: [NSObjectProtocol] = []
    /// 所有记录写入按提交顺序串行执行，防止旧快照晚完成后覆盖新记录。
    private let persistenceQueue = DispatchQueue(label: "com.simpleview.reading-record-writer", qos: .utility)
    
    // [生命周期钩子]
    private init() {
        createDirectoryIfNeeded()
        registerAppLifecycleNotifications()
    }
    
    // 注册各种乱七八糟的系统通知。
    // 目的是：不管是在 Mac 还是 iOS，只要应用被推到后台，或者被强制杀死，我们都能第一时间接到通知！
    private func registerAppLifecycleNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppDeactivated() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppActivated() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppDeactivated() }
        })
    }
    
    private func handleAppDeactivated() {
        saveAllRecords() // 被切到后台时，赶紧存档
        self.sessionStartTime = nil // 强制暂停秒表，防止把在后台的时间算成阅读时间
    }
    
    private func handleAppActivated() {
        // 如果切回来的时候用户还在读文章，重新按下秒表
        (NSApp.keyWindow?.windowController as? AppWindowController)?.appState?.updateReadingTracking()
    }
    
    private func createDirectoryIfNeeded() {
        let url = saveDirectoryURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    
    private func fileURL(for title: String) -> URL {
        let safeTitle = title.replacingOccurrences(of: "/", with: "-") // 过滤掉斜杠，防止系统以为是子目录
        return saveDirectoryURL.appendingPathComponent("\(safeTitle).json")
    }
    
    /// 旧记录无法区分同名文件，只在首次遇到该旧标题时迁移；保留 Legacy 备份。
    /// 先落盘新 ID，再移动旧记录，失败时保留原文件并报告，避免静默清空数据。
    func prepareRecord(url: URL) {
        let id = DocumentIdentity.id(for: url)
        let title = url.deletingPathExtension().lastPathComponent
        let destination = fileURL(for: id)
        let legacy = fileURL(for: title)
        if !FileManager.default.fileExists(atPath: destination.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            do {
                saveAllRecords(sync: true)
                var record = try JSONDecoder().decode(DocumentRecord.self, from: Data(contentsOf: legacy))
                record.documentID = id
                record.documentTitle = title
                try JSONEncoder().encode(record).write(to: destination, options: .atomic)
                let backup = saveDirectoryURL.appendingPathComponent("Legacy", isDirectory: true)
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: legacy, to: backup.appendingPathComponent("\(UUID().uuidString)-\(legacy.lastPathComponent)"))
                recordsCache.removeValue(forKey: title)
            } catch { NSLog("阅读记录迁移失败：%@", error.localizedDescription) }
        }
        _ = loadRecord(for: id, displayTitle: title)
    }

    func updateRecord(_ record: DocumentRecord) {
        recordsCache[record.documentID] = record
        dirtyRecords.insert(record.documentID) // 盖上脏标记的戳
    }
    
    func loadRecord(for title: String, displayTitle: String? = nil) -> DocumentRecord {
        var recordToReturn: DocumentRecord
        
        if let cached = recordsCache[title] {
            recordToReturn = cached
        } else {
            let url = fileURL(for: title)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    recordToReturn = try decoder.decode(DocumentRecord.self, from: data)
                } catch {
                    recordToReturn = DocumentRecord(documentID: title, documentTitle: displayTitle ?? title)
                }
            } else {
                recordToReturn = DocumentRecord(documentID: title, documentTitle: displayTitle ?? title)
            }
        }
        
        // [极致的数据同步]
        // 不管是刚从硬盘解析出来，还是从内存缓存里直接取出的旧对象，
        // 每次提取记录时，都强制去全局大字典里拉一次最新的 bio！
        // 这样确保用户在其他标签页修改作者履历后，切回本页面能立刻体现！
        var hasChanges = false
        for i in 0..<recordToReturn.authors.count {
            let name = recordToReturn.authors[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let globalAuthor = GlobalAuthorManager.shared.authors[name] {
                if recordToReturn.authors[i].bio != globalAuthor.bio {
                    recordToReturn.authors[i].bio = globalAuthor.bio
                    hasChanges = true
                }
            }
        }
        
        // 如果同步导致了数据更新，或者本来就是新建/刚读取的，覆盖更新到缓存中
        if hasChanges || recordsCache[title] == nil {
            recordsCache[title] = recordToReturn
        }
        
        return recordToReturn
    }
    
    // [最高权限覆盖] 当在全局设置修改作者后，立刻更新内存缓存，防止脏数据回流
    func syncLoadedRecordsWithGlobalAuthor(name: String, globalAuthor: GlobalAuthor) {
        var needsRefresh = false
        for (docID, var record) in recordsCache {
            for i in 0..<record.authors.count where record.authors[i].name.trimmingCharacters(in: .whitespacesAndNewlines) == name {
                record.authors[i].firstName = globalAuthor.firstName
                record.authors[i].lastName = globalAuthor.lastName
                record.authors[i].bio = globalAuthor.bio
                recordsCache[docID] = record
                if docID == currentDocumentID { needsRefresh = true }
            }
        }
        if needsRefresh { DispatchQueue.main.async { self.objectWillChange.send() } }
    }
    
    /// 主线程取值快照，串行队列原子落盘。失败键保存在锁内而不是异步回调中，
    /// 因此退出时同步等待后即可得到真实结果，不会赶在失败回调之前退出。
    @discardableResult
    func saveAllRecords(sync: Bool = false) -> Bool {
        commitCurrentTime()
        let failedIDs = writeFailures.withLock { Set($0.keys) }
        let ids = dirtyRecords.union(failedIDs)
        let snapshots = ids.compactMap { recordsCache[$0] }
        dirtyRecords.subtract(ids)
        let target = saveDirectoryURL
        let failures = writeFailures
        if !snapshots.isEmpty {
            // 作者信息先在主执行器更新，退出时的 saveAuthors 才能包含本轮修改。
            GlobalAuthorManager.shared.upsert(snapshots.flatMap { record in
                record.authors.map { (record.documentID, $0) }
            })
            persistenceQueue.async {
                for record in snapshots {
                    do {
                        let name = record.documentID.replacingOccurrences(of: "/", with: "-")
                        try JSONEncoder().encode(record).write(to: target.appendingPathComponent(name + ".json"), options: .atomic)
                        _ = failures.withLock { $0.removeValue(forKey: record.documentID) }
                    } catch { failures.withLock { $0[record.documentID] = error.localizedDescription } }
                }
            }
        }
        if sync {
            persistenceQueue.sync {}
            // 前一轮异步写入可能刚刚失败：重新取最新内存值重试，不能恢复旧快照。
            let retryIDs = failures.withLock { Set($0.keys) }.subtracting(ids)
            if !retryIDs.isEmpty {
                dirtyRecords.formUnion(retryIDs)
                return saveAllRecords(sync: true)
            }
            let error = failures.withLock { $0.values.first }
            lastError = error.map { "阅读记录保存失败：" + $0 }
            return error == nil
        }
        return true // 异步调用仅代表已排队；关闭/退出必须使用 sync。
    }

    // MARK: - Tracking Logic (核心追踪器)
    
    /// 当用户打开了文件、切换了标签、翻了页，都会触发它。
    func startTracking(documentID: String, documentTitle: String, pageIndex: Int, owner: ObjectIdentifier) {
        let enableReadingRecord = UserDefaults.standard.bool(forKey: "enableReadingRecord")
        guard enableReadingRecord else { stopTracking(owner: owner); return }
        if trackingOwner == owner, currentDocumentID == documentID,
           currentPageIndex == pageIndex, sessionStartTime != nil { return }
        
        // 我们刚翻到新的一页，意味着旧的那一页被看完了！先把旧的那页的时间结算掉！
        commitCurrentTime()
        
        // 初始化新的秒表数据
        let fileID = documentID
        trackingOwner = owner
        self.currentDocumentID = fileID
        self.currentPageIndex = pageIndex
        self.sessionStartTime = Date() // 按下秒表
        
        self.currentRecord = loadRecord(for: fileID, displayTitle: documentTitle)
    }
    
    /// 计算从按下秒表到现在过了多久，把它加到总阅读时间里。
    func commitCurrentTime() {
        guard let start = sessionStartTime,
              let docID = currentDocumentID,
              let pageIdx = currentPageIndex else { return }
        
        let elapsed = Date().timeIntervalSince(start)
        // [防抖设计] 如果你疯狂滑滚轮，每一页只停留了0.5秒，那不算在认真阅读，直接抛弃掉，不然会产生大量的脏数据导致卡顿。
        if elapsed >= 5.0 {
            var record = recordsCache[docID] ?? DocumentRecord(documentID: docID, documentTitle: docID)
            
            record.totalReadingTime += elapsed // 增加总时间
            let existingPageTime = record.pageDurations[pageIdx] ?? 0
            record.pageDurations[pageIdx] = existingPageTime + elapsed // 增加这单页的停留时间
            record.lastReadDate = Date()
            
            recordsCache[docID] = record
            dirtyRecords.insert(docID)
            
            if currentRecord?.documentID == docID {
                currentRecord = record
            }
        }
        
        // 重置秒表
        self.sessionStartTime = Date()
    }
    
    func stopTracking(owner: ObjectIdentifier) {
        // 关闭后台窗口不能停止另一个窗口的计时器。
        guard trackingOwner == owner else { return }
        trackingOwner = nil
        commitCurrentTime()
        self.currentDocumentID = nil
        self.currentPageIndex = nil
        self.sessionStartTime = nil
        self.currentRecord = nil
    }
}
