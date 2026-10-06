import SwiftUI
import PDFKit
import Combine

extension AppState {

    func setupCallbacks() {
        // [闭包与弱引用]
        // [weak self] 是 Swift 避免闭包造成循环引用（互相抓住不放）的终极武器。
        pdfView.onAnnotationSelected = { [weak self] annot in
            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                if let annot, annot.page?.document !== self.pdfView.document { return }
                self.selectedAnnotation = annot
            }
        }
        pdfView.onAnnotationContentsChanged = { [weak self] annot, text in
            DispatchQueue.main.async {
                guard let self, !self.isClosed, let doc = self.pdfView.document,
                      annot.page?.document === doc else { return }
                if self.annotationManager.updateContents(text, of: annot, in: doc) {
                    self.isDirty = true
                }
            }
        }
        pdfView.onAnnotationDeleted = { [weak self] annot in
            DispatchQueue.main.async {
                guard let self, !self.isClosed, let document = self.pdfView.document,
                      annot.page?.document === document else { return }
                self.selectedAnnotation = annot
                self.deleteSelectedAnnotation()
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
        pdfView.onAnnotationPagesChanged = { [weak self] indices in
            for index in indices { self?.thumbnailManager.invalidateThumbnail(at: index) }
        }
        pdfView.onSaveRequired = { [weak self] in
            self?.isDirty = true
        }
        pdfView.onInkCommitted = { [weak self] annotation in
            // 切换工具可能发生在 SwiftUI 更新期间，延后一轮发布列表变化。
            // 只追加新批次，不扫描全书，也不触碰其他窗口的旧标注。
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed, let page = annotation.page,
                      let document = self.pdfView.document, page.document === document else { return }
                // 侧栏首次展开可能已读到这一笔，延迟回调不能再追加一次。
                self.annotationManager.register(annotation, in: document)
                self.thumbnailManager.invalidateThumbnail(at: document.index(for: page))
            }
        }
    }
    
    // [教程注释：基于 Combine 的响应式编程流]
    func setupObservers() {
        let nc = NotificationCenter.default
        FeaturePreferences.shared.$eyeCare
            .removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                let color = enabled ? self.pageBackgroundColor : .default
                if self.pdfView._threadSafePageBackgroundColor != color {
                    self.pdfView._threadSafePageBackgroundColor = color
                }
            }.store(in: &cancellables)
        
        // 只监听本窗口。必须在读取 PDFView 或进入 MainActor 闭包之前切回主队列；
        // NotificationCenter 会在发布线程同步投递，不能假设 PDFKit 总在主线程发通知。
        nc.publisher(for: .PDFViewPageChanged, object: pdfView)
            .receive(on: DispatchQueue.main)
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
                    if self.liveState.currentPageIndex != index {
                        self.liveState.currentPageIndex = index
                        
                        self.updateReadingTracking()
                    }
                }
            }
            .store(in: &cancellables)
            
        // 监听可见区域变化（包括微小的滚动），如果处于非活动状态但用户还在阅读，应重置休眠倒计时
        nc.publisher(for: .PDFViewVisiblePagesChanged, object: pdfView)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                #if os(macOS)
                if let window = self.hostingWindow, !window.isKeyWindow {
                    self.scheduleHibernation()
                }
                #endif
            }
            .store(in: &cancellables)

        // 监听文本选择事件
        nc.publisher(for: .PDFViewSelectionChanged, object: pdfView)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                
                // 只有处于文本高亮/下划线/删除线模式下，才去给选中的文字打标。手绘(.ink)模式下绝不触发文本打标。
                guard self.activeType == .highlight || self.activeType == .underline || self.activeType == .strikeout else { return }
                
                guard !self.isApplyingAnnotation else { return }
                
                if let selection = self.pdfView.currentSelection, let str = selection.string, !str.isEmpty {
                    if str != self.lastProcessedSelectionString {
                        self.lastProcessedSelectionString = str
                        // 如果选了文本，且当前开启了文本标注工具，直接打上标注！
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

        liveState.pageIndexSubject
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main) 
            .sink { [weak self] index in
                guard let self = self else { return }
                // 缩略图由可见侧栏单元按需申请；正文翻页不再同步序列化
                // 前后 30 页，否则扫描页和 Beamer 会阻塞正文的滚动与瓦片加载。
                
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
                    UserDefaults.standard.set(index, forKey: "PDFLastPage_" + DocumentIdentity.id(for: url))
                }
            }
            .store(in: &cancellables)
            
        // 保存由 applicationShouldTerminate 统一完成，可取消的阶段才能处理失败。
        nc.publisher(for: NSWindow.willEnterFullScreenNotification)
            .sink { [weak self] _ in self?.pdfView.autoScales = false }
            .store(in: &cancellables)
        nc.publisher(for: NSWindow.didEnterFullScreenNotification)
            .sink { [weak self] _ in self?.pdfView.autoScales = true }
            .store(in: &cancellables)
        nc.publisher(for: NSWindow.didExitFullScreenNotification)
            .sink { [weak self] _ in self?.pdfView.autoScales = true }
            .store(in: &cancellables)
            
        // [新增：监听选中状态用于 AI 字数统计]
        nc.publisher(for: .PDFViewSelectionChanged, object: pdfView)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if let selection = self.pdfView.currentSelection?.string, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 简单的中英文分离字数计算
                    let englishWords = selection.split(separator: " ").count
                    let chineseChars = selection.filter { $0.isLetter && !$0.isASCII }.count
                    self.liveState.selectedEnglishWords = englishWords
                    self.liveState.selectedChineseChars = chineseChars
                } else {
                    self.liveState.selectedEnglishWords = nil
                    self.liveState.selectedChineseChars = nil
                }
            }
            .store(in: &cancellables)

        // 监听内存模式动态切换，实时更新 PDFView 的渲染策略
        nc.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // 同步护眼色到所有窗口（@AppStorage 的 didSet 只在改色的当前窗口触发，跨窗口同步靠此观察器）
                let bgRaw = UserDefaults.standard.integer(forKey: "pdfPageBackgroundColor")
                let bgColor = FeaturePreferences.shared.eyeCare ? (PDFPageBackgroundColor(rawValue: bgRaw) ?? .default) : .default
                if self.pdfView._threadSafePageBackgroundColor != bgColor {
                    self.pdfView._threadSafePageBackgroundColor = bgColor
                }
                let width = AnnotationDefaults.lineWidth()
                if self.currentLineWidth != width { self.currentLineWidth = width }
                // 同步内存模式渲染策略
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
        
    }
}
