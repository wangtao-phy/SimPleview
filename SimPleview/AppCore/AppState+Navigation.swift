import SwiftUI
import PDFKit

/// [教程注释：文档导航逻辑与扩展]
/// 将跳转逻辑从主文件中抽离，便于管理和阅读。
extension AppState {
    
    // MARK: - Navigation
    
    // [逻辑流程：页面跳转与边界保护]
    func goToPage(_ index: Int, recordHistory: Bool = true) {
        // [防御性编程] 必须确认有文档，且页数大于0，否则后面的数学计算可能崩溃
        guard let doc = pdfView.document else { return }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { return }
        
        // [核心算法：钳位函数 (Clamp)]
        // 如果用户在第一页还要往前翻(变成 -1)，或者在最后一页往后翻，这个代码会将它死死锁在 0 到最大页码之间。
        let clampedIndex = max(0, min(index, pageCount - 1))
        
        // 【稳健性优化】上锁，防止在跳转动画期间引发的系统页码回跳
        isNavigating = true
        
        // 委托给导航管理器去执行真正的底层 PDFKit 翻页
        navigationManager.goToPage(clampedIndex, pdfView: pdfView, recordHistory: recordHistory)
        
        // 只有页码真正改变时，才去触发 SwiftUI 的重绘
        if self.currentPageIndex != clampedIndex {
            self.currentPageIndex = clampedIndex
        }
        
        // 跳转结束，稍微延迟一点放开锁，防止 PDFKit 残留的回调事件
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isNavigating = false
        }
    }
    
    // 处理左侧缩略图被点击时的复杂逻辑（比如按住 Shift 连选）
    func handleThumbnailClick(index: Int, isCommandPressed: Bool, isShiftPressed: Bool) {
        navigationManager.handleThumbnailClick(index: index, pdfView: pdfView, isCommandPressed: isCommandPressed, isShiftPressed: isShiftPressed)
        self.currentPageIndex = navigationManager.currentPageIndex
    }
    
    func goBack() {
        navigationManager.goBack(pdfView: pdfView)
        self.currentPageIndex = navigationManager.currentPageIndex
    }
    
    func recordHistoryAction() {
        navigationManager.recordHistoryAction(currentPageIndex: currentPageIndex)
    }
    
    // [交互逻辑：选中批注后的跟随跳转]
    func handleAnnotationSelection(_ annotation: PDFAnnotation) {
        annotationJumpTask?.cancel()
        
        if !MemoryMode.current.policy.delaysNavigationJumps {
            // 即时跳转
            executeAnnotationJump(annotation)
        } else {
            // 节约模式：防抖 0.2 秒，确保用户停下按键后才真正进行跳转，防止频繁跨页触发大量内存分配
            annotationJumpTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                self?.executeAnnotationJump(annotation)
            }
        }
    }
    
    // 实际执行物理跳转的方法
    private func executeAnnotationJump(_ annotation: PDFAnnotation) {
        // 找出这个批注所在的页
        guard let page = annotation.page, let doc = page.document else { return }
        let index = doc.index(for: page)
        
        // 【防跳动核心逻辑】：判断该批注是否已经在屏幕的可视范围内
        // 如果用户直接点击 PDF 画布上的批注，它必然在可视范围内；
        // 如果我们在此时继续调用 go(to:)，PDFKit 会试图将其强制居中，导致恶心的画面跳动。
        let visibleRectOnPage = pdfView.convert(pdfView.bounds, to: page)
        if visibleRectOnPage.intersects(annotation.bounds) {
            // 已经在视野里了，只需安静地更新页码，锁死页面不发生任何物理滚动
            self.currentPageIndex = index
            return
        }
        
        // 如果批注在视野外（比如从侧边栏点击了其他页的批注），我们才执行滚动跳转
        // 上锁：标记当前正在“因为程序逻辑而导航中”，屏蔽掉用户的滑动干扰
        isNavigating = true
        if self.currentPageIndex != index { 
            self.recordHistoryAction() 
            // 【极其关键】必须显式更新页码状态，否则 LeftSidebarView 里的 onChange(of: currentPageIndex) 监听不到，
            // 左侧缩略图也就不会跟着往下滚了！
            self.currentPageIndex = index 
        }
        
        // 底层 PDFKit 指令：跳到那一页，然后精准定位到那个批注所在的坐标框！
        pdfView.go(to: page)
        pdfView.go(to: annotation.bounds, on: page)
        
        // 延迟 0.1 秒后解锁
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isNavigating = false
        }
    }
    
    // MARK: - Search
    // 所有的搜索功能全部转发给专门的 SearchManager
    func performSearch() {
        searchManager.performSearch(in: pdfView.document, pdfView: pdfView)
    }
    
    func goToNextSearchResult() { searchManager.goToNextSearchResult(pdfView: pdfView) }
    func goToPreviousSearchResult() { searchManager.goToPreviousSearchResult(pdfView: pdfView) }
    func selectSearchResult(at index: Int) { searchManager.selectSearchResult(at: index, pdfView: pdfView) }
    
    // MARK: - Undo (撤销机制)
    func undo() {
        recordHistoryAction() 
        // 向管理器发送撤销请求。它会返回是否成功。
        if annotationManager.undo(in: pdfView.document, pdfView: pdfView, onThumbnailUpdate: { [weak self] index in
            // 如果撤销的是“删除页面”这类影响全局的操作，index 会是 -1
            if index == -1 {
                self?.thumbnailManager.clearCache()
                self?.documentVersion = UUID() // 强刷整个文档的 UI
            } else {
                // 否则只是局部页面的批注撤销，单独重绘那一页即可
                self?.thumbnailManager.removeThumbnail(for: index)
                self?.generateThumbnail(for: index)
            }
        }, onPageChange: { [weak self] index in
            self?.goToPage(index)
        }) {
            isDirty = true
        }
    }
    
    func stopHistoryTimer() {
        historyTimerTask?.cancel()
        historyTimerTask = nil
    }
}
