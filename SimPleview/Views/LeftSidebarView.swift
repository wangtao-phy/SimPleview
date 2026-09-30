import SwiftUI
import PDFKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// [教程注释：左侧边栏总入口]
/// 这是掌控左侧面板的视图。顶部是一个分段选择器 (Segmented Control)，用于在“缩略图(Thumbnails)”和“大纲(Outline)”之间切换。
struct LeftSidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    // 贯穿整个左边栏的焦点系统，用于支持键盘操作
    @FocusState.Binding var isThumbnailFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // [顶部分段选择器]
            HStack(spacing: 8) {
                #if os(macOS)
                Button(action: { uiState.isShowingTabGroupsPopover.toggle() }) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundColor(.primary)
                }
                .buttonStyle(SidebarIconButtonStyle())
                .popover(isPresented: $uiState.isShowingTabGroupsPopover, arrowEdge: .bottom) {
                    TabGroupsPopoverView()
                }
                #endif
                
                Picker("", selection: $uiState.leftSidebarTab) {
                    Text(state.L("Thumbnails")).tag(0)
                    Text(state.L("Outline")).tag(1)
                }
                .pickerStyle(.segmented)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            Divider()
            
            // [核心内容区]
            switch uiState.leftSidebarTab {
            case 0: ThumbnailListView(state: state, isThumbnailFocused: $isThumbnailFocused)
            case 1: OutlineView(state: state)
            default: EmptyView()
            }
        }
        #if os(macOS)
        // 焦点挂在左侧栏 VStack（普通视图，焦点稳定）而非 ScrollView（NSScrollView 焦点不可靠），
        // 且切 tab 时 VStack 不会被移除，FocusState 不会复位，切回缩略图栏时键盘翻页依然生效。
        .focusable()
        .focused($isThumbnailFocused)
        .focusEffectDisabled()
        #endif
    }
}

// MARK: - Thumbnail List View
/// [教程注释：缩略图列表视图]
/// 负责渲染整个 PDF 文档的一排排小图片。
struct ThumbnailListView: View {
    @ObservedObject var state: AppState
    @FocusState.Binding var isThumbnailFocused: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var visibleIndices: [Int] = []
    @State private var isScrolling = false

    private func updateViewport(_ indices: [Int]) {
        guard let document = state.pdfView.document else { return }
        let identity = ObjectIdentifier(document)
        state.thumbnailManager.updateViewport(indices, in: document, displayScale: displayScale) { [weak state] in
            state?.pdfView.document.map(ObjectIdentifier.init) == identity
        }
    }

    
    #if os(macOS)
    /// 方向键翻页的统一处理。
    ///
    /// 两条分支：
    /// 1. Shift+方向键 → 范围连选：以 `shiftSelectionAnchor` 为锚点，把锚点与目标页之间的区间全部纳入 `selectedIndices`。
    ///    （鼠标和键盘共用锚点，普通选择时更新）
    /// 2. 普通方向键 → 翻页：
    ///    - 性能模式（`delaysNavigationJumps == false`）：立即 `goToPage`，所见即所得。
    ///    - 节约模式：先更新页码/选中态，200ms 防抖后再 `goToPage`，避免按住方向键时高频跨页触发大量内存分配。
    private func navigateThumbnail(to newIndex: Int, isShift: Bool) {
        guard (0..<state.liveState.totalPageCount).contains(newIndex) else { return }
        state.thumbnailJumpTask?.cancel()
        if isShift {
            if state.shiftSelectionAnchor == nil {
                state.shiftSelectionAnchor = state.liveState.currentPageIndex
            }
            state.liveState.currentPageIndex = newIndex
            let anchor = state.shiftSelectionAnchor!
            let range = min(anchor, newIndex)...max(anchor, newIndex)
            state.selectedIndices = Set(range)
        } else {
            state.shiftSelectionAnchor = newIndex
            state.selectedIndices = [newIndex]
            if !MemoryMode.current.policy.delaysNavigationJumps {
                state.goToPage(newIndex)
            } else {
                state.liveState.currentPageIndex = newIndex
                state.selectedIndices = [newIndex]
                state.thumbnailJumpTask?.cancel()
                state.thumbnailJumpTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    state.goToPage(state.liveState.currentPageIndex)
                }
            }
        }
    }
    #endif
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // [性能优化核心：LazyVStack]
                // 绝对不能用普通的 VStack！如果文档有 3000 页，VStack 会一口气把 3000 页的 UI 全部构建出来，瞬间卡死。
                // LazyVStack 就像一条流水线，只渲染当前屏幕上能看到的那几个，滚下去再临时构建。
                LazyVStack(spacing: 0) {
                    ForEach(0..<state.liveState.totalPageCount, id: \.self) { index in
                        VStack(spacing: 0) {
                            // 拖拽插入时显示的那条蓝色的横线（在图片上方）
                            DropInsertLine(index: index, state: state)
                            
                            // 真正的缩略图卡片
                            ThumbnailItem(index: index, state: state, isSelected: state.selectedIndices.contains(index))
                                .equatable() // .equatable() 告诉 SwiftUI：如果不发生实质性变化，不要去重绘它！
                                .onTapGesture {
                                    // 捕获系统修饰键，用于判断是 Command 点击(点选) 还是 Shift 点击(连选)
                                    let isCommand = NSEvent.modifierFlags.contains(.command)
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    state.handleThumbnailClick(index: index, isCommandPressed: isCommand, isShiftPressed: isShift)
                                    isThumbnailFocused = true // 把键盘焦点抢过来
                                }
                        }
                        .id(index)
                    }
                    
                    // 最后一页底部也要加一条插入线，允许把页面拖到整个文档最后面
                    DropInsertLine(index: state.liveState.totalPageCount, state: state)
                }
                .scrollTargetLayout()
                .id(state.documentVersion) // [黑魔法] 强行绑定 UUID。当页面发生大规模新增或删除时，改变 UUID 让整个列表彻底重建
                .padding(.bottom, 10)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { isThumbnailFocused = true }
            }
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { indices in
                visibleIndices = indices
                updateViewport(indices)
            }
            .onChange(of: displayScale) { _, _ in updateViewport(visibleIndices) }
            .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
            .onReceive(state.thumbnailManager.hotReloadSubject) { _ in updateViewport(visibleIndices) }
            .onDisappear { updateViewport([]) }
            #if os(macOS)
            // [修复] 改用 NSEvent 本地监听拦截方向键。原 .onKeyPress 依赖 SwiftUI 焦点 + ScrollView，
            // 在 macOS 上会被内层 NSScrollView 抢先消费方向键导致失效。本地监听在事件派发前拦截，稳定可靠。
            .background(
                ThumbnailKeyMonitorView(
                    isFocused: isThumbnailFocused,
                    onAction: { action in
                        switch action {
                        case .move(let offset, let extend):
                            navigateThumbnail(to: state.liveState.currentPageIndex + offset, isShift: extend)
                        case .boundary(let last, let extend):
                            navigateThumbnail(to: last ? state.liveState.totalPageCount - 1 : 0, isShift: extend)
                        case .selectAll: state.selectAllPages()
                        case .copy: state.copyPages(at: state.selectedIndices)
                        case .paste: state.pastePages(after: state.selectedIndices.max() ?? state.liveState.currentPageIndex)
                        case .delete:
                            if let index = state.selectedIndices.min() { state.deletePage(at: index) }
                        }
                    }
                )
            )
            #endif
            .onChange(of: state.liveState.currentPageIndex) { _, newIndex in
                // 原生列表只在选中页不在视口内时跟随；用户正在滚动侧栏时
                // 不用新的定位动画覆盖其手势，否则会产生追赶和反复加载。
                guard !isScrolling, !visibleIndices.contains(newIndex) else { return }
                proxy.scrollTo(newIndex)
            }
            .onChange(of: state.pageStructureChanged) { _, _ in
                // 插入/删除/重排页后，上下文菜单关闭 + PDFView.go(to:)（异步）可能抢走焦点。
                // 立即重新聚焦会被随后发生的焦点抢占“覆盖”，延迟到这些瞬态事件完成之后再重新聚焦。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isThumbnailFocused = true
                }
            }
            .onAppear {
                // 当用户从“大纲”选项卡切回“缩略图”选项卡时，由于此时的 ScrollView 是全新的，
                // 我们必须在它刚出现的一瞬间，把它拉回当前所处的阅读页码位置，否则它会傻傻地待在最顶部。
                // 这里的 anchor: .center 是安全的，因为视图还没渲染出来，没有视觉跳动！
                proxy.scrollTo(state.liveState.currentPageIndex, anchor: .center)
            }
        }
    }
}

// MARK: - Drag & Drop Indicator
/// [教程注释：拖拽目标插入指示线]
struct DropInsertLine: View {
    let index: Int
    @ObservedObject var state: AppState
    @State private var isOver = false // 记录鼠标拖着东西有没有悬停在我的上面
    
    var body: some View {
        ZStack {
            // 透明度0.001的占位符，用来扩大拖拽判定区域的高度
            Color.black.opacity(0.001)
                .frame(height: 24)
            
            // 当悬停时显示一根蓝色的圆角长条
            Rectangle()
                .fill(isOver ? Color.accentColor : Color.clear)
                .frame(height: 4)
                .cornerRadius(2)
                .padding(.horizontal, 4)
        }
        // 文档内重排、跨窗口拖页和 Finder 的 PDF 文件共用插入位置。
        .onDrop(of: [ThumbnailPageDrag.type, .pdf, .fileURL], isTargeted: $isOver) { providers in
            state.acceptPageDrop(providers, at: index)
        }
    }
}

/// [教程注释：独立图片卡片]
struct ThumbnailItem: View, Equatable {
    let index: Int
    @ObservedObject var state: AppState
    let isSelected: Bool
    
    // 恢复标准的 @State 状态驱动模式
    @State private var thumbnail: PlatformImage?
    @State private var isVisible = false
    
    static func == (lhs: ThumbnailItem, rhs: ThumbnailItem) -> Bool { 
        // 只能比较外界传入的不可变属性。
        lhs.index == rhs.index && lhs.isSelected == rhs.isSelected 
    }
    
    var body: some View {
        // 【稳健性核心】通过静态内存数组直接 O(1) 获取每一页的独立物理比例。
        let ratio = state.pageAspectRatios.indices.contains(index) ? state.pageAspectRatios[index] : (1.0 / 1.414)
        
        VStack(spacing: 6) {
            ZStack {
                if let img = thumbnail ?? state.getThumbnail(for: index) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .contrast(1.15)
                        .scaledToFit()
                        .frame(width: ThumbnailManager.displayWidth)
                } else {
                    // [骨架屏 / Skeleton] 如果图片还没渲染出来，先显示一个空白框
                    Color.primary.opacity(0.03)
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(width: ThumbnailManager.displayWidth)
                }
            }
            .frame(width: ThumbnailManager.displayWidth).background(Color.white).cornerRadius(4)

            .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
            // 选中时的蓝色外加粗框
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            // 底下的页码标
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .padding(.horizontal, 10).contentShape(Rectangle())
        // 接收来自画图线程通过 Combine 发回来的“画好了”信号！
        .onReceive(state.thumbnailUpdateSubject) { payload in 
            if isVisible && payload.0 == index {
                thumbnail = payload.1 
            } 
        }
        .onReceive(state.thumbnailManager.thumbnailInvalidatedSubject) { changedIndex in
            // 保留当前图像直到新版就绪，避免编辑时闪成空白；缓存已经失效，
            // 新请求会准备最新页面。离屏单元不因编辑通知重新占用渲染队列。
            if isVisible && changedIndex == index { state.generateThumbnail(for: index) }
        }
        // 接收热重载的“唤醒”信号！仅当前可见的 ThumbnailItem 会收到此信号，触发自身的精准重绘
        .onReceive(state.thumbnailManager.hotReloadSubject) { _ in
            thumbnail = isVisible ? state.getThumbnail(for: index) : nil
        }
        // LazyVStack 可能保留离屏行及其订阅，通知本身不代表该行可见。
        // 显式可见性门禁阻止热重载/预取通知重新填满离屏强引用。
        .onAppear {
            isVisible = true
            thumbnail = state.getThumbnail(for: index)
        }
        .onDisappear {
            isVisible = false
            // SwiftUI 可保留滚出屏幕的行；释放行级引用才能让全局缓存预算生效。
            thumbnail = nil
        }
        .contextMenu {
            let targets = state.selectedIndices.contains(index) ? state.selectedIndices : [index]
            Button(state.L("Select All Pages")) { state.selectAllPages() }
            Button(state.L("Copy Pages")) { state.copyPages(at: targets) }
            Button(state.L("Paste Pages After")) { state.pastePages(after: targets.max() ?? index) }
                .disabled(NSPasteboard.general.availableType(from: [.pdf]) == nil)
            Divider()
            Button(state.L("Rotate Left")) { state.rotatePages(at: targets, clockwise: false) }
            Button(state.L("Rotate Right")) { state.rotatePages(at: targets, clockwise: true) }
            Divider()
            Button(action: { state.insertBlankPage(at: index + 1) }) {
                Label(state.L("Insert Blank Page After"), systemImage: "plus.rectangle.on.rectangle")
            }
            Divider()
            #if os(macOS)
            Button(state.L("Insert PDF Before...")) { state.promptInsertPDF(at: index) }
            Button(state.L("Insert PDF After...")) { state.promptInsertPDF(at: index + 1) }
            Divider()
            #endif
            Button(state.selectedIndices.count > 1 && state.selectedIndices.contains(index) ? state.L("Delete Selected Pages") : state.L("Delete Page"), role: .destructive) { state.deletePage(at: index) }
                .disabled(targets.count >= state.liveState.totalPageCount)
        }
        // [极客级拖拽：向外部暴露该文件]
        .onDrag {
            // 先确定这一拖拉起了哪些页面
            let targetIndices = state.selectedIndices.contains(index) ? state.selectedIndices : [index]
            
            let selection = ThumbnailPageDrag(document: state.documentVersion, indices: targetIndices.sorted())
            let provider = NSItemProvider() // 系统底层的拖拽物提供者
            
            // 1. 同文档重排只传修订身份和页码，不生成 PDF。
            provider.registerDataRepresentation(forTypeIdentifier: ThumbnailPageDrag.type.identifier, visibility: .all) { completion in
                completion(try? JSONEncoder().encode(selection), nil)
                return nil
            }
            
            // 2. 如果用户真的是想拖到桌面上当做一个独立的新 PDF (关键性能优化：异步生成！)
            provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
                Task {
                    let url = await MainActor.run {
                        state.documentVersion == selection.document ? state.exportPagesAsPDF(at: targetIndices) : nil
                    }
                    completion(url, false, nil)
                }
                return nil
            }
            provider.suggestedName = "dragger"
            
            return provider
        }
    }
}

// MARK: - Custom Button Style for Tab Groups Button
struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
    }
}

#if os(macOS)
// MARK: - 缩略图键盘导航监听 (NSEvent 本地监听)
//
// [为什么不用 .onKeyPress]
// 原 .onKeyPress 依赖 SwiftUI 焦点 + ScrollView。但 ScrollView 内部是一个 NSScrollView，
// 它会在事件派发阶段“抢先消费”上/下方向键（用于原生滚动），导致 .onKeyPress 永远收不到键。
//
// [本方案原理]
// `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 注册的是**应用级**监听器，
// 在事件派发到任何 NSView（包括 NSScrollView）**之前**拦截，因此不依赖 SwiftUI 焦点、
// 也不受 NSScrollView 拦截影响——与右侧搜索栏的 ArrowMonitorNSView 是同一套验证过的机制。
//
// [焦点门控]
// 监听器是应用级的，必须靠 `isFocused`（来自 FocusState `isThumbnailFocused`）过滤：
// 只有当缩略图列表真正获得焦点时才拦截方向键，否则放行给 PDF/搜索框等其它控件。
//
// [键码对照] 126 = Up, 125 = Down, 51 = Backspace(退格), 117 = Forward Delete(删除)
//
// [生命周期]
// `viewDidMoveToWindow` 在视图挂载到窗口时注册监听、移出窗口时注销，避免监听器泄漏。
enum ThumbnailKeyAction: Equatable {
    case move(Int, extend: Bool), boundary(last: Bool, extend: Bool)
    case selectAll, copy, paste, delete

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": self = .selectAll
            case "c": self = .copy
            case "v": self = .paste
            default: return nil
            }
            return
        }
        // 不把 Cmd/Option/Control+方向键或删除键误当成普通页面操作。
        guard modifiers.isEmpty || modifiers == .shift else { return nil }
        let extend = modifiers.contains(.shift)
        switch event.keyCode {
        case 126: self = .move(-1, extend: extend)
        case 125: self = .move(1, extend: extend)
        case 115: self = .boundary(last: false, extend: extend)
        case 119: self = .boundary(last: true, extend: extend)
        case 51 where !extend, 117 where !extend: self = .delete
        default: return nil
        }
    }
}

struct ThumbnailKeyMonitorView: NSViewRepresentable {
    var isFocused: Bool
    var onAction: (ThumbnailKeyAction) -> Void

    func makeNSView(context: Context) -> ThumbnailKeyMonitorNSView {
        let view = ThumbnailKeyMonitorNSView()
        view.isFocused = isFocused
        view.onAction = onAction
        return view
    }
    func updateNSView(_ view: ThumbnailKeyMonitorNSView, context: Context) {
        view.isFocused = isFocused
        view.onAction = onAction
    }
}

final class ThumbnailKeyMonitorNSView: NSView {
    var isFocused = false
    var onAction: ((ThumbnailKeyAction) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }; return self.handle(event)
            }
        } else if window == nil { removeMonitor() }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        // 后台标签可能保留 FocusState；同时检查真实窗口、可见性和第一响应者。
        guard isFocused, let window, event.window === window, window.isKeyWindow,
              !isHiddenOrHasHiddenAncestor else { return event }
        var responder = window.firstResponder as? NSView
        while let view = responder {
            if view is NSTextView || view is NSTextField || view is PDFView { return event }
            responder = view.superview
        }
        guard let action = ThumbnailKeyAction(event: event), let onAction else { return event }
        onAction(action)
        return nil
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
#endif
