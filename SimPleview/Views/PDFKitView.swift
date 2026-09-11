import SwiftUI
@preconcurrency import PDFKit

import AppKit
import os

// MARK: - Custom PDF View Subclass

/// 核心定制版 PDF 视图。
///
/// 继承自原生的 `PDFView`。由于原生组件缺乏完善的笔迹交互控制和精细的右键选单拦截能力，
/// 本类通过桥接原生生命周期和钩子方法，实现了以下核心能力：
/// - macOS 平台的高性能非阻塞原生路径实时绘制。
/// - "替身批注法" (Ghost Annotation Method) 实现的 O(1) 性能选区边框。
class CustomPDFView: PDFView {
    nonisolated let renderSnapshot = OSAllocatedUnfairLock(initialState: PDFRenderSnapshot())
    nonisolated let scanCache = ScanPageCache()
    // 不重写 document：PDFKit 的后台页面分析会通过 ObjC 读取该属性。
    // Swift 的 MainActor getter 会使原生后台调用触发线程断言；缓存由
    // prepareForDocumentReplacement、视图移除和内存压力入口负责清理。
    var isPublishingRenderSnapshot = false
    nonisolated(unsafe) var renderObserver: NSObjectProtocol?

    /// 只改变 PDFPage 的绘图开关，不写入批注 /F，也不移除批注。
    /// PDFKit 序列化不会保存此页面开关，因此隐藏时保存/打印仍包含标注。
    var annotationsVisible = true

    func setAnnotationsVisible(_ visible: Bool) {
        annotationsVisible = visible
        if !visible {
            currentSelectedBatchID = nil
            lastClickedAnnotation = nil
            cleanupMenuObservers()
        }
        if let document {
            for index in 0..<document.pageCount { document.page(at: index)?.displaysAnnotations = visible }
        }
        layoutDocumentView()
        setPlatformNeedsDisplay()
        documentView?.needsDisplay = true
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { publishRenderSnapshot() } }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        publishRenderSnapshot()
        super.setNeedsDisplay(invalidRect)
    }

    override func layout() {
        super.layout()
        publishRenderSnapshot()
    }

    
    // MARK: - Dependencies & Communication
    
    /// 与 SwiftUI 数据流桥接的核心控制器，负责派发批注变更事件。
    weak var manager: AnnotationManager?
    
    // MARK: - State Tracking
    
    /// 记录用户最后一次右键交互所选中的批注，用于构建关联菜单。
    var lastClickedAnnotation: PDFAnnotation?
    
    /// 记录进入编辑状态前的批注颜色，用于在放弃编辑时执行状态回滚。
    var initialAnnotationColor: PlatformColor?
    
    #if os(macOS)
    nonisolated(unsafe) var menuObserver: NSObjectProtocol?
    nonisolated(unsafe) var colorObserver: NSKeyValueObservation?
    var currentPopover: NSPopover?
    
    // Link Hover Preview State
    var trackingArea: NSTrackingArea?
    var hoverTask: Task<Void, Never>?
    var hoverPopover: NSPopover?
    var currentHoveredLink: PDFAnnotation?
    var _threadSafeHoveredLinkBounds: CGRect?
    var _threadSafeHoveredLinkPage: PDFPage?
    
    // macOS 原生手绘的实时状态缓存
    var currentDrawingPath: NSBezierPath?
    var currentDrawingPage: PDFPage?
    var currentDrawingBatchID: String?
    
    // 签名缩放交互状态
    var resizingAnnotation: PDFAnnotation?
    var resizeHandleCorner: Int? // 0: TL, 1: TR, 2: BL, 3: BR
    var resizeStartBounds: CGRect = .zero
    var resizeStartMouse: NSPoint = .zero
    
    var _threadSafeDrawingPath: NSBezierPath?
    var _threadSafeDrawingPage: PDFPage?
    
    // 手绘：缓存连续多笔划，在 commit 时才一次性写入 PDFAnnotation
    var draftInkPaths: [NSBezierPath] = [] {
        didSet { _threadSafeDraftInkPaths = draftInkPaths }
    }
    var _threadSafeDraftInkPaths: [NSBezierPath] = []
    var draftInkPage: PDFPage? {
        didSet { _threadSafeDraftInkPage = draftInkPage }
    }
    var _threadSafeDraftInkPage: PDFPage?
    
    // [防误触] 用户在画图时，如果不小心按了 Cmd+A，原生 PDFKit 会无视状态直接全选文本。
    // 这会导致画面闪烁或者误触发其他逻辑，我们在这里直接拦截掉！
    override func selectAll(_ sender: Any?) {
        if self.activeType == .ink {
            return // 画图模式下，禁止全选文本
        }
        super.selectAll(sender)
    }
    
    /// 仅在用户确认放弃修改、旧文档即将被替换时调用。避免草稿仍引用旧 PDFPage。
    func discardDraftInk() {
        draftInkPaths = []
        draftInkPage = nil
        currentDrawingPath = nil
        currentDrawingPage = nil
        currentDrawingBatchID = nil
        _threadSafeDrawingPath = nil
        _threadSafeDrawingPage = nil
    }

    /// 文件替换和关闭共用的引用释放点。弹窗、悬停和拖动状态都可能拥有旧页；
    /// 先关观察者/弹窗，再清状态，避免重载后回调修改已不属于当前文档的批注。
    func prepareForDocumentReplacement() {
        scanCache.removeAll()
        cleanupMenuObservers()
        discardDraftInk()
        lastClickedAnnotation = nil
        initialAnnotationColor = nil
        currentHoveredLink = nil
        _threadSafeHoveredLinkBounds = nil
        _threadSafeHoveredLinkPage = nil
        resizingAnnotation = nil
        resizeHandleCorner = nil
        currentSelectedBatchID = nil
        clearSelection()
        highlightedSelections = nil
        renderSnapshot.withLock { $0 = PDFRenderSnapshot() }
    }

    // 支持在草稿阶段（还没 commit）的单笔撤销
    func undoDraftInk() -> Bool {
        guard !draftInkPaths.isEmpty else { return false }
        draftInkPaths.removeLast()
        onSaveRequired?() // 撤销已自动保存的草稿，也要把删除结果同步写盘。
        if draftInkPaths.isEmpty {
            draftInkPage = nil
        }
        self.setPlatformNeedsDisplay()
        return true
    }
    
    deinit {
        if let renderObserver { NotificationCenter.default.removeObserver(renderObserver) }
        if let obs = menuObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        colorObserver?.invalidate()
    }
    #endif
    
    // MARK: - Cross-Platform Properties
    
    /// 当前选中的批注的全局批次标识符。
    /// 当设值发生变更时，自动触发跨平台的重绘逻辑（如 macOS 的 `needsDisplay` 或 iOS 的替身边框刷新）。
    var currentSelectedBatchID: String? {
        didSet {
            _threadSafeBatchID = currentSelectedBatchID
            if currentSelectedBatchID != oldValue {
                self.needsDisplay = true
            }
        }
    }
    
    /// 主执行器内的兼容字段；后台渲染只读取 renderSnapshot，不读取本字段。
    var _threadSafeBatchID: String?
    
    // 给 SwiftUI 外层调用的闭包钩子
    var onAnnotationSelected: ((PDFAnnotation?) -> Void)?
    var onAnnotationDeleted: ((PDFAnnotation) -> Void)?
    var onColorChanged: ((PlatformColor, String) -> Void)?
    var onMouseUp: (() -> Void)?
    var onSaveRequired: (() -> Void)?
    var onAnnotationContentsChanged: ((PDFAnnotation, String) -> Void)?
    
    var inkColor: PlatformColor = .systemBlue {
        didSet {
            _threadSafeInkColor = inkColor
        }
    }
    var _threadSafeInkColor: PlatformColor = .systemBlue
    
    #if os(macOS)
    // [P1优化] 缓存 SF Symbol 图标，避免在高频 draw 方法中每帧重建
    var _cachedNoteCGImage: CGImage?
    var _cachedNoteIconPixels = 0
    var _cachedNoteIconTint: NSColor?
    #endif
    
    // 当前状态（是在看书、划线、还是手写？）
    var activeType: AnnotationType = AnnotationType.none {
        willSet {
            if activeType == .ink && newValue != .ink { commitDraftInk() }
        }
        didSet {
            _threadSafeActiveType = activeType
        }
    }
    var _threadSafeActiveType: AnnotationType = .none
    
    var lineWidth: CGFloat = 3.0 {
        didSet {
            _threadSafeLineWidth = lineWidth
        }
    }
    var _threadSafeLineWidth: CGFloat = 3.0

    // [护眼背景色状态]
    var _threadSafePageBackgroundColor: PDFPageBackgroundColor = .default

    
    // [颜色批次同步]
    // 当改变了某一个笔画的颜色时，我们需要顺藤摸瓜，用 batchID 把属于同一个字的所有其他笔画全部染成新颜色！
    func syncBatchColor(for annot: PDFAnnotation) {
        guard let batchID = annot.userName, let doc = document else { return }
        let color = annot.color
        StandardInk.setColor(color, to: annot)
        // 【极致 O(1) 优化】相邻页检索
        if let basePage = annot.page {
            let baseIndex = doc.index(for: basePage)
            let start = max(0, baseIndex - 2)
            let end = min(doc.pageCount, baseIndex + 3)
            
            for i in start..<end {
                if let page = doc.page(at: i) {
                    for a in page.annotations where a.userName == batchID && a != annot {
                        StandardInk.setColor(color, to: a)
                    }
                }
            }
        }
        onSaveRequired?() // 右键改色也是文档编辑，必须触发保存。
        setPlatformNeedsDisplay() // 命令底层重绘 PDF
    }
    
}
