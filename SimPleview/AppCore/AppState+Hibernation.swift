import Foundation
import PDFKit
import Combine
import AppKit

/// 休眠暂停本窗口的后台工作，保留文档、阅读位置和已完成的缩略图。
/// 大幅正文缓存可重新生成；其他窗口的缓存不受本窗口休眠影响。
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
        if !trimmed.isEmpty, let minutes = Double(trimmed), minutes.isFinite, minutes > 0 {
            timeoutSeconds = min(minutes, 7 * 24 * 60) * 60.0
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
        // 图片的休眠仅清缓存，保留修改，不自动弹出另存为。
        if let url = fileURL, !ImageDocumentManager.isImageFile(url: url), hasUnsavedChanges {
            guard save(sync: true) else { return }
        }
        
        thumbnailManager.suspend()
        if MemoryMode.current.policy.allowsHibernation {
            // 不改变页间距、不强制重排，也不清理其他窗口。保留缩略图以便立即返回。
            pdfView.scanCache.suspend()
        }

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
        
        // 页面实例和位置均未改变，唤醒只恢复工作，不重新加载或淘汰有效图像。
        thumbnailManager.resume()
        pdfView.scanCache.resume()
        pdfView.scheduleRenderSnapshot()

        cancelHibernation()
    }
}
