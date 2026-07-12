import Foundation
import PDFKit
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// [教程注释：极客级内存休眠机制]
/// 这是本 App 引以为傲的核心卖点之一。
/// 背景：PDFKit 渲染的页面在后台会一直缓存着 CoreGraphics 的位图数据，打开几本长 PDF 后，Mac 很容易吃掉好几个 G 的内存。
/// 我们的解决方案是：当这个文档窗口失去焦点达到设定时间后，强行杀死整个引擎，只留一个黑色的占位蒙版；用户点一下，瞬间原样复活！
extension AppState {
    
    // MARK: - Hibernation System
    
    // [逻辑流程：预约休眠]
    // 当检测到窗口被系统挂起到后台（失去焦点）时调用。
    func scheduleHibernation() {
        // 先把之前的计时任务废了，防止计时混乱
        cancelHibernation()
        // 如果已经睡着了，就不管了
        guard !isHibernating else { return }
        
        var timeoutSeconds: Double = 0
        // [性能/自定义/节约模式统一]：从偏好设置里读取用户设定的阈值，默认 20 分钟
        let timeoutStr = UserDefaults.standard.string(forKey: "hibernationTimeoutStr") ?? "20"
        let trimmed = timeoutStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let minutes = Double(trimmed), minutes > 0 {
            timeoutSeconds = minutes * 60.0
        } else {
            return // 从不休眠
        }
        
        // [核心概念：DispatchWorkItem]
        // 它可以把一段闭包代码打包成一个对象。相比直接用 DispatchQueue.async，
        // 它的好处是随时可以调用 `item.cancel()` 来取消这趟班车！
        let item = DispatchWorkItem { [weak self] in
            self?.hibernate()
        }
        
        hibernationWorkItem = item // 存下来，方便等会如果用户回来了，可以 cancel 掉
        
        // 发送倒计时班车
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: item)
    }
    
    // 取消休眠倒计时
    func cancelHibernation() {
        hibernationWorkItem?.cancel()
        hibernationWorkItem = nil
    }
    
    // [逻辑流程：深度休眠降内存]
    func hibernate() {
        // 如果连文件都没打开，睡个啥
        guard let _ = fileURL, !isHibernating else { return }
        
        // 睡觉前，先把用户画到一半的批注存入硬盘！安全第一！
        save(immediate: true)
        
        if MemoryMode.current.policy.allowsHibernation {
            // [极致 O(1) 状态保存]
            if let dest = pdfView.currentDestination, let page = dest.page, let doc = pdfView.document {
                let index = doc.index(for: page)
                self.hibernatedPosition = (index, dest.point, dest.zoom)
            }
            
            // 【稳定性修复】：以前激进地销毁 pdfView 和 document 会触发 PDFKit 底层的 CoreGraphics 字体子集(CGFont)缓存断裂，
            // 导致唤醒后重新加载时 LaTeX 公式中 delta 等符号全部丢失，甚至整个页面白屏。
            // 为了保证绝对的稳定性，我们现在绝对不销毁 PDFDocument 和 PDFView 本身，
            // 而是主动清理所有的外围占用缓存，将 PDFKit 本身的图块回收交还给操作系统的内存压缩器。
            
            MemoryManager.shared.clearCaches()
            thumbnailManager.clearCache()
            
            // [极致节约]：隐式触发机制让 PDFKit 释放不可见图块
            pdfView.clearSelection()
            pdfView.displaysPageBreaks = false // 强制关闭页边距渲染以清空额外图层
            pdfView.layoutDocumentView()       // 强制重新布局，触底释放
            pdfView.displaysPageBreaks = true  // 恢复状态
        }
        // [性能模式]：什么都不做！保留原有的 pdfView 和所有的内存状态，主打用空间换时间！
        
        isHibernating = true
        hibernationWorkItem = nil
        
        // 在窗口标题上加一个睡觉的 Emoji 标识（Zzz...）
        #if os(macOS)
        originalWindowTitle = hostingWindow?.title
        if let title = originalWindowTitle {
            hostingWindow?.title = "💤 " + title
        }
        #endif
    }
    
    // [逻辑流程：唤醒复活]
    func wakeUp() {
        guard isHibernating, fileURL != nil else { return }
        isHibernating = false
        
        #if os(macOS)
        // [P1修复] 使用保存的原始标题直接恢复，避免 emoji 截断风险
        if let original = originalWindowTitle {
            hostingWindow?.title = original
            originalWindowTitle = nil
        }
        #endif
        
        if !MemoryMode.isPerformance {
            // [节约模式]：因为休眠时我们不再销毁底层 PDFDocument 实例，所以完全不需要重新 loadPDF。
            // 只要把蒙版去掉，PDFKit 就会自动请求由于内存压力而被系统清理的渲染图块，这是极其稳健的！
            
            // 为了确切跳回离开时的位置，防止因为清理了缓存导致缩放或者位置偏移，我们可以用 hibernatedPosition
            if let pos = self.hibernatedPosition {
                if let doc = pdfView.document, let page = doc.page(at: pos.pageIndex) {
                    let dest = PDFDestination(page: page, at: pos.point)
                    dest.zoom = pos.zoom
                    self.pdfView.go(to: dest)
                }
                self.hibernatedPosition = nil
            }
        }
        // [性能模式]：底层视图和缩略图在此期间毫发无损，仅仅是撤掉了黑屏蒙版，瞬间回归，没有任何复杂的重新挂载逻辑，极其稳健！
        
        thumbnailManager.hotReloadSubject.send()
        
        cancelHibernation()
    }
}
