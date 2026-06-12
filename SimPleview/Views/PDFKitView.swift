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

/// [教程注释：定制版核心 PDF 视图 (CustomPDFView)]
/// PDFKit 原生的 PDFView 有很多限制，比如不能手写、右键菜单里混杂了很多没用的系统选项。
/// 所以我们必须继承它，然后通过各种底层 Hook 技术来“黑”进系统流程，实现我们需要的高级功能。
class CustomPDFView: PDFView {
    
    // [通讯通道]
    weak var manager: AnnotationManager?
    
    // 记住用户刚才右键点的是哪个批注，用来给弹出的菜单传参数
    var lastClickedAnnotation: PDFAnnotation?
    var initialAnnotationColor: PlatformColor?
    
    #if os(iOS)
    // Apple Pencil 专属透明画布，永远盖在 PDF 视图最上面
    var canvasView: PKCanvasView?
    // 原生的画笔工具箱（底部弹出的那个选颜色的转盘）
    var toolPicker: PKToolPicker?
    #endif
    
    #if os(macOS)
    var menuObserver: NSObjectProtocol?
    var colorObserver: NSKeyValueObservation?
    var currentPopover: NSPopover?
    

    #endif
    
    var currentSelectionBorderAnnotations: [PDFAnnotation] = []
    
    // 【新增】：用于判断哪个批注正在被选中，以决定画框或弹窗
    var currentSelectedBatchID: String? {
        didSet {
            if currentSelectedBatchID != oldValue {
                self.updateSelectionBorder()
            }
        }
    }
    
    #if os(iOS)
    var allowMenuForCurrentSelection = false
    var editMenuInteraction: UIEditMenuInteraction?
    #endif
    
    // 【核心重构：替身批注法】
    // 在原地生成纯净的 `.square` 批注作为边框，完美贴合任何翻页缩放。
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
            var lowestAnnotation: PDFAnnotation? = nil
            var minMinY: CGFloat = .greatestFiniteMagnitude
            
            // 第一次遍历：找出最低点（用于 macOS 端便签图标锚定，iOS 虽然暂不使用但也一并找出无妨）
            for annot in page.annotations where annot.userName == batchID {
                let y = annot.bounds.minY
                if y < minMinY {
                    minMinY = y
                    lowestAnnotation = annot
                }
            }
            
            for annot in page.annotations where annot.userName == batchID {
                let generousBounds = annot.bounds.insetBy(dx: -4, dy: -4)
                let borderAnnot = SelectionBorderAnnotation(bounds: generousBounds, forType: .square, withProperties: nil)
                borderAnnot.isLowest = (annot === lowestAnnotation)
                
                page.addAnnotation(borderAnnot)
                currentSelectionBorderAnnotations.append(borderAnnot)
            }
        }
    }
    
    // 给 SwiftUI 外层调用的闭包钩子
    var onAnnotationSelected: ((PDFAnnotation?) -> Void)?
    var onAnnotationDeleted: ((PDFAnnotation) -> Void)?
    var onColorChanged: ((PlatformColor, String) -> Void)?
    var onMouseUp: (() -> Void)?
    var onSaveRequired: (() -> Void)?
    var onAnnotationContentsChanged: ((PDFAnnotation, String) -> Void)?
    
    var inkColor: PlatformColor = .systemBlue
    
    // 当前状态（是在看书、划线、还是手写？）
    var activeType: AnnotationType = AnnotationType.none {
        willSet {
            #if os(iOS)
            // [核心黑科技：手写烘焙 (Baking)]
            // 如果你退出了手写模式，赶紧把画布上的墨水“烘焙”成 PDF 原生的批注格式！
            if activeType == .ink && newValue != .ink { bakeDrawingToPDF() }
            #endif
        }
        didSet {
            #if os(iOS)
            updateHandwritingState()
            #endif
        }
    }


    
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



