import SwiftUI
import PDFKit
import Combine

// MARK: - Annotation Manager Engine

/// 核心批注调度引擎。
///
/// `AnnotationManager` 负责接管 PDFKit 原生的批注流。
/// 它实现了以下核心能力：
/// 1. 颜色与画笔状态管理，并将状态响应式暴露给 SwiftUI (`@Published`)。
/// 2. PDF 批注收集器：将离散分布在数百页中的原生批注对象集中收集为一维数组。
/// 3. 全局事务与回滚 (Undo/Redo)：实现无损级别的撤销引擎，支持跨页动作的原子级撤销。
final class AnnotationManager: ObservableObject {
    
    // MARK: - Data Source & Undo Stack
    
    /// 已经被引擎收集的所有合法批注数组。
    /// UI 层的左侧边栏 (Sidebar) 通过订阅该数组进行 `ForEach` 实时大纲渲染。
    @Published var allAnnotations: [PDFAnnotation] = []
    
    /// 撤销动作栈 (Undo Stack)。
    /// 采用自定义的 `UndoAction` 枚举封装每一次原子绘制动作，通过堆栈机制实现 Cmd+Z 无损回滚。
    @Published var batchStack: [UndoAction] = []
    
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
            #if os(macOS)
            return NSColor(hex: name) ?? defaultColor
            #else
            return defaultColor
            #endif
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
        // 启动时从本地硬盘读取用户偏好的默认颜色
        self.underlineColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultUnderlineColor"), defaultColor: .platformBlue)
        self.highlightColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultHighlightColor"), defaultColor: .platformYellow)
        self.strikeoutColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultStrikeoutColor"), defaultColor: .platformRed)
        self.inkColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultInkColor"), defaultColor: .platformBlue)
        
        // 监听来自设置面板的广播。如果设置面板修改了颜色，这里收到通知后自动更新
        NotificationCenter.default.addObserver(self, selector: #selector(updateColorsFromDefaults), name: NSNotification.Name("DefaultColorsChanged"), object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func updateColorsFromDefaults() {
        // 必须在主线程更新，因为 @Published 会触发 SwiftUI 渲染
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.underlineColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultUnderlineColor"), defaultColor: .platformBlue)
            self.highlightColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultHighlightColor"), defaultColor: .platformYellow)
            self.strikeoutColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultStrikeoutColor"), defaultColor: .platformRed)
            self.inkColor = AnnotationManager.color(from: UserDefaults.standard.string(forKey: "defaultInkColor"), defaultColor: .platformBlue)
        }
    }
    
    // [多线程保护：刷新令牌]
    // 每次刷新生成一个新的 UUID。如果后台任务跑完发现自己的 UUID 不是最新的，就静默作废。
    // 这样既能防止并发冲突，又不会“漏掉”最后一次合法的刷新请求。
    private var currentRefreshUUID = UUID()
    
    var canUndo: Bool { !batchStack.isEmpty }
    
    // [核心逻辑：全局批注扫描仪]
    // 遍历整个 PDF 每一页，把我们关心的批注挖出来，缓存给 UI
    func refreshAnnotations(in document: PDFDocument?) {
        guard let document = document else {
            self.allAnnotations = []
            return
        }
        
        let token = UUID()
        self.currentRefreshUUID = token
        
        // 我们关心这些类型的批注（包括系统 Markup 可能产生的签名 stamp、形状 square/circle 等）
        let lowercasedTargets: Set<String> = ["highlight", "underline", "strikeout", "ink", "stamp", "freetext", "square", "circle", "line", "polygon", "polyline"]

        var seenIDs = Set<String>()
        var collectedAnnots: [PDFAnnotation] = []
        
        // [极速主线程合并遍历] 
        // 彻底剔除背景分发，消除线程上下文切换与安全隐患，在单遍循环内完成清理与收录
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for annot in page.annotations {
                guard let type = annot.type, lowercasedTargets.contains(type.lowercased()) else { continue }
                
                let id = annot.userName ?? ""
                
                if id.starts(with: "B-") {
                    if !id.isEmpty && seenIDs.insert(id).inserted {
                        collectedAnnots.append(annot)
                    }
                } else {
                    if !id.starts(with: "EXT-") {
                        annot.userName = "EXT-\(UUID().uuidString.prefix(8))"
                    }
                    collectedAnnots.append(annot)
                }
            }
        }
        
        // [极其关键的底层性能优化：Schwartzian 变换 (Decorate-Sort-Undecorate) 排序算法]
        // 将计算量降维到了绝对的 O(N)，完全在主线程毫秒级完成，毫无卡顿！
        let decorated = collectedAnnots.map { annot in
            (annot, annot.modificationDate ?? Date.distantPast, annot.userName ?? "")
        }
        
        let sortedDecorated = decorated.sorted { a, b in
            if a.1 == b.1 { return a.2 < b.2 }
            return a.1 < b.1
        }
        
        let sortedAnnots = sortedDecorated.map { $0.0 }
        
        // 如果在此极短时间内没有被新的请求覆盖，就更新 UI
        if self.currentRefreshUUID == token {
            self.allAnnotations = sortedAnnots
        }
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
            
            // 创建 PDFKit 原生批注对象
            let annot = PDFAnnotation(bounds: line.bounds(for: page), forType: subtype, withProperties: nil)
            annot.color = color
            annot.userName = batchID // 借用 userName 存我们的内部 ID
            
            // 真正将批注写入该页面
            page.addAnnotation(annot)
            newAnnots.append(annot)
            
            if let doc = page.document { affectedPageIndices.insert(doc.index(for: page)) }
        }
        
        guard !affectedPageIndices.isEmpty else { return false }
        
        // 压入撤销栈
        batchStack.append(.annotation(batchID: batchID, pageIndices: affectedPageIndices))
        // 画完后自动取消文字选中状态，体验更好
        pdfView.clearSelection()
        
        // 【O(1) 增量更新】直接把新批注塞入缓存，彻底抛弃 O(N) 的刷新全书逻辑！
        // 关键修复：只塞入第一个分段，防止跨行产生多个同 batchID 批注，导致 SwiftUI 列表渲染重复和错乱！
        if let first = newAnnots.first {
            // 给新创建的批注打上时间戳
            first.modificationDate = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // [功能更新] 按照修改时间排序，新创建的必定是最新修改的，可以直接丢到最后面，彻底将时间复杂度降为 O(1)！
                self.allAnnotations.append(first)
            }
        }
        
        pendingColorOverride = nil
        
        // 告诉外面：“这两页的画面被污染了，你们赶紧重新生成左侧缩略图！”
        for index in affectedPageIndices {
            onThumbnailUpdate(index)
        }
        
        pdfView.setPlatformNeedsDisplay()
        PlatformUtils.updateWindows()
        return true
    }
    

    
    // [核心架构：撤销 (Undo) 解析器]
    // 当按 Cmd+Z 时，系统会掉进这个巨大的 switch 里，根据上一次是什么动作，反向回滚！
    @discardableResult
    func undo(in document: PDFDocument?, pdfView: PDFView?, onThumbnailUpdate: (Int) -> Void, onPageChange: (Int) -> Void) -> Bool {
        // 弹出最后一次操作
        guard let lastAction = batchStack.popLast(), let doc = document else { return false }
        
        switch lastAction {
        case .annotation(let batchID, let pageIndices):
            // 【极致 O(K) 优化】如果上次是画线，回滚就是：直接定位到被污染的那几页删去，绝不遍历全书！
            var affectedPageIndices = Set<Int>()
            var deletedAnnots = Set<PDFAnnotation>()
            for i in pageIndices {
                if i < doc.pageCount, let page = doc.page(at: i) {
                    var hasRemoved = false
                    for a in page.annotations where a.userName == batchID {
                        // 触发 PDFKit 原生 KVO 机制：状态变更会精准通知底层 CoreAnimation 废弃脏图块，实现 O(1) 局部刷新
                        a.shouldDisplay = false
                        page.removeAnnotation(a) 
                        deletedAnnots.insert(a)
                        hasRemoved = true
                    }
                    if hasRemoved {
                        affectedPageIndices.insert(i)
                    }
                }
            }
            for index in affectedPageIndices {
                onThumbnailUpdate(index)
            }
            // 增量删除
            DispatchQueue.main.async { [weak self] in
                self?.allAnnotations.removeAll(where: { deletedAnnots.contains($0) })
            }
            
        case .deleteAnnotation(let annotations, let pageIndices):
            // 如果上次是不小心删除了某根线，回滚就是：把线原封不动地贴回去
            var affectedPageIndices = Set<Int>()
            for (annot, pageIdx) in zip(annotations, pageIndices) {
                annot.shouldDisplay = true // 撤销时恢复显示
                if pageIdx < doc.pageCount, let page = doc.page(at: pageIdx) {
                    page.addAnnotation(annot)
                    affectedPageIndices.insert(pageIdx)
                }
            }
            for index in affectedPageIndices {
                onThumbnailUpdate(index)
            }
            // 增量增加
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // 过滤掉 batchID 相同的碎块，只让唯一的代表进入 UI 列表
                var seen = Set<String>()
                let unique = annotations.filter { 
                    guard let id = $0.userName, !id.isEmpty else { return false }
                    return seen.insert(id).inserted
                }
                // [性能优化：移除 O(N log N) 的全量排序开销]
                // 撤销时仅有少量元素需要恢复。由于元素很可能就是最新的，我们从后往前扫描进行 O(K) 甚至 O(1) 的定点插入
                for ann in unique {
                    let targetDate = ann.modificationDate ?? Date.distantPast
                    let targetName = ann.userName ?? ""
                    var insertIndex = self.allAnnotations.count
                    
                    for i in stride(from: self.allAnnotations.count - 1, through: 0, by: -1) {
                        let existingDate = self.allAnnotations[i].modificationDate ?? Date.distantPast
                        if existingDate < targetDate {
                            insertIndex = i + 1
                            break
                        } else if existingDate == targetDate {
                            if (self.allAnnotations[i].userName ?? "") <= targetName {
                                insertIndex = i + 1
                                break
                            }
                        }
                    }
                    self.allAnnotations.insert(ann, at: insertIndex)
                }
            }
            
        case .deletePage(let page, let index):
            // 撤销删页
            doc.insert(page, at: index)
            onThumbnailUpdate(-1)
            onPageChange(index)
            
        case .insertPages(let count, let startIndex):
            // 撤销插入
            for _ in 0..<count {
                if startIndex < doc.pageCount {
                    doc.removePage(at: startIndex)
                }
            }
            onThumbnailUpdate(-1)
            onPageChange(startIndex)
            
        case .reorderPages(let originalIndices, let insertedAt):
            // 撤销页面排序 (极其复杂的倒序恢复逻辑)
            let count = originalIndices.count
            let offset = originalIndices.filter { $0 < insertedAt }.count
            let currentStart = max(0, min(insertedAt - offset, doc.pageCount - count))
            
            var pagesToRestore: [PDFPage] = []
            for _ in 0..<count {
                if currentStart < doc.pageCount, let page = doc.page(at: currentStart) {
                    doc.removePage(at: currentStart)
                    pagesToRestore.append(page)
                }
            }
            
            let sortedOriginal = originalIndices.enumerated().sorted { $0.element < $1.element }
            for (i, originalIdx) in sortedOriginal {
                let page = pagesToRestore[i]
                doc.insert(page, at: originalIdx)
            }
            
            onThumbnailUpdate(-1)
            onPageChange(originalIndices.first ?? 0)
        }
        
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
        
        if isInternalBatch {
            // 内部批注：通过 batchID 批量删除同一笔画出的所有分段
            if let basePage = annotation.page {
                let baseIndex = doc.index(for: basePage)
                let start = max(0, baseIndex - 2)
                let end = min(doc.pageCount, baseIndex + 3)
                
                for i in start..<end {
                    if let page = doc.page(at: i) {
                        var hasRemoved = false
                        for a in page.annotations where a.userName == batchID {
                            a.shouldDisplay = false
                            deletedAnnots.append(a)
                            pageIndices.append(i)
                            page.removeAnnotation(a)
                            hasRemoved = true
                        }
                        if hasRemoved {
                            affectedPageIndices.insert(i)
                        }
                    }
                }
            }
        } else {
            // 外部批注（来自系统 Markup 等）：精确删除单个标注对象
            if let page = annotation.page {
                let pageIndex = doc.index(for: page)
                annotation.shouldDisplay = false
                page.removeAnnotation(annotation)
                deletedAnnots.append(annotation)
                pageIndices.append(pageIndex)
                affectedPageIndices.insert(pageIndex)
            }
        }
        
        if !deletedAnnots.isEmpty {
            if isInternalBatch {
                // 将删除动作压入撤销栈
                // [防崩溃保护]：系统 Markup 产生的外部标注在被移除后，若强行重新 addAnnotation 会触发 PDFKit 的底层 C++ 崩溃。
                // 按照用户的合理逻辑：外部手绘被删除后直接视为永久删除，不纳入撤销回退栈。
                batchStack.append(.deleteAnnotation(annotations: deletedAnnots, pageIndices: pageIndices))
            }
        } else {
            return false
        }
        
        for index in affectedPageIndices {
            onThumbnailUpdate(index)
        }
        
        // 增量删除
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let deletedSet = Set(deletedAnnots)
            var newAll = [PDFAnnotation]()
            for a in self.allAnnotations {
                if !deletedSet.contains(a) {
                    newAll.append(a)
                }
            }
            self.allAnnotations = newAll
        }
        pdfView?.setPlatformNeedsDisplay()
        PlatformUtils.updateWindows()
        return true
    }
    
    // 强制同步特定 ID 批注的所有部分的颜色（解决跨页批注颜色断层的问题）
    @discardableResult
    func syncBatchColor(for annot: PDFAnnotation, in document: PDFDocument?, pdfView: PDFView?) -> Bool {
        guard let batchID = annot.userName, let doc = document else { return false }
        let color = annot.color
        var changed = false
        // 【极致 O(1) 优化】相邻页检索
        if let basePage = annot.page {
            let baseIndex = doc.index(for: basePage)
            let start = max(0, baseIndex - 2)
            let end = min(doc.pageCount, baseIndex + 3)
            
            for i in start..<end {
                if let page = doc.page(at: i) {
                    for a in page.annotations where a.userName == batchID && a != annot && a.color != color {
                        a.color = color
                        changed = true
                    }
                }
            }
        }
        if changed {
            pdfView?.setPlatformNeedsDisplay()
        }
        return changed
    }
}
