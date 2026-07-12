import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import QuickLook

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// [教程注释：主舞台与根视图]
/// 这是每个单独文档窗口的“大管家”，负责搭建左、中、右三个区域的整体骨架 (NavigationSplitView + Inspector)，
/// 并挂载所有的快捷键、菜单事件和跨平台的界面状态协调。
struct ContentView: View {
    // 观察全局统一的快捷键派发中心
    @ObservedObject var shortcutManager = ShortcutManager.shared
    
    // [核心概念：@StateObject]
    // 这是 SwiftUI 中极度重要的数据声明方式。
    // 它告诉系统：“我是这个对象 (AppState) 的主人！请保证在这个 View 存在期间，它不会被销毁”。
    // 这与 @ObservedObject（只是引用别人的对象，生命周期不由自己管）有着本质区别。
    @StateObject var state: AppState
    
    // 同理，生成这个专属窗口自己的界面状态控制器。
    @StateObject var uiState = UIState()
    
    // [教程注释：获取系统环境]
    // 监听当前是白天(Light)还是黑夜(Dark)模式，用于后续底层渲染适配。
    @Environment(\.colorScheme) var colorScheme
    
    // [核心概念：@FocusState]
    // SwiftUI 的革命性焦点管理功能，绑定这个布尔值，当它变成 true 时，对应的 TextField 会瞬间获取光标并（在 iOS 上）弹起键盘。
    @FocusState private var isThumbnailFocused: Bool
    
    // 原生文件选择器是否弹出的标志
    @State private var isImporting = false
    
    // 存放快速翻页输入框里的字符串
    @State private var inputPageText: String = ""
    
    // 打开新窗口的方法注入
    @Environment(\.openWindow) private var openWindow
    
    #if os(macOS)
    // 逆向反向绑定：为了能够在 SwiftUI 里动态改变其宿主原生窗口（NSWindow）的标题栏属性，
    // 我们用一个 @State 把外界真正的指针“钩”进来保存着。
    @State private var hostingWindow: NSWindow?
    #endif
    
    // 监听休眠时间的改变，以便实时对处于后台的标签页生效
    @AppStorage("hibernationTimeoutStr") var hibernationTimeoutStr: String = "20"
    
    /// 初始化函数（根据是否传了 URL 来创建不同的状态引擎）
    init(url: URL? = nil) {
        // [底层逻辑：手动初始化 @StateObject]
        // 正常我们在定义时写 `= AppState()` 就可以了，但是因为我们需要动态传参 (url)，
        // 所以必须使用 _state（也就是包裹着 AppState 的底层 StateObject 结构体）来进行显式赋值。
        _state = StateObject(wrappedValue: AppState(url: url))
    }
    
    init(state: AppState) {
        _state = StateObject(wrappedValue: state)
    }
    
    private func executeIfActive(_ action: @escaping () -> Void) {
        #if os(macOS)
        if hostingWindow?.isKeyWindow == true { action() }
        #else
        action()
        #endif
    }
    
    // MARK: - Core Application View Structure
    
    var body: some View {
        // [UI 布局：三栏架构之神]
        // NavigationSplitView 是苹果在较新的系统中提供的大杀器，专门为取代旧的 NavigationView 设计。
        // 它自带极其完美的左中右抽屉交互，尤其在 iPad 上会自动适配侧滑手势。
        NavigationSplitView(columnVisibility: $uiState.columnVisibility) {
            // [左侧栏]
            LeftSidebarView(state: state, uiState: uiState, isThumbnailFocused: $isThumbnailFocused)
                // 限制左栏宽度拉伸范围
                .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 280)
        } detail: {
            HStack(spacing: 0) {
                // [中间主内容区]
                PDFContainerView
                    .navigationTitle(PlatformUtils.isiOS ? "" : state.fileName)
                    #if os(iOS)
                    // iOS 专用的导航栏排版
                    .toolbar {
                        // [教程注释：ToolbarItemGroup]
                        // 它可以把一堆按钮塞进导航栏的左上角 (navigationBarLeading)。
                        ToolbarItemGroup(placement: .navigationBarLeading) {
                            HStack(spacing: 2) {
                                Button(action: state.goBack) {
                                    Image(systemName: "chevron.left").fontWeight(.bold)
                                }
                                // .disabled() 也是 SwiftUI 非常典型的响应式修饰符。
                                // 当历史记录为空时，后退按钮自动变灰，完全不需要写手动判断逻辑。
                                .disabled(state.navigationHistory.isEmpty)
                                pageNumberInput
                            }
                        }
                    }
                    .toolbar {
                        if uiState.showActionGroup {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                ActionGroupView(state: state, uiState: uiState) {
                                    isImporting = true
                                }
                            }
                        }
                    }
                    .toolbar {
                        if uiState.showAnnotationGroup {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                AnnotationGroupView(state: state, uiState: uiState)
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(action: { state.rotateCurrentPageLeft() }) {
                                Image(systemName: "rotate.left")
                            }
                        }
                    }
                    .toolbar {
                        if uiState.showColorGroup {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                ColorGroupView(state: state, uiState: uiState)
                            }
                        }
                    }
                    .popover(isPresented: $uiState.isShowingToolbarCustomizer) {
                        ToolbarSelectionWindow(uiState: uiState)
                    }
                    #endif
                    #if os(macOS)
                    .modifier(MacToolbarModifier(
                        state: state,
                        uiState: uiState,
                        shortcutManager: shortcutManager,
                        pageNumberInput: AnyView(pageNumberInput)
                    ))
                    #endif
                
                // [右侧边栏]
                // 变通方案：直接放在 HStack 里，这样它的高度自然会受到安全区域（Toolbar 底部）的限制，
                // 分割线绝不会穿透到 Toolbar 上，完美解决重叠问题！
                if uiState.showRightSidebar && !uiState.isSlideshowActive {
                    Divider()
                    RightSidebarView(state: state, uiState: uiState)
                        .frame(width: 250)
                }
            }
        }
        // [核心概念：环境聚焦值传递]
        // 让整个应用里所有的“专注事件” (如菜单栏快捷键) 都能顺利找到我！
        .focusedSceneValue(\.appState, state)
        .focusedSceneValue(\.uiState, uiState)
        
        // 监听外部应用（如文件管家）调用的 "在 App 中打开此文件" 事件。
        .onOpenURL { state.loadPDF(url: $0) }
        .onChange(of: uiState.isSlideshowActive) { _, isActive in
            if isActive {
                state.enterPresentationMode(uiState: uiState)
            } else {
                state.exitPresentationMode(uiState: uiState)
            }
        }
        .popover(isPresented: $uiState.isShowingAnnotationEditor) {
            AnnotationEditorView(state: state, uiState: uiState)
        }

        #if os(macOS)
        // [高级黑科技：窗口状态桥接]
        // WindowAccessor 是一段我们自己封装的原生视图，它可以神不知鬼不觉地爬到树的顶端，
        // 把底层的 NSWindow 拿出来赋给我们的 hostingWindow 变量。
        .background(WindowAccessor(window: $hostingWindow, state: state))
        // 响应底层脏数据状态，让 Mac 窗口标题栏自动出现代表“未保存更改”的黑色圆点
        .onReceive(state.documentManager.$isDirty) { isDirty in
            hostingWindow?.isDocumentEdited = isDirty
        }

        // [逻辑流程：休眠机制的实现]
        // 当窗口获得焦点：立即叫醒应用，取消休眠，让内存重组。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === hostingWindow {
                if state.isHibernating {
                    state.wakeUp()
                } else {
                    state.cancelHibernation()
                }

            }
        }
        // 当窗口失去焦点（用户切去了微信或看网页）：开始倒计时准备内存休眠。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === hostingWindow {
                state.scheduleHibernation()
            }
        }
        // 当窗口马上要关闭：强制给阅读到一半的文章打上“已读”相关的标签记录。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow {
                let isMatch = (window === hostingWindow)
                if isMatch {
                    for doc in state.documents {
                        state.autoTagDocumentIfCompleted(url: doc.url)
                    }
                }
            }
        }
        // 当用户在设置中改变了休眠时间：
        // 只有那些当前不在焦点（后台）的窗口，才需要用新时间重新启动一轮休眠倒计时。
        .onChange(of: hibernationTimeoutStr) { _, _ in
            if let window = hostingWindow, !window.isKeyWindow {
                state.scheduleHibernation()
            }
        }
        #endif
        .onAppear {
            #if os(macOS) 
            // 如果第一次打开没有任何页面，启动自动恢复上次关闭前的窗口记忆系统
            if !AppState.hasAttemptedRestore && state.fileURL == nil {
                AppState.hasAttemptedRestore = true
                AppState.startRestoreChain(openWindow: { url in
                    NSApp.openSwiftUIWindow(for: url)
                })
            }
            #endif
        }
        // Global commands moved to PDFContainerView to reduce compiler complexity
        .onDisappear {
            state.cleanup()
        }
    }

    // MARK: - PDF Viewing Container

    // [教程注释：ViewBuilder]
    // 当你需要在一个函数/属性里面写 if-else 来返回不同的视图时，必须加上 @ViewBuilder 标签。
    // 它允许你在内部像写普通代码一样堆叠组合不同的 UI 块。
    @ViewBuilder
    private var PDFContainerView: some View {
        VStack(spacing: 0) {

            #if os(iOS)
            if !state.documents.isEmpty {
                DocumentTabsView(state: state)
            }
            #endif
            
            // ZStack 会让所有组件像是“洋葱”一样，一层一层地在屏幕 Z 轴上叠起来。
            ZStack {
                if state.fileURL != nil {
                    // 如果有文件，加载真正的 PDF 引擎视图
                    #if os(iOS)
                    PDFKitRepresentable(pdfView: state.pdfView, activeType: $state.activeType, inkColor: state.currentColor, selectedBatchID: state.selectedAnnotation?.userName)
                        .focusable()
                        .focusEffectDisabled()
                        .id(state.pdfViewId) // 绑定唯一ID强制系统刷新
                    #else
                    PDFKitRepresentable(pdfView: state.pdfView, activeType: $state.activeType, inkColor: state.currentColor, selectedBatchID: state.selectedAnnotation?.userName)
                        .focusable()
                        .focusEffectDisabled()
                        .id(state.pdfViewId)
                    #endif
                } else {
                    // 如果没文件，显示高大上的“暂无内容”界面
                    ContentUnavailableView {
                        Label(state.L("No PDF Opened"), systemImage: "doc.text.fill")
                    } description: {
                        Text(PlatformUtils.isiOS ? state.L("iOS Open File Description") : state.L("Open File Description"))
                    } actions: {
                        Button(state.L("Open File")) {
                            #if os(macOS)
                            executeOpenFlow()
                            #else
                            isImporting = true
                            #endif
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                
                // [逻辑流程：假死状态蒙版]
                // 当进入省电/省内存休眠模式时，在最顶层铺设一层黑色的模糊玻璃效果 (UltraThinMaterial)。
                if state.isHibernating {
                    Color.black.opacity(0.4)
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        // 任何对玻璃层的点击操作都会立刻解除休眠！
                        .onTapGesture {
                            state.wakeUp()
                        }
                    
                    VStack(spacing: 16) {
                        Image(systemName: "powersleep")
                            .font(.system(size: 64))
                            .foregroundColor(.white)
                        Text(state.L("Window Hibernating"))
                            .font(.title)
                            .foregroundColor(.white)
                        Text(state.L("Click anywhere to wake up and restore memory"))
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // [核心概念：原生文件选择器]
        // fileImporter 是一种通过系统统一调度来拉起文件管理器的方法（比 UIKit 的那些 delegate 代码简练太多了）。
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): state.loadPDF(url: url)
            case .failure(_): break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerBurnIn"))) { _ in
            #if os(macOS)
            if hostingWindow?.isKeyWindow == true {
                state.documentManager.burnInAnnotations(pdfView: state.pdfView)
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalUndo"))) { _ in executeIfActive { state.undo() } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalRedo"))) { _ in executeIfActive { state.redo() } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalSave"))) { _ in executeIfActive { state.save(immediate: true) } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalHighlight"))) { _ in executeIfActive { state.activeType = .highlight } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalUnderline"))) { _ in executeIfActive { state.activeType = .underline } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalStrikeout"))) { _ in executeIfActive { state.activeType = .strikeout } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalNone"))) { _ in executeIfActive { state.activeType = .none } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalInk"))) { _ in executeIfActive { state.activeType = .ink } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalCompareView"))) { _ in executeIfActive { state.openCompareWindow() } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalPrint"))) { _ in
            #if os(macOS)
            executeIfActive { state.printDocument() }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalPresentation"))) { _ in
            executeIfActive {
                uiState.isSlideshowActive.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GlobalRevealInFinder"))) { _ in executeIfActive { state.revealInFinder() } }
    }

    // 翻页控件输入框独立拆分成一个组件视图，保持主代码的整洁
    private var pageNumberInput: some View {
        HStack(spacing: 2) {
            TextField("", text: $inputPageText)
                // 当用户在这个框里敲回车时触发
                .onSubmit {
                    if let val = Int(inputPageText) {
                        // 数组索引是从0开始的，所以减一。并将其计入历史，以供可以返回
                        state.goToPage(val - 1, recordHistory: true)
                    }
                    inputPageText = String(state.currentPageIndex + 1)
                }
                // 当别人翻页时，文本框里的数字跟着变
                .onChange(of: state.currentPageIndex) { _, newIndex in
                    inputPageText = String(newIndex + 1)
                }
                .onAppear {
                    inputPageText = String(state.currentPageIndex + 1)
                }
                .multilineTextAlignment(.center)
                .frame(width: 32)
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #else
                // 专门给 iOS 单独设计的浅灰色圆角质感输入框，不套用 Mac 的那种硬朗框框。
                .textFieldStyle(.plain)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(6)
                #endif
            
            Text("/\(state.totalPageCount)")
                .font(.system(size: PlatformUtils.isiOS ? 13 : 11))
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .padding(.trailing, 4)
    }

    #if os(macOS)
    /// 触发 macOS 底层的文件打开流
    private func executeOpenFlow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                state.loadPDF(url: url)
            }
        }
    }
    #endif
}

#if os(macOS)
// [终极架构：隔离修饰器]
// 通过将整个庞大的 Toolbar 移入一个独立的 ViewModifier，我们将编译器推断的复杂度瞬间降为了 O(1)！
// 这个技巧是解决 SwiftUI "表达式过于复杂无法在合理时间内完成编译" 终极法宝，同时完美保留原生定制。
struct MacToolbarModifier: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    @ObservedObject var shortcutManager: ShortcutManager
    let pageNumberInput: AnyView
    
    @State private var quickLookURL: URL?
    
    func body(content: Content) -> some View {
        content
            .mainToolbar(state: state, uiState: uiState, pageNumberInput: pageNumberInput)
            // [极其关键的修复] 将 ToolbarItem 中的快捷键提取到后台层，避免在 Customize Toolbar 面板中克隆带有 Shortcut 的按钮引发布局死循环崩溃
            .background(
                Button("") { state.openInBrowser() }
                    .keyboardShortcut(shortcutManager.openInBrowser.keyEquivalent, modifiers: shortcutManager.openInBrowser.modifiers)
                    .disabled(state.fileURL == nil)
                    .opacity(0)
            )
    }
}

// [教程注释：如何将 macOS 底层对象包装给 SwiftUI 使用]
#endif

