import SwiftUI
import PDFKit

/// [教程注释：演示与全屏模式]
extension AppState {
    
    // MARK: - Presentation Mode
    func enterPresentationMode(uiState: UIState) {
        #if os(macOS)
        guard let window = pdfView.window else { return }
        
        // 1. 备份：把当前的侧边栏状态存到 uiState 里
        uiState.savedColumnVisibility = uiState.columnVisibility
        uiState.savedShowRightSidebar = uiState.showRightSidebar
        self.savedDisplayMode = self.pdfView.displayMode
        
        // 关闭自动缩放，防止在变形期间出现闪烁和巨大的性能消耗
        self.pdfView.autoScales = false
        
        // 2. 将左右侧栏全部收起
        uiState.columnVisibility = .detailOnly
        uiState.showRightSidebar = false
        
        DispatchQueue.main.async { [weak self, weak window, weak uiState] in
            guard let self = self, let win = window else { return }
            // 3. 将 PDF 的排版强制切换成“幻灯片排版”：每次只显示完整的一页
            self.pdfView.displayMode = .singlePage
            // 裁剪掉白边
            self.pdfView.displayBox = .cropBox
            self.pdfView.displaysPageBreaks = false
            self.pdfView.backgroundColor = .black
            
            // 4. 暴力隐藏所有原生的 Mac 窗口边框、标题和按钮
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.toolbar?.isVisible = false
            
            // 5. 触发系统的全屏动画
            if !win.styleMask.contains(.fullScreen) { win.toggleFullScreen(nil) }
            
            // [黑科技：原生键盘事件拦截]
            // 如果用户在全屏下按了 ESC 键（Key Code: 53），我们要主动退出演示！
            // NSEvent.addLocalMonitorForEvents 可以截获当前 App 里所有的键盘敲击。
            if self.eventMonitor == nil {
                self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak uiState] event in
                    if event.keyCode == 53 { DispatchQueue.main.async { uiState?.isSlideshowActive = false }; return nil } // 拦截吃掉这个事件
                    return event // 放行给系统
                }
            }
            
            // 6. 等动画完全结束后（大约0.8秒），重新打开自动缩放让这一页填满整个黑屏
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak uiState] in
                guard let self = self else { return }
                if uiState?.isSlideshowActive == true && self.pdfView.document != nil { self.pdfView.autoScales = true }
            }
        }
        #endif
    }
    
    // 退出演示模式，基本就是把上面所有的动作反向执行一次
    func exitPresentationMode(uiState: UIState) {
        #if os(macOS)
        guard let window = pdfView.window else { return }
        self.pdfView.autoScales = false
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window, weak uiState] in
            guard let self = self, let win = window else { return }
            self.pdfView.displayMode = self.savedDisplayMode
            self.pdfView.displaysPageBreaks = true
            self.pdfView.backgroundColor = .controlBackgroundColor
            win.titleVisibility = .visible
            win.titlebarAppearsTransparent = false
            win.toolbar?.isVisible = true
            if let uiState = uiState {
                // 恢复原来的左右边栏
                uiState.columnVisibility = uiState.savedColumnVisibility
                uiState.showRightSidebar = false
            }
            // 撤销键盘监听，防止影响其他地方输入
            if let monitor = self.eventMonitor { NSEvent.removeMonitor(monitor); self.eventMonitor = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                if self.pdfView.document != nil { self.pdfView.autoScales = true }
            }
        }
        #endif
    }
}
