import Foundation
import SwiftUI
import Combine

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
    
    /// 当前用户正在看的那个文件的记录，方便在全局 UI 里直接绑定展示。
    @Published var currentRecord: DocumentRecord?
    
    // [秒表引擎的心脏]
    private var currentDocumentID: String?
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
            saveAllRecords() // 在搬家前，先在老房子里存档
            
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
    
    // [生命周期钩子]
    private init() {
        createDirectoryIfNeeded()
        
        // 注册各种乱七八糟的系统通知。
        // 目的是：不管是在 Mac 还是 iOS，只要应用被推到后台，或者被强制杀死，我们都能第一时间接到通知！
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppDeactivated() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppActivated() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppDeactivated() }
        }
        #else
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppDeactivated() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppActivated() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAppDeactivated() }
        }
        #endif
    }
    
    private func handleAppDeactivated() {
        saveAllRecords() // 被切到后台时，赶紧存档
        self.sessionStartTime = nil // 强制暂停秒表，防止把在后台的时间算成阅读时间
    }
    
    private func handleAppActivated() {
        // 如果切回来的时候用户还在读文章，重新按下秒表
        if currentDocumentID != nil && currentPageIndex != nil {
            self.sessionStartTime = Date()
        }
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
    
    func updateRecord(_ record: DocumentRecord) {
        recordsCache[record.documentID] = record
        dirtyRecords.insert(record.documentID) // 盖上脏标记的戳
    }
    
    func loadRecord(for title: String) -> DocumentRecord {
        if let cached = recordsCache[title] {
            return cached
        }
        
        let url = fileURL(for: title)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 没有？就建个新的
            let newRecord = DocumentRecord(documentID: title, documentTitle: title)
            recordsCache[title] = newRecord
            return newRecord
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let record = try decoder.decode(DocumentRecord.self, from: data)
            recordsCache[title] = record
            return record
        } catch {
            let newRecord = DocumentRecord(documentID: title, documentTitle: title)
            recordsCache[title] = newRecord
            return newRecord
        }
    }
    
    // [高性能存储流水线]
    func saveAllRecords() {
        // 存之前先结算一下当前秒表累计的最后一点时间
        commitCurrentTime()
        
        guard !dirtyRecords.isEmpty else { return }
        
        // 第一步：在主线程，迅速把所有需要保存的记录“快照”复制一份（因为是 struct，复制极快），
        // 然后立刻清空脏标记，放过主线程，防止阻塞 UI！
        var recordsToSave: [DocumentRecord] = []
        let targetDirectory = self.saveDirectoryURL
        
        // [P1修复] 复制脏标记快照，仅在写入成功后才清除对应标记
        let dirtySnapshot = dirtyRecords
        dirtyRecords.removeAll()
        for docID in dirtySnapshot {
            if let record = recordsCache[docID] {
                recordsToSave.append(record)
            }
        }
        
        // 第二步：拿着数据的快照，跑去后台线程进行 CPU 密集型的 JSON 编码和硬盘读写操作
        DispatchQueue.global(qos: .background).async { [weak self] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            
            var allAuthorsToUpsert: [(String, AuthorInfo)] = []
            
            for record in recordsToSave {
                let safeTitle = record.documentID.replacingOccurrences(of: "/", with: "-")
                let url = targetDirectory.appendingPathComponent("\(safeTitle).json")
                
                // 将编码 (CPU 密集型操作) 和写入 (I/O) 全部放在后台，绝不卡顿
                if let data = try? encoder.encode(record) {
                    do {
                        try data.write(to: url, options: .atomic)
                    } catch {
                        // [P1修复] 写入失败时，将脏标记放回，下次重试
                        DispatchQueue.main.async { [weak self] in
                            self?.dirtyRecords.insert(record.documentID)
                        }
                    }
                }
                
                for author in record.authors {
                    allAuthorsToUpsert.append((record.documentID, author))
                }
            }
            
            // 顺便把这些作者信息也丢给全局作者数据库进行“投喂”
            if !allAuthorsToUpsert.isEmpty {
                DispatchQueue.main.async {
                    // 全局作者库是基于 SwiftUI @Published，写入动作应该在主线程发起（内部有优化）
                    GlobalAuthorManager.shared.upsert(allAuthorsToUpsert)
                    GlobalAuthorManager.shared.recalculateArticleCounts()
                }
            }
        }
    }
    
    // MARK: - Tracking Logic (核心追踪器)
    
    /// 当用户打开了文件、切换了标签、翻了页，都会触发它。
    func startTracking(documentID: String, documentTitle: String, pageIndex: Int) {
        let enableReadingRecord = UserDefaults.standard.bool(forKey: "enableReadingRecord")
        guard enableReadingRecord else { return }
        
        // 我们刚翻到新的一页，意味着旧的那一页被看完了！先把旧的那页的时间结算掉！
        commitCurrentTime()
        
        // 初始化新的秒表数据
        let fileID = documentTitle
        self.currentDocumentID = fileID
        self.currentPageIndex = pageIndex
        self.sessionStartTime = Date() // 按下秒表
        
        self.currentRecord = loadRecord(for: fileID)
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
    
    func stopTracking() {
        commitCurrentTime()
        self.currentDocumentID = nil
        self.currentPageIndex = nil
        self.sessionStartTime = nil
        self.currentRecord = nil
    }
}
