import SwiftUI
import PDFKit
import Combine

/// [教程注释：文件加载与多标签支持]
extension AppState {
    
    // [逻辑流程：存盘操作接口]
    // 转发给内部的 documentManager。
    // 保存事务同步返回实际结果；sync 保留为现有调用点的兼容参数。
    var hasUnsavedChanges: Bool { isDirty || !pdfView.draftInkPaths.isEmpty }

    @discardableResult
    func save(sync: Bool = false, immediate: Bool = false) -> Bool {
        // Cmd+S/Cmd+Q 不保证改变第一响应者，必须主动提交尚未落入 PDF 的草稿。
        pdfView.commitDraftInk()
        autosaveTask?.cancel()
        autosaveTask = nil
        return documentManager.save(pdfView: pdfView, sync: sync, immediate: immediate)
    }
    
    /// 停止编辑两秒后写回原 PDF。任务只弱引用窗口，并验证文档加载代数和
    /// 编辑版本；换文档、关闭窗口或手动保存后，过期任务不能再写旧内容。
    func scheduleAutosave() {
        autosaveTask?.cancel()
        guard !isClosed, let url = fileURL, !ImageDocumentManager.isImageFile(url: url) else { return }
        let generation = loadGeneration, revision = editRevision
        autosaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, !self.isClosed,
                  self.loadGeneration == generation, self.editRevision == revision,
                  self.fileURL == url, self.isDirty, !self.isResolvingReload else { return }
            self.autosaveTask = nil
            // 不在尚未抬笔的事件追踪循环中取快照；抬笔回调会重新安排保存。
            guard self.pdfView.currentDrawingPath == nil else { return }
            guard let document = self.pdfView.makeAutosaveDocument() else {
                self.documentManager.saveIssue = "无法生成完整的标注副本，修改仍保留在窗口中，请手动保存。"
                return
            }
            self.documentManager.save(pdfView: self.pdfView, automatically: true, documentToSave: document)
        }
    }

    // [原生打印功能]
    func printDocument() {
        // 使用 PDFView 自带的原生打印接口，完美包含一切手写和矢量批注
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        pdfView.commitDraftInk()
        guard let document = pdfView.document,
              let data = StandardInk.exportData(of: document), let copy = PDFDocument(data: data) else { return }
        let printableView = PDFView()
        printableView.document = copy
        printableView.print(with: printInfo, autoRotate: true)
    }
    
    /// [核心概念：加载 PDF]
    /// 这是 App 启动后最重要的函数，负责将硬盘里的 PDF 文件塞入内存。
    func loadPDF(url: URL, isHotReloading: Bool = false) {
        guard !isClosed, !documentManager.isSaving, !isResolvingReload else { return }
        // 外部更新不打断阅读，也不能静默丢弃窗口中的未保存标注。
        // 保留当前版本；用户主动打开文档时仍走下面的修改确认流程。
        if isHotReloading && hasUnsavedChanges {
            hibernatedPosition = nil
            return
        }
        if hasUnsavedChanges {
            isResolvingReload = true
            let alert = NSAlert()
            alert.messageText = "当前文档还有未保存的修改"
            alert.informativeText = "保留当前修改会继续使用窗口中的版本；重新加载将放弃这些修改。可先取消并另存副本。"
            alert.addButton(withTitle: "保留当前修改")
            alert.addButton(withTitle: "放弃修改并重新加载")
            let response = alert.runModal()
            isResolvingReload = false
            guard response == .alertSecondButtonReturn else {
                hibernatedPosition = nil
                return
            }
        }
        let targetURL = resolveSecurityURL(url: url)
        loadGeneration &+= 1
        let generation = loadGeneration
        let revision = editRevision
        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            // 每个加载任务持有自己的安全访问租约。旧任务结束时只释放自己的
            // startAccessing，不能按 URL 相等去释放另一个同 URL 新任务的权限。
            let accessing = targetURL.startAccessingSecurityScopedResource()
            defer { if accessing { targetURL.stopAccessingSecurityScopedResource() } }
            let doc = ImageDocumentManager.isImageFile(url: targetURL)
                ? ImageDocumentManager.createPDFDocument(fromImageURL: targetURL)
                : PDFDocument(url: targetURL)
            if let doc, doc.isEncrypted { doc.unlock(withPassword: "") }
            await MainActor.run {
                guard let self, !self.isClosed, !Task.isCancelled,
                      self.loadGeneration == generation else { return }
                self.loadTask = nil
                // 用户可能在后台解析期间又画了一笔。此检查必须在替换前执行，
                // 即使开始加载时明确选择了放弃旧修改，也不能放弃后来新增的编辑。
                guard self.editRevision == revision else {
                    self.hibernatedPosition = nil
                    return
                }
                guard let doc, !doc.isLocked, doc.pageCount > 0 else {
                    // 原子替换、重新编译或云同步期间，路径可能暂时不可读。
                    // 热重载失败只保留现有文档；即使文件永久移除也不弹窗或关闭窗口。
                    self.hibernatedPosition = nil
                    guard !isHotReloading else { return }
                    let alert = NSAlert()
                    alert.messageText = "无法打开文档"
                    alert.informativeText = "文件可能损坏、为空或需要密码。当前窗口中的文档已保留。"
                    alert.runModal()
                    return
                }
                self.pdfView.prepareForDocumentReplacement()
                self.navigationManager.clearHistory()
                self.selectedAnnotation = nil
                self.searchManager.clear()
                _ = self.documentManager.handleDocumentAccess(url: targetURL)
                self.setupDocument(doc, url: targetURL, isHotReloading: isHotReloading)
            }
        }
    }

    // [教程注释：文件加载完毕后的基建配置]
    func setupDocument(_ doc: PDFDocument, url: URL, isHotReloading: Bool = false) {
        let migratedInk = StandardInk.migrate(in: doc)
        // 必须先关掉原生手绘层，再交给 PDFView，避免先创建模糊位图缓存。
        StandardInk.prepareForScreen(in: doc)
        self.fileURL = url
        self.pdfView.document = doc
        self.pdfView.setAnnotationsVisible(areAnnotationsVisible)
        
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
        
        self.isDirty = migratedInk
        self.liveState.totalPageCount = doc.pageCount
        self.rebuildPageAspectRatios()
        

        statisticsTask?.cancel()
        liveState.totalEnglishWords = nil
        liveState.totalChineseChars = nil
        let documentID = ObjectIdentifier(doc)
        // 普通 Task 会继承 MainActor；detached + 独立 URL 文档才真正隔离解析。
        // 回写只短暂取得 self，关闭窗口不会被全文统计任务强引用保活。
        statisticsTask = Task.detached(priority: .utility) { [weak self] in
            guard let statistics = DocumentStatistics.read(url: url), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isClosed, !Task.isCancelled,
                      self.pdfView.document.map(ObjectIdentifier.init) == documentID else { return }
                self.liveState.totalEnglishWords = statistics.englishWords
                self.liveState.totalChineseChars = statistics.chineseCharacters
                self.statisticsTask = nil
            }
        }

        readingTracker.prepareRecord(url: url)
        updateReadingTracking()
        
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
            
            let pageKey = "PDFLastPage_" + DocumentIdentity.id(for: url)
            let legacyPageKey = "PDFLastPage_" + url.lastPathComponent
            if UserDefaults.standard.object(forKey: pageKey) == nil,
               let legacy = UserDefaults.standard.object(forKey: legacyPageKey) {
                UserDefaults.standard.set(legacy, forKey: pageKey)
                UserDefaults.standard.removeObject(forKey: legacyPageKey)
            }
            let savedPage = UserDefaults.standard.integer(forKey: pageKey)
            self.goToPage(max(0, min(savedPage, max(0, doc.pageCount - 1))))
            self.thumbnailManager.clearCache()
            
            self.refreshAnnotations()
            
            self.documentVersion = UUID() 
            self.objectWillChange.send()
        }
    }
    
    /// 只有当前活动窗口可以拥有全局秒表；后台加载/热重载只准备记录，不抢计时。
    func updateReadingTracking() {
        guard !isClosed, hostingWindow?.isKeyWindow == true, NSApp.isActive,
              let url = fileURL else { return }
        readingTracker.startTracking(documentID: DocumentIdentity.id(for: url),
            documentTitle: url.deletingPathExtension().lastPathComponent,
            pageIndex: liveState.currentPageIndex, owner: ObjectIdentifier(self))
    }

    // [智能自动化：文献已读打签]
    // 这是个专为强迫症学者设计的功能。关闭文件时，检查各种信息（是否总结过？是否有打分？是否有作者信息？）
    // 如果全都有，说明这篇论文已经“精读”过了，自动在 macOS 底层用访达（Finder）给文件挂上一个橘黄色的“已精读”系统标签！
    func autoTagDocumentIfCompleted(url: URL) {
        if let record = ReadingTracker.shared.recordsCache[DocumentIdentity.id(for: url)] {
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
