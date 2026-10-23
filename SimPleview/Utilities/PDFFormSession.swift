import AppKit
import PDFKit

/// 只观察当前可见的标准表单字段，不扫描整本 PDF，也不修改字段的只读权限。
/// 原有表单保留 PDFKit 编辑器；识别后生成的字段用 AppKit 输入控件，避免
/// PDFKit 动态字段缓存漏掉首次点击或输入提交。保存仍是标准 Widget/AcroForm。
@MainActor final class PDFFormSession: NSObject, NSTextFieldDelegate {
    private struct Field {
        weak var annotation: PDFAnnotation?
        var value: String?
        var state: PDFWidgetCellState
        var observations: [NSKeyValueObservation]
    }
    private weak var view: CustomPDFView?
    private var fields: [ObjectIdentifier: Field] = [:]
    private var notifications: [NSObjectProtocol] = []
    private struct Hints {
        weak var page: PDFPage?
        let bounds: CGRect
        let rotation: Int
        let candidates: [PDFFormDetection.Candidate]
    }
    private var hints: [ObjectIdentifier: Hints] = [:]
    private var hintOrder: [ObjectIdentifier] = []
    private var requestedPages: [Hints] = []
    private var detectionTask: Task<Void, Never>?
    private var detectionID = UUID()
    private var editor: NSTextField?
    private weak var editingField: PDFAnnotation?
    private(set) var hasPendingText = false

    init(view: CustomPDFView) { self.view = view; super.init() }

    var isEditing: Bool {
        guard let editor = view?.window?.firstResponder as? NSTextView else { return false }
        return owns(editor)
    }

    private func owns(_ object: AnyObject) -> Bool {
        guard let view else { return false }
        if let child = object as? NSView, child.isDescendant(of: view) { return true }
        // AppKit 可复用窗口级 field editor；其 delegate 才是实际所属的控件。
        if let editor = object as? NSTextView, let control = editor.delegate as? NSView {
            return control.isDescendant(of: view)
        }
        return false
    }

    func refresh(pages: [PDFPage]) {
        flushChanges()
        positionEditor()
        var trackedPages = pages
        if let page = editingField?.page, !trackedPages.contains(where: { $0 === page }) { trackedPages.append(page) }
        // 用户可以保持字段焦点并滚动。额外观察编辑器所在的一页，直到它提交；
        // 不能因这一页滚出可见范围而漏掉最后的字段值或缩略图更新。
        if let view, let editor = view.window?.firstResponder as? NSTextView, owns(editor) {
            let control = (editor.isFieldEditor ? editor.delegate as? NSView : nil) ?? editor
            let point = view.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), from: control)
            if let page = view.page(for: point, nearest: false), !trackedPages.contains(where: { $0 === page }) {
                trackedPages.append(page)
            }
        }
        let annotations = trackedPages.flatMap(\.annotations).filter { $0.type == "Widget" }
        let identities = Set(annotations.map(ObjectIdentifier.init))
        fields = fields.filter { identities.contains($0.key) }
        for annotation in annotations {
            let id = ObjectIdentifier(annotation)
            guard fields[id] == nil else { continue }
            // KVO 不保证回调线程。后台通知只传身份，主线程通知同步登记，
            // 保证 Cmd+S 的保存判断不会早于字段值的提交。
            let changed: @Sendable () -> Void = { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.fieldChanged(id) }
                } else {
                    Task { @MainActor [weak self] in self?.fieldChanged(id) }
                }
            }
            let value = annotation.observe(\.widgetStringValue) { _, _ in changed() }
            let state = annotation.observe(\.buttonWidgetState) { _, _ in changed() }
            fields[id] = Field(annotation: annotation, value: annotation.widgetStringValue,
                state: annotation.buttonWidgetState, observations: [value, state])
        }
        if fields.isEmpty {
            if !isEditing && !hasPendingText { stopObserving() }
            return
        }
        guard notifications.isEmpty else { return }
        for name in [NSText.didChangeNotification, NSText.didEndEditingNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let object = notification.object as? NSView
                MainActor.assumeIsolated {
                    guard let self, let object, self.owns(object) else { return }
                    if name == NSText.didChangeNotification {
                        self.hasPendingText = true
                        self.view?.onSaveRequired?()
                    } else if self.hasPendingText {
                        self.hasPendingText = false
                        self.flushChanges()
                        self.view?.onSaveRequired?() // 输入结束后重新安排自动保存，不抢走输入焦点。
                    }
                }
            }
            notifications.append(token)
        }
    }

    private func fieldChanged(_ id: ObjectIdentifier) {
        guard var field = fields[id], let annotation = field.annotation, let view,
              let page = annotation.page, let document = view.document, page.document === document else { return }
        let value = annotation.widgetStringValue, state = annotation.buttonWidgetState
        guard field.value != value || field.state != state else { return }
        field.value = value
        field.state = state
        fields[id] = field
        view.onSaveRequired?()
        view.onAnnotationPagesChanged?([document.index(for: page)])
        view.invalidatePageContent(page)
    }

    private func flushChanges() {
        for id in Array(fields.keys) { fieldChanged(id) }
    }

    /// 显式保存/打印/退出前结束所属字段编辑。验证若拒绝提交，保留编辑器和文档。
    @discardableResult func commit() -> Bool {
        updateEditorValue()
        if isEditing, let view, let window = view.window, !window.makeFirstResponder(view) { return false }
        finishEditor()
        flushChanges()
        hasPendingText = false
        return true
    }

    private func stopObserving() {
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        fields.removeAll()
        hasPendingText = false
    }

    func reset() {
        finishEditor()
        stopObserving()
        cancelDetection()
        hints.removeAll()
        hintOrder.removeAll()
    }

    /// 切换工具立即取消未完成的分析；几何缓存只含小量矩形和弱页面引用。
    func cancelDetection() {
        detectionID = UUID()
        detectionTask?.cancel()
        detectionTask = nil
        requestedPages.removeAll()
    }

    /// 可见页变化合并到一次后台任务。捕获单页值后交给独立 PDFDocument 分析，
    /// 不在滚动/绘图回调中遍历正文，也不跨执行器传递活动 PDFKit 对象。
    func prepare(pages: [PDFPage]) {
        guard let view, view.isFormFilling, let document = view.document,
              !document.isEncrypted, document.allowsCommenting else { return }
        requestedPages = pages.prefix(16).map {
            Hints(page: $0, bounds: $0.bounds(for: .cropBox), rotation: $0.rotation, candidates: [])
        }
        guard detectionTask == nil, requestedPages.contains(where: { item in
            item.page.map { cachedHints(on: $0) == nil } ?? false
        }) else { return }
        let id = detectionID
        detectionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            while let self, self.detectionID == id, let view = self.view, view.isFormFilling,
                  let page = self.requestedPages.compactMap(\.page).first(where: { self.cachedHints(on: $0) == nil }),
                  let document = view.document, page.document === document {
                let bounds = page.bounds(for: .cropBox), rotation = page.rotation
                var candidates: [PDFFormDetection.Candidate] = []
                if let input = PDFFormDetection.capture(page, source: view.scanCache.source) {
                    let worker = Task.detached(priority: .utility) { PDFFormDetection.candidates(input: input) }
                    candidates = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                }
                guard !Task.isCancelled, self.detectionID == id, view.isFormFilling,
                      view.document === document, page.document === document,
                      page.bounds(for: .cropBox) == bounds, page.rotation == rotation else { break }
                let key = ObjectIdentifier(page)
                self.hints[key] = Hints(page: page, bounds: bounds, rotation: rotation, candidates: candidates)
                self.hintOrder.removeAll { $0 == key }
                self.hintOrder.append(key)
                if self.hintOrder.count > 32 { self.hints.removeValue(forKey: self.hintOrder.removeFirst()) }
                view.setPlatformNeedsDisplay()
                view.invalidatePageContent(page)
            }
            if let self, self.detectionID == id { self.detectionTask = nil }
        }
    }

    private func cachedHints(on page: PDFPage) -> [PDFFormDetection.Candidate]? {
        guard let cached = hints[ObjectIdentifier(page)], cached.page === page,
              cached.bounds == page.bounds(for: .cropBox), cached.rotation == page.rotation else { return nil }
        return cached.candidates
    }

    func candidateBounds(on page: PDFPage) -> [CGRect] {
        availableCandidates(on: page).map(\.bounds)
    }

    private func availableCandidates(on page: PDFPage) -> [PDFFormDetection.Candidate] {
        let widgets = page.annotations.filter { $0.type == "Widget" }
        return (cachedHints(on: page) ?? []).filter { candidate in
            guard candidate.text != nil else { return false } // 无法确认旧内容时保留原件。
            // 已填过的旧提示保留原生外观，不能叠加另一个字段造成文字重影。
            if candidate.legacyIndex != nil && candidate.text != "" { return false }
            let area = candidate.bounds.width * candidate.bounds.height
            return !widgets.contains {
                let overlap = candidate.bounds.intersection($0.bounds)
                return !overlap.isNull && overlap.width * overlap.height >= area * 0.5
            }
        }
    }

    /// 只在真正点击填空处时创建标准字段；打开模式和识别本身不改文档。
    /// 保留原来的 Apple 空提示与元数据，新 Widget 位于其上，撤销也不会丢原件。
    @discardableResult func activateField(at point: CGPoint) -> Bool {
        guard let view, view.activeType == .none, let document = view.document,
              !document.isLocked, document.allowsFormFieldEntry,
              let page = view.page(for: point, nearest: false), page.document === document,
              page.displaysAnnotations else { return false }
        let local = view.convert(point, to: page)
        if let field = page.annotations.reversed().first(where: {
            $0.type == "Widget" && $0.widgetFieldType == .text &&
                $0.fieldName?.hasPrefix("SimPleview.Form.") == true && $0.bounds.contains(local)
        }), !field.isReadOnly {
            if editingField === field, editor != nil { return false } // 原控件处理光标定位。
            guard commit() else { return true }
            beginEditing(field)
            return true
        }
        guard commit() else { return true }
        guard view.isFormFilling, !document.isEncrypted, document.allowsCommenting,
              let candidate = availableCandidates(on: page).first(where: { $0.bounds.contains(local) }) else { return false }
        if candidate.legacyIndex != nil {
            guard page.annotations.contains(where: {
                $0.type == "FreeText" && $0.isFormFieldPresentation && $0.bounds == candidate.bounds &&
                ($0.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { return false }
        }
        let field = PDFAnnotation(bounds: candidate.bounds, forType: .widget, withProperties: nil)
        // 表单历史直接使用唯一字段名；Widget 不支持普通批注的 userName。
        let batchID = "SimPleview.Form." + UUID().uuidString
        field.widgetFieldType = .text
        field.fieldName = batchID
        field.widgetStringValue = candidate.text ?? ""
        field.font = .systemFont(ofSize: candidate.fontSize)
        field.fontColor = .black
        field.backgroundColor = .clear
        field.color = .clear
        let border = PDFBorder(); border.lineWidth = 0; field.border = border
        field.shouldDisplay = true
        field.shouldPrint = true
        page.addAnnotation(field)
        // 同步原生显示/点击缓存，但不把新字段的输入交给尚未稳定的内部编辑器。
        view.annotationsChanged(on: page)
        refresh(pages: view.visiblePages + [page])
        let index = document.index(for: page)
        view.manager?.record(.annotation(batchID: batchID, pageIndices: [index]))
        view.onAnnotationPagesChanged?([index])
        view.onSaveRequired?()
        view.setPlatformNeedsDisplay()
        view.invalidatePageContent(page)
        beginEditing(field)
        return true
    }

    private func beginEditing(_ field: PDFAnnotation) {
        guard let view, let window = view.window else { return }
        view.resetLinkPreview()
        let control = NSTextField()
        control.stringValue = field.widgetStringValue ?? ""
        control.isBordered = false
        control.drawsBackground = true
        control.backgroundColor = .textBackgroundColor
        control.textColor = .textColor
        control.focusRingType = .exterior
        control.maximumNumberOfLines = 1
        control.cell?.isScrollable = true
        control.delegate = self
        editor = control
        editingField = field
        // PDFKit 可以重建 documentView 内的页面子视图。编辑控件挂在本视图，
        // 用公开坐标转换跟随页面，避免重绘时被内部视图管理移除。
        view.addSubview(control)
        positionEditor()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(control)
    }

    private func positionEditor() {
        guard let view, let editor, let root = editor.superview, let field = editingField,
              let page = field.page, page.document === view.document else { return }
        editor.frame = root.convert(view.convert(field.bounds, from: page), from: view).insetBy(dx: -2, dy: -2)
        editor.font = .systemFont(ofSize: (field.font?.pointSize ?? 12) * view.scaleFactor)
        editor.isHidden = !view.visibleRect.intersects(view.convert(field.bounds, from: page))
    }

    func ownsEditorPoint(_ point: CGPoint) -> Bool {
        guard let view, let editor, !editor.isHidden, let root = editor.superview else { return false }
        return editor.frame.contains(root.convert(point, from: view))
    }

    private func updateEditorValue() {
        guard let view, let field = editingField, field.page?.document === view.document,
              let editor, field.widgetStringValue != editor.stringValue else { return }
        field.widgetStringValue = editor.stringValue
        fieldChanged(ObjectIdentifier(field))
    }

    private func finishEditor() {
        editor?.delegate = nil
        editor?.removeFromSuperview()
        editor = nil
        editingField = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === editor else { return }
        hasPendingText = true
        updateEditorValue()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === editor else { return }
        updateEditorValue()
        finishEditor()
        hasPendingText = false
        view?.onSaveRequired?()
    }

    isolated deinit {
        detectionTask?.cancel()
        for token in notifications { NotificationCenter.default.removeObserver(token) }
    }
}
