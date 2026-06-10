import SwiftUI
import PDFKit

/// [教程注释：Extension 扩展机制解耦]
/// 随着业务增长，AppState 里的函数会越来越多。
/// 我们可以利用 Swift 强大的 `extension` (扩展) 机制，把特定功能（比如此处的批注处理）分散到单独的文件里。
/// 这能极大提升代码的可读性和多人协作效率！
extension AppState {
    
    // MARK: - Annotation Logic (批注核心控制逻辑)
    
    // [逻辑流程：应用新批注]
    // 当用户圈选了文字并松开鼠标，这个方法就会被触发。
    func applyAnnotation() {
        // [防重入锁机制]
        // PDFKit 引擎比较古老，有时候一次动作会触发两次回调。如果上一次批注还在处理中，我们直接拦截掉第二次，防止死锁。
        guard !isApplyingAnnotation else { return }
        isApplyingAnnotation = true
        
        // 每次产生新批注，这意味着用户做了一次关键的编辑，我们要把当前位置计入“跳转历史”。
        recordHistoryAction() 
        
        // 核心执行：把它交给我们写的 annotationManager。如果它返回 true 表示打标注成功。
        if annotationManager.applyAnnotation(type: activeType, pdfView: pdfView, onThumbnailUpdate: { [weak self] index in
            // [性能优化] 只有当被修改的那一页的缩略图存在时，才去刷新它的缩略图，避免重绘所有左侧缩略图
            self?.thumbnailManager.removeThumbnail(for: index)
            self?.generateThumbnail(for: index)
        }) {
            isDirty = true // 将文档打上“被弄脏(已被编辑，需要保存)”的标记
        }
        isApplyingAnnotation = false
        
        // iOS 沙盒机制不同，没有明显的“退出”或保存动作，我们需要随时帮它落盘。
        #if os(iOS)
        if isDirty { documentManager.saveForiOS(pdfView: pdfView) }
        #endif
    }
    
    func deleteAnnotation(_ annotation: PDFAnnotation) {
        if annotationManager.deleteAnnotation(annotation, in: pdfView.document, pdfView: pdfView, onThumbnailUpdate: { [weak self] index in
            self?.thumbnailManager.removeThumbnail(for: index)
            self?.generateThumbnail(for: index)
        }) {
            isDirty = true
        }
        #if os(iOS)
        if isDirty { documentManager.saveForiOS(pdfView: pdfView) }
        #endif
    }
    
    func deleteSelectedAnnotation() {
        // 如果当前有选中的批注，直接将其删除
        if let current = selectedAnnotation { deleteAnnotation(current) }
    }
    
    func refreshAnnotations() {
        annotationManager.refreshAnnotations(in: pdfView.document)
    }
    
    // MARK: - Utilities (辅助工具)
    
    // [教程注释：倒计时自动回弹]
    // 阅读器的核心痛点：用户用了高亮工具，看完想滑屏时，却不小心在屏幕上画出了一长条。
    // 所以我们做了一个定时器：用户激活标注工具后，如果15秒不操作，自动变回默认的滑动状态 (.none)。
    func resetAnnotationTimer() {
        stopAnnotationTimer()
        guard activeType != AnnotationType.none else { return }
        
        // 从偏好设置 UserDefaults 里读取设定的秒数
        let timeoutStr = UserDefaults.standard.string(forKey: "annotationRevertTimeoutStr") ?? "15"
        let timeout = Double(timeoutStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 15.0
        let finalTimeout = timeout > 0 ? timeout : 15.0
        
        // 创建一次性的并发任务，时间一到就把工具置空。
        annotationTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(finalTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self?.activeType != AnnotationType.none { self?.activeType = AnnotationType.none }
        }
    }
    
    // 销毁并清除任务
    func stopAnnotationTimer() {
        annotationTimerTask?.cancel()
        annotationTimerTask = nil
    }
    
    // [逻辑流程：颜色状态机]
    // 一个极其巧妙的颜色聚合分发器。根据当前选中的是什么工具，返回它专属的颜色记忆。
    var currentColor: PlatformColor {
        get { 
            if let pending = annotationManager.pendingColorOverride { return pending }
            switch activeType { 
            case .highlight: return annotationManager.highlightColor 
            case .underline: return annotationManager.underlineColor 
            case .strikeout: return annotationManager.strikeoutColor 
            case .ink: return annotationManager.inkColor 
            default: return annotationManager.highlightColor 
            } 
        }
        set { 
            annotationManager.pendingColorOverride = newValue
        }
    }
    
    var currentColorName: String {
        let color = currentColor
        if color == .platformBlue { return L("Blue") }
        if color == .platformRed { return L("Red") }
        if color == .platformYellow { return L("Yellow") }
        if color == .platformGreen { return L("Green") }
        if color == .platformPurple { return L("Purple") }
        return L("Color")
    }
    
    // MARK: - PDFViewDelegate (PDF 引擎渲染底层委托)
    // [教程注释：原生选中拦截]
    // [教程注释：接管鼠标碰撞检测]
    // PDF 默认的批注有很多坑（比如高亮一句话其实是由底层好几个小方块拼起来的）。
    // 这个方法可以拦截鼠标点上去的那一刻，我们用批注自带的 `userName` 字段（我们把它魔改成了批次 ID）
    // 把“同一批次”产生的碎块在逻辑上视为一个大批注，选中一个等于全选！
    #if os(macOS)
    func pdfView(_ pdfView: PDFView, willHitAnnotation annotation: PDFAnnotation, withEvent event: NSEvent) -> PDFAnnotation? {
        if let bid = annotation.userName {
            DispatchQueue.main.async { [weak self] in
                if self?.selectedAnnotation?.userName != bid {
                    // 寻找到同一批次最早的那个主批注作为被选中的核心
                    self?.selectedAnnotation = self?.allAnnotations.first { $0.userName == bid } ?? annotation
                }
            }
        }
        return annotation // 返回原批注，让系统走完默认点击流程
    }
    #endif
}
