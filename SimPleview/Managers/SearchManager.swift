import SwiftUI
import PDFKit
import Combine

/// 原生异步全文搜索；只保存有限的页码、行框和文字，不持有结果选区或 PDF 副本。
@MainActor
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
    
    private var searchGeneration: UInt = 0
    private weak var searchingDocument: PDFDocument?
    private var searchObservers: [AnyCancellable] = []
    private var startPage = 0
    private let resultLimit = 200
    private var forwardMatches: [SearchMatch] = []
    private var wrappedMatches: [SearchMatch] = []

    isolated deinit {
        for observer in searchObservers { observer.cancel() }
        searchingDocument?.cancelFindString()
    }

    /// 动态计算并用于在右上角或侧边栏显示的文本进度（例如："2 / 15"）
    var searchProgressText: String {
        guard !searchResults.isEmpty else { return "" }
        let current = (currentSearchIndex ?? -1) + 1
        return "\(current) / \(searchResults.count)"
    }
    
    /// 使用 PDFKit 自己的异步搜索，直接搜索当前编辑文档。不能把活动文档
    /// 丢给后台线程，也不必在主线程序列化整本 PDF 或长期缓存另一份文件。
    func performSearch(in document: PDFDocument?, pdfView: PDFView?) {
        cancelSearch()
        searchResults = []
        currentSearchIndex = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let document, !document.isLocked, document.pageCount > 0 else { return }

        startPage = pdfView?.currentPage.flatMap { page in
            page.document === document ? document.index(for: page) : nil
        } ?? 0
        searchingDocument = document
        isSearching = true
        let generation = searchGeneration
        for name in [Notification.Name.PDFDocumentDidFindMatch, .PDFDocumentDidEndFind] {
            // 通过主队列接收原生结果；PDFSelection 不跨执行器缓存。代数同时
            // 屏蔽已经排队的旧通知，换词/换文件/关闭后不能回填上一轮结果。
            let observer = NotificationCenter.default.publisher(for: name, object: document)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self, self.searchGeneration == generation,
                          notification.object as? PDFDocument === self.searchingDocument else { return }
                    if name == .PDFDocumentDidEndFind { self.finishSearch() }
                    else if let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection {
                        self.receive(selection)
                    }
                }
            searchObservers.append(observer)
        }
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    private func receive(_ selection: PDFSelection) {
        guard let document = searchingDocument, let page = selection.pages.first,
              page.document === document else { return }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index) else { return }
        // 跨页短语仍作为一次匹配；定位首个命中页，只收集属于该页的行框。
        let bounds = selection.selectionsByLine().filter { $0.pages.contains(page) }.map { $0.bounds(for: page) }
        let match = SearchMatch(boundsArray: bounds, pageIndex: index, context: selection.string ?? "")
        if index < startPage {
            // 原生搜索从首页开始。暂存前半部分的有限结果，最后才接到当前页
            // 之后的结果后面，避免搜索过程中插队、改变用户正在选择的结果。
            if wrappedMatches.count < resultLimit { wrappedMatches.append(match) }
        } else {
            forwardMatches.append(match)
            if forwardMatches.count == resultLimit { finishSearch() }
            else if forwardMatches.count == 1 || forwardMatches.count.isMultiple(of: 15) {
                publish(forwardMatches)
            }
        }
    }

    private func publish(_ matches: [SearchMatch]) {
        searchResults = matches
        if currentSearchIndex == nil, !matches.isEmpty { currentSearchIndex = 0 }
    }

    private func finishSearch() {
        publish(Array((forwardMatches + wrappedMatches).prefix(resultLimit)))
        cancelSearch()
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
        
        guard let pdfView, let document = pdfView.document,
              match.pageIndex >= 0, match.pageIndex < document.pageCount,
              let page = document.page(at: match.pageIndex) else { return }
        var selection: PDFSelection?
        for bounds in match.boundsArray {
            if let part = page.selection(for: bounds) {
                if let current = selection { current.add(part) } else { selection = part }
            }
        }
        if let selection {
            // 搜索定位属于视图状态，不能临时添加 PDFAnnotation：用户可能在
            // 动画结束之前保存文件，使所谓 SEARCH_FLASH 永久写入 PDF。
            // 使用 PDFView 原生选区动画，也无需任务在半秒内强持有旧页面。
            pdfView.go(to: selection)
            pdfView.setCurrentSelection(selection, animate: true)
        }
    }

    func clear() {
        cancelSearch()
        searchQuery = ""
        searchResults = []
        currentSearchIndex = nil
    }

    /// 先移除订阅，再取消原生任务；取消自身也可能同步发布结束通知。
    /// 休眠只停止工作并释放临时匹配，保留已经显示的结果和查询。
    func cancelSearch() {
        searchGeneration &+= 1
        for observer in searchObservers { observer.cancel() }
        searchObservers.removeAll()
        let document = searchingDocument
        searchingDocument = nil
        document?.cancelFindString()
        forwardMatches.removeAll()
        wrappedMatches.removeAll()
        isSearching = false
    }
}
