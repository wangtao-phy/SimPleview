import SwiftUI
@preconcurrency import PDFKit
@preconcurrency import Combine

/// [教程注释：搜索系统引擎 (SearchManager)]
/// `SearchManager` 负责管理 PDF 内的全局搜索逻辑：
/// 1. 提供搜索的响应式状态（例如：是否正在搜索、搜索文本、当前高亮结果索引）
/// 2. 在后台线程执行异步的文本搜索，防止大型 PDF 搜索时主线程卡死
/// 3. 管理搜索结果的上下跳转逻辑
final class SearchManager: ObservableObject {
    
    // [UI 绑定状态]
    /// 用户当前输入的搜索关键词
    @Published var searchQuery: String = ""
    /// 包含所有搜索匹配项 (SearchMatch) 的数组
    @Published var searchResults: [SearchMatch] = []
    /// 当前用户聚焦在第几个搜索结果上 (基于 0 的索引)
    @Published var currentSearchIndex: Int? = nil
    /// 标记底层是否仍在搜索（用于在 UI 上显示转圈圈的 loading）
    @Published var isSearching: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    // [核心引擎：搜索队列]
    // 因为 PDF 搜索非常消耗 CPU，如果用户连续快速打字 "h", "he", "hel", "hello"
    // 我们不能开四个线程去搜，所以这是一个最大并发度为 1 的串行队列。
    private let searchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated // 优先级很高，毕竟用户在等
        return q
    }()
    
    /// 动态计算并用于在右上角或侧边栏显示的文本进度（例如："2 / 15"）
    var searchProgressText: String {
        guard !searchResults.isEmpty else { return "" }
        let current = (currentSearchIndex ?? -1) + 1
        return "\(current) / \(searchResults.count)"
    }
    
    // [逻辑流程：发起一场搜索]
    /// 在指定的 PDF 文档中触发全局字符串搜索
    /// - Parameters:
    ///   - document: 当前打开的 PDFDocument
    ///   - pdfView: 当前渲染的 PDFView，用于在重置搜索时清除高亮等状态
    func performSearch(in document: PDFDocument?, pdfView: PDFView?) {
        // 第一步：立刻废弃掉之前正在进行的旧搜索（因为用户的 query 可能已经变了）
        searchQueue.cancelAllOperations()
        document?.cancelFindString()
        
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 如果输入为空，大扫除，清空所有搜索状态
        guard !query.isEmpty, let document = document else {
            self.searchResults = []
            self.currentSearchIndex = nil
            self.isSearching = false
            #if os(iOS)
            pdfView?.highlightedSelections = nil
            #endif
            return
        }
        
        isSearching = true
        let currentQuery = query
        
        let startIndex = pdfView?.currentPage.map { document.index(for: $0) } ?? 0
        nonisolated(unsafe) let safeDocument = document
        
        // [异步编程：OperationBlock]
        // 切入后台线程执行底层的文本扫描，支持被中途取消
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            // 刚进来就先查一下有没有被取消，不要浪费算力
            guard let operation = operation, !operation.isCancelled else { return }
            
            // [流式渐进搜索引擎 (Iterative Streaming Search)]
            // 获取当前所处页码，以此作为搜索起点
            
            // 构建一个指向起始页开头的零长度 Selection，作为“光标”起点
            var currentSelection: PDFSelection? = nil
            if let startPage = safeDocument.page(at: startIndex) {
                currentSelection = document.selection(from: startPage, atCharacterIndex: 0, to: startPage, atCharacterIndex: 0)
            }
            
            var matches: [SearchMatch] = []
            var hasWrapped = false // 记录是否已经查到文档末尾并折返到了开头
            
            // 使用 while 循环配合 findString(fromSelection:)，可以每次只搜出一个结果就立即返回
            // 这种“一次给一个”的方式能完美避免死锁整个文档，极大节约 CPU！
            while !operation.isCancelled && matches.count < 200 {
                var shouldBreak = false
                var shouldContinue = false
                
                // [极限内存优化：切断 C 语言底层内存堆积]
                // 搜索时底层产生的海量临时缓存必须在每次循环后立刻释放，否则 200 次循环将导致几百兆的内存峰值。
                autoreleasepool {
                    // 从上一次找到的光标位置继续往下找
                    guard let sel = safeDocument.findString(currentQuery, fromSelection: currentSelection, withOptions: [.caseInsensitive, .diacriticInsensitive]) else {
                        // 如果往后找不到了
                        if !hasWrapped && startIndex > 0 {
                            // 【折返逻辑】：如果不是从第一页开始找的，那就折返到全书第 0 页重新继续找
                            hasWrapped = true
                            if let firstPage = safeDocument.page(at: 0) {
                                currentSelection = safeDocument.selection(from: firstPage, atCharacterIndex: 0, to: firstPage, atCharacterIndex: 0)
                            }
                            shouldContinue = true
                            return
                        } else {
                            // 已经搜遍全书了，退出循环
                            shouldBreak = true
                            return
                        }
                    }
                    
                    // 检查折返后是否已经扫过了起始页，如果是，说明搜完了整整一圈
                    if hasWrapped, let page = sel.pages.first, safeDocument.index(for: page) >= startIndex {
                        shouldBreak = true
                        return
                    }
                    
                    // 成功找到一个结果，更新光标位置
                    currentSelection = sel
                    
                    guard let page = sel.pages.first else { 
                        shouldContinue = true
                        return 
                    }
                    
                    // [极限内存优化：丢弃原生 Selection 换取内存自由]
                    // 彻底抛弃庞大的 PDFSelection 强引用。我们只抽取出轻量级的 CGRect 坐标。
                    let bounds = sel.selectionsByLine().map { $0.bounds(for: page) }
                    let match = SearchMatch(
                        boundsArray: bounds,
                        pageIndex: document.index(for: page),
                        context: sel.string ?? ""
                    )
                    matches.append(match)
                    
                    // [P1优化] 批量上屏：每累积 15 个结果或第 1 个结果时才投递，
                    // 将主线程 dispatch 次数从 200 降到 ~15 次，消除 O(n²) 数组拷贝
                    if matches.count == 1 || matches.count % 15 == 0 {
                        let currentMatchesSnapshot = matches
                        DispatchQueue.main.async {
                            guard let self = self, !operation.isCancelled else { return }
                            self.searchResults = currentMatchesSnapshot
                            if self.currentSearchIndex == nil {
                                self.currentSearchIndex = 0
                            }
                        }
                    }
                }
                
                if shouldBreak { break }
                if shouldContinue { continue }
            }
            
            // 收尾动作：先投递最后一批未上屏的结果（防止总数非 15 倍数时遗漏尾部），再标记搜索结束
            DispatchQueue.main.async {
                guard let self = self, !operation.isCancelled else { return }
                self.searchResults = matches
                if self.currentSearchIndex == nil && !matches.isEmpty {
                    self.currentSearchIndex = 0
                }
                self.isSearching = false
            }
        }
        
        searchQueue.addOperation(operation) // 把任务扔进队列开始跑
    }
    
    // [交互逻辑：上下翻阅搜索结果]
    
    /// 跳转到下一个搜索结果 (支持首尾循环跳转，到了最后一个按下一个会回到第一个)
    func goToNextSearchResult(pdfView: PDFView?) {
        let count = searchResults.count
        guard count > 0 else { return }
        let nextIndex = (currentSearchIndex ?? -1) + 1
        selectSearchResult(at: nextIndex % count, pdfView: pdfView) // % count 就是取模循环的精髓
    }
    
    /// 跳转到上一个搜索结果 (支持首尾循环跳转)
    func goToPreviousSearchResult(pdfView: PDFView?) {
        if !searchResults.isEmpty {
            let prevIndex = (currentSearchIndex ?? searchResults.count) - 1
            selectSearchResult(at: prevIndex >= 0 ? prevIndex : searchResults.count - 1, pdfView: pdfView)
        }
    }
    
    /// 选中特定索引的搜索结果并命令 PDFView 滚动到那里去
    func selectSearchResult(at index: Int, pdfView: PDFView?) {
        guard index >= 0 && index < searchResults.count else { return }
        if currentSearchIndex != index { currentSearchIndex = index }
        let match = searchResults[index]
        
        // UI 更新和页面跳转必须在主线程执行
        DispatchQueue.main.async {
            guard let pdfView = pdfView, let document = pdfView.document else { return }
            guard match.pageIndex < document.pageCount, let page = document.page(at: match.pageIndex) else { return }
            
            // 【极限内存优化：坐标重组高亮】
            // 因为内存中已经没有原生 `PDFSelection` 了，我们在这里使用 `match.boundsArray` 和 `page.selection(for: bounds)`
            // 毫秒级动态拼装出一个高亮选区。这种用微小 CPU 计算换取成百上千兆常驻内存释放的策略非常值得。
            var finalSelection: PDFSelection?
            for bounds in match.boundsArray {
                if let sel = page.selection(for: bounds) {
                    if finalSelection == nil {
                        finalSelection = sel
                    } else {
                        finalSelection?.add(sel)
                    }
                }
            }
            
            if let selection = finalSelection {
                // go(to:) 会让视图平滑滚动或直接跳转到该选区所在的页面
                pdfView.go(to: selection)
                // 告诉 PDFView，这是现在用户“选中的高亮区域”
                pdfView.currentSelection = selection
                
                // [Skim 级特效：动态高亮平滑闪烁]
                // 动态生成一堆高亮 Annotation 铺在目标位置上，并使用平滑动画让其褪色。
                let flashAnnotations = match.boundsArray.map { bounds -> PDFAnnotation in
                    let annot = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    // 使用纯黄色，更加明亮醒目
                    #if os(macOS)
                    annot.color = NSColor.yellow.withAlphaComponent(1.0)
                    #else
                    annot.color = UIColor.yellow.withAlphaComponent(1.0)
                    #endif
                    page.addAnnotation(annot)
                    return annot
                }
                
                // 使用 Timer 实现平滑褪色动画 (0.5秒内褪色完毕)
                var step = 0
                let totalSteps = 12 // 12 帧，每帧 0.04 秒 ≈ 0.5 秒动画
                let timer = Timer(timeInterval: 0.04, repeats: true) { t in
                    step += 1
                    let alpha = CGFloat(1.0 - Double(step) / Double(totalSteps))
                    
                    if step >= totalSteps {
                        t.invalidate()
                        for annot in flashAnnotations {
                            page.removeAnnotation(annot)
                        }
                    } else {
                        for annot in flashAnnotations {
                            #if os(macOS)
                            annot.color = NSColor.yellow.withAlphaComponent(alpha)
                            #else
                            annot.color = UIColor.yellow.withAlphaComponent(alpha)
                            #endif
                        }
                    }
                }
                // 必须加入 common 模式，否则用户在滑动触控板时动画会卡顿
                RunLoop.main.add(timer, forMode: .common)
                
                #if os(iOS)
                pdfView.highlightedSelections = [selection]
                pdfView.becomeFirstResponder()
                #endif
            }
        }
    }
    
    // 清空重置
    func clear() {
        searchQuery = ""
        searchResults = []
        currentSearchIndex = nil
        isSearching = false
    }
}
