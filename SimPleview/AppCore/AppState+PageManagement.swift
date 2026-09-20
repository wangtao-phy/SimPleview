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
    
    /// 页面结构改变后统一更新索引、缩略图映射和几何数据。
    /// 异步布局前检查文档身份，防止换文件后执行上一份文档的跳转。
    func pageStructureDidChange(in document: PDFDocument, navigateTo index: Int? = nil) {
        guard pdfView.document === document else { return }
        annotationManager.refreshAnnotations(in: document)
        thumbnailManager.reconcile(with: document)
        liveState.totalPageCount = document.pageCount
        liveState.currentPageIndex = max(0, min(liveState.currentPageIndex, document.pageCount - 1))
        selectedIndices = selectedIndices.filter { (0..<document.pageCount).contains($0) }
        rebuildPageAspectRatios()
        pdfView.backgroundGeometryDocument = nil
        pdfView.preparePageBackground(for: document)
        documentVersion = UUID()
        let revision = UUID()
        pageStructureChanged = revision
        if let annotation = selectedAnnotation, annotation.page?.document !== document { selectedAnnotation = nil }
        thumbnailManager.hotReloadSubject.send()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pdfView.document === document, self.pageStructureChanged == revision else { return }
            self.pdfView.layoutDocumentView()
            if let index, let page = document.page(at: index) { self.pdfView.go(to: page) }
            self.pdfView.setPlatformNeedsDisplay()
        }
    }

    func movePages(from sourceIndices: Set<Int>, to destinationIndex: Int) {
        guard let doc = pdfView.document else { return }
        let sources = sourceIndices.filter { (0..<doc.pageCount).contains($0) }.sorted()
        guard !sources.isEmpty else { return }
        let destination = max(0, min(destinationIndex, doc.pageCount))
        let offset = sources.filter { $0 < destination }.count
        let start = destination - offset
        let targets = Array(start..<(start + sources.count))
        guard sources != targets else { return }
        let pages = sources.compactMap { doc.page(at: $0) }
        guard pages.count == sources.count else { return }
        for index in sources.reversed() { doc.removePage(at: index) }
        for (page, index) in zip(pages, targets) { doc.insert(page, at: index) }
        annotationManager.record(.movePages(from: targets, to: sources))
        selectedIndices = Set(targets)
        liveState.currentPageIndex = start
        pageStructureDidChange(in: doc, navigateTo: start)
        isDirty = true
    }

    func insertBlankPage(at index: Int) {
        guard let doc = pdfView.document else { return }
        let index = max(0, min(index, doc.pageCount))
        let reference = doc.page(at: max(0, min(index, doc.pageCount - 1)))
        let bounds = reference?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let page = PDFPage()
        page.setBounds(bounds, for: .mediaBox)
        doc.insert(page, at: index)
        annotationManager.record(.insertPages(count: 1, startIndex: index))
        selectedIndices = [index]
        liveState.currentPageIndex = index
        pageStructureDidChange(in: doc, navigateTo: index)
        isDirty = true
    }

    func deletePage(at index: Int) {
        guard let doc = pdfView.document, doc.pageCount > 1 else { return }
        let indices = (selectedIndices.contains(index) ? selectedIndices : [index])
            .filter { (0..<doc.pageCount).contains($0) }.sorted()
        guard !indices.isEmpty, indices.count < doc.pageCount else { return }
        let pages = indices.compactMap { doc.page(at: $0) }
        guard pages.count == indices.count else { return }
        for index in indices.reversed() { doc.removePage(at: index) }
        // 一次多选删除对应一个历史动作，撤销时按原位置完整恢复。
        annotationManager.record(.deletePages(pages: pages, indices: indices))
        selectedIndices.removeAll()
        pageStructureDidChange(in: doc)
        isDirty = true
    }

    func insertPDF(url: URL, at index: Int) {
        guard let doc = pdfView.document else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = PDFDocument(url: url), !source.isLocked, source.pageCount > 0 else { return }
        let pages = (0..<source.pageCount).compactMap { source.page(at: $0) }
        guard pages.count == source.pageCount else { return }
        let index = max(0, min(index, doc.pageCount))
        for (offset, page) in pages.enumerated() { doc.insert(page, at: index + offset) }
        annotationManager.record(.insertPages(count: pages.count, startIndex: index))
        if liveState.currentPageIndex >= index { liveState.currentPageIndex += pages.count }
        pageStructureDidChange(in: doc)
        isDirty = true
    }

    /// [功能点：原生的逆时针旋转当前页 90 度]
    func rotateCurrentPageLeft() {
        guard let doc = pdfView.document, let page = doc.page(at: liveState.currentPageIndex) else { return }
        
        // PDFKit 角度要求为 0, 90, 180, 270 (不能是负数)
        let newRotation = (page.rotation - 90) % 360
        page.rotation = newRotation < 0 ? newRotation + 360 : newRotation
        pdfView.backgroundGeometryDocument = nil
        pdfView.preparePageBackground(for: doc)
        
        // [Bug修复核心] 旋转后，页面的物理宽高比例发生了反转（比如横版变竖版）。
        // 如果不同步更新内存中的 pageAspectRatios，左侧边栏的骨架屏占位框高度就会错乱。
        if pageAspectRatios.indices.contains(liveState.currentPageIndex) {
            pageAspectRatios[liveState.currentPageIndex] = 1.0 / pageAspectRatios[liveState.currentPageIndex]
        }
        
        // 当前页仍是被旋转的页时立即使缓存失效；若推迟到异步回调，
        // 用户已经翻页就会刷新错误的缩略图。此处只排队，不同步绘图。
        thumbnailManager.invalidateThumbnail(at: liveState.currentPageIndex)

        // 下一轮主队列更新原生页面布局。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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
            try AtomicPDFWriter.write(newDoc, to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }
    #endif
}
