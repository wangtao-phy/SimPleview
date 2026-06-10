import SwiftUI
import PDFKit

#if os(iOS)

/// [教程注释：iOS 工具栏模块化组件]
/// iOS 顶部的 Toolbar (导航栏) 空间寸土寸金。为了让代码清爽，
/// 我们把顶部那一排复杂的按钮拆成了三个组件：画笔组、颜色组、功能组。

// MARK: - 第一组：标注工具包 (Annotation Group)
/// 包含：箭头(正常阅读)、高亮、下划线、删除线、手写笔
struct AnnotationGroupView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    var body: some View {
        // ControlGroup 是 iOS 16 提供的高级控件，它能自动把几个按钮合成一个带胶囊底色的连体婴，非常美观。
        ControlGroup {
            annotationButton(icon: "cursorarrow", type: AnnotationType.none)
            annotationButton(icon: "highlighter", type: .highlight)
            annotationButton(icon: "underline", type: .underline)
            annotationButton(icon: "strikethrough", type: .strikeout)
            annotationButton(icon: "scribble", type: .ink)
        }
        .controlGroupStyle(.navigation) // 让它的高度和背景色完美融入顶部导航栏
        .contextMenu { ToolbarCustomizerMenu(uiState: uiState) } // 长按触发隐藏的定制菜单
    }
    
    private func annotationButton(icon: String, type: AnnotationType) -> some View {
        Button(action: { state.activeType = type }) { // 点击后切换全局状态
            Image(systemName: icon)
                // 如果当前选中的是这个工具，图标就变粗(bold)变蓝(accentColor)
                .font(.system(size: 14, weight: state.activeType == type ? .bold : .regular))
                .foregroundColor(state.activeType == type ? .accentColor : .primary)
                .contentShape(Rectangle()) // 扩大点击热区，别让用户手指戳不中
        }
    }
}

// MARK: - 第二组：颜色大圆点 (Color Group)
/// 点击它会弹出一个包含常用颜色的微型下拉菜单。
struct ColorGroupView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    var body: some View {
        // 我们在下方写好的自定义颜色菜单组件
        ColorPickerMenu(state: state)
            .contextMenu { ToolbarCustomizerMenu(uiState: uiState) } // 依然埋入长按定制菜单
    }
}

// MARK: - 第三组：核心功能包 (Action Group)
/// 包含：导入新文件、打开/关闭左边栏、打开/关闭右边栏
struct ActionGroupView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    var onImport: () -> Void
    
    var body: some View {
        ControlGroup {
            Button(action: { onImport() }) {
                Label("导入", systemImage: "plus.circle")
            }
            
            Button(action: { uiState.toggleLeftSidebar(state: state) }) {
                Label(state.L("Left Column"), systemImage: "sidebar.left")
                    // 如果边栏不是关闭状态，图标就变成实心(fill)以示区分
                    .symbolVariant(uiState.columnVisibility != .detailOnly ? .fill : .none)
            }
            
            Button(action: { uiState.toggleRightSidebar(state: state) }) {
                Label(state.L("Right Column"), systemImage: "sidebar.right")
                    .symbolVariant(uiState.showRightSidebar ? .fill : .none)
            }
        }
        .controlGroupStyle(.navigation) 
        .contextMenu { ToolbarCustomizerMenu(uiState: uiState) }
    }
}

// 长按呼出的“定制菜单”入口按钮
struct ToolbarCustomizerMenu: View {
    @ObservedObject var uiState: UIState
    var body: some View {
        Button(action: { uiState.isShowingToolbarCustomizer = true }) { // 点击后弹出一个全屏窗口
            Label("定制工具栏", systemImage: "slider.horizontal.3")
        }
    }
}

// 这是用户点击“定制工具栏”后弹出来的独立窗口，里面用 Toggle 开关控制刚才那三组视图的显示与隐藏
struct ToolbarSelectionWindow: View {
    @ObservedObject var uiState: UIState
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("显示工具栏组")) {
                    Toggle("标注工具", isOn: $uiState.showAnnotationGroup)
                    Toggle("颜色选择", isOn: $uiState.showColorGroup)
                    Toggle("核心功能", isOn: $uiState.showActionGroup)
                }
            }
            .navigationTitle("定制工具栏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { uiState.isShowingToolbarCustomizer = false }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 280) // 给 iPad 设置个最小窗口大小
    }
}
#endif

// MARK: - 跨平台的颜色选择菜单
/// 点击后下拉展示 5 个常用颜色。在 Mac 上，最下面还会多出一个“自定义颜色”呼出系统调色板。
struct ColorPickerMenu: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        // Menu 控件自带原生的点击弹窗效果
        Menu {
            // 循环生成 5 个标准颜色选项
            ForEach([
                (state.L("Blue"), PlatformColor.platformBlue),
                (state.L("Red"), PlatformColor.platformRed),
                (state.L("Yellow"), PlatformColor.platformYellow),
                (state.L("Green"), PlatformColor.platformGreen),
                (state.L("Purple"), PlatformColor.platformPurple)
            ], id: \.0) { name, color in
                colorMenuOption(name, color)
            }
            
            Divider() // 分割线
            
            Button(action: {
                #if os(macOS)
                // 仅在 macOS 支持高级系统调色板 (NSColorPanel)
                ColorPanelManager.shared.show(initialColor: state.currentColor) { newColor in
                    state.currentColor = newColor
                }
                #endif
            }) {
                Label { Text(state.L("Other Color...")) } icon: {
                    Image(systemName: "paintpalette")
                }
            }
        } label: { // Menu 闭合时，平时显示在界面上的样子（就是一个大圆点）
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(state.currentColor)) // 圆点颜色实时跟随当前选中的颜色
                    .imageScale(.large)
                
                #if os(macOS)
                // 在 macOS 的原生 Toolbar 里，如果只放一个图标，按钮的点击热区会极其小且怪异
                // 加上一个看不见的空格，能强行把按钮撑宽，这是个非常有效的丑陋黑客技巧。
                Text(" ") 
                #endif
            }
        }
    }
    
    private func colorMenuOption(_ name: String, _ color: PlatformColor) -> some View {
        Button(action: { state.currentColor = color }) {
            #if os(macOS)
            Label { Text(name) } icon: {
                Image(nsImage: NSImage.flatColorDot(color: color))
            }
            #else
            Label { Text(name) } icon: {
                Image(systemName: "circle.fill").foregroundStyle(Color(color))
            }
            #endif
        }
    }
}

// MARK: - iOS 专属：批注二次编辑面板
/// 当你在 iOS 上点击了 PDF 里的某条高亮，屏幕底部会弹出一个浮窗。
/// 这个浮窗就是这里定义的。它允许你修改高亮的颜色，或者一键删掉它。
struct AnnotationEditorView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    var body: some View {
        VStack(spacing: 15) {
            Text("调整标注").font(.headline).padding(.top)
            
            // 颜色选择排排坐
            HStack(spacing: 20) {
                ForEach([("蓝色", PlatformColor.platformBlue), ("红色", PlatformColor.platformRed), ("黄色", PlatformColor.platformYellow), ("绿色", PlatformColor.platformGreen), ("紫色", PlatformColor.platformPurple)], id: \.0) { name, color in
                    Button(action: {
                        if let annot = state.selectedAnnotation {
                            annot.color = color
                            // 极品细节：不仅改这条的颜色，还要用 syncBatchColor 找出同一个字的其他笔画一起改掉！
                            state.pdfView.syncBatchColor(for: annot)
                            
                            // [新增] 完美复刻 macOS 逻辑：修改批注颜色时，同步更新全局的画笔颜色！
                            state.currentColor = color
                            state.pdfView.onColorChanged?(color, annot.type ?? "")
                            
                            uiState.isShowingAnnotationEditor = false // 改完立刻自动关窗
                        }
                    }) {
                        // 画一个彩色实心圆作为色板
                        Circle().fill(Color(color)).frame(width: 30, height: 30)
                            // 加一层极淡的外阴影描边，否则白色的页面遇到淡黄色的圆点就看不清边缘了
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                    }
                }
            }
            
            Divider()
            
            // 删除按钮，role: .destructive 会让它自动变成醒目的红色警示语
            Button(role: .destructive, action: {
                state.deleteSelectedAnnotation()
                uiState.isShowingAnnotationEditor = false
            }) {
                Label("删除标注", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).padding(.horizontal)
        }
        .padding()
        .frame(width: 250) // 限制宽度，让浮窗不要显得太大太笨重
    }
}

#if os(macOS)
class ColorPanelManager: NSObject, NSWindowDelegate {
    static let shared = ColorPanelManager()
    private var colorUpdateCallback: ((NSColor) -> Void)?
    private var isObserving = false
    
    func show(initialColor: NSColor, onUpdate: @escaping (NSColor) -> Void) {
        self.colorUpdateCallback = onUpdate
        
        let panel = NSColorPanel.shared
        panel.color = initialColor
        panel.showsAlpha = false
        panel.mode = .RGB
        
        if !isObserving {
            panel.setTarget(self)
            panel.setAction(#selector(colorDidChange(_:)))
            isObserving = true
        }
        
        panel.makeKeyAndOrderFront(nil)
    }
    
    @objc private func colorDidChange(_ sender: NSColorPanel) {
        colorUpdateCallback?(sender.color)
    }
}

extension NSImage {
    /// 动态绘制一个纯平面的实心圆点（无高光、无阴影、无模板化剥色）
    static func flatColorDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: NSPoint(x: 1, y: 1), size: NSSize(width: 12, height: 12))).fill()
        image.unlockFocus()
        image.isTemplate = false // 极度关键：禁止被 Menu 染成黑白单色！
        return image
    }
}
#endif
