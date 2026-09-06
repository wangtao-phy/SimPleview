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
    @Published var fileURL: URL? {
        didSet {
            savedFileVersion = fileURL.flatMap { try? AtomicPDFWriter.FileVersion(url: $0) }
            saveIssue = nil
        }
    }
    private var savedFileVersion: AtomicPDFWriter.FileVersion?
    @Published var saveIssue: String?
    
    /// 标记当前文档是否包含未保存的修改 (比如你刚画了一条线)
    @Published var isDirty: Bool = false
    
    // [沙盒授权缓存]
    /// (macOS) 当前正在安全访问的文件 URL，用于在切换文件时正确释放上一个文件的权限，防止句柄泄露导致崩溃
    private var macOSAccessingURL: URL?
    
    // [保存防抖]
    /// 用于防抖动 (Debounce) 的保存任务，避免频繁修改导致频繁磁盘 I/O，损坏 SSD 寿命
    private(set) var isSaving = false
    
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
    //
    // [注意] updateOpenedRecent 从未被调用，因此 OpenedPDFBookmarks 字典始终为空，下面的书签链路目前是惰性 no-op。
    // 实际的窗口恢复由 applicationDidFinishLaunching 中的 SavedWindowGroups（纯路径）承担。
    // 若日后启用 App Sandbox，需在此处重新挂入“写入书签”的逻辑。
    
    /// 当文档被显式关闭时，从持久化历史中移除它的书签权限
    func removeFromOpenedRecent(url: URL?) {
        #if os(macOS)
        guard let path = url?.path else { return }
        var dict = UserDefaults.standard.dictionary(forKey: "OpenedPDFBookmarks") as? [String: Data] ?? [:]
        dict.removeValue(forKey: path)
        UserDefaults.standard.set(dict, forKey: "OpenedPDFBookmarks")
        #endif
    }
    
    /// 保存和关闭共用一个同步结果。图片使用应用模态另存为面板，直到用户完成
    /// 或取消才返回；调用者不能把“面板已出现”误认为“文件已经保存”。
    /// isSaving 防止面板的嵌套事件循环重入保存。后台休眠不弹图片导出面板。
    @discardableResult
    func save(pdfView: PDFView?, sync: Bool = false, immediate: Bool = false,
              automatically: Bool = false, documentToSave: PDFDocument? = nil) -> Bool {
        guard !isSaving else { return false }
        guard let url = fileURL, let document = documentToSave ?? pdfView?.document else { return !isDirty }
        let isImage = ImageDocumentManager.isImageFile(url: url)
        guard isDirty || (isImage && immediate) else { return true }
        if isImage && !sync && !immediate { return false }
        if automatically && (isImage || savedFileVersion == nil) {
            saveIssue = "尚未写入 PDF，请使用保存按钮选择保存位置。"
            return false
        }
        isSaving = true
        let monitor = fileMonitor
        monitor?.isSelfSaving = true
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            isSaving = false
            monitor?.updateLastKnownModDate()
            // 只操作本次保存对应的监视器，不影响随后打开的新文档。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak monitor] in
                monitor?.isSelfSaving = false
            }
        }
        do {
            if isImage {
                guard try ImageDocumentManager.promptSaveAs(pdfDocument: document, originalURL: url) != nil else { return false }
            } else {
                try AtomicPDFWriter.write(document, to: url, expectedVersion: automatically ? savedFileVersion : nil)
            }
            savedFileVersion = try? AtomicPDFWriter.FileVersion(url: url)
            saveIssue = nil
            isDirty = false
            return true
        } catch {
            saveIssue = error.localizedDescription
            // 自动保存失败保留脏标记并在状态栏提示，不反复弹模态窗口打断输入。
            guard !automatically else { return false }
            let alert = NSAlert(error: error)
            alert.messageText = "保存失败，修改仍保留在窗口中"
            alert.runModal()
            return false
        }
    }

    // MARK: - Security Scoped Resources Access
    
    // 负责申请和释放沙盒权限，防止应用崩溃
    func handleDocumentAccess(url: URL) -> Bool {
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
    }

    /// 仅在该 URL 仍是当前持有的授权时释放它，避免过期加载任务误释放新文档的权限。
    func releaseDocumentAccessIfCurrent(url: URL, wasAccessing: Bool = true) {
        guard macOSAccessingURL == url else { return }
        guard wasAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        macOSAccessingURL = nil
    }
    
    // 程序退出时的终极清理
    func closeAll() {
        // 停止事件源；描述符由取消回调独立关闭，随后释放安全访问租约。
        fileMonitor?.stop()
        fileMonitor = nil
        
        macOSAccessingURL?.stopAccessingSecurityScopedResource()
        macOSAccessingURL = nil
    }
}

// MARK: - File Monitor for External Changes (外部文件变更监听)
/// [教程注释：极客级文件监听器 (File Monitor)]
/// FileMonitor 使用 DispatchSource 的 vnode 事件监视当前文件，原子替换后重建监听。
/// 为什么要这个？因为我们的用户可能是科研工作者，他们可能一边用我们的 App 看文献，一边在 iCloud 或者别的同步盘里修改这个文件。
/// 如果文件在外面变了，我们要能瞬间察觉，并且自动刷新页面！
class FileMonitor: NSObject {
    let url: URL
    var onDidChange: (() -> Void)?
    
    private var lastKnownModDate: Date?
    private var acknowledgedModDate: Date?
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    /// 实例级防抖任务，替代全局 cancelPreviousPerformRequests，避免多窗口互相干扰
    nonisolated(unsafe) private var debounceWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var restartWorkItem: DispatchWorkItem?
    private var isStopped = false
    
    init(url: URL) {
        self.url = url
        super.init()
        self.lastKnownModDate = getModDate()
        self.acknowledgedModDate = lastKnownModDate
        startMonitoring()
    }
    
    private func startMonitoring() {
        guard !isStopped, source == nil else { return }
        // [极限性能优化] 使用底层的 kqueue (vnode) 机制监听文件变更
        // 放弃笨重且经常漏报的 NSFilePresenter。DispatchSource 直接监听内核级别的写入事件。
        let fileDescriptor = open(url.path, O_EVTONLY)
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
                // 仅停止旧 vnode，不将整个监视器标记为停止；关闭窗口时的 stop()
                // 会取消下面的重启任务，避免陈旧监听器复活。
                self.source?.cancel()
                self.source = nil
                self.restartWorkItem?.cancel()

                // 给系统 0.5 秒的喘息时间，让新文件彻底在硬盘上落位，然后重新抛出事件并挂载监听
                let restart = DispatchWorkItem { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.lastKnownModDate = self.getModDate()
                    self.triggerChange()
                    self.startMonitoring()
                }
                self.restartWorkItem = restart
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restart)
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
        
        // cancel() 只提交异步取消请求；此时监视器可能已经被窗口释放。
        // 回调只拥有本次打开的 FD，不依赖 self，也不会误关重启后的新 FD。
        // FD 的所有权转交给 source，只有这一处 close，stop/deinit 可重复取消。
        source?.setCancelHandler {
            close(fileDescriptor)
        }
        
        source?.resume()
    }
    
    func stop() {
        isStopped = true
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        source?.cancel()
        source = nil
    }
    
    private func getModDate() -> Date? {
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    
    func updateLastKnownModDate() {
        lastKnownModDate = getModDate()
        acknowledgedModDate = lastKnownModDate
    }

    var isSelfSaving = false

    private func triggerChange() {
        guard !isStopped else { return }
        if isSelfSaving {
            // 保存抑制窗口期间的外部更新不能直接丢弃，稍后重新比较磁盘版本。
            debounceWorkItem?.cancel()
            let retry = DispatchWorkItem { [weak self] in self?.triggerChange() }
            debounceWorkItem = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
            return
        }
        let date = getModDate()
        guard date != acknowledgedModDate else { return }
        acknowledgedModDate = date
        onDidChange?()
    }
    deinit {
        debounceWorkItem?.cancel()
        restartWorkItem?.cancel()
        source?.cancel()
    }
}
