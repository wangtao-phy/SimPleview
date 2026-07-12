import SwiftUI
import PDFKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import Combine
import os

/// [教程注释：PDF 页面操作引擎]
/// 涵盖了删除、插入、重排、导出等高阶操作。
extension AppState {
    
    // MARK: - Page Management
    
    // [逻辑流程：页面重排与拖拽移动]
    func movePages(from sourceIndices: Set<Int>, to destinationIndex: Int) {
        guard let doc = pdfView.document, !sourceIndices.isEmpty else { return }
        
        // 1. 过滤：保证拿到的都是合法的页码，并从小到大排序
        let validSources = sourceIndices.filter { $0 >= 0 && $0 < doc.pageCount }.sorted()
        guard !validSources.isEmpty else { return }
        
        // 2. 将要移动的页面先保存在内存数组里
        let pagesToMove = validSources.compactMap { doc.page(at: $0) }
        
        // 3. 将这次移动操作压入撤销栈，以便用户反悔
        annotationManager.batchStack.append(.reorderPages(originalIndices: validSources, insertedAt: destinationIndex))
        annotationManager.redoStack.removeAll()
        
        // 4. 计算插入点的数学偏移（因为当你删掉前面的页面后，原本的 destination 索引会发生改变）
        let offset = validSources.filter { $0 < destinationIndex }.count
        let insertAt = max(0, min(destinationIndex - offset, doc.pageCount - validSources.count))
        
        // 5. 必须倒序删除！如果你正序删除，删了第0页，原来的第1页就变成了第0页，接下来你要删第1页时就乱套了。
        for src in validSources.reversed() {
            if src < doc.pageCount {
                doc.removePage(at: src)
            }
        }
        
        // 6. 按顺序插入到目标位置
        for (i, page) in pagesToMove.enumerated() {
            doc.insert(page, at: insertAt + i)
        }
        
        // 7. 更新选区和视图状态，并清除所有缩略图缓存
        self.selectedIndices = Set(insertAt..<(insertAt + pagesToMove.count))
        self.currentPageIndex = insertAt
        self.totalPageCount = doc.pageCount
        thumbnailManager.clearCache()
        self.documentVersion = UUID()
        
        DispatchQueue.main.async { [weak self] in
            self?.pdfView.layoutDocumentView()
            if let targetPage = doc.page(at: insertAt) { self?.pdfView.go(to: targetPage) }
            self?.pdfView.setPlatformNeedsDisplay()
        }
        self.isDirty = true
    }
    
    // [功能点：插入空白页]
    func insertBlankPage(at index: Int) {
        guard let doc = pdfView.document else { return }
        let insertAt = max(0, min(index, doc.pageCount))
        
        // 参考上一页的尺寸，如果不在这中间，就给个标准的国际 A4 纸大小 (595 x 842 pt)
        let refPage = doc.page(at: max(0, min(insertAt, doc.pageCount - 1)))
        let bounds = refPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        
        let newPage = PDFPage()
        newPage.setBounds(bounds, for: .mediaBox) // mediaBox 代表纸张物理大小
        
        doc.insert(newPage, at: insertAt)
        
        // 压入撤销栈
        batchStack.append(.insertPages(count: 1, startIndex: insertAt))
        redoStack.removeAll()
        totalPageCount = doc.pageCount
        thumbnailManager.clearCache()
        
        // 自动跳转并选中新页面
        self.currentPageIndex = insertAt
        self.selectedIndices = [insertAt]
        
        pdfView.setPlatformNeedsDisplay()
        isDirty = true
        
        DispatchQueue.main.async { [weak self] in
            self?.pdfView.layoutDocumentView()
            if let targetPage = doc.page(at: insertAt) {
                self?.pdfView.go(to: targetPage)
            }
        }
    }
    
    func deletePage(at index: Int) {
        // [防呆设计] 如果只剩最后一页了，就绝不让它删，不然底层引擎崩溃
        guard let doc = pdfView.document, doc.pageCount > 1 else { return }
        
        // 如果右键点击的那一页恰好是被多选（按住了Cmd）的那些页里面，我们就把他们一块删了。
        let targetIndices = selectedIndices.contains(index) ? selectedIndices.sorted(by: >) : [index]
        let validTargetIndices = targetIndices.filter { $0 >= 0 && $0 < doc.pageCount }
        
        if validTargetIndices.isEmpty || validTargetIndices.count >= doc.pageCount { return }
        
        for idx in validTargetIndices {
            if let pageToDelete = doc.page(at: idx) {
                doc.removePage(at: idx)
                batchStack.append(.deletePage(page: pageToDelete, index: idx))
                redoStack.removeAll()
            }
        }
        selectedIndices.removeAll()
        totalPageCount = doc.pageCount
        thumbnailManager.clearCache()
        if currentPageIndex >= totalPageCount { currentPageIndex = totalPageCount - 1 }
        pdfView.setPlatformNeedsDisplay()
        isDirty = true
    }
    
    // 把另一个 PDF 文件的所有页面塞入到现在的文档中
    func insertPDF(url: URL, at index: Int) {
        guard let doc = pdfView.document, let insertDoc = PDFDocument(url: url) else { return }
        let insertAt = max(0, min(index, doc.pageCount))
        
        for i in 0..<insertDoc.pageCount {
            if let page = insertDoc.page(at: i) { doc.insert(page, at: insertAt + i) }
        }
        batchStack.append(.insertPages(count: insertDoc.pageCount, startIndex: insertAt))
        redoStack.removeAll()
        totalPageCount = doc.pageCount
        thumbnailManager.clearCache()
        if currentPageIndex >= insertAt { currentPageIndex += insertDoc.pageCount }
        pdfView.setPlatformNeedsDisplay()
        isDirty = true
    }
    
    /// [功能点：原生的逆时针旋转当前页 90 度]
    func rotateCurrentPageLeft() {
        guard let doc = pdfView.document, let page = doc.page(at: currentPageIndex) else { return }
        
        // PDFKit 角度要求为 0, 90, 180, 270 (不能是负数)
        let newRotation = (page.rotation - 90) % 360
        page.rotation = newRotation < 0 ? newRotation + 360 : newRotation
        
        // [Bug修复核心] 旋转后，页面的物理宽高比例发生了反转（比如横版变竖版）。
        // 如果不同步更新内存中的 pageAspectRatios，左侧边栏的骨架屏占位框高度就会错乱。
        if pageAspectRatios.indices.contains(currentPageIndex) {
            pageAspectRatios[currentPageIndex] = 1.0 / pageAspectRatios[currentPageIndex]
        }
        
        // 使用异步主线程调用，既满足 @MainActor 限制，又能确保修改立刻反映到 UI 上。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // [性能优化] 抛弃了以前那种“删除缓存 -> 排队等后台线程用 dataRepresentation 重新画”的低效做法。
            // 这种旧做法由于存在竞态条件，极大概率导致缩略图不更新。
            // 现在的 updateLiveThumbnail 直接在主线程抓取页面最新快照并瞬间强制覆盖缓存，速度快且 100% 准确！
            self.thumbnailManager.updateLiveThumbnail(for: page, at: self.currentPageIndex)
            
            self.pdfView.layoutDocumentView()
            self.pdfView.setPlatformNeedsDisplay()
        }
        isDirty = true
    }
    

    #if os(macOS)

    
    func promptInsertPDF(at index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.insertPDF(url: url, at: index) }
        }
    }
    
    // [底层逻辑：多页面拖出导出功能]
    // 当用户在左侧选中了 5 页，然后往外面的桌面一拖。
    // 我们需要在内存里瞬间生成一个临时的新 PDF（包含这5页），然后把这个临时文件的地址交给 macOS 的拖拽引擎。
    @MainActor
    func exportPagesAsPDF(at indices: Set<Int>) -> URL? {
        guard let doc = pdfView.document, !indices.isEmpty else { return nil }
        let newDoc = PDFDocument()
        let sortedIndices = indices.sorted()
        
        for idx in sortedIndices {
            // PDFPage.copy() 是深度拷贝，断开它和原文档的联系
            if let page = doc.page(at: idx), let copy = page.copy() as? PDFPage {
                newDoc.insert(copy, at: newDoc.pageCount)
            }
        }
        
        guard newDoc.pageCount > 0 else { return nil }
        // 找到系统提供给当前 App 的专属临时文件夹
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("dragger.pdf") // 这个名字不重要，因为拖拽松手后由系统命名
            return newDoc.write(to: fileURL) ? fileURL : nil // 写进硬盘
        } catch {
            return nil
        }
    }
    #endif
}
