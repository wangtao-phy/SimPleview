import SwiftUI
import PDFKit
import Combine

// [P1修复] 安全唯一标识：优先使用 userName，若为空则回退到对象内存地址，防止 ForEach id 碰撞
extension PDFAnnotation {
    var safeID: String {
        userName ?? "obj-\(ObjectIdentifier(self).hashValue)"
    }
}

/// [教程注释：左侧批注大纲视图]
/// 负责展示你在文档中划出的所有高亮、下划线和笔记，并允许你点击跳转或直接修改备注。
struct AnnotationSidebarView: View {
    @ObservedObject var state: AppState
    
    // SwiftUI 原生焦点状态绑定，直接使用标注的 userName (String) 作为焦点标识
    @FocusState private var focusedField: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // [空状态展示]
            if state.allAnnotations.isEmpty {
                // macOS 14+ 提供的原生空状态视图
                ContentUnavailableView("无标注内容", systemImage: "pencil.and.outline", description: Text("在文档中划线或高亮来记录内容"))
                    .frame(maxHeight: .infinity)
            } else {
                #if os(iOS)
                // [iOS 专用列表]
                // iOS 的 List 性能极佳，自带左滑删除等手势，所以我们尽量使用系统原生 List
                List {
                    ForEach(state.allAnnotations, id: \.safeID) { annotation in
                        let isSelected = state.selectedAnnotation?.userName == annotation.userName
                        Button(action: {
                            state.selectedAnnotation = annotation
                        }) {
                            AnnotationRow(annotation: annotation, isSelected: isSelected, focusedField: $focusedField, onSelect: {
                                state.selectedAnnotation = annotation
                            })
                        }
                        .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                            .listRowSeparator(.visible, edges: .bottom)
                    }
                    .onDelete { indexSet in // 原生左滑删除
                        for index in indexSet {
                            state.deleteAnnotation(state.allAnnotations[index])
                        }
                    }
                }
                .listStyle(.plain)
                #else
                // [macOS 专用列表]
                // 响应用户需求：使用原生左滑删除替代右键菜单，这要求我们必须使用原生的 List 组件。
                ScrollViewReader { proxy in // 用于代码控制滚动条的位置
                    List {
                        ForEach(state.allAnnotations, id: \.safeID) { annotation in
                            let id = annotation.safeID
                            let isSelected = state.selectedAnnotation?.userName == id
                            
                            AnnotationRow(annotation: annotation, isSelected: isSelected, focusedField: $focusedField, onSelect: {
                                state.selectedAnnotation = annotation
                                focusedField = id
                            })
                                // [键盘事件拦截] 仅当这一行被选中时，按下 Delete 或 Backspace 键才触发删除
                                .onKeyPress(.delete) {
                                    if focusedField == id {
                                        state.deleteSelectedAnnotation()
                                        return .handled
                                    }
                                    return .ignored
                                }
                                .onKeyPress("\u{7F}") {
                                    if focusedField == id {
                                        state.deleteSelectedAnnotation()
                                        return .handled
                                    }
                                    return .ignored
                                }
                                .onTapGesture {
                                    state.selectedAnnotation = annotation
                                    focusedField = id
                                }
                            .id(annotation.safeID)
                            // [原生的左滑删除] 替代了原来的右键删除 (.contextMenu)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    state.deleteAnnotation(annotation)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            // 消除 List 默认边距，实现无缝贴合
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.visible, edges: .bottom)
                        }
                    }
                    .listStyle(.plain)
                    // [主视图同步侧边栏]
                    // 当主视图点击了标注，这里的 selectedAnnotation 也会变，我们让列表自动滚动过去
                    .onChange(of: state.selectedAnnotation) { _, newSelection in
                        if let nid = newSelection?.userName {
                            withAnimation {
                                proxy.scrollTo(nid, anchor: .center)
                            }
                        }
                    }
                    // [修复] 使用 .onKeyPress 替代 .onMoveCommand
                    // .onMoveCommand 挂在 ScrollViewReader 上时，如果焦点在子视图 AnnotationRow 上，
                    // 方向键事件会被子视图吞掉，导致第一次点击标注后上下键失效。
                    // .onKeyPress 支持从聚焦子视图冒泡到父视图，确保方向键始终生效。
                    .onKeyPress(.upArrow) {
                        let all = state.allAnnotations
                        guard let currentIndex = all.firstIndex(where: { $0.userName == state.selectedAnnotation?.userName }),
                              currentIndex > 0 else { return .handled }
                        let nextAnnot = all[currentIndex - 1]
                        state.selectedAnnotation = nextAnnot
                        let nid = nextAnnot.userName ?? ""
                        focusedField = nid
                        proxy.scrollTo(nid, anchor: .center)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        let all = state.allAnnotations
                        guard let currentIndex = all.firstIndex(where: { $0.userName == state.selectedAnnotation?.userName }),
                              currentIndex < all.count - 1 else { return .handled }
                        let nextAnnot = all[currentIndex + 1]
                        state.selectedAnnotation = nextAnnot
                        let nid = nextAnnot.userName ?? ""
                        focusedField = nid
                        proxy.scrollTo(nid, anchor: .center)
                        return .handled
                    }
                }
                #endif
            }
        }
        // [延迟加载批注]
        // 极客内存优化：我们在打开文档时绝对不去遍历全文抽取批注（那会把上千页 PDF 的缓存全部激活，导致闲置内存飙升到 500MB）。
        // 只有当用户真正点击右侧的“批注”标签页，展示出这个大纲视图时，我们才去抽取。
        .onAppear {
            if state.allAnnotations.isEmpty {
                state.annotationManager.refreshAnnotations(in: state.pdfView.document)
            }
        }
    }
}

/// [教程注释：大纲列表中的单个元素行]
struct AnnotationRow: View {
    let annotation: PDFAnnotation
    let isSelected: Bool
    @FocusState.Binding var focusedField: String?
    var onSelect: (() -> Void)? = nil
    
    var body: some View {
        let id = annotation.userName ?? ""
        
        VStack(alignment: .leading, spacing: 4) {
            // [顶部元数据信息栏]
            HStack {
                Circle()
                    .fill(Color(annotation.color))
                    .frame(width: 8, height: 8)
                
                Text(annotation.typeDisplay)
                    .font(PlatformUtils.isiOS ? .body : .caption)
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Spacer()
                
                if let page = annotation.page, let index = page.document?.index(for: page) {
                    Text("P\(index + 1)")
                        .font(PlatformUtils.isiOS ? .subheadline : .caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            
            // [底部文本展示区]
            // 用户逻辑：1. 不需要状态，直接读取内容。 2. 必须预留展示空间。 3. 支持超长文本局部滚动。
            let text = annotation.simPleNote
            if text.isEmpty {
                Text(" ")
                    .font(.system(size: PlatformUtils.isiOS ? 16 : 11))
                    .frame(minHeight: PlatformUtils.isiOS ? 22 : 16, alignment: .topLeading)
                    .padding(.top, 4)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(text)
                        .font(.system(size: PlatformUtils.isiOS ? 16 : 11))
                        .foregroundColor(isSelected ? .primary : .primary.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // 给内部留一点点边距，防止滚动条遮挡文字
                        .padding(.trailing, 8) 
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect?()
                        }
                }
                .frame(maxHeight: 120) // 限制最大高度，如果文字很少会自动收缩，如果很多就会出现滚动条
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()) // 全面覆盖整个标注框
        .onTapGesture { // 拦截一切落在外层的点击
            onSelect?()
        }
        #if os(macOS)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .focusable()
        .focused($focusedField, equals: id)
        #else
        .background(isSelected ? Color.black.opacity(0.05) : Color.clear) // iOS 也给个微微的高亮反馈
        #endif
    }
}

// 拓展 PDF 底层枚举，将英文类型翻译成人类友好的中文
extension PDFAnnotation {
    var typeDisplay: String {
        guard let typeStr = self.type else { return "标注" }
        if typeStr.contains("Highlight") { return "高亮" }
        if typeStr.contains("Underline") { return "下划线" }
        if typeStr.contains("StrikeOut") { return "删除线" }
        if typeStr.contains("Ink") { return "手绘" }
        if typeStr.contains("Stamp") { return "签名" }
        return "标注"
    }
}
