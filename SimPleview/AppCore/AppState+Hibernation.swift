import Foundation
import PDFKit
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
            // [极致 O(1) 状态保存] 提取精确的物理位置数据，完全避免持有 PDFDestination 导致的对象泄漏
            if let dest = pdfView.currentDestination, let page = dest.page, let doc = pdfView.document {
                let index = doc.index(for: page)
                self.hibernatedPosition = (index, dest.point, dest.zoom)
            }
            
            // [节约模式]：毫不留情，彻底粉碎底层视图，释放几百兆的图形缓存以换取极致内存！
            pdfView.document = nil
            pdfView.removeFromSuperview()
            pdfView = CustomPDFView()
            
            // 由于是新对象，需要重新绑好两根关键的代理线
            pdfView.manager = self.annotationManager
            pdfView.delegate = self
            // [P0修复] 重建所有核心回调，否则唤醒后标注点击/删除/保存等功能全部失效
            setupCallbacks()
            
            // 强制 SwiftUI 扔掉旧壳子
            pdfViewId = UUID()
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
        guard isHibernating, let url = fileURL else { return }
        isHibernating = false
        
        #if os(macOS)
        // [P1修复] 使用保存的原始标题直接恢复，避免 emoji 截断风险
        if let original = originalWindowTitle {
            hostingWindow?.title = original
            originalWindowTitle = nil
        }
        #endif
        
        if !MemoryMode.isPerformance {
            // [节约模式]：由于休眠时已经把视图砸了，现在必须重新读盘加载。
            //底层 loadPDF 会自动检测到 hibernatedPosition 进行 O(1) 级的完美状态恢复
            loadPDF(url: url)
        }
        // [性能模式]：底层视图和缩略图在此期间毫发无损，仅仅是撤掉了黑屏蒙版，瞬间回归，没有任何复杂的重新挂载逻辑，极其稳健！
        
        cancelHibernation()
    }
}
