import SwiftUI
import PDFKit
import Combine

/// [教程注释：文件加载与多标签支持]
extension AppState {
    
    // [逻辑流程：存盘操作接口]
    // 转发给内部的 documentManager。
    // sync 参数决定是阻塞主线程同步保存，还是放后台异步保存。
    func save(sync: Bool = false, immediate: Bool = false) {
        documentManager.save(pdfView: pdfView, sync: sync, immediate: immediate)
    }
    
    // [原生打印功能]
    func printDocument() {
        // 使用 PDFView 自带的原生打印接口，完美包含一切手写和矢量批注
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        pdfView.print(with: printInfo, autoRotate: true)
    }
    
    /// [核心概念：加载 PDF]
    /// 这是 App 启动后最重要的函数，负责将硬盘里的 PDF 文件塞入内存。
    func loadPDF(url: URL, isHotReloading: Bool = false) {
        // [底层逻辑：App Sandbox 沙盒权限机制]
        // 苹果系统的安全机制极其严格。如果这个 URL 是我们通过系统的弹窗选的，它会有“SecurityScopedResource”权限。
        // 如果是历史记录里的，需要解析书签来恢复权限。这个 resolve 函数帮我们封装了底层复杂的权限申请。
        let targetURL = resolveSecurityURL(url: url)
        
        // 每一次加载都获得版本号；慢的旧请求只能自行释放资源，不能回写 UI。
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()

        // [性能优化：后台线程解析 PDF]
        // 有些几百兆的学术巨作，如果在主线程打开，整个 App 会卡死好几秒。
        // 所以我们在高优先级后台线程读取文件。
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            // 开始申请访问这个文件的系统级授权
            let accessResult: Bool? = await MainActor.run {
                guard let self, self.loadGeneration == generation else { return nil }
                return self.documentManager.handleDocumentAccess(url: targetURL)
            }
            guard let accessing = accessResult else { return }

            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.documentManager.releaseDocumentAccessIfCurrent(url: targetURL, wasAccessing: accessing)
                }
                return
            }
            
            // [系统架构级决策：为什么必须使用 URL 而不能用 Data(mmap) 避开缓存]
            // PDFKit 底层与基于 URL 的系统级全局缓存深度绑定。虽然这会导致关闭文档后内存看似无法立刻释放（表现为系统的 Purgeable 可回收缓存），
            // 但如果强制使用 Data(contentsOf:) 初始化来试图绕过缓存，会触发两大致命退化：
            // 1. PDFKit 会关闭底层的异步图块渲染（Asynchronous Tile Rendering），导致主线程被同步渲染阻塞（触发 UI 严重闪烁/白屏）。
            // 2. doc.documentURL 会变成 nil，导致所有强依赖此属性的功能（如阅读记录追踪 ReadingTracker）直接报废。
            // 因此，我们必须拥抱原生的 URL 加载模式，将内存的回收调度权完全交还给 macOS/iOS 的虚拟内存内核。
            // [混合架构：图片包装]
            let document: PDFDocument?
            let isImage = ImageDocumentManager.isImageFile(url: targetURL)
            if isImage {
                document = ImageDocumentManager.createPDFDocument(fromImageURL: targetURL)
            } else {
                document = PDFDocument(url: targetURL)
            }
            
            guard let doc = document else {
                await MainActor.run { [weak self] in
                    self?.documentManager.releaseDocumentAccessIfCurrent(url: targetURL, wasAccessing: accessing)
                }
                return
            }
            
            // 如果遇到加密的 PDF（比如某些论文），尝试用空密码先解锁
            if doc.isEncrypted { doc.unlock(withPassword: "") }
            
            // [逻辑流程：回归主线程极速更新 UI]
            // PDF 读取完毕后，必须切回主线程进行 UI 绑定，让用户能够瞬间看到 PDF！
            await MainActor.run {
                guard let self, !Task.isCancelled, self.loadGeneration == generation else {
                    // 新请求已经接管了授权；只释放仍归本请求持有的权限。
                    if accessing { self?.documentManager.releaseDocumentAccessIfCurrent(url: targetURL, wasAccessing: accessing) }
                    return
                }
                
                // macOS: 每次打开新文件时，我们把它从“最近打开”的内部列表里清理掉，防止重复。
                self.documentManager.removeFromOpenedRecent(url: self.fileURL)
                
                self.setupDocument(doc, url: targetURL, isHotReloading: isHotReloading)
            }
        }
        loadTask = task
    }
    

    // [教程注释：文件加载完毕后的基建配置]
    func setupDocument(_ doc: PDFDocument, url: URL, isHotReloading: Bool = false) {
        self.fileURL = url
        self.pdfView.document = doc
        
        if !isHotReloading {
            HistoryManager.shared.recordOpen(url: url)
        }
        
        // autoScales = true 让 PDF 自动贴合窗口大小
        self.pdfView.autoScales = true
        // singlePageContinuous 是经典的竖向连续滚动模式
        self.pdfView.displayMode = .singlePageContinuous
        
        // 【稳健核心修复：混合页面大小防白屏】
        // 1. 必须开启 displaysPageBreaks。苹果底层在连续滚动模式下，如果遇到不同尺寸的页面拼接，
        // 它的 tile cache（图块缓存）会发生坐标错乱，导致较小或较大比例的页面直接被裁切掉或者渲染成白屏。
        self.pdfView.displaysPageBreaks = true
        
        // 2. 根据当前的 MemoryMode 策略动态设置插值质量。
        // 性能模式下使用 .high 获取无瑕画质，节约模式下使用 .low 极大降低瓦片缓存导致的内存飙升。
        let policy = MemoryMode.current.policy
        self.pdfView.interpolationQuality = policy.interpolationQuality
        #if os(macOS)
        self.pdfView.pageShadowsEnabled = policy.pageShadowsEnabled
        #endif
        
        // 3. 统一采用 cropBox 进行展示（这是学术界和出版界的标准，避免把出血线和裁切标记显示出来）
        self.pdfView.displayBox = .cropBox
        
        self.isDirty = false
        self.liveState.totalPageCount = doc.pageCount
        self.rebuildPageAspectRatios()
        

        // [新增：极低优先级异步计算文档总字数，绝不卡顿主线程]
        self.liveState.totalEnglishWords = nil
        self.liveState.totalChineseChars = nil
        Task(priority: .background) {
            var englishWords = 0
            var chineseChars = 0
            let pageCount = doc.pageCount
            for i in 0..<pageCount {
                if Task.isCancelled { break }
                if let pageString = doc.page(at: i)?.string {
                    englishWords += pageString.split(separator: " ").count
                    chineseChars += pageString.filter { $0.isLetter && !$0.isASCII }.count
                }
                // 极速计算：仅在后台做微弱让步，不再硬核睡眠，速度提升百倍
                if i % 10 == 0 { await Task.yield() }
            }
            if !Task.isCancelled {
                self.liveState.totalEnglishWords = englishWords
                self.liveState.totalChineseChars = chineseChars
            }
        }

        
        let title = url.deletingPathExtension().lastPathComponent
        // 告诉阅读记录追踪器：“哥们开始看了，开始计时！”
        self.readingTracker.startTracking(documentID: title, documentTitle: title, pageIndex: self.liveState.currentPageIndex)
        
        // [黑科技：监听外部文件篡改]
        // 用 DispatchSource 监听硬盘上的文件。如果此时用户用另外的 PDF 软件修改了这个文件并保存，
        // 我们的 App 会瞬间感知到，并自动重新加载。
        let monitor = FileMonitor(url: url)
        monitor.onDidChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 对于文件被外部修改（如 Markup popover 点击 Done），我们发起热重载
                // 并提前记录当前的物理坐标，伪装成一次“休眠唤醒”来避开全量重置
                let pageIndex = self.liveState.currentPageIndex
                let zoom = self.pdfView.scaleFactor
                let pt = self.pdfView.currentDestination?.point ?? .zero
                self.hibernatedPosition = (pageIndex: pageIndex, point: pt, zoom: zoom)
                self.loadPDF(url: url, isHotReloading: true)
            }
        }
        self.documentManager.fileMonitor = monitor
        
        // [核心 O(1) 状态恢复]：判断是否是从节约模式休眠唤醒 或 热重载
        if let pos = self.hibernatedPosition {
            // 这是唤醒：瞬间用 O(1) 算法挂靠精准物理坐标，且跳过清空缓存和庞大的 UI 重绘
            if let page = doc.page(at: pos.pageIndex) {
                let dest = PDFDestination(page: page, at: pos.point)
                dest.zoom = pos.zoom
                self.pdfView.go(to: dest)
                // 热重载后恢复手动缩放：setupDocument 前面已设 autoScales=true（自动贴合），
                // 会让触控板拺合缩放失效（Cmd+/- 会隐式关闭 autoScales 所以还能用）。
                // 恢复到一个具体 zoom 后应关闭 autoScales，保持手动缩放与热重载前一致。
                self.pdfView.autoScales = false
            }
            // 恢复完毕，清空位置缓存
            self.hibernatedPosition = nil
            
            // 唤醒或热重载依然需要刷新左侧批注列表
            self.refreshAnnotations()
            
            if isHotReloading {
                // [热重载缩略图无缝刷新]
                // 绝不能调用改变 documentVersion 导致整个侧边栏闪白重建！
                // 我们调用 clearCache() 清理掉所有指向旧 PDFDocument 的废弃图片内存，
                // 然后通过 hotReloadSubject 唤醒所有“当前可见”的缩略图重新发起渲染！
                self.thumbnailManager.clearCache()
                self.thumbnailManager.hotReloadSubject.send()
                
                // [防内存泄漏与崩溃] 热重载时底层 PDFDocument 实例已换新，必须清空撤销栈，
                // 否则旧的 PDFPage/PDFAnnotation 被强引用会导致内存泄漏，且 Undo 会崩溃。
                self.annotationManager.batchStack.removeAll()
                self.annotationManager.redoStack.removeAll()
            }
            
        } else {
            // 这是全新打开文件：重置历史、清空缓存、强迫 UI 重绘
            self.navigationHistory.removeAll()
            self.annotationManager.batchStack.removeAll() // 换了新文件，肯定要清空上个文件的撤销栈
            self.annotationManager.redoStack.removeAll()
            
            let savedPage = UserDefaults.standard.integer(forKey: "PDFLastPage_" + url.lastPathComponent)
            self.goToPage(max(0, min(savedPage, max(0, doc.pageCount - 1))))
            self.thumbnailManager.clearCache()
            
            self.refreshAnnotations()
            
            self.documentVersion = UUID() 
            self.objectWillChange.send()
        }
    }
    
    // [智能自动化：文献已读打签]
    // 这是个专为强迫症学者设计的功能。关闭文件时，检查各种信息（是否总结过？是否有打分？是否有作者信息？）
    // 如果全都有，说明这篇论文已经“精读”过了，自动在 macOS 底层用访达（Finder）给文件挂上一个橘黄色的“已精读”系统标签！
    func autoTagDocumentIfCompleted(url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        
        if let record = ReadingTracker.shared.recordsCache[title] {
            let hasDate = !record.articleDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSummary = !record.articleSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasRatings = !record.ratings.isEmpty
            let hasValidAuthor = record.authors.contains { author in
                !author.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !author.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            
            if hasDate && hasSummary && hasRatings && hasValidAuthor {
                var fileURL = url
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
                
                do {
                    // 读取系统原生的标签
                    var existingTags = try fileURL.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
                    if !existingTags.contains(where: { $0.hasPrefix("已精读") }) {
                        existingTags.append("已精读\n7") // 7 在 macOS 中代表橙色的系统颜色代码
                        var rv = URLResourceValues()
                        rv.tagNames = existingTags
                        try fileURL.setResourceValues(rv) // 真正写入硬盘
                    }
                } catch {
                    // 默默失败，不打扰用户
                }
            }
        }
    }
}
