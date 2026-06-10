import SwiftUI
import PDFKit
import Combine

/// [教程注释：文档生命周期管理器 (DocumentManager)]
/// `DocumentManager` 负责管理 PDF 文件的生命周期，包括：
/// 1. 文件的打开、关闭与安全沙盒权限 (Security Scoped Bookmark) 的管理
/// 2. 多文档或单文档的状态维护 (如 `fileURL`, `isDirty` 等)
/// 3. 在后台队列中安全、原子化地保存文档修改，避免阻塞主线程 UI
final class DocumentManager: ObservableObject {
    
    // [核心数据：基础文件状态]
    /// 当前打开的 PDF 文件的本地 URL
    @Published var fileURL: URL?
    
    /// (仅限 iOS) 多标签文档列表：iOS 没有浮动窗口，只能在一个界面里开多个标签
    @Published var documents: [PDFDocumentModel] = []
    
    /// (仅限 iOS) 的当前活动文档索引
    @Published var activeDocumentIndex: Int = 0
    
    /// 标记当前文档是否包含未保存的修改 (比如你刚画了一条线)
    @Published var isDirty: Bool = false
    
    // [沙盒授权缓存]
    /// (macOS) 当前正在安全访问的文件 URL，用于在切换文件时正确释放上一个文件的权限，防止句柄泄露导致崩溃
    private var macOSAccessingURL: URL?
    
    // [保存防抖]
    /// 用于防抖动 (Debounce) 的保存任务，避免频繁修改导致频繁磁盘 I/O，损坏 SSD 寿命
    private var saveWorkItem: DispatchWorkItem?
    
    /// 监听外部文件被其他应用修改的监听器
    var fileMonitor: FileMonitor? {
        willSet {
            // 如果替换监听器，先把老的停掉
            fileMonitor?.stop()
        }
    }
    
    // MARK: - Bookmark Management (书签权限管理)
    // 苹果系统有极其严格的沙盒机制。用户选择了一个文件授权给你，重启 App 之后，这个 URL 就作废了！
    // 所以我们需要把那个 URL 的底层权限打包成“书签 (Bookmark Data)”，存进系统偏好设置。下次通过书签还原出带权限的 URL。
    
    /// 将最新打开的文件路径和权限书签保存到 UserDefaults，以便下次启动时恢复
    func updateOpenedRecent(url: URL) {
        #if os(macOS)
        guard url.isFileURL else { return }
        var dict = UserDefaults.standard.dictionary(forKey: "OpenedPDFBookmarks") as? [String: Data] ?? [:]
        do {
            // 关键 API：生成携带安全作用域的数据
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            dict[url.path] = bookmark
            UserDefaults.standard.set(dict, forKey: "OpenedPDFBookmarks")
        } catch {
            // 失败就随风而去
        }
        #endif
    }
    
    /// 当文档被显式关闭时，从持久化历史中移除它的书签权限
    func removeFromOpenedRecent(url: URL?) {
        #if os(macOS)
        guard let path = url?.path else { return }
        var dict = UserDefaults.standard.dictionary(forKey: "OpenedPDFBookmarks") as? [String: Data] ?? [:]
        dict.removeValue(forKey: path)
        UserDefaults.standard.set(dict, forKey: "OpenedPDFBookmarks")
        #endif
    }
    
    /// 仅限 iOS: 将所有打开的选项卡的文档状态序列化保存，方便应用下次启动时重新恢复这些标签页
    func persistiOSDocuments() {
        #if os(iOS)
        let bookmarks = documents.compactMap { model -> Data? in
            try? model.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: "OpenediOSPDFBookmarks")
        #endif
    }
    
    // MARK: - Safe Background Saving (安全后台保存机制)
    
    // [核心引擎：多线程调度]
    /// 专门用于在后台执行保存的串行队列，避免在写入大文件 (比如百兆 PDF) 时导致主线程卡顿 (彩虹圈)

    /// 将对 PDF 的修改保存到磁盘
    /// - Parameters:
    ///   - pdfView: 当前对应的 PDFView
    ///   - sync: 是否需要强制同步保存 (例如应用即将退出或休眠时，必须等它写完)
    ///   - immediate: 是否跳过防抖时间，立即在后台异步保存
    func save(pdfView: PDFView?, sync: Bool = false, immediate: Bool = false) {
        // 如果文件没有被修改，或者缺乏必要的上下文，直接跳过以节省性能
        guard isDirty, let url = fileURL, let document = pdfView?.document else { return }

        // 在主线程提取数据，完美避开 PDFDocument 的非线程安全问题！
        // 取出 Data 对象后，I/O 写入磁盘的操作就不再需要占用主线程了
        guard let data = document.dataRepresentation() else { return }

        // 每次触发保存时，先把之前倒计时的任务取消掉（这就是典型的 Debounce 防抖逻辑）
        saveWorkItem?.cancel()

        // 提取闭包：这是真正的存盘核心动作
        let performWrite = { [weak self] in
            // 在写入前请求系统的安全写入权限
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // 通知主线程我们正在进行自我保存，避免文件监视器误报
            DispatchQueue.main.async {
                self?.fileMonitor?.isSelfSaving = true
            }
            
            // [极其重要的稳健性修复：安全原子写入 + 异步非阻塞]
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            var success = false
            do {
                // 使用 Data.write，不再依赖 Document.write
                try data.write(to: tempURL, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
                success = true
            } catch {
                // 写入失败处理
            }
            
            DispatchQueue.main.async {
                if success {
                    self?.fileMonitor?.updateLastKnownModDate()
                    self?.isDirty = false
                    self?.saveWorkItem = nil
                    // 延迟恢复：给 DispatchSource 事件足够的清空时间
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.fileMonitor?.isSelfSaving = false
                    }
                } else {
                    self?.fileMonitor?.isSelfSaving = false
                }
            }
        }

        // 根据同步、异步要求执行调度
        if sync {
            performWrite()
        } else {
            let workItem = DispatchWorkItem {
                // 将极其耗时的 I/O 写入发配到后台，彻底解放主线程，拒绝转彩虹圈
                DispatchQueue.global(qos: .userInitiated).async {
                    performWrite()
                }
            }
            saveWorkItem = workItem

            if immediate {
                DispatchQueue.main.async(execute: workItem)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
            }
        }
    }
    
    // MARK: - iOS Specific Debounced Save
    #if os(iOS)
    private var iosSaveDebounceWorkItem: DispatchWorkItem?
    
    /// 专门为 iOS 优化的延迟保存机制。
    /// 核心区别：将防抖等待放在 `document.dataRepresentation()` 之前执行。
    /// 只有当用户停笔 3 秒后，才真正进入主线程提取沉重的 PDF 数据，从而彻底消除标注时的 UI 卡顿。
    func saveForiOS(pdfView: PDFView?) {
        guard isDirty, let url = fileURL, let document = pdfView?.document else { return }
        
        iosSaveDebounceWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isDirty else { return }
            
            // 停笔 3 秒后，此时 UI 已经不卡了，我们在主线程安全提取 PDF 数据
            guard let data = document.dataRepresentation() else { return }
            
            // 拿到 Data 后，切到后台子线程去执行真实的硬盘写入
            DispatchQueue.global(qos: .userInitiated).async {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                var success = false
                do {
                    try data.write(to: tempURL, options: .atomic)
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
                    success = true
                } catch {
                    // iOS 写入失败处理
                }
                
                if success {
                    DispatchQueue.main.async {
                        self.isDirty = false
                    }
                }
            }
        }
        
        iosSaveDebounceWorkItem = workItem
        // 延迟 3 秒，防止连续高频标注导致重复序列化
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
    #endif
    
    // MARK: - Security Scoped Resources Access
    
    // 负责申请和释放沙盒权限，防止应用崩溃
    func handleDocumentAccess(url: URL) -> Bool {
        #if os(macOS)
        let accessing = url.startAccessingSecurityScopedResource()
        // macOS 是单窗口结构，所以如果换了新文件，一定要把旧文件的访问锁释放掉
        if let oldURL = macOSAccessingURL {
            oldURL.stopAccessingSecurityScopedResource()
        }
        if accessing {
            macOSAccessingURL = url
        } else {
            macOSAccessingURL = nil
        }
        return accessing
        #else
        // iOS 管理方式不一样，它的锁存在 Model 身上
        return url.startAccessingSecurityScopedResource()
        #endif
    }
    
    // 程序退出时的终极清理
    func closeAll() {
        // [极致内存斩杀] 彻底注销系统级文件监听器，打破 NSFileCoordinator 的强引用死锁
        fileMonitor?.stop()
        fileMonitor = nil
        
        #if os(macOS)
        macOSAccessingURL?.stopAccessingSecurityScopedResource()
        #endif
        
        #if os(iOS)
        for doc in documents {
            if doc.isAccessing {
                doc.url.stopAccessingSecurityScopedResource()
            }
        }
        #endif
    }
}

// MARK: - File Monitor for External Changes (外部文件变更监听)
/// [教程注释：极客级文件监听器 (File Monitor)]
/// `FileMonitor` 基于 `NSFilePresenter` 实现对当前正在阅读的 PDF 文件的外部监听。
/// 为什么要这个？因为我们的用户可能是科研工作者，他们可能一边用我们的 App 看文献，一边在 iCloud 或者别的同步盘里修改这个文件。
/// 如果文件在外面变了，我们要能瞬间察觉，并且自动刷新页面！
class FileMonitor: NSObject {
    let url: URL
    var onDidChange: (() -> Void)?
    
    private var lastKnownModDate: Date?
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    /// 实例级防抖任务，替代全局 cancelPreviousPerformRequests，避免多窗口互相干扰
    private var debounceWorkItem: DispatchWorkItem?
    
    init(url: URL) {
        self.url = url
        super.init()
        self.lastKnownModDate = getModDate()
        startMonitoring()
    }
    
    private func startMonitoring() {
        // [极限性能优化] 使用底层的 kqueue (vnode) 机制监听文件变更
        // 放弃笨重且经常漏报的 NSFilePresenter。DispatchSource 直接监听内核级别的写入事件。
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }
        
        // 【关键逻辑：支持原子保存】预览 App 等现代软件保存时不是直接覆盖，而是写入临时文件后重命名替换（原子保存）。
        // 这会导致原有的 vnode 被 .delete 或 .rename。我们必须同时监听这些事件来“接力”监控。
        let eventMask: DispatchSource.FileSystemEvent = [.write, .delete, .rename, .revoke]
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: eventMask, queue: .main)
        
        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let data = self.source?.data ?? []
            
            // 发生了原子覆盖保存，原有物理文件已经被“狸猫换太子”，当前句柄失效
            if data.contains(.delete) || data.contains(.rename) || data.contains(.revoke) {
                self.stop() // 立刻掐断对旧鬼影文件的监听
                
                // 给系统 0.5 秒的喘息时间，让新文件彻底在硬盘上落位，然后重新抛出事件并挂载监听
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.lastKnownModDate = self.getModDate()
                    self.triggerChange()
                    self.startMonitoring()
                }
                return
            }
            
            // 常规直接写入保存
            if data.contains(.write) {
                guard let newModDate = self.getModDate() else { return }
                if let last = self.lastKnownModDate, newModDate <= last { return }
                self.lastKnownModDate = newModDate
                // 防抖处理：系统保存时可能会瞬间触发多次 write 事件
                // 使用实例级 DispatchWorkItem 替代全局 cancelPreviousPerformRequests，避免多窗口互相干扰
                self.debounceWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.triggerChange()
                }
                self.debounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
            }
        }
        
        source?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        
        source?.resume()
    }
    
    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }
    
    private func getModDate() -> Date? {
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    
    func updateLastKnownModDate() {
        DispatchQueue.main.async {
            self.lastKnownModDate = self.getModDate()
        }
    }
    
    /// 标记当前是否为本应用自身在保存，若是则不触发重载
    var isSelfSaving = false
    
    private func triggerChange() {
        guard !isSelfSaving else { return }
        onDidChange?()
    }
}
