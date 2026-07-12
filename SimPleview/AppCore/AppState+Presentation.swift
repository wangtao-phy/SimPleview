import SwiftUI
import PDFKit

/// [教程注释：演示与全屏模式]
extension AppState {
    
    // MARK: - Presentation Mode
    
    /// 进入放映模式 (Slide Show)
    ///
    /// 最合理稳健的实现逻辑：
    /// 1. 不使用 SwiftUI 的 .toolbar(.hidden)，因为它会和 AppKit 原生的全屏机制产生冲突。
    /// 2. 不使用将视图拔出创建新全屏窗口的做法，这会导致 SwiftUI 的约束失效，引发画面缩角。
    /// 3. 我们直接在原生的 Window 上触发 `toggleFullScreen`，并暴力隐藏它的标题栏和工具栏。
    /// 4. 针对标签页（Tab Bar）残留的顽疾，我们采用禁用机制 (`tabbingMode = .disallowed`)，从根本上剥夺窗口显示标签的权利。
    func enterPresentationMode(uiState: UIState) {
        #if os(macOS)
        guard let window = pdfView.window else { return }
        
        // 1. 备份：将当前的侧边栏状态、排版模式等存起来，以便退出时恢复
        uiState.savedColumnVisibility = uiState.columnVisibility
        uiState.savedShowRightSidebar = uiState.showRightSidebar
        self.savedDisplayMode = self.pdfView.displayMode
        
        // 临时关闭自动缩放，防止在变形期间出现闪烁和巨大的性能消耗
        self.pdfView.autoScales = false
        
        // 2. 将左右侧栏全部收起，腾出最大空间给 PDF
        uiState.columnVisibility = .detailOnly
        uiState.showRightSidebar = false
        
        // 使用异步队列，等待侧边栏收起的动画开始后再进行全屏切换，防止动画冲突
        DispatchQueue.main.async { [weak self, weak window, weak uiState] in
            guard let self = self, let win = window else { return }
            
            // 3. 将 PDF 的排版强制切换成“幻灯片排版”：每次只显示完整的一页，并去掉页面之间的灰色背景
            self.pdfView.displayMode = .singlePage
            self.pdfView.displayBox = .cropBox
            self.pdfView.displaysPageBreaks = false
            self.savedBackgroundColor = self.pdfView.backgroundColor
            self.pdfView.backgroundColor = .black
            
            // 4. 暴力隐藏所有原生的 Mac 窗口边框、标题和按钮
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.toolbar?.isVisible = false
            
            // 5. [核心修复：标签栏残留问题]
            // MacOS 默认会在全屏或多窗口时尝试合并标签页，这可能导致顶部出现一条空隙或标签栏。
            // 通过设置 tabbingMode = .disallowed，我们从根源上告诉系统：“这个窗口绝对不允许拥有标签页”。
            if #available(macOS 10.12, *) {
                self.savedTabbingMode = win.tabbingMode
                win.tabbingMode = .disallowed
            }
            
            // 6. 触发系统的全屏动画
            if !win.styleMask.contains(.fullScreen) { win.toggleFullScreen(nil) }
            
            // 7. [黑科技：原生键盘事件拦截]
            // 当系统进入全屏后，我们需要确保用户按下 ESC 时能主动退出放映模式。
            // NSEvent.addLocalMonitorForEvents 可以截获当前 App 所有的键盘敲击。
            if self.eventMonitor == nil {
                self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak uiState] event in
                    // keyCode 53 代表 ESC 键
                    if event.keyCode == 53 { 
                        DispatchQueue.main.async { uiState?.isSlideshowActive = false }
                        return nil // 返回 nil 代表拦截并吃掉这个事件，系统不会再响应该 ESC
                    }
                    return event // 其他按键放行给系统
                }
            }
            
            // 8. 等全屏动画完全结束后（大约0.8秒），重新开启自动缩放，让幻灯片完美填满黑屏
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak uiState] in
                guard let self = self else { return }
                if uiState?.isSlideshowActive == true && self.pdfView.document != nil { 
                    self.pdfView.autoScales = true 
                }
            }
        }
        #endif
    }
    
    /// 退出演示模式
    ///
    /// 核心原则是“原样奉还”。之前藏起来的、修改过的属性，全部逆向恢复。
    func exitPresentationMode(uiState: UIState) {
        #if os(macOS)
        guard let window = pdfView.window else { return }
        
        // 1. 关闭自动缩放，防止退出全屏动画中画面乱飘
        self.pdfView.autoScales = false
        
        // 2. 恢复标签页权限（退出放映后，允许系统重新展示标签栏）
        if #available(macOS 10.12, *) {
            window.tabbingMode = self.savedTabbingMode
        }
        
        // 3. 触发系统的退出全屏动画
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        
        // 4. 等待动画基本完成（全屏动画通常不到 0.5 秒），然后再恢复 UI 细节
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window, weak uiState] in
            guard let self = self, let win = window else { return }
            
            // 恢复 PDF 排版和背景
            self.pdfView.displayMode = self.savedDisplayMode
            self.pdfView.displaysPageBreaks = true
            self.pdfView.backgroundColor = self.savedBackgroundColor
            
            // 恢复 Mac 窗口边框、标题、工具栏
            win.titleVisibility = .visible
            win.titlebarAppearsTransparent = false
            win.toolbar?.isVisible = true
            
            if let uiState = uiState {
                // 恢复之前的左右边栏显示状态
                uiState.columnVisibility = uiState.savedColumnVisibility
                uiState.showRightSidebar = uiState.savedShowRightSidebar
            }
            
            // 5. 撤销键盘监听，防止影响后续系统正常的 ESC 操作
            if let monitor = self.eventMonitor { 
                NSEvent.removeMonitor(monitor)
                self.eventMonitor = nil 
            }
            
            // 6. 最后，再稍等一瞬，重新开启自动缩放
            // （需要等侧边栏动画结束后再缩放，否则布局还没稳定）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                if self.pdfView.document != nil { self.pdfView.autoScales = true }
            }
        }
        #endif
    }
}
