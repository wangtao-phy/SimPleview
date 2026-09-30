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
        shiftSelectionAnchor = nil
        thumbnailJumpTask?.cancel()
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
        guard pdfView.document != nil else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = PDFDocument(url: url), !source.isLocked, source.pageCount > 0 else { return }
        insertPages(from: source, at: index)
    }

    func insertPages(from source: PDFDocument, at index: Int) {
        guard let doc = pdfView.document, !source.isLocked, source.pageCount > 0 else { return }
        let pages = (0..<source.pageCount).compactMap { source.page(at: $0)?.copy() as? PDFPage }
        guard pages.count == source.pageCount else { return }
        // 粘贴是新的标注副本。批次 ID 必须与原件分开，否则侧栏会把两份
        // 笔迹当成同一组；只重置本应用的 ID，保留外部批注的作者名称。
        var batches: [String: String] = [:]
        for page in pages {
            for annotation in page.annotations {
                if let name = annotation.userName, name.hasPrefix("B-") || name.hasPrefix("S-") {
                    let replacement = batches[name] ?? String(name.prefix(2)) + UUID().uuidString
                    batches[name] = replacement
                    annotation.userName = replacement
                }
                if annotation.value(forAnnotationKey: VectorInk.idKey) != nil {
                    annotation.setValue(UUID().uuidString, forAnnotationKey: VectorInk.idKey)
                }
            }
        }
        let index = max(0, min(index, doc.pageCount))
        for (offset, page) in pages.enumerated() { doc.insert(page, at: index + offset) }
        annotationManager.record(.insertPages(count: pages.count, startIndex: index))
        selectedIndices = Set(index..<(index + pages.count))
        liveState.currentPageIndex = index
        pageStructureDidChange(in: doc, navigateTo: index)
        isDirty = true
    }

    func rotateSelectedPagesLeft() {
        // 工具栏与缩略图右键菜单使用同一批量旋转逻辑；无选中页时才回退到当前页。
        let targets = selectedIndices.isEmpty ? [liveState.currentPageIndex] : selectedIndices
        rotatePages(at: targets, clockwise: false)
    }

    func rotatePages(at indices: Set<Int>, clockwise: Bool) {
        guard let doc = pdfView.document else { return }
        let indices = indices.filter { (0..<doc.pageCount).contains($0) }.sorted()
        guard !indices.isEmpty else { return }
        let pages = indices.compactMap { doc.page(at: $0) }
        guard pages.count == indices.count else { return }
        annotationManager.record(.rotatePages(indices: indices, rotations: pages.map(\.rotation)))
        for page in pages { page.rotation = (page.rotation + (clockwise ? 90 : 270)) % 360 }
        for index in indices { thumbnailManager.invalidateThumbnail(at: index) }
        refreshPageGeometry(in: doc, at: indices)
        isDirty = true
    }

    /// 旋转仅更新几何和对应缩略图，不重建整个侧栏，保留多选和滚动位置。
    func refreshPageGeometry(in doc: PDFDocument, at indices: [Int]) {
        guard pdfView.document === doc else { return }
        pdfView.backgroundGeometryDocument = nil
        pdfView.preparePageBackground(for: doc)
        var ratios = pageAspectRatios
        for index in indices where ratios.indices.contains(index) {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox), rotated = page.rotation % 180 != 0
            let width = rotated ? bounds.height : bounds.width
            let height = rotated ? bounds.width : bounds.height
            if height > 0 { ratios[index] = width / height }
        }
        pageAspectRatios = ratios
        DispatchQueue.main.async { [weak self, weak doc] in
            guard let self, let doc, self.pdfView.document === doc else { return }
            self.pdfView.layoutDocumentView()
            self.pdfView.setPlatformNeedsDisplay()
        }
    }

    #if os(macOS)

    
    func copyPages(at indices: Set<Int>, to pasteboard: NSPasteboard = .general) {
        // 复用经过校验的导出路径，恢复隐藏原生外观，避免复制后丢失矢量手绘。
        guard let url = exportPagesAsPDF(at: indices) else { return }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard let data = try? Data(contentsOf: url) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .pdf)
    }

    func pastePages(after index: Int, from pasteboard: NSPasteboard = .general) {
        guard let data = pasteboard.data(forType: .pdf), let source = PDFDocument(data: data) else { return }
        insertPages(from: source, at: index + 1)
    }

    func acceptPageDrop(_ providers: [NSItemProvider], at index: Int) -> Bool {
        guard pdfView.document != nil,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(ThumbnailPageDrag.type.identifier)
                    || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                    || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
              }) else { return false }
        let revision = documentVersion
        Task { @MainActor [weak self] in
            if provider.hasItemConformingToTypeIdentifier(ThumbnailPageDrag.type.identifier) {
                let data = await Self.dropData(provider, type: ThumbnailPageDrag.type)
                guard let data, let selection = try? JSONDecoder().decode(ThumbnailPageDrag.self, from: data),
                      let self, self.documentVersion == revision else { return }
                if selection.document == revision {
                    self.movePages(from: Set(selection.indices), to: index)
                    return
                }
            }
            // 回调只跨执行器传 Data/URL，PDFDocument 与提供者始终留在主执行器。
            // 等待期间若换文件或增删页面，原插入位置已失效，不再修改文档。
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                let data = await Self.dropData(provider, type: .pdf)
                guard let self, self.documentVersion == revision,
                      let data, let source = PDFDocument(data: data) else { return }
                self.insertPages(from: source, at: index)
            } else {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                guard let self, self.documentVersion == revision,
                      let url, url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
                self.insertPDF(url: url, at: index)
            }
        }
        return true
    }

    private static func dropData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

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
            try? FileManager.default.removeItem(at: tempDir)
            return nil
        }
    }
    #endif
}

/// 拖拽载荷携带文档修订身份，不依靠可能残留的窗口级拖拽状态。
/// 同文档重排只传索引；跨文档才按需生成 PDF。
nonisolated struct ThumbnailPageDrag: Codable, Sendable {
    static let type = UTType(exportedAs: "com.tau.simpleview.pages")
    let document: UUID
    let indices: [Int]
}
