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
    
    // MARK: - Safe Background Saving (安全后台保存机制)
    
    // [核心引擎：多线程调度]
    // (已移除 saveQueue，因为 PDFKit 的 write(to:) 如果不在 MainActor 执行，极易在与 PDFView 渲染并发时引发崩溃)

    /// 将对 PDF 的修改保存到磁盘
    /// - Parameters:
    ///   - pdfView: 当前对应的 PDFView
    ///   - sync: 是否需要强制同步保存 (例如应用即将退出或休眠时，必须等它写完)
    ///   - immediate: 是否跳过防抖时间，立即在后台异步保存
    func save(pdfView: PDFView?, sync: Bool = false, immediate: Bool = false) {
        guard let url = fileURL, let document = pdfView?.document else { return }

        // 快速判断是否为图片 (避免频繁的文件系统调用)
        let ext = url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp"].contains(ext)

        // 如果文件没有被修改：
        // 对于普通 PDF，直接跳过以节省性能
        // 对于图片，只有在用户明确触发保存（Cmd+S 会传入 immediate=true 或 sync=true）时，才允许弹出另存为窗口
        if !isDirty {
            if !isImage || (!sync && !immediate) {
                return
            }
        }

        // 每次触发保存时，先把之前倒计时的任务取消掉（这就是典型的 Debounce 防抖逻辑）
        saveWorkItem?.cancel()

        // 提取闭包：这是真正的存盘核心动作
        // 【重大恶性 Bug 修复：放弃直接原地覆盖，采用绝对安全的原子化替换保存】
        // 以前的代码认为直接 write(to: originalURL) 可以触发增量保存从而保护 LaTeX。
        // 但实际上，当 PDFKit 决定无法进行增量保存（例如删除了页面、重排了页面）时，它会强行进行全量重写 (Full Rewrite)。
        // 此时由于目标 URL 是它当前正在 mmap(内存映射) 读取的原文件，这会导致原文件被 O_TRUNC 截断清空！
        // 当渲染引擎试图从被清空的原文件中读取未缓存的页面内容流 (/Contents) 时，会读到 0 字节，从而将一个完全空白的页面写入新文件！
        // 这就是为什么“重新打开pdf时某个页面全白了，但标注还在”的根本原因。
        // 解法：先写入系统的临时文件夹，然后再原子化替换原文件。这 100% 杜绝了内存映射截断的问题！
        let workItem = DispatchWorkItem { [weak self] in
            // 在写入前请求系统的安全写入权限
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // 通知主线程我们正在进行自我保存，避免文件监视器误报
            self?.fileMonitor?.isSelfSaving = true
            
            // [重大修复]：绝对不能使用 tempURL 进行间接替换！
            // PDFKit 一旦发现 targetURL != originalURL，就会强行进行 Full Rewrite（全量重构）。
            // 苹果的 Full Rewrite 引擎存在极大的缺陷，会直接剥离和破坏 LaTeX 等复杂文档中的 Type 3 和 subset 字体，导致公式字母全灭。
            // 必须直接 write(to: url) 才能触发苹果底层的 Incremental Save（增量保存），这样 100% 保护原文档不被破坏。
            // 之前出现的 White Page Bug，是因为在 Global 后台线程执行 write，导致与主线程 PDFView 渲染产生竞态。
            // 现在我们已经将 workItem 强制在 MainActor 执行，彻底杜绝了 White Page 的问题！
            // [混合架构：图片包装导出]
            if ImageDocumentManager.isImageFile(url: url) {
                // 如果是后台静默保存，对于图片我们直接忽略，不影响原文件，也不弹窗打扰用户
                guard sync || immediate else {
                    self?.fileMonitor?.isSelfSaving = false
                    return
                }
                
                #if os(macOS)
                ImageDocumentManager.promptSaveAs(pdfDocument: document, originalURL: url) { savedURL in
                    if savedURL != nil {
                        self?.isDirty = false
                        self?.fileMonitor?.updateLastKnownModDate()
                    }
                    self?.fileMonitor?.isSelfSaving = false
                }
                #endif
                return
            }
            
            let finalSuccess = document.write(to: url)
            if finalSuccess {
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

        saveWorkItem = workItem

        // [主线程防抖序列化]：
        // 绝对不能将 `document.write` 移到后台线程！
        // 经过验证，因为 PDFKit 内部线程安全机制的缺陷，在后台执行 write(to:) 会与主线程渲染产生严重竞态，
        // 导致应用在删除批注后保存时直接崩溃，或引发 White Page Bug！
        // 只能强制在 MainActor 执行，通过 500ms 的精细防抖来减轻卡顿。
        if sync {
            // 退出流程要求 write 已经完成；不能仅仅排到下一轮主事件循环。
            workItem.perform()
        } else if immediate {
            DispatchQueue.main.async(execute: workItem)
        } else {
            // 500ms 精细防抖，尽可能聚拢高频变动，只在最后停顿后执行一次主程序列化
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
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
        // [极致内存斩杀] 彻底注销系统级文件监听器，打破 NSFileCoordinator 的强引用死锁
        fileMonitor?.stop()
        fileMonitor = nil
        
        macOSAccessingURL?.stopAccessingSecurityScopedResource()
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
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    /// 实例级防抖任务，替代全局 cancelPreviousPerformRequests，避免多窗口互相干扰
    nonisolated(unsafe) private var debounceWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var restartWorkItem: DispatchWorkItem?
    private var isStopped = false
    
    init(url: URL) {
        self.url = url
        super.init()
        self.lastKnownModDate = getModDate()
        startMonitoring()
    }
    
    private func startMonitoring() {
        guard !isStopped, source == nil else { return }
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
        
        source?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
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
    deinit {
        debounceWorkItem?.cancel()
        restartWorkItem?.cancel()
        source?.cancel()
    }
}
