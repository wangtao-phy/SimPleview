import SwiftUI
import PDFKit
import Combine

/// [教程注释：导航与历史管理器 (NavigationManager)]
/// 在 PDF 阅读器中，用户经常会通过点击书签、搜索结果或者内部链接进行长距离的页面跳转。
/// 如果没有历史记录，用户跳过去之后就回不来了！
/// 这个类专门用来记录用户的每一次“跳跃”，从而实现类似浏览器“后退(Back)”的功能。
final class NavigationManager: ObservableObject {
    // 当前我们正在看第几页 (0-indexed)
    @Published var currentPageIndex: Int = 0
    
    // [核心数据：历史轨迹栈]
    // 每次发生长距离跳转前，把当前的页码推进去。最多存 30 条。
    @Published var navigationHistory: [Int] = []
    
    // 多选状态下选中的所有页码（主要用于左侧大纲的拖拽和删除多页）
    @Published var selectedIndices: Set<Int> = []
    
    // [逻辑流程：记录历史]
    func recordHistoryAction(currentPageIndex: Int) {
        // 防止连续记录同一个地方
        if let last = navigationHistory.last, last == currentPageIndex {
            return
        }
        navigationHistory.append(currentPageIndex)
        
        // 限制数组长度，防止看了一年之后数组撑爆内存
        if navigationHistory.count > 30 { navigationHistory.removeFirst() }
    }
    
    // [核心指令：跳转到某页]
    func goToPage(_ index: Int, pdfView: PDFView?, recordHistory: Bool = true) {
        guard let doc = pdfView?.document else { return }
        let pageCount = doc.pageCount
        guard index >= 0 && index < pageCount else { return } // 防越界崩溃
        
        if recordHistory {
            recordHistoryAction(currentPageIndex: currentPageIndex)
        }
        
        if let page = doc.page(at: index) {
            pdfView?.go(to: page) // 这是 PDFKit 提供的原生接口，能让视图丝滑滚过去
            currentPageIndex = index
            
            // 如果你只跳到这一页，那么默认就只“选中”这一页
            if !selectedIndices.contains(index) {
                selectedIndices = [index]
            }
        }
    }
    
    // [复杂交互逻辑：处理缩略图栏的点击]
    // 缩略图栏的点击非常复杂，因为在 Mac 上你可以按住 Command 多选，或者按住 Shift 连选！
    func handleThumbnailClick(index: Int, pdfView: PDFView?, isCommandPressed: Bool, isShiftPressed: Bool) {
        if isCommandPressed {
            // [Command 键：点选]
            if selectedIndices.contains(index) {
                selectedIndices.remove(index) // 再点一次就取消选中
            } else {
                selectedIndices.insert(index) // 加入选中套餐
            }
        } else if isShiftPressed {
            // [Shift 键：范围连选]
            let lastIndex = currentPageIndex
            let range = lastIndex < index ? lastIndex...index : index...lastIndex
            selectedIndices.formUnion(Set(range)) // 求并集，全选上
        } else {
            // [普通点击：单选]
            selectedIndices = [index]
        }
        
        // 如果是普通点击，我们需要记录一次历史轨迹，因为这是明确的导航意图
        if !isCommandPressed && !isShiftPressed {
            goToPage(index, pdfView: pdfView, recordHistory: true)
        } else {
            // 多选操作不计入导航历史（仅同步显示）
            currentPageIndex = index
            if let page = pdfView?.document?.page(at: index) {
                pdfView?.go(to: page)
            }
        }
    }
    
    // [时光倒流：返回上一页]
    func goBack(pdfView: PDFView?) {
        // 把连续重复的、或者是和当前页面一模一样的历史弹掉
        while !navigationHistory.isEmpty && navigationHistory.last == currentPageIndex {
            navigationHistory.removeLast()
        }
        // 如果还有剩的，那就是我们要回去的上一站
        if let prev = navigationHistory.popLast() {
            // 注意这里 recordHistory 传的是 false，因为你在“回滚历史”，不应该把回滚也当成新历史记下来
            goToPage(prev, pdfView: pdfView, recordHistory: false)
        }
    }
    
    // 清空历史（比如换了新的 PDF 文档时）
    func clearHistory() {
        navigationHistory.removeAll()
    }
}
