import SwiftUI

/// [教程注释：右侧边栏总入口]
/// 右侧边栏负责一切和“当前正文阅读状态”无关的附加功能：
/// 包括了查看大纲标注(Annotations)、全局搜索(Search)、以及阅读时长统计(Record)。
struct RightSidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    // 读取 UserDefaults 里的开关：用户是否开启了“阅读统计”功能
    @AppStorage("enableReadingRecord") var enableReadingRecord = false
    
    var body: some View {
        VStack(spacing: 0) {
            // [顶部分段选择器]
            Picker("", selection: $uiState.rightSidebarTab) {
                Text(state.L("Annotations")).tag(0)
                Text(state.L("Search")).tag(1)
                
                // 动态选项：只有用户在设置里开启了这功能，才显示这个标签
                if enableReadingRecord {
                    Text(state.L("Record")).tag(2)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)
            
            Divider()
            
            // [核心内容区路由]
            switch uiState.rightSidebarTab {
            case 0: AnnotationSidebarView(state: state)
            case 1: SearchSidebarView(state: state, uiState: uiState, searchManager: state.searchManager)
            case 2:
                if enableReadingRecord {
                    ReadingRecordView(state: state)
                } else {
                    EmptyView()
                }
            default: EmptyView()
            }
        }
        // [防御性编程] 
        // 假设用户现在正停留在“统计(Record)”标签，然后他打开设置，把这功能关了。
        // 如果我们不处理，这页面就会变成一片空白卡住。所以我们监听开关，如果关了，强制跳回第一个标签。
        .onChange(of: enableReadingRecord) { _, newValue in
            if !newValue && uiState.rightSidebarTab == 2 {
                uiState.rightSidebarTab = 0
            }
        }
    }
}

/// [教程注释：全局搜索侧边栏]
/// 提供一个输入框，按下回车后调用底层的 `SearchManager` 进行多线程全局搜索。
struct SearchSidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    @ObservedObject var searchManager: SearchManager
    @FocusState private var isSearchFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            
            // [顶部：搜索控制台]
            VStack(spacing: 8) {
                // 1. 搜索框组合
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    
                    TextField(state.L("Search Document..."), text: $searchManager.searchQuery)
                        .textFieldStyle(.plain) // 扒掉系统默认的白底圆角框，因为我们外面自己画了一个更好看的
                        #if os(macOS)
                        .focusEffectDisabled() // 彻底消除系统聚焦时闪烁的默认白色边框 / 聚焦环
                        .background(Color.clear)
                        #endif
                        .focused($isSearchFocused)
                        .submitLabel(.search) // iOS 专用：把键盘右下角的回车键变成蓝色的“搜索”按钮
                        .onSubmit {
                            // 当用户按下回车时，显式触发主线程更新，调用搜索下一个的逻辑
                            DispatchQueue.main.async {
                                state.goToNextSearchResult()
                            }
                        }
                        .onChange(of: uiState.focusSearchTrigger) { _, _ in
                            DispatchQueue.main.async {
                                isSearchFocused = true
                            }
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if uiState.rightSidebarTab == 1 && uiState.showRightSidebar {
                                    isSearchFocused = true
                                }
                            }
                        }
                    
                    // 当有文字时，显示一个“小叉叉”按钮用来一键清空
                    if !searchManager.searchQuery.isEmpty {
                        Button(action: { searchManager.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.05)) // 自定义浅色底纹
                .cornerRadius(8)
                
                // 2. 状态反馈区 (正在搜索、查无结果、结果统计)
                if searchManager.isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .padding(.trailing, 2)
                        Text(state.L("Searching..."))
                            .font(.system(.caption))
                            .foregroundColor(.secondary)
                    }
                    .padding(.trailing, 4)
                    .transition(.opacity)
                } else if !searchManager.searchQuery.isEmpty && searchManager.searchResults.isEmpty {
                    // 搜了，但是没搜到
                    HStack {
                        Spacer()
                        Text(state.L("No results"))
                            .font(.system(.caption))
                            .foregroundColor(.secondary)
                    }
                    .padding(.trailing, 4)
                    .transition(.opacity)
                } else if !searchManager.searchResults.isEmpty {
                    // 搜到了，显示 "2 / 150" 这样的进度
                    HStack {
                        Spacer()
                        Text(searchManager.searchProgressText)
                            .font(.system(.caption, design: .monospaced)) // monospaced: 等宽字体，数字跳动时不会左右抖动
                            .foregroundColor(.secondary)
                            .padding(.trailing, 4)
                    }
                    .transition(.opacity)
                }
            }
            .padding(10)
            // 当状态变化时，给上述三个状态的切换加上平滑的淡入淡出动画
            .animation(.easeInOut(duration: 0.2), value: searchManager.isSearching)
            .animation(.easeInOut(duration: 0.2), value: searchManager.searchResults.isEmpty)
            
            // [底部：搜索结果列表区]
            #if os(macOS)
            // Mac 上因为需要精确控制背景色，弃用 List，改用 ScrollView + LazyVStack 手动打造，防止闪烁
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<searchManager.searchResults.count, id: \.self) { index in
                            if index < searchManager.searchResults.count {
                                let isCurrent = searchManager.currentSearchIndex == index
                                let format = state.L("Page Number Input")
                                
                                SearchResultItem(index: index, match: searchManager.searchResults[index], isCurrentIndex: isCurrent, pageFormat: format)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        searchManager.currentSearchIndex = index
                                        state.selectSearchResult(at: index)
                                    }
                                    .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .cornerRadius(6)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                #if os(macOS)
                .background(
                    ArrowKeyMonitorView(
                        onUp: {
                            guard !searchManager.searchResults.isEmpty else { return }
                            let newIndex = (searchManager.currentSearchIndex ?? searchManager.searchResults.count) - 1
                            if newIndex >= 0 {
                                searchManager.currentSearchIndex = newIndex
                                state.selectSearchResult(at: newIndex)
                            }
                        },
                        onDown: {
                            guard !searchManager.searchResults.isEmpty else { return }
                            let newIndex = (searchManager.currentSearchIndex ?? -1) + 1
                            if newIndex < searchManager.searchResults.count {
                                searchManager.currentSearchIndex = newIndex
                                state.selectSearchResult(at: newIndex)
                            }
                        }
                    )
                )
                #endif
                .onChange(of: searchManager.currentSearchIndex) { _, newIndex in
                    if let index = newIndex {
                        withAnimation { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
            #else
            // selection 绑定了一个可空变量，使得点击某一行时它会变成蓝底选中状态
            List(selection: $searchManager.currentSearchIndex) {
                ForEach(0..<searchManager.searchResults.count, id: \.self) { index in
                    if index < searchManager.searchResults.count {
                        // 移除对 state 和 searchManager 的重型依赖，只传递计算好的轻量数值
                        let isCurrent = searchManager.currentSearchIndex == index
                        let format = state.L("Page Number Input")
                        Button(action: {
                            searchManager.currentSearchIndex = index
                            state.selectSearchResult(at: index)
                        }) {
                            SearchResultItem(index: index, match: searchManager.searchResults[index], isCurrentIndex: isCurrent, pageFormat: format)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(index as Int?)
                    }
                }
            }
            .listStyle(.sidebar) // 使用原生侧边栏风格（没有丑陋的分隔线）
            .scrollContentBackground(.hidden) // [修复] 消除 List 默认白色背景，防止打开搜索时的白色闪烁
            .onChange(of: searchManager.currentSearchIndex) { _, newIndex in
                // 当用户点击了某一项，命令 PDF 滚过去
                if let index = newIndex { state.selectSearchResult(at: index) }
            }
            #endif
        }
    }
}

/// [教程注释：搜索列表中的单行结果组件]
struct SearchResultItem: View {
    let index: Int
    // 我们自己定义的搜索结果结构体，包含页码和上下文文字
    let match: SearchMatch
    let isCurrentIndex: Bool
    let pageFormat: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 页码标题 (例如: 第 5 页)
            Text(String(format: pageFormat, "\(match.pageIndex + 1)"))
                .font(PlatformUtils.isiOS ? .body : .caption)
                .bold()
                // 如果当前正好停留在这行，字体变成灰色(配合蓝色背景)；否则是高亮色
                .foregroundColor(isCurrentIndex ? .secondary : .accentColor)
            
            // 上下文原文
            Text(match.context)
                .font(.system(size: PlatformUtils.isiOS ? 15 : 11))
                .lineLimit(2) // 最多显示两行，剩下的用 ... 截断
        }.padding(.vertical, 4)
    }
}

#if os(macOS)
import AppKit

struct ArrowKeyMonitorView: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = ArrowMonitorNSView()
        view.onUp = onUp
        view.onDown = onDown
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class ArrowMonitorNSView: NSView {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var monitor: Any?
    
    override func viewDidMoveToWindow() {
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, let window = self.window else { return event }
                
                // Only intercept if the first responder is inside the sidebar (e.g. the search text field)
                // or if it's the window itself. If it's the PDFView, we shouldn't intercept.
                let firstResponder = window.firstResponder
                let isPDFViewFocused = String(describing: type(of: firstResponder)).contains("PDFView")
                
                if !isPDFViewFocused {
                    if event.keyCode == 126 { // Up arrow
                        self.onUp?()
                        return nil
                    } else if event.keyCode == 125 { // Down arrow
                        self.onDown?()
                        return nil
                    }
                }
                return event
            }
        } else {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}
#endif
