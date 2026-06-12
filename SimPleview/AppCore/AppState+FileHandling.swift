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
    
    /// [核心概念：加载 PDF]
    /// 这是 App 启动后最重要的函数，负责将硬盘里的 PDF 文件塞入内存。
    func loadPDF(url: URL, isHotReloading: Bool = false) {
        #if os(iOS)
        // iOS 模式下：如果在多标签页中发现这个文件已经打开了，直接切换到它，不再重复加载。
        if let existingIndex = documents.firstIndex(where: { $0.url == url }) {
            selectDocument(at: existingIndex)
            return
        }
        #endif
        
        #if os(macOS)
        // [底层逻辑：App Sandbox 沙盒权限机制]
        // 苹果系统的安全机制极其严格。如果这个 URL 是我们通过系统的弹窗选的，它会有“SecurityScopedResource”权限。
        // 如果是历史记录里的，需要解析书签来恢复权限。这个 resolve 函数帮我们封装了底层复杂的权限申请。
        let resolvedURL = resolveSecurityURL(url: url)
        let targetURL = resolvedURL
        #else
        let targetURL = url
        #endif
        
        // [性能优化：后台线程解析 PDF]
        // 有些几百兆的学术巨作，如果在主线程打开，整个 App 会卡死好几秒。
        // 所以我们在高优先级后台线程读取文件。
        Task.detached(priority: .userInitiated) { [weak self] in
            // 开始申请访问这个文件的系统级授权
            let accessing = await MainActor.run {
                self?.documentManager.handleDocumentAccess(url: targetURL) ?? false
            }
            
            // [系统架构级决策：为什么必须使用 URL 而不能用 Data(mmap) 避开缓存]
            // PDFKit 底层与基于 URL 的系统级全局缓存深度绑定。虽然这会导致关闭文档后内存看似无法立刻释放（表现为系统的 Purgeable 可回收缓存），
            // 但如果强制使用 Data(contentsOf:) 初始化来试图绕过缓存，会触发两大致命退化：
            // 1. PDFKit 会关闭底层的异步图块渲染（Asynchronous Tile Rendering），导致主线程被同步渲染阻塞（触发 UI 严重闪烁/白屏）。
            // 2. doc.documentURL 会变成 nil，导致所有强依赖此属性的功能（如阅读记录追踪 ReadingTracker）直接报废。
            // 因此，我们必须拥抱原生的 URL 加载模式，将内存的回收调度权完全交还给 macOS/iOS 的虚拟内存内核。
            guard let doc = PDFDocument(url: targetURL) else {
                if accessing { targetURL.stopAccessingSecurityScopedResource() }
                return
            }
            
            // 如果遇到加密的 PDF（比如某些论文），尝试用空密码先解锁
            if doc.isEncrypted { doc.unlock(withPassword: "") }
            
            // [逻辑流程：回归主线程极速更新 UI]
            // PDF 读取完毕后，必须切回主线程进行 UI 绑定，让用户能够瞬间看到 PDF！
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                #if os(iOS)
                // iOS: 新开一个标签页
                let newModel = PDFDocumentModel(url: url, document: doc, isAccessing: accessing)
                self.documentManager.documents.append(newModel)
                self.documentManager.activeDocumentIndex = self.documentManager.documents.count - 1
                #else
                // macOS: 每次打开新文件时，我们把它从“最近打开”的内部列表里清理掉，防止重复。
                self.documentManager.removeFromOpenedRecent(url: self.fileURL)
                #endif
                
                self.setupDocument(doc, url: url, isHotReloading: isHotReloading)
                
                #if os(iOS)
                // 存进UserDefaults持久化标签状态
                self.documentManager.persistiOSDocuments()
                #endif
            }
        }
    }
    

    // [教程注释：文件加载完毕后的基建配置]
    func setupDocument(_ doc: PDFDocument, url: URL, isHotReloading: Bool = false) {
        self.fileURL = url
        self.pdfView.document = doc
        
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
        self.totalPageCount = doc.pageCount
        
        let title = url.deletingPathExtension().lastPathComponent
        // 告诉阅读记录追踪器：“哥们开始看了，开始计时！”
        self.readingTracker.startTracking(documentID: title, documentTitle: title, pageIndex: self.currentPageIndex)
        
        // [黑科技：监听外部文件篡改]
        // 用 DispatchSource 监听硬盘上的文件。如果此时用户用另外的 PDF 软件修改了这个文件并保存，
        // 我们的 App 会瞬间感知到，并自动重新加载。
        let monitor = FileMonitor(url: url)
        monitor.onDidChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 对于文件被外部修改（如 Markup popover 点击 Done），我们发起热重载
                // 并提前记录当前的物理坐标，伪装成一次“休眠唤醒”来避开全量重置
                let pageIndex = self.currentPageIndex
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
            }
            // 恢复完毕，清空位置缓存
            self.hibernatedPosition = nil
            
            // 唤醒或热重载依然需要刷新左侧批注列表
            self.refreshAnnotations()
            
            if isHotReloading {
                // [热重载缩略图无缝刷新]
                // 绝不能调用 clearCache() 和改变 documentVersion 导致整个侧边栏闪白！
                // 我们只需精准移除刚刚被编辑的这一页的旧缓存，并通知其重新渲染。
                self.thumbnailManager.removeThumbnail(for: pos.pageIndex)
                self.generateThumbnail(for: pos.pageIndex)
                
                // [防内存泄漏与崩溃] 热重载时底层 PDFDocument 实例已换新，必须清空撤销栈，
                // 否则旧的 PDFPage/PDFAnnotation 被强引用会导致内存泄漏，且 Undo 会崩溃。
                self.annotationManager.batchStack.removeAll()
            }
            
        } else {
            // 这是全新打开文件：重置历史、清空缓存、强迫 UI 重绘
            self.navigationHistory.removeAll()
            self.annotationManager.batchStack.removeAll() // 换了新文件，肯定要清空上个文件的撤销栈
            
            let savedPage = UserDefaults.standard.integer(forKey: "PDFLastPage_" + url.lastPathComponent)
            self.goToPage(max(0, min(savedPage, max(0, doc.pageCount - 1))))
            self.thumbnailManager.clearCache()
            
            self.refreshAnnotations()
            
            self.documentVersion = UUID() 
            self.objectWillChange.send()
        }
    }
    
    // MARK: - iOS Multi-tab support
    
    // iOS 专用：切换顶部标签页
    func selectDocument(at index: Int) {
        guard index >= 0 && index < documents.count else { return }
        documentManager.activeDocumentIndex = index
        let model = documents[index]
        
        // [状态替换大法]
        // 切换标签页时，把新文件的历史、批注堆栈全部“覆盖”到当前的视图环境里。
        self.currentPageIndex = model.currentPageIndex
        self.navigationManager.navigationHistory = model.navigationHistory
        self.allAnnotations = model.allAnnotations
        self.batchStack = model.batchStack
        
        self.setupDocument(model.document, url: model.url)
        self.refreshAnnotations()
        
        // 让 PDF 引擎精准跳转到之前看到的那页
        if let page = model.document.page(at: model.currentPageIndex) {
            pdfView.go(to: page)
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
                #if os(macOS)
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
                #endif
            }
        }
    }
    
    // 关闭标签页（或关闭单文档窗口时触发）
    func closeDocument(at index: Int) {
        guard index >= 0 && index < documents.count else { return }
        
        let documentToClose = documents[index]
        autoTagDocumentIfCompleted(url: documentToClose.url) // 关闭前尝试打标签
        
        let removed = documentManager.documents.remove(at: index)
        // 取消底层授权，防止句柄泄露
        if removed.isAccessing { removed.url.stopAccessingSecurityScopedResource() }
        
        if documents.isEmpty {
            // 如果全关了，清空环境，显示空白占位图
            fileURL = nil
            pdfView.document = nil
            activeDocumentIndex = 0
            allAnnotations = []
            batchStack = []
            navigationManager.clearHistory()
        } else {
            // 如果还剩有标签，自动跳到左边那个标签
            let newIndex = min(index, documents.count - 1)
            selectDocument(at: newIndex)
        }
        documentManager.persistiOSDocuments()
    }
    
    #if os(iOS)
    // [底层逻辑：iOS 上的 URL 书签恢复]
    // iOS 重启 App 后，直接用原来的 URL 会因为沙盒报错“无权限”。
    // 必须要用上次特意存进 UserDefaults 的 Bookmark (书签数据) 还原出一条有权限的 URL 才行！
    func restoreiOSDocuments() {
        guard let bookmarks = UserDefaults.standard.array(forKey: "OpenediOSPDFBookmarks") as? [Data] else { return }
        for data in bookmarks {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
                if !isStale { loadPDF(url: url) }
            } catch {
            }
        }
    }
    
    func autoSyncCurrentDocument() {
        guard !documents.isEmpty && activeDocumentIndex < documents.count else { return }
        documentManager.documents[activeDocumentIndex].currentPageIndex = self.currentPageIndex
        documentManager.documents[activeDocumentIndex].navigationHistory = self.navigationHistory
        documentManager.documents[activeDocumentIndex].allAnnotations = self.allAnnotations
        documentManager.documents[activeDocumentIndex].batchStack = self.batchStack
        documentManager.persistiOSDocuments()
    }
    #endif
}
