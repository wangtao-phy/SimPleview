import SwiftUI
#if os(iOS)

/// [教程注释：iOS 顶层多标签页视图]
/// 因为 iOS 的原生设计逻辑是一次只能看一个窗口（直到最近的 Stage Manager 才有改善），
/// 传统阅读器要想换本书看，必须退回到主目录去选，非常打断心流。
/// 这个 View 用纯 SwiftUI 仿造了类似于 macOS Safari 浏览器顶部的“标签页 (Tabs)”系统。
struct DocumentTabsView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        // [滚动代理器] 用于在标签很多超出屏幕时，能够用代码命令它滚到某个特定的标签处
        ScrollViewReader { proxy in
            // 横向滑动，隐藏原生的滚动条
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 遍历当前在内存中打开的所有 PDF 文档
                    ForEach(Array(state.documents.enumerated()), id: \.element.id) { index, doc in
                        tabItem(index: index, doc: doc)
                            .id(doc.id) // 关键：指定 ID 以便 ScrollViewProxy 根据这个 ID 来定位和查找
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            // 监听：如果当前活跃的文档索引发生了变化（比如用户新建了一个标签，或者删了一个跳转到了下一个）
            .onChange(of: state.activeDocumentIndex) { _, index in
                // 带有弹簧动画 (spring) 自动滚动到那个选中的标签，让它居中显示在屏幕里
                if index < state.documents.count {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        proxy.scrollTo(state.documents[index].id, anchor: .center)
                    }
                }
            }
            // 首次进入界面时的初始化定位
            .onAppear {
                if state.activeDocumentIndex < state.documents.count {
                    proxy.scrollTo(state.documents[state.activeDocumentIndex].id, anchor: .center)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground)) // 使用 iOS 原生的高级次级背景色（跟随深色模式）
        Divider() // 标签栏底部的分割线
    }
    
    // [单个标签的设计模块]
    // 使用 @ViewBuilder 能够让我们在函数里写 SwiftUI 声明式语法
    @ViewBuilder
    private func tabItem(index: Int, doc: PDFDocumentModel) -> some View {
        // 判断这一个是不是当前正在被用户看的标签
        let isSelected = state.activeDocumentIndex == index
        
        HStack(spacing: 6) {
            // 图标：文档 Icon
            Image(systemName: "doc.text.fill")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .accentColor : .secondary)
            
            // 标题：长名字会被 .lineLimit(1) 切断并加上省略号
            Text(doc.fileName)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: 150)
            
            // 右侧的小叉号 (关闭按钮)
            Button(action: { 
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    state.closeDocument(at: index) 
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(isSelected ? .accentColor.opacity(0.8) : .secondary.opacity(0.7))
                    .padding(5)
                    // 背景的小圆圈
                    .background(Circle().fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain) // 去除原生 Button 附带的点击变暗效果
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // 整个标签的圆角胶囊背景
        .background(
            Capsule()
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(uiColor: .tertiarySystemBackground))
        )
        // 选中状态下，外面再套一层描边，更有立体感
        .overlay(
            Capsule()
                .stroke(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 0.5)
        )
        // 点击整个标签本体的触发事件
        .onTapGesture {
            if !isSelected {
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.selectDocument(at: index) // 将大权移交给这一个文档
                }
            }
        }
        // 长按呼出的上下文菜单 (Context Menu)
        .contextMenu {
            Button(action: { state.selectDocument(at: index) }) {
                Label(state.L("Activate Tab"), systemImage: "checkmark.circle")
            }
            
            Divider()
            
            Button(role: .destructive, action: { state.closeDocument(at: index) }) {
                Label(state.L("Close"), systemImage: "xmark")
            }
            
            // 批量操作：“关闭其他所有标签”
            Button(role: .destructive, action: { 
                // 必须从后往前删 (reversed)，否则你删了前面的，后面的 index 就全乱了！会导致数组越界崩溃。
                for i in (0..<state.documents.count).reversed() where i != index {
                    state.closeDocument(at: i)
                }
            }) {
                Label(state.L("Close Others"), systemImage: "xmark.on.rectangle")
            }
        }
    }
}

#endif
