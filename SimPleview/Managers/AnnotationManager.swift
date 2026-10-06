import SwiftUI
import PDFKit
import Combine

/// 管理标注颜色、侧栏索引和编辑操作；撤销/重做由 AnnotationManager+History 实现。
/// PDFKit 对象与发布状态均在主执行器内访问。
final class AnnotationManager: ObservableObject {
    let batchIndex = AnnotationBatchIndex()
    
    // MARK: - Data Source & Undo Stack
    
    /// 已经被引擎收集的所有合法批注数组。
    /// UI 层的右侧边栏 (Sidebar) 通过订阅该数组进行 `ForEach` 实时大纲渲染。
    @Published private(set) var allAnnotations: [PDFAnnotation] = []
    
    /// 撤销动作栈 (Undo Stack)。
    /// 采用自定义的 `UndoAction` 枚举封装每一次原子绘制动作，通过堆栈机制实现 Cmd+Z 无损回滚。
    @Published private(set) var batchStack: [UndoAction] = []
    
    /// 重做动作栈 (Redo Stack)。
    @Published private(set) var redoStack: [UndoAction] = []
    
    // [颜色管理]
    // 给不同的批注类型设定当前选中的颜色，带有 @Published，一旦修改，UI 上所有使用了这颜色的画笔图标都会跟着变
    @Published var underlineColor: PlatformColor = .platformBlue
    @Published var highlightColor: PlatformColor = .platformYellow
    @Published var strikeoutColor: PlatformColor = .platformRed
    @Published var inkColor: PlatformColor = .platformBlue
    
    // [状态覆盖]
    // 如果用户在颜色面板强行选了一个不在预设里的颜色，暂时存在这里，下一次画画时优先用它
    @Published var pendingColorOverride: PlatformColor? = nil
    
    // 辅助函数：把UserDefaults里存的字符串（比如 "Red" 或 "#FF0000"）转成系统原生颜色
    private static func color(from name: String?, defaultColor: PlatformColor) -> PlatformColor {
        guard let name = name else { return defaultColor }
        if name.hasPrefix("#") {
            return NSColor(hex: name) ?? defaultColor
        }
        switch name {
        case "Blue": return .platformBlue
        case "Red": return .platformRed
        case "Yellow": return .platformYellow
        case "Green": return .platformGreen
        case "Purple": return .platformPurple
        default: return defaultColor
        }
    }
    
    // [初始化与通知监听]
    init() {
        loadDefaultColors()
        
        // 监听来自设置面板的广播。如果设置面板修改了颜色，这里收到通知后自动更新
        NotificationCenter.default.addObserver(self, selector: #selector(updateColorsFromDefaults), name: NSNotification.Name("DefaultColorsChanged"), object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func updateColorsFromDefaults() {
        // 必须在主线程更新，因为 @Published 会触发 SwiftUI 渲染
        DispatchQueue.main.async { [weak self] in
            self?.loadDefaultColors()
        }
    }
    
    private func loadDefaultColors() {
        let defaults = UserDefaults.standard
        underlineColor = Self.color(from: defaults.string(forKey: "defaultUnderlineColor"), defaultColor: .platformBlue)
        highlightColor = Self.color(from: defaults.string(forKey: "defaultHighlightColor"), defaultColor: .platformYellow)
        strikeoutColor = Self.color(from: defaults.string(forKey: "defaultStrikeoutColor"), defaultColor: .platformRed)
        inkColor = Self.color(from: defaults.string(forKey: "defaultInkColor"), defaultColor: .platformBlue)
    }

    /// 新编辑统一清空重做栈；外部调用方只能提交动作，不能直接改历史数组。
    func record(_ action: UndoAction) {
        batchStack.append(action)
        redoStack.removeAll()
        batchIndex.invalidate()
    }

    func clearHistory() {
        batchStack.removeAll()
        redoStack.removeAll()
    }

    func reset() {
        clearHistory()
        allAnnotations.removeAll()
        batchIndex.invalidate()
    }

    /// 仅供历史执行器在动作成功后转移栈顶。
    func finishHistory(isUndo: Bool, inverse: UndoAction) {
        if isUndo { batchStack.removeLast(); redoStack.append(inverse) }
        else { redoStack.removeLast(); batchStack.append(inverse) }
        batchIndex.invalidate()
    }

    func removeFromSidebar(_ annotations: [PDFAnnotation]) {
        let removed = Set(annotations)
        allAnnotations.removeAll { removed.contains($0) }
    }

    /// 已挂入当前文档的标注才可进入侧栏，批次去重与排序都由管理器维护。
    func register(_ annotation: PDFAnnotation, in document: PDFDocument) {
        guard annotation.page?.document === document else { return }
        let id = annotation.userName ?? ""
        guard !allAnnotations.contains(where: {
            $0 === annotation || (id.hasPrefix("B-") && $0.userName == id)
        }) else { return }
        let key = Self.annotationSortKey(annotation)
        let index = allAnnotations.firstIndex { key < Self.annotationSortKey($0) } ?? allAnnotations.endIndex
        allAnnotations.insert(annotation, at: index)
    }

    @discardableResult
    func updateContents(_ text: String, of annotation: PDFAnnotation, in document: PDFDocument) -> Bool {
        guard annotation.page?.document === document else { return false }
        let date = Date()
        for index in batchIndex.pages(for: annotation, in: document) {
            guard let page = document.page(at: index) else { continue }
            for target in page.annotations where target === annotation ||
                ((annotation.userName ?? "").hasPrefix("B-") && target.userName == annotation.userName) {
                target.simPleNote = text
                target.modificationDate = date
            }
        }
        let batchID = annotation.userName
        if let index = allAnnotations.firstIndex(where: {
            $0 === annotation || (batchID?.hasPrefix("B-") == true && $0.userName == batchID)
        }) {
            let representative = allAnnotations.remove(at: index)
            register(representative, in: document)
        }
        return true
    }

    var canUndo: Bool { !batchStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    
    // [核心逻辑：全局批注扫描仪]
    // 遍历整个 PDF 每一页，把我们关心的批注挖出来，缓存给 UI
    func refreshAnnotations(in document: PDFDocument?) {
        guard let document = document else {
            batchIndex.invalidate()
            self.allAnnotations = []
            return
        }
        
        // 我们关心这些类型的批注（包括系统 Markup 可能产生的签名 stamp、形状 square/circle 等）
        let lowercasedTargets: Set<String> = ["highlight", "underline", "strikeout", "ink", "stamp", "freetext", "square", "circle", "line", "polygon", "polyline"]

        var seenIDs = Set<String>()
        var collectedAnnots: [PDFAnnotation] = []
        
        // 全量扫描只用于打开、重载等需要重建索引的场合；编辑采用增量更新。
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for annot in page.annotations {
                guard let type = annot.type, lowercasedTargets.contains(type.lowercased()) else { continue }
                // [防污染] 跳过搜索闪烁的临时批注，避免其进入侧边栏列表
                if (annot.userName ?? "") == "SEARCH_FLASH" { continue }
                
                let id = annot.userName ?? ""
                
                if id.starts(with: "B-") {
                    if !id.isEmpty && seenIDs.insert(id).inserted {
                        collectedAnnots.append(annot)
                    }
                } else if id.starts(with: "S-") {
                    // 保留签名批注的 ID，千万不能覆盖！
                    // [彻底根除模糊位图]：强制让签名的 shouldDisplay = false，完全隐藏 PDFKit 的低清光栅化位图渲染，仅由我们自定义的渲染引擎在屏幕上高清绘制矢量路径
                    annot.shouldDisplay = false
                    collectedAnnots.append(annot)
                } else {
                    if !id.starts(with: "EXT-") {
                        annot.userName = "EXT-\(UUID().uuidString.prefix(8))"
                    }
                    collectedAnnots.append(annot)
                }
            }
        }
        
        batchIndex.rebuild(in: document)
        // PDFKit 和侧栏数组由主执行器持有；扫描没有挂起点，不需要刷新令牌。
        // 按修改时间及标识排序，撤销恢复也使用相同规则。
        // 先提取排序键，避免 O(n log n) 次比较反复读取 PDFKit 属性。
        let keyed = collectedAnnots.map { ($0, Self.annotationSortKey($0)) }
        allAnnotations = keyed.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    static func annotationSortKey(_ annotation: PDFAnnotation) -> (Date, String) {
        (annotation.modificationDate ?? .distantPast, annotation.userName ?? "")
    }

    // [核心逻辑：绘制批注]
    // 根据用户的鼠标选区 (Selection)，往 PDF 页面上绘制高亮、下划线等。
    @discardableResult
    func applyAnnotation(type: AnnotationType, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void) -> Bool {
        // 防呆设计：如果没选类型，或者没选中任何文字，直接失败返回
        guard type != AnnotationType.none, let pdfView = pdfView, let selection = pdfView.currentSelection, let selectionString = selection.string, !selectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        
        // 生成一个包含当前时间的唯一批次 ID
        let batchID = "B-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
        
        // 根据传入的类型，提取正确的颜色和 PDF底层对应的类型常量
        let (color, subtype): (PlatformColor, PDFAnnotationSubtype) = {
            let baseColor: PlatformColor = {
                switch type {
                case .highlight: return highlightColor
                case .underline: return underlineColor
                case .strikeout: return strikeoutColor
                default: return .platformClear
                }
            }()
            let activeColor = pendingColorOverride ?? baseColor
            
            switch type {
            case .highlight: return (activeColor, .highlight)
            case .underline: return (activeColor, .underline)
            case .strikeout: return (activeColor, .strikeOut)
            default: return (.platformClear, .highlight)
            }
        }()
        
        var affectedPageIndices = Set<Int>()
        var newAnnots: [PDFAnnotation] = []
        
        // [坑点注意：跨页选区]
        // 用户可能从上一页拉到了下一页。PDFKit 是按页管理坐标的，所以必须按照行 (Line) 把选区分割开！
        selection.selectionsByLine().forEach { line in
            guard let page = line.pages.first else { return }
            
            let annot = PDFAnnotation(bounds: line.bounds(for: page), forType: subtype, withProperties: nil)
            annot.color = color
            annot.userName = batchID // 借用 userName 存我们的内部 ID
            
            let border = PDFBorder()
            border.lineWidth = AnnotationDefaults.lineWidth()
            annot.border = border
            
            // 真正将批注写入该页面
            page.addAnnotation(annot)
            newAnnots.append(annot)
            
            if let doc = page.document { affectedPageIndices.insert(doc.index(for: page)) }
        }
        
        guard !affectedPageIndices.isEmpty else { return false }
        
        // 压入撤销栈
        record(.annotation(batchID: batchID, pageIndices: affectedPageIndices))
        // 画完后自动取消文字选中状态，体验更好
        pdfView.clearSelection()
        
        // 增量添加当前批次的侧栏代表，无需重新扫描整本文档。
        // 关键修复：只塞入第一个分段，防止跨行产生多个同 batchID 批注，导致 SwiftUI 列表渲染重复和错乱！
        if let first = newAnnots.first {
            // 给新创建的批注打上时间戳
            first.modificationDate = Date()
            // 与页面修改同步发布，避免关闭或换文档后迟到的回调回填旧标注。
            if let document = pdfView.document { register(first, in: document) }
        }
        
        pendingColorOverride = nil
        
        // 告诉外面：“这两页的画面被污染了，你们赶紧重新生成左侧缩略图！”
        for index in affectedPageIndices {
            onThumbnailUpdate(index)
        }
        
        // PDFKit 已将新标注挂到对应页面；补充局部重绘即可。
        // 不强制刷新整个视口及所有窗口，避免旧矢量标注一起闪动。
        for annotation in newAnnots {
            guard let page = annotation.page else { continue }
            pdfView.setNeedsDisplay(pdfView.convert(annotation.bounds, from: page).insetBy(dx: -10, dy: -10))
        }
        return true
    }
    
    // [功能点：应用签名标注]
    func applySignature(annotation: PDFAnnotation, to page: PDFPage, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void) -> Bool {
        guard let doc = page.document else { return false }
        let pageIndex = doc.index(for: page)
        
        let batchID = "S-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
        annotation.userName = batchID
        annotation.modificationDate = Date()
        
        page.addAnnotation(annotation)
        
        // 压入撤销栈，以便 Cmd+Z 时能和普通标注一样被正常拔除
        record(.annotation(batchID: batchID, pageIndices: [pageIndex]))
        
        register(annotation, in: doc)
        
        onThumbnailUpdate(pageIndex)
        pdfView?.setPlatformNeedsDisplay()
        PlatformUtils.updateWindows()
        return true
    }
    

    
    // 手动删除某条批注
    @discardableResult
    func deleteAnnotation(_ annotation: PDFAnnotation, in document: PDFDocument?, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void) -> Bool {
        guard let doc = document else { return false }
        
        let batchID = annotation.userName ?? ""
        let isInternalBatch = batchID.starts(with: "B-")
        
        var deletedAnnots: [PDFAnnotation] = []
        var pageIndices: [Int] = []
        var affectedPageIndices = Set<Int>()
        
        guard annotation.page?.document === doc else { return false }
        for index in batchIndex.pages(for: annotation, in: doc).sorted() {
            guard let page = doc.page(at: index) else { continue }
            let targets = isInternalBatch ? page.annotations.filter { $0.userName == batchID } : [annotation]
            for target in targets {
                deletedAnnots.append(target)
                pageIndices.append(index)
                page.removeAnnotation(target)
            }
            if !targets.isEmpty { affectedPageIndices.insert(index) }
        }
        batchIndex.invalidate()

        if !deletedAnnots.isEmpty {
            if isInternalBatch {
                // 将删除动作压入撤销栈
                // [防崩溃保护]：系统 Markup 产生的外部标注在被移除后，若强行重新 addAnnotation 会触发 PDFKit 的底层 C++ 崩溃。
                // 按照用户的合理逻辑：外部手绘被删除后直接视为永久删除，不纳入撤销回退栈。
                record(.deleteAnnotation(annotations: deletedAnnots, pageIndices: pageIndices))
            }
        } else {
            return false
        }
        
        for index in affectedPageIndices {
            onThumbnailUpdate(index)
        }
        
        let deletedSet = Set(deletedAnnots)
        allAnnotations.removeAll { deletedSet.contains($0) }
        pdfView?.setPlatformNeedsDisplay()
        PlatformUtils.updateWindows()
        return true
    }
    
    /// 返回实际涉及的页码，供调用方只刷新相关缩略图。
    @discardableResult
    func syncBatchColor(for annotation: PDFAnnotation, in document: PDFDocument?, pdfView: PDFView?) -> Set<Int> {
        guard let document, annotation.page?.document === document else { return [] }
        let indices = batchIndex.pages(for: annotation, in: document)
        let color = StandardInk.displayColor(of: annotation)
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            for target in page.annotations where target === annotation ||
                ((annotation.userName ?? "").hasPrefix("B-") && target.userName == annotation.userName) {
                if StandardInk.displayColor(of: target) != color { StandardInk.setColor(color, to: target) }
            }
        }
        pdfView?.setPlatformNeedsDisplay()
        return indices
    }
}
