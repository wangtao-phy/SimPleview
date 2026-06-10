import SwiftUI
import PDFKit
import Combine

extension AppState {

    func setupCallbacks() {
        // [闭包与弱引用]
        // [weak self] 是 Swift 避免闭包造成循环引用（互相抓住不放）的终极武器。
        pdfView.onAnnotationSelected = { [weak self] annot in
            DispatchQueue.main.async { self?.selectedAnnotation = annot }
        }
        pdfView.onAnnotationContentsChanged = { [weak self] annot, text in
            DispatchQueue.main.async {
                // [极速稳健跨行同步]：与其扫描全书成百上千页，不如只扫描当前批注所在页的相邻 ±2 页
                // 这样既能完美归结跨越多行的批注，又能将性能损耗降至几乎为 0，实现真正的瞬时响应！
                if let doc = self?.pdfView.document, let id = annot.userName, !id.isEmpty, let page = annot.page {
                    let pageIndex = doc.index(for: page)
                    let start = max(0, pageIndex - 2)
                    let end = min(doc.pageCount, pageIndex + 3)
                    
                    for i in start..<end {
                        if let searchPage = doc.page(at: i) {
                            for searchAnnot in searchPage.annotations where searchAnnot.userName == id {
                                searchAnnot.contents = text
                                searchAnnot.modificationDate = Date()
                            }
                        }
                    }
                } else {
                    annot.contents = text // 兜底
                    annot.modificationDate = Date()
                }
                self?.isDirty = true
                self?.objectWillChange.send()
                
                // [极致性能优化] 由于修改时间变成了最新 (Date())，不需要全量排序（频繁访问 modificationDate 会引发严重的 CPU 耗时和卡顿），
                // 只需要把这个批注从数组中找到，抽出来，放到最后面即可。时间复杂度从 O(N log N) 且高消耗，直接降到 O(N) 且零消耗。
                if let am = self?.annotationManager, let id = annot.userName {
                    if let idx = am.allAnnotations.firstIndex(where: { $0.userName == id }) {
                        let updatedAnnot = am.allAnnotations.remove(at: idx)
                        am.allAnnotations.append(updatedAnnot)
                    }
                }
                
                // [P1-2优化] 移除 Array(current) 全量克隆
                // objectWillChange.send() 已在上方调用，足以让 SwiftUI 感知变化
                // 额外通知 annotationManager 刷新侧边栏显示
                self?.annotationManager.objectWillChange.send()
            }
        }
        pdfView.onAnnotationDeleted = { [weak self] annot in
            DispatchQueue.main.async {
                self?.selectedAnnotation = annot
                self?.deleteSelectedAnnotation()
            }
        }
        pdfView.onColorChanged = { [weak self] color, type in
            DispatchQueue.main.async {
                if type.contains("Highlight") { self?.highlightColor = color }
                else if type.contains("Underline") { self?.underlineColor = color }
                else if type.contains("StrikeOut") { self?.strikeoutColor = color }
            }
        }
        pdfView.onMouseUp = { [weak self] in
            DispatchQueue.main.async {
                self?.applyAnnotation()
                self?.resetAnnotationTimer()
            }
        }
        #if os(iOS)
        pdfView.onSaveRequired = { [weak self] in
            self?.isDirty = true
            self?.save()
        }
        #else
        pdfView.onSaveRequired = { [weak self] in
            self?.isDirty = true
        }
        #endif
    }
    
    // [教程注释：基于 Combine 的响应式编程流]
    func setupObservers() {
        let nc = NotificationCenter.default
        
        // 监听 PDF 翻页系统通知
        nc.publisher(for: .PDFViewPageChanged)
            .compactMap { [weak self] _ in self?.pdfView.currentPage }
            .compactMap { [weak self] page -> Int? in
                guard let doc = self?.pdfView.document, page.document === doc else { return nil }
                return doc.index(for: page)
            }
            .removeDuplicates() // 如果页码没变就不要重复触发后面的逻辑
            .sink { [weak self] index in
                // 收到新页码后的处理
                DispatchQueue.main.async {
                    // 【稳健性优化】如果正在程序跳转导航中，不要接收系统的页码事件，防止动画回跳导致状态冲突！
                    guard let self = self, !self.isNavigating else { return }
                    if self.currentPageIndex != index {
                        self.currentPageIndex = index
                        
                        // 开始记录这新的一页花了多少时间阅读
                        if let doc = self.pdfView.document, let url = doc.documentURL {
                            let title = url.deletingPathExtension().lastPathComponent
                            self.readingTracker.startTracking(documentID: title, documentTitle: title, pageIndex: index)
                        }
                        
                        #if os(iOS)
                        self.autoSyncCurrentDocument()
                        #endif
                    }
                }
            }
            .store(in: &cancellables)

        // 监听文本选择事件
        nc.publisher(for: .PDFViewSelectionChanged)
            #if os(iOS)
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main) // 防抖：iOS 手指划动会触发几百次选择改变，防抖让它安静下来再处理
            #else
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            #endif
            .sink { [weak self] _ in
                guard let self = self, self.activeType != AnnotationType.none, !self.isApplyingAnnotation else { return }
                if let selection = self.pdfView.currentSelection, let str = selection.string, !str.isEmpty {
                    if str != self.lastProcessedSelectionString {
                        self.lastProcessedSelectionString = str
                        // 如果选了文本，且当前开启了高亮工具，直接打上高亮！
                        self.applyAnnotation()
                    }
                }
            }
            .store(in: &cancellables)
            
        // (Removed: searchManager.objectWillChange forwarding to avoid whole-app re-renders on every keystroke)
            
        // 搜索词防抖系统：用户打字每打一个字不立马搜，停手 350 毫秒才去搜，极大地节约 CPU
        searchManager.$searchQuery
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.performSearch() }
            .store(in: &cancellables)

        $currentPageIndex
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main) 
            .sink { [weak self] index in
                guard let self = self else { return }
                // 预加载当前页码前后的缩略图，保证左边栏滚动如丝般顺滑
                self.prefetchThumbnails(around: index)
                
                // [智能历史判定] 停留 10 秒以上，才自动作为重要历史点记录下来
                self.historyTimerTask?.cancel()
                self.historyTimerTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.recordHistoryAction()
                }
                
                if self.selectedIndices.count <= 1 {
                    self.selectedIndices = [index]
                }
                
                self.navigationManager.currentPageIndex = index
                
                if let url = self.fileURL {
                    // 把页码存入磁盘，下次打开回到这里
                    UserDefaults.standard.set(index, forKey: "PDFLastPage_" + url.lastPathComponent)
                }
                
                #if os(iOS)
                self.autoSyncCurrentDocument()
                #endif
            }
            .store(in: &cancellables)
            
        annotationManager.$allAnnotations
            .dropFirst()
            .sink { [weak self] _ in
                #if os(iOS)
                self?.autoSyncCurrentDocument()
                #endif
            }
            .store(in: &cancellables)

        #if os(macOS)
        // 监听到系统真的要退出了，马上发起急救式保存
        nc.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                AppState.isAppExiting = true
                if self?.isDirty == true {
                    self?.save(sync: true)
                }
            }
            .store(in: &cancellables)
            
        nc.publisher(for: NSWindow.willEnterFullScreenNotification)
            .sink { [weak self] _ in self?.pdfView.autoScales = false }
            .store(in: &cancellables)
        nc.publisher(for: NSWindow.didExitFullScreenNotification)
            .sink { [weak self] _ in self?.pdfView.autoScales = false }
            .store(in: &cancellables)
        #endif
        
        nc.publisher(for: NSNotification.Name("PDFRefreshAnnotations"))
            .sink { [weak self] _ in self?.refreshAnnotations() }
            .store(in: &cancellables)
            
        // 监听内存模式动态切换，实时更新 PDFView 的渲染策略
        nc.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let policy = MemoryMode.current.policy
                if self.pdfView.interpolationQuality != policy.interpolationQuality {
                    self.pdfView.interpolationQuality = policy.interpolationQuality
                    #if os(macOS)
                    self.pdfView.pageShadowsEnabled = policy.pageShadowsEnabled
                    #endif
                    self.pdfView.setPlatformNeedsDisplay()
                }
            }
            .store(in: &cancellables)
            
        // [合并监听器]
        // 任何一个底层管理器的状态变更，都会合并 (Merge) 成一个流，用 100 毫秒节流阀节流后，向外抛出 AppState 更新的信号。
        Publishers.Merge4(
            thumbnailManager.objectWillChange,
            navigationManager.objectWillChange,
            annotationManager.objectWillChange,
            documentManager.objectWillChange
        )
        .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)
        
        // [极限原生优化：内存告警压缩]
        // 监听 macOS 底层的虚拟内存压力。这是最原生的手段，比任何黑科技都稳健。
        setupMemoryPressureObserver()
    }
    
    private func setupMemoryPressureObserver() {
        // 创建底层 DispatchSource 监听内存压力
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            
            // 如果不是节约模式，不激进清理
            guard MemoryMode.current.policy.aggressivePurgeOnClose else { return }
            
            if event.contains(.warning) || event.contains(.critical) {
                // 1. 瞬间清空缩略图排队任务与所有图片缓存
                self.thumbnailManager.clearCache()
                
                // 2. 强迫 PDFKit 吐出非可视区域的瓦片（Tile Cache）
                // 这个原生调用会让 PDFView 重新评估可视区域，从而释放大量积压在 CoreAnimation 里的高清贴图。
                #if os(macOS)
                self.pdfView.layoutDocumentView()
                #else
                self.pdfView.setNeedsLayout()
                #endif
            }
        }
        source.resume()
        self.memoryPressureSource = source
    }
}
