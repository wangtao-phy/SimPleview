import SwiftUI
@preconcurrency import PDFKit
#if os(iOS)
import PencilKit // Apple 专门用来处理 Apple Pencil 绘图的强大底层框架
#endif

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Custom PDF View Subclass

/// 核心定制版 PDF 视图。
///
/// 继承自原生的 `PDFView`。由于原生组件缺乏完善的笔迹交互控制和精细的右键选单拦截能力，
/// 本类通过桥接原生生命周期和钩子方法，实现了以下核心能力：
/// - macOS 平台的高性能非阻塞原生路径实时绘制。
/// - iOS 平台的 `PKCanvasView` 桥接与触控拦截。
/// - "替身批注法" (Ghost Annotation Method) 实现的 O(1) 性能选区边框。
class CustomPDFView: PDFView {
    
    // MARK: - Dependencies & Communication
    
    /// 与 SwiftUI 数据流桥接的核心控制器，负责派发批注变更事件。
    weak var manager: AnnotationManager?
    
    // MARK: - State Tracking
    
    /// 记录用户最后一次右键交互所选中的批注，用于构建关联菜单。
    var lastClickedAnnotation: PDFAnnotation?
    
    /// 记录进入编辑状态前的批注颜色，用于在放弃编辑时执行状态回滚。
    var initialAnnotationColor: PlatformColor?
    
    #if os(iOS)
    // Apple Pencil 专属透明画布，永远盖在 PDF 视图最上面
    var canvasView: PKCanvasView?
    // 原生的画笔工具箱（底部弹出的那个选颜色的转盘）
    var toolPicker: PKToolPicker?
    #endif
    
    #if os(macOS)
    nonisolated(unsafe) var menuObserver: NSObjectProtocol?
    nonisolated(unsafe) var colorObserver: NSKeyValueObservation?
    var currentPopover: NSPopover?
    
    // macOS 原生手绘的实时状态缓存
    var currentDrawingPath: NSBezierPath?
    var currentDrawingPage: PDFPage?
    var currentDrawingBatchID: String?
    
    // 签名缩放交互状态
    var resizingAnnotation: PDFAnnotation?
    var resizeHandleCorner: Int? // 0: TL, 1: TR, 2: BL, 3: BR
    var resizeStartBounds: CGRect = .zero
    var resizeStartMouse: NSPoint = .zero
    
    nonisolated(unsafe) var _threadSafeDrawingPath: NSBezierPath?
    nonisolated(unsafe) var _threadSafeDrawingPage: PDFPage?
    
    // 手绘：缓存连续多笔划，在 commit 时才一次性写入 PDFAnnotation
    var draftInkPaths: [NSBezierPath] = [] {
        didSet { _threadSafeDraftInkPaths = draftInkPaths }
    }
    nonisolated(unsafe) var _threadSafeDraftInkPaths: [NSBezierPath] = []
    var draftInkPage: PDFPage? {
        didSet { _threadSafeDraftInkPage = draftInkPage }
    }
    nonisolated(unsafe) var _threadSafeDraftInkPage: PDFPage?
    
    // [防误触] 用户在画图时，如果不小心按了 Cmd+A，原生 PDFKit 会无视状态直接全选文本。
    // 这会导致画面闪烁或者误触发其他逻辑，我们在这里直接拦截掉！
    override func selectAll(_ sender: Any?) {
        if self.activeType == .ink {
            return // 画图模式下，禁止全选文本
        }
        super.selectAll(sender)
    }
    
    // 支持在草稿阶段（还没 commit）的单笔撤销
    func undoDraftInk() -> Bool {
        guard !draftInkPaths.isEmpty else { return false }
        draftInkPaths.removeLast()
        if draftInkPaths.isEmpty {
            draftInkPage = nil
        }
        self.setPlatformNeedsDisplay()
        return true
    }
    
    deinit {
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
                #if os(macOS)
                self.needsDisplay = true
                #else
                self.updateSelectionBorder()
                #endif
            }
        }
    }
    
    /// 用于后台线程（如缩略图生成器）安全读取的批次标识符快照。
    nonisolated(unsafe) var _threadSafeBatchID: String?
    
    #if os(iOS)
    var allowMenuForCurrentSelection = false
    var currentSelectionBorderAnnotations: [PDFAnnotation] = []
    var editMenuInteraction: UIEditMenuInteraction?
    
    // MARK: - Core Graphics / Rendering Mechanics
    
    /// 刷新当前活跃的选取边框。
    ///
    /// **底层原理：替身批注法**
    /// 在原地生成纯净的 `.square` 批注作为边框，完美贴合任何翻页缩放。
    /// 这种方法完全规避了传统基于 `UIView/NSView` 叠层渲染时因 PDF 缩放引起的坐标系撕裂问题。
    func updateSelectionBorder() {
        // 先清理旧的边框替身
        for annot in currentSelectionBorderAnnotations {
            annot.page?.removeAnnotation(annot)
        }
        currentSelectionBorderAnnotations.removeAll()
        
        // 如果被清空了，就此打住
        guard let batchID = currentSelectedBatchID else { return }
        
        // 【极简优化】：用户点击批注时，批注所在的页必然在屏幕可视范围内。
        // 所以我们只需要遍历 self.visiblePages 即可，彻底避免 O(N) 遍历整个几百页文档引发的卡顿！
        for page in self.visiblePages {
            for annot in page.annotations where annot.userName == batchID {
                let generousBounds = annot.bounds.insetBy(dx: -4, dy: -4)
                let borderAnnot = PDFAnnotation(bounds: generousBounds, forType: .square, withProperties: nil)
                borderAnnot.color = UIColor.systemBlue.withAlphaComponent(0.8)
                // 仅设置边框色
                borderAnnot.interiorColor = .clear
                // 给替身打上绝对不可变、不可存的标签
                borderAnnot.shouldPrint = false
                borderAnnot.isReadOnly = true
                borderAnnot.userName = "SYSTEM_BORDER"
                
                page.addAnnotation(borderAnnot)
                currentSelectionBorderAnnotations.append(borderAnnot)
            }
        }
    }
    #endif
    
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
    nonisolated(unsafe) var _threadSafeInkColor: PlatformColor = .systemBlue
    
    #if os(macOS)
    // [P1优化] 缓存 SF Symbol 图标，避免在高频 draw 方法中每帧重建
    nonisolated(unsafe) var _cachedNoteIcon: NSImage?
    #endif
    
    // 当前状态（是在看书、划线、还是手写？）
    var activeType: AnnotationType = AnnotationType.none {
        willSet {
            #if os(iOS)
            // [核心黑科技：手写烘焙 (Baking)]
            // 如果你退出了手写模式，赶紧把画布上的墨水“烘焙”成 PDF 原生的批注格式！
            if activeType == .ink && newValue != .ink { bakeDrawingToPDF() }
            #elseif os(macOS)
            if activeType == .ink && newValue != .ink { commitDraftInk() }
            #endif
        }
        didSet {
            _threadSafeActiveType = activeType
            #if os(iOS)
            updateHandwritingState()
            #endif
        }
    }
    nonisolated(unsafe) var _threadSafeActiveType: AnnotationType = .none
    
    var lineWidth: CGFloat = 3.0 {
        didSet {
            _threadSafeLineWidth = lineWidth
        }
    }
    nonisolated(unsafe) var _threadSafeLineWidth: CGFloat = 3.0


    
    // [颜色批次同步]
    // 当改变了某一个笔画的颜色时，我们需要顺藤摸瓜，用 batchID 把属于同一个字的所有其他笔画全部染成新颜色！
    func syncBatchColor(for annot: PDFAnnotation) {
        guard let batchID = annot.userName, let doc = document else { return }
        let color = annot.color
        // 【极致 O(1) 优化】相邻页检索
        if let basePage = annot.page {
            let baseIndex = doc.index(for: basePage)
            let start = max(0, baseIndex - 2)
            let end = min(doc.pageCount, baseIndex + 3)
            
            for i in start..<end {
                if let page = doc.page(at: i) {
                    for a in page.annotations where a.userName == batchID && a != annot {
                        a.color = color
                    }
                }
            }
        }
        setPlatformNeedsDisplay() // 命令底层重绘 PDF
    }
    
}



