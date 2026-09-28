import SwiftUI
import PDFKit
import PencilKit

/// 文字输入持有明确的页面/标注目标；弹窗期间翻页不会把文字写到另一页。
struct AnnotationTextRequest: Identifiable {
    let id = UUID()
    let page: PDFPage
    let annotation: PDFAnnotation?
    let bounds: CGRect
}

@MainActor
final class NotebookSession: ObservableObject {
    let url: URL
    let storage = NotebookStorage(recoveryDirectory: URL.documentsDirectory.appendingPathComponent("恢复的笔记", isDirectory: true))
    @Published private(set) var document: PDFDocument?
    @Published private(set) var revision = 0
    @Published private(set) var savedRevision = 0
    @Published private(set) var isSaving = false
    @Published var error: String?
    @Published var textRequest: AnnotationTextRequest?
    // 弹窗关闭会清空 error；打开失败的页面仍需保留原因和重试入口，不能
    // 因为用户点了“好”就重新显示一个没有任务在执行的加载指示器。
    @Published private(set) var openingFailure: String?
    @Published var pageIndex = 0
    @Published var writing = false
    @Published var adjustingInk = false
    @Published var pageTurning = PageTurning(rawValue: UserDefaults.standard.string(forKey: "padPageTurning") ?? "") ?? .continuous {
        didSet { UserDefaults.standard.set(pageTurning.rawValue, forKey: "padPageTurning") }
    }
    @Published var annotationsVisible = true
    @Published var fingerDrawing = false
    @Published var paper = NotebookPaper.blank
    weak var pdfView: PDFView?
    private(set) var softwareRenderer: SoftwarePageRenderer?
    var isReadOnly: Bool { softwareRenderer != nil }
    var canvas: PKCanvasView?
    @Published var isUsingTool = false
    private(set) var isNotebook = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    lazy var editingUndoManager = NotebookUndoManager(session: self)
    var drawingDidChange: ((PDFPage, PKDrawing) -> Void)?
    // 历史属于文档，而非可能被 PDFKit 回收的画布。闭包接收会话参数，
    // 不捕获会话本身；最多保留 50 次编辑，限制旧笔迹与页面的驻留量。
    private struct Edit {
        let undo: (NotebookSession) -> Void
        let redo: (NotebookSession) -> Void
    }
    private var undoEdits: [Edit] = []
    private var redoEdits: [Edit] = []
    private var drawings: [ObjectIdentifier: PKDrawing] = [:]
    private var version: PadFileVersion?
    private var background: Data?
    private var debounce: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var hasScope = false
    private var isOpening = false
    private var isClosed = false
    var dirty: Bool { revision != savedRevision }

    init(url: URL) { self.url = url }
    deinit {
        debounce?.cancel()
        if hasScope { url.stopAccessingSecurityScopedResource() }
    }

    func open() async {
        guard document == nil, !isOpening, !isClosed, !Task.isCancelled else { return }
        isOpening = true
        openingFailure = nil
        hasScope = url.startAccessingSecurityScopedResource()
        // 打开失败、任务取消或等待期间关闭，都必须释放本次权限租约。
        // 成功后由 close/deinit 接管，重复进入 open 不重复申请权限。
        defer {
            isOpening = false
            if document == nil, hasScope {
                url.stopAccessingSecurityScopedResource()
                hasScope = false
            }
        }
        do {
            // 图形服务异常只切换显示方式，不拒绝读取用户文件。检查有时间上限，
            // 系统编译器卡住时也不会让旧笔记永久停在“正在打开”。
            let nativeRendering = await NativeRenderingCheck.isAvailable()
            try Task.checkCancellation()
            guard !isClosed else { return }
            let (data, version) = try await storage.read(url)
            try Task.checkCancellation()
            guard !isClosed else { return }
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else {
                throw PadError.message("PDF 无法打开、没有页面或需要先解除密码保护。")
            }
            // 只移除本版本持有完整编辑数据的笔迹外观，交给画布显示；
            // 其他软件的批注仍归 PDFKit 所有，不能删掉它们或重复绘制。
            var loadedDrawings: [ObjectIdentifier: PKDrawing] = [:]
            if nativeRendering {
                for index in 0..<pdf.pageCount {
                    try Task.checkCancellation()
                    guard let page = pdf.page(at: index) else { continue }
                    loadedDrawings[ObjectIdentifier(page)] = try VectorInk.takeEditableDrawing(from: page)
                }
            }
            // 记住新建笔记本的纸张，重新打开后追加页面沿用相同底色。
            if let keywords = pdf.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String],
               let savedPaper = NotebookPaper.allCases.first(where: { keywords.contains($0.keyword) }) {
                paper = savedPaper
                isNotebook = true
            }
            drawings = loadedDrawings
            if !nativeRendering {
                // 只读模式保留原有 PDF 笔迹外观，不创建原生手写画布，也不拆掉
                // 标注后再尝试重建。缓存和导出沿用原字节，打开不会写回文件。
                softwareRenderer = SoftwarePageRenderer(data: data)
                background = data
            }
            self.version = version
            document = pdf
            error = nil
        } catch is CancellationError {
            if !isClosed { openingFailure = "打开已取消，请重试。" }
        } catch {
            openingFailure = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    func drawing(for page: PDFPage) -> PKDrawing { drawings[ObjectIdentifier(page)] ?? PKDrawing() }
    func update(_ drawing: PKDrawing, on page: PDFPage) {
        guard !isReadOnly, page.document === document, self.drawing(for: page) != drawing else { return }
        let previous = self.drawing(for: page)
        applyDrawing(drawing, on: page)
        record(undo: { $0.applyDrawing(previous, on: page) }, redo: { $0.applyDrawing(drawing, on: page) })
    }
    private func applyDrawing(_ drawing: PKDrawing, on page: PDFPage) {
        guard page.document === document else { return }
        // 先更新模型再刷新原生画布，delegate 的回调即使晚到也不会重复登记。
        drawings[ObjectIdentifier(page)] = drawing
        drawingDidChange?(page, drawing)
        changed()
    }
    private func record(undo: @escaping (NotebookSession) -> Void, redo: @escaping (NotebookSession) -> Void) {
        undoEdits.append(Edit(undo: undo, redo: redo))
        if undoEdits.count > 50 { undoEdits.removeFirst() }
        redoEdits.removeAll()
        refreshHistory()
    }
    private func refreshHistory() {
        canUndo = !undoEdits.isEmpty; canRedo = !redoEdits.isEmpty
        // PencilKit 工具面板也观察这个公开通知，从同一历史刷新按钮状态。
        NotificationCenter.default.post(name: .NSUndoManagerDidCloseUndoGroup, object: editingUndoManager)
    }
    func undo() {
        guard !isUsingTool, let edit = undoEdits.popLast() else { return }
        edit.undo(self); redoEdits.append(edit); refreshHistory()
    }
    func redo() {
        guard !isUsingTool, let edit = redoEdits.popLast() else { return }
        edit.redo(self); undoEdits.append(edit); refreshHistory()
    }
    func changed(backgroundChanged: Bool = false) {
        guard !isReadOnly else { return }
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
        isClosed = true
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
        guard !isReadOnly, let document else { return }
        do {
            let page = try paper.page(), index = min(pageIndex+1, document.pageCount)
            insert(page, drawing: PKDrawing(), at: index)
        } catch { self.error = error.localizedDescription }
    }
    /// 只延续笔记本末页的矢量底纸。笔迹保存在独立 PKDrawing 中，文字笔记等
    /// PDF 标注也一并清除；因此混用米黄、方格等纸张时仍保持当前页的真实样式。
    func appendBlankPage(after lastPage: PDFPage) {
        guard !isReadOnly, isNotebook, !isClosed, !isUsingTool, let document,
              document.page(at: document.pageCount - 1) === lastPage else { return }
        // 通过独立的单页 PDF 恢复底纸，清理副本标注时不触碰原页。
        // 保留矢量内容，不截图或复制原生笔迹。
        guard let data = lastPage.dataRepresentation,
              let copy = PDFDocument(data: data), let page = copy.page(at: 0) else {
            error = "无法创建空白页面。"
            return
        }
        defer { withExtendedLifetime(copy) {} }
        for annotation in page.annotations { page.removeAnnotation(annotation) }
        let index = document.pageCount
        insert(page, drawing: PKDrawing(), at: index)
    }

    func duplicatePage() {
        guard !isReadOnly, let document, let original = document.page(at: pageIndex), let copy = original.copy() as? PDFPage else { return }
        insert(copy, drawing: drawing(for: original), at: pageIndex + 1)
    }
    func removePage() {
        guard !isReadOnly, let document, document.pageCount > 1, let page = document.page(at: pageIndex) else { return }
        let index = pageIndex, drawing = drawing(for: page)
        setPage(page, drawing: drawing, at: index, present: false)
        record(undo: { $0.setPage(page, drawing: drawing, at: index, present: true) },
               redo: { $0.setPage(page, drawing: drawing, at: index, present: false) })
    }
    func movePage(from: Int, to: Int) {
        guard !isReadOnly, let document, from != to, to >= 0, to < document.pageCount, let page = document.page(at: from) else { return }
        reorder(page, to: to)
        record(undo: { $0.reorder(page, to: from) }, redo: { $0.reorder(page, to: to) })
    }
    private func reorder(_ page: PDFPage, to index: Int) {
        guard let document, page.document === document else { return }
        document.removePage(at: document.index(for: page)); document.insert(page, at: index)
        changed(backgroundChanged: true); go(to: index)
    }
    private func insert(_ page: PDFPage, drawing: PKDrawing, at index: Int) {
        setPage(page, drawing: drawing, at: index, present: true)
        record(undo: { $0.setPage(page, drawing: drawing, at: index, present: false) },
               redo: { $0.setPage(page, drawing: drawing, at: index, present: true) })
    }
    private func setPage(_ page: PDFPage, drawing: PKDrawing, at index: Int, present: Bool) {
        guard let document else { return }
        if present {
            // 恢复页面前先恢复笔迹，PDFKit 创建覆盖视图时便能读到完整内容。
            drawings[ObjectIdentifier(page)] = drawing
            document.insert(page, at: min(index, document.pageCount))
        } else if page.document === document {
            document.removePage(at: document.index(for: page))
            drawings.removeValue(forKey: ObjectIdentifier(page))
        }
        changed(backgroundChanged: true); go(to: min(index, document.pageCount - 1))
    }
    func markSelection(_ type: PDFAnnotationSubtype) {
        guard !isReadOnly else { return }
        guard let selection = pdfView?.currentSelection else { error = "请先在阅读模式长按并选中文字。"; return }
        var added: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
                switch type {
                case .highlight: annotation.color = UIColor.systemYellow.withAlphaComponent(0.35)
                case .underline: annotation.color = .systemBlue
                default: annotation.color = .systemRed
                }
                added.append((page, annotation))
            }
        }
        guard !added.isEmpty else { return }
        setAnnotations(added, present: true)
        record(undo: { $0.setAnnotations(added, present: false) }, redo: { $0.setAnnotations(added, present: true) })
        pdfView?.clearSelection()
    }
    func saveAnnotationText(_ text: String, for request: AnnotationTextRequest) {
        guard !isReadOnly, request.page.document === document else { return }
        if let annotation = request.annotation {
            guard request.page.annotations.contains(where: { $0 === annotation }) else { return }
            guard annotation.contents != text else { return }
            let previous = annotation.contents
            setContents(text, annotation: annotation)
            record(undo: { $0.setContents(previous, annotation: annotation) }, redo: { $0.setContents(text, annotation: annotation) })
        } else {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let bounds = request.page.bounds(for: .cropBox)
            let origin = CGPoint(x: min(max(bounds.minX, request.bounds.minX), bounds.maxX - 28),
                                 y: min(max(bounds.minY, request.bounds.maxY - 28), bounds.maxY - 28))
            let note = PDFAnnotation(bounds: CGRect(origin: origin, size: CGSize(width: 28, height: 28)), forType: .text, withProperties: nil)
            note.contents = text; note.color = .systemYellow
            let added = [(request.page, note)]
            setAnnotations(added, present: true)
            record(undo: { $0.setAnnotations(added, present: false) }, redo: { $0.setAnnotations(added, present: true) })
        }
    }

    private func setContents(_ text: String?, annotation: PDFAnnotation) {
        annotation.contents = text
        changed(backgroundChanged: true)
    }
    private func setAnnotations(_ annotations: [(PDFPage, PDFAnnotation)], present: Bool) {
        for (page, annotation) in annotations where page.document === document {
            if present { page.addAnnotation(annotation) } else { page.removeAnnotation(annotation) }
        }
        changed(backgroundChanged: true)
    }
    func deleteAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard !isReadOnly, page.document === document,
              page.annotations.contains(where: { $0 === annotation }) else { return }
        let removed = [(page, annotation)]
        setAnnotations(removed, present: false)
        record(undo: { $0.setAnnotations(removed, present: true) }, redo: { $0.setAnnotations(removed, present: false) })
    }
}

/// 原生画笔面板与应用按钮共用同一编辑历史。禁止系统重复注册笔迹副本，
/// 但保留标准 UndoManager 接口，供 PencilKit 的撤销按钮和系统手势调用。
@MainActor final class NotebookUndoManager: UndoManager {
    private weak var session: NotebookSession?
    init(session: NotebookSession) {
        self.session = session
        super.init()
        disableUndoRegistration()
    }
    override var canUndo: Bool { session?.canUndo == true && session?.isUsingTool == false }
    override var canRedo: Bool { session?.canRedo == true && session?.isUsingTool == false }
    override func undo() { session?.undo() }
    override func redo() { session?.redo() }
}
