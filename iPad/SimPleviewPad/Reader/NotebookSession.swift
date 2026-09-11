import SwiftUI
import PDFKit
import PencilKit

@MainActor
final class NotebookSession: ObservableObject {
    let url: URL
    let storage = NotebookStorage(recoveryDirectory: URL.documentsDirectory.appendingPathComponent("恢复的笔记", isDirectory: true))
    @Published private(set) var document: PDFDocument?
    @Published private(set) var revision = 0
    @Published private(set) var savedRevision = 0
    @Published private(set) var isSaving = false
    @Published var error: String?
    @Published var pageIndex = 0
    @Published var writing = false
    @Published var annotationsVisible = true
    @Published var fingerDrawing = false
    @Published var paper = NotebookPaper.blank
    weak var pdfView: PDFView?
    var canvas: PKCanvasView?
    var isUsingTool = false
    private var drawings: [ObjectIdentifier: PKDrawing] = [:]
    private var version: PadFileVersion?
    private var background: Data?
    private var debounce: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var hasScope = false
    var dirty: Bool { revision != savedRevision }

    init(url: URL) { self.url = url }
    deinit {
        debounce?.cancel()
        if hasScope { url.stopAccessingSecurityScopedResource() }
    }

    func open() async {
        guard document == nil else { return }
        hasScope = url.startAccessingSecurityScopedResource()
        do {
            let (data, version) = try await storage.read(url)
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else {
                throw PadError.message("PDF 无法打开、没有页面或需要先解除密码保护。")
            }
            // 只移除本版本持有完整编辑数据的笔迹外观，交给画布显示；
            // 其他软件的批注仍归 PDFKit 所有，不能删掉它们或重复绘制。
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                drawings[ObjectIdentifier(page)] = try VectorInk.takeEditableDrawing(from: page)
            }
            self.version = version
            document = pdf
        } catch { self.error = error.localizedDescription }
    }

    func drawing(for page: PDFPage) -> PKDrawing { drawings[ObjectIdentifier(page)] ?? PKDrawing() }
    func update(_ drawing: PKDrawing, on page: PDFPage) {
        guard page.document === document else { return }
        drawings[ObjectIdentifier(page)] = drawing
        changed()
    }
    func changed(backgroundChanged: Bool = false) {
        if backgroundChanged { background = nil }
        revision += 1
        if !isUsingTool { scheduleSave() }
    }
    func scheduleSave() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !self.isUsingTool else { return }
            _ = await self.save()
        }
    }

    func snapshot() throws -> PadSaveSnapshot {
        guard let document else { throw PadError.message("文档尚未打开。") }
        if background == nil { background = document.dataRepresentation() }
        guard let background else { throw PadError.message("无法读取 PDF 页面数据。") }
        var byPage: [Int: PKDrawing] = [:]
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { byPage[index] = drawing(for: page) }
        }
        return PadSaveSnapshot(background: background, drawings: byPage)
    }

    /// 关闭与自动保存共用一个任务。保存期间仍可书写；成功只确认该次快照的版本。
    @discardableResult func save() async -> Bool {
        if let task = saveTask {
            return await task.value
        }
        guard dirty else { return true }
        guard let version else { return false }
        do {
            let snapshot = try snapshot(), savingRevision = revision
            isSaving = true
            let task = Task { [self] in
                do {
                    let newVersion = try await storage.save(snapshot, to: url, expected: version)
                    self.version = newVersion
                    savedRevision = savingRevision
                    error = nil
                    return true
                } catch { self.error = error.localizedDescription; return false }
            }
            saveTask = task
            let ok = await task.value
            saveTask = nil; isSaving = false
            if ok && dirty { scheduleSave() }
            return ok
        } catch { self.error = error.localizedDescription; return false }
    }

    func close() async -> Bool {
        debounce?.cancel(); debounce = nil
        while dirty {
            guard await save() else { return false }
            await Task.yield()
        }
        if hasScope { url.stopAccessingSecurityScopedResource(); hasScope = false }
        return true
    }

    /// 界面使用从 1 开始的页码，PDFKit 使用从 0 开始的索引。
    /// 先检查范围再减一，拒绝空白、非整数、越界及超出 Int 的输入。
    func pageIndex(forPageNumber text: String) -> Int? {
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let count = document?.pageCount, number >= 1, number <= count else { return nil }
        return number - 1
    }

    func go(to index: Int) {
        guard let document, let page = document.page(at: index) else { return }
        pageIndex = index; pdfView?.go(to: page)
    }
    func insertPage() {
        guard let document else { return }
        do {
            let page = try paper.page(), index = min(pageIndex+1, document.pageCount)
            document.insert(page, at: index); changed(backgroundChanged: true); go(to: index)
        } catch { self.error = error.localizedDescription }
    }
    func duplicatePage() {
        guard let document, let original = document.page(at: pageIndex), let copy = original.copy() as? PDFPage else { return }
        document.insert(copy, at: pageIndex+1)
        drawings[ObjectIdentifier(copy)] = drawing(for: original)
        changed(backgroundChanged: true); go(to: pageIndex+1)
    }
    func removePage() {
        guard let document, document.pageCount > 1, let page = document.page(at: pageIndex) else { return }
        drawings.removeValue(forKey: ObjectIdentifier(page))
        document.removePage(at: pageIndex)
        changed(backgroundChanged: true); go(to: min(pageIndex, document.pageCount-1))
    }
    func movePage(from: Int, to: Int) {
        guard let document, from != to, to >= 0, to < document.pageCount, let page = document.page(at: from) else { return }
        document.removePage(at: from); document.insert(page, at: to)
        changed(backgroundChanged: true); go(to: to)
    }
    func markSelection(_ type: PDFAnnotationSubtype) {
        guard let selection = pdfView?.currentSelection else { error = "请先在阅读模式长按并选中文字。"; return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
                annotation.color = type == .highlight ? UIColor.systemYellow.withAlphaComponent(0.35) : .systemRed
                page.addAnnotation(annotation)
            }
        }
        pdfView?.clearSelection(); changed(backgroundChanged: true)
    }
    func addNote(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = document?.page(at: pageIndex) else { return }
        let bounds = page.bounds(for: .cropBox)
        let note = PDFAnnotation(bounds: CGRect(x: bounds.minX+24, y: bounds.maxY-54, width: 28, height: 28), forType: .text, withProperties: nil)
        note.contents = text; note.color = .systemYellow
        page.addAnnotation(note); changed(backgroundChanged: true)
    }
}
