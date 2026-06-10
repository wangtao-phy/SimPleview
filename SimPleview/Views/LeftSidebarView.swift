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
            Picker("", selection: $uiState.leftSidebarTab) {
                Text(state.L("Thumbnails")).tag(0)
                Text(state.L("Outline")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            
            Divider()
            
            // [核心内容区]
            switch uiState.leftSidebarTab {
            case 0: ThumbnailListView(state: state, isThumbnailFocused: $isThumbnailFocused)
            case 1: OutlineView(state: state)
            default: EmptyView()
            }
        }
        #if os(iOS)
        // 在 iOS 的原生 NavigationSplitView 中，如果不加这句，它会自带一个难以控制的展开/收起按钮
        .toolbar(removing: .sidebarToggle)
        #endif
    }
}

// MARK: - Thumbnail List View
/// [教程注释：缩略图列表视图]
/// 负责渲染整个 PDF 文档的一排排小图片。
struct ThumbnailListView: View {
    @ObservedObject var state: AppState
    @FocusState.Binding var isThumbnailFocused: Bool
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // [性能优化核心：LazyVStack]
                // 绝对不能用普通的 VStack！如果文档有 3000 页，VStack 会一口气把 3000 页的 UI 全部构建出来，瞬间卡死。
                // LazyVStack 就像一条流水线，只渲染当前屏幕上能看到的那几个，滚下去再临时构建。
                LazyVStack(spacing: 0) {
                    ForEach(0..<state.totalPageCount, id: \.self) { index in
                        VStack(spacing: 0) {
                            // 拖拽插入时显示的那条蓝色的横线（在图片上方）
                            DropInsertLine(index: index, state: state)
                            
                            // 真正的缩略图卡片
                            ThumbnailItem(index: index, state: state, isSelected: state.selectedIndices.contains(index))
                                .equatable() // .equatable() 告诉 SwiftUI：如果不发生实质性变化，不要去重绘它！
                                .id(index) // 给滚动定位器打的标记
                                .onTapGesture {
                                    #if os(macOS)
                                    // 捕获系统修饰键，用于判断是 Command 点击(点选) 还是 Shift 点击(连选)
                                    let isCommand = NSEvent.modifierFlags.contains(.command)
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    state.handleThumbnailClick(index: index, isCommandPressed: isCommand, isShiftPressed: isShift)
                                    state.shiftSelectionAnchor = nil // 鼠标点击后重置键盘连选锚点
                                    #else
                                    state.goToPage(index)
                                    #endif
                                    isThumbnailFocused = true // 把键盘焦点抢过来
                                }
                        }
                    }
                    
                    // 最后一页底部也要加一条插入线，允许把页面拖到整个文档最后面
                    DropInsertLine(index: state.totalPageCount, state: state)
                }
                .id(state.documentVersion) // [黑魔法] 强行绑定 UUID。当页面发生大规模新增或删除时，改变 UUID 让整个列表彻底重建
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { isThumbnailFocused = true }
            }
            #if os(macOS)
            .focusable() // 让它能接盘键盘按键
            .focused($isThumbnailFocused)
            .focusEffectDisabled() // 取消原生的蓝色对焦框，因为我们在内部做了红色的描边
            .onKeyPress { keyPress in
                let isShift = keyPress.modifiers.contains(.shift)
                
                if keyPress.key == .upArrow {
                    let newIndex = state.currentPageIndex - 1
                    guard newIndex >= 0 else { return .handled }
                    
                    if isShift {
                        if state.shiftSelectionAnchor == nil {
                            state.shiftSelectionAnchor = state.currentPageIndex
                        }
                        state.currentPageIndex = newIndex
                        let anchor = state.shiftSelectionAnchor!
                        let range = min(anchor, newIndex)...max(anchor, newIndex)
                        state.selectedIndices = Set(range)
                    } else {
                        state.shiftSelectionAnchor = nil
                        if !MemoryMode.current.policy.delaysNavigationJumps {
                            state.goToPage(newIndex)
                        } else {
                            state.currentPageIndex = newIndex
                            state.selectedIndices = [newIndex]
                            state.thumbnailJumpTask?.cancel()
                            state.thumbnailJumpTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled else { return }
                                state.goToPage(state.currentPageIndex)
                            }
                        }
                    }
                    return .handled
                } else if keyPress.key == .downArrow {
                    let newIndex = state.currentPageIndex + 1
                    guard newIndex < state.totalPageCount else { return .handled }
                    
                    if isShift {
                        if state.shiftSelectionAnchor == nil {
                            state.shiftSelectionAnchor = state.currentPageIndex
                        }
                        state.currentPageIndex = newIndex
                        let anchor = state.shiftSelectionAnchor!
                        let range = min(anchor, newIndex)...max(anchor, newIndex)
                        state.selectedIndices = Set(range)
                    } else {
                        state.shiftSelectionAnchor = nil
                        if !MemoryMode.current.policy.delaysNavigationJumps {
                            state.goToPage(newIndex)
                        } else {
                            state.currentPageIndex = newIndex
                            state.selectedIndices = [newIndex]
                            state.thumbnailJumpTask?.cancel()
                            state.thumbnailJumpTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled else { return }
                                state.goToPage(state.currentPageIndex)
                            }
                        }
                    }
                    return .handled
                } else if keyPress.key == .delete || keyPress.key == KeyEquivalent("\u{7F}") {
                    state.deletePage(at: state.currentPageIndex)
                    return .handled
                }
                
                return .ignored
            }
            #endif
            .onChange(of: state.currentPageIndex) { _, newIndex in
                let anim: Animation = !MemoryMode.current.policy.delaysNavigationJumps
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.15, dampingFraction: 0.9)
                withAnimation(anim) {
                    proxy.scrollTo(newIndex)
                }
            }
            .onAppear {
                // 当用户从“大纲”选项卡切回“缩略图”选项卡时，由于此时的 ScrollView 是全新的，
                // 我们必须在它刚出现的一瞬间，把它拉回当前所处的阅读页码位置，否则它会傻傻地待在最顶部。
                // 这里的 anchor: .center 是安全的，因为视图还没渲染出来，没有视觉跳动！
                proxy.scrollTo(state.currentPageIndex, anchor: .center)
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
        // 注册拖放目标点，允许纯文本或 PDF 文件掉落到上面
        .onDrop(of: [.plainText, .pdf], isTargeted: $isOver) { _ in
            if let sourceIndices = state.draggedIndices {
                DispatchQueue.main.async {
                    // 当松开鼠标时，触发真实的重排逻辑
                    state.movePages(from: sourceIndices, to: index)
                    state.draggedIndices = nil // 拖拽结束
                }
                return true
            }
            return false
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
    
    static func == (lhs: ThumbnailItem, rhs: ThumbnailItem) -> Bool { 
        // 只能比较外界传入的不可变属性。
        lhs.index == rhs.index && lhs.isSelected == rhs.isSelected 
    }
    
    var body: some View {
        // 【稳健性核心】通过静态内存数组直接 O(1) 获取每一页的独立物理比例。
        let ratio = state.pageAspectRatios.indices.contains(index) ? state.pageAspectRatios[index] : (1.0 / 1.414)
        
        VStack(spacing: 6) {
            ZStack {
                if let img = thumbnail {
                    #if os(macOS)
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .contrast(1.15)
                        .aspectRatio(contentMode: .fit)
                    #else
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.high)
                        .contrast(1.15)
                        .aspectRatio(contentMode: .fit)
                    #endif
                } else {
                    // [骨架屏 / Skeleton] 如果图片还没渲染出来，先显示一个空白框
                    Color.primary.opacity(0.03)
                        .aspectRatio(ratio, contentMode: .fit)
                        .onAppear { 
                            // 刚出现时立刻去内存缓存里碰碰运气
                            if let cached = state.getThumbnail(for: index) { 
                                thumbnail = cached 
                            } else { 
                                // 缓存里没有，命令专门的引擎去后台渲染
                                state.generateThumbnail(for: index) 
                            } 
                        } 
                }
            }
            .frame(width: 140).background(Color.white).cornerRadius(4)

            .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
            // 选中时的蓝色外加粗框
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            // 底下的页码标
            Text("\(index + 1)")
                .font(.system(size: PlatformUtils.isiOS ? 15 : 10, weight: .medium))
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .padding(.horizontal, 10).contentShape(Rectangle())
        // 接收来自画图线程通过 Combine 发回来的“画好了”信号！
        .onReceive(state.thumbnailUpdateSubject) { if $0 == index { thumbnail = state.getThumbnail(for: index) } }
        // 修复灰白问题的关键：滚出屏幕时，仅仅取消排队任务即可，坚决不要把 thumbnail 设为 nil！
        // 因为 NSCache 和强引用池会自动管理底层内存的抛弃与保留，SwiftUI 这里自然持有即可。
        .onDisappear {
            state.cancelThumbnailGeneration(for: index)
        }
        .contextMenu {
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
        }
        // [极客级拖拽：向外部暴露该文件]
        .onDrag {
            // 先确定这一拖拉起了哪些页面
            let targetIndices = state.selectedIndices.contains(index) ? state.selectedIndices : [index]
            state.draggedIndices = targetIndices
            
            #if os(macOS)
            let indicesStr = targetIndices.sorted().map { String($0) }.joined(separator: ",")
            let provider = NSItemProvider() // 系统底层的拖拽物提供者
            
            // 1. 如果你在软件内部拖动重排，传个字符串记录位置就行了，不用真生成文件
            provider.registerObject(indicesStr as NSString, visibility: .all)
            
            // 2. 如果用户真的是想拖到桌面上当做一个独立的新 PDF (关键性能优化：异步生成！)
            provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
                Task {
                    let url = await MainActor.run {
                        state.exportPagesAsPDF(at: targetIndices)
                    }
                    completion(url, false, nil)
                }
                return nil
            }
            provider.suggestedName = "dragger"
            
            return provider
            #else
            return NSItemProvider(object: String(index) as NSString)
            #endif
        }
    }
}
