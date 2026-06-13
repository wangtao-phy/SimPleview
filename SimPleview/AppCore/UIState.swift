import SwiftUI
import Combine
import PDFKit

/// [教程注释：UI 状态与业务状态的解耦]
/// 为什么不把这些属性放在 AppState 里？
/// 这是一个高级的架构技巧：我们将**纯 UI 的展示状态** (比如侧边栏开没开、选了哪个 Tab)
/// 和**业务核心状态** (打开了哪个文档、在第几页) 彻底分离。
/// 这样做可以让 `UIState` 变得极度轻量，无论 UI 怎么调整、重绘，都不会触发底层沉重 PDF 引擎的不必要刷新。
class UIState: ObservableObject {
    // [核心概念：@Published 属性包装器]
    // 凡是被 @Published 修饰的变量，只要它的值发生改变，
    // 所有依赖(订阅)它的 SwiftUI 视图都会自动并且高效地重新渲染。
    
    /// 左侧栏是否可见 (直接绑定给原生的 NavigationSplitView 使用)
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// 右侧边栏是否可见 (由我们自定义的 Inspector 控制)
    @Published var showRightSidebar: Bool = false
    
    /// 左侧边栏当前选中的标签页 (0: 缩略图, 1: 大纲)
    @Published var leftSidebarTab: Int = 0
    /// 右侧边栏当前选中的标签页 (0: 批注列表, 1: 搜索)
    @Published var rightSidebarTab: Int = 0
    
    /// 是否处于全屏演示模式（幻灯片模式）
    @Published var isSlideshowActive: Bool = false
    
    /// 控制签名浮窗的显示
    @Published var isShowingSignaturePopover: Bool = false
    
    // [教程注释：焦点触发器模式]
    // 在纯 SwiftUI 中控制键盘焦点的转移是一个痛点。
    // 我们用一个永远独一无二的 UUID 变量作为 Trigger。每次你想让搜索框激活，就换一个新 UUID。
    // 视图通过 `.onChange(of: focusSearchTrigger)` 监听到变化后，配合 `@FocusState` 实现唤起键盘。
    @Published var focusSearchTrigger = UUID()
    
    /// 控制是否显示 iPad 样式的手写工具栏面板 / 自定义工具栏
    @Published var isShowingToolbarCustomizer = false
    @Published var isShowingAnnotationEditor = false

    
    // MARK: - Tools Customization (工具栏自定义)
    
    // [核心概念：@AppStorage]
    // 这是 UserDefaults 的 SwiftUI 完美绑定。
    // 只要改变这个变量，它不仅会触发 UI 刷新，还会自动静默写入硬盘。下次打开 App 依然保持这个设定。
    @AppStorage("showAnnotationGroup") var showAnnotationGroup = true
    @AppStorage("showColorGroup") var showColorGroup = true
    @AppStorage("showActionGroup") var showActionGroup = true
    
    // MARK: - Presentation State Cache (演示模式状态缓存)
    /// 用于在进入幻灯片模式前，保存当前的侧边栏状态，以便退出演示时能够精确恢复用户之前的排版。
    var savedColumnVisibility: NavigationSplitViewVisibility = .all
    var savedShowRightSidebar: Bool = false
    
    // [逻辑流程：带动画的状态切换]
    /// 切换左侧边栏的显示/隐藏状态
    /// - Parameter state: 传入 AppState 是因为侧边栏的折叠会改变 PDF 窗口大小。
    /// PDFKit 在动态改变大小时如果不关闭 `autoScales`，会触发极其消耗 CPU 的重绘卡顿。
    func toggleLeftSidebar(state: AppState? = nil) {
        state?.pdfView.autoScales = false
        
        // withAnimation 提供顺滑的过渡动画
        withAnimation(.easeInOut(duration: 0.2)) {
            if columnVisibility == .all {
                columnVisibility = .detailOnly
            } else {
                columnVisibility = .all
            }
        }
        
        // 动画（0.2秒）结束后，再恢复 PDFView 的自动缩放
        if let state = state {
            // [专家级防泄漏] 虽然延迟仅有 0.25 秒，但在复杂的视图卸载场景下，强行保留大体积的 AppState 可能引发短暂的内存峰值或卸载失败。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak state] in
                state?.pdfView.autoScales = true
            }
        }
    }
    
    /// 切换右侧边栏的显示/隐藏状态
    func toggleRightSidebar(state: AppState? = nil) {
        state?.pdfView.autoScales = false
        withAnimation(.easeInOut(duration: 0.2)) {
            showRightSidebar.toggle()
        }
        if let state = state {
            // [专家级防泄漏]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak state] in
                state?.pdfView.autoScales = true
            }
        }
    }
    
    /// 唤起右侧搜索栏，并请求键盘焦点
    func triggerSearchFocus(state: AppState? = nil) {
        state?.pdfView.autoScales = false
        // 使用 DispatchQueue 确保在主线程执行 UI 更新
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                // 如果右侧栏本来就开着，而且就是在搜索 Tab 上，我们就关掉它（相当于 Toggle 操作）
                if self.showRightSidebar && self.rightSidebarTab == 1 {
                    self.showRightSidebar = false
                } else {
                    // 否则，强制切到搜索 Tab (1) 并展开右侧栏
                    self.rightSidebarTab = 1
                    self.showRightSidebar = true
                }
            }
            // 更换 UUID 触发 ContentView 中的 `.onChange` 拦截器
            self.focusSearchTrigger = UUID()
            
            if let state = state {
                // [专家级防泄漏]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak state] in
                    state?.pdfView.autoScales = true
                }
            }
        }
    }
}
