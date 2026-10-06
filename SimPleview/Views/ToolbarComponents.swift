import SwiftUI
import PDFKit

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
                // 系统颜色面板是共享单例；回调不能长期保留已经关闭的文档窗口。
                ColorPanelManager.shared.show(initialColor: state.currentColor) { [weak document = state] newColor in
                    guard let document, !document.isClosed else { return }
                    document.currentColor = newColor
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
                
                // 在 macOS 的原生 Toolbar 里，如果只放一个图标，按钮的点击热区会极其小且怪异
                // 加上一个看不见的空格，能强行把按钮撑宽，这是个非常有效的丑陋黑客技巧。
                Text(" ") 
            }
        }
    }
    
    private func colorMenuOption(_ name: String, _ color: PlatformColor) -> some View {
        Button(action: { state.currentColor = color }) {
            colorMenuText(name: name, color: color)
        }
    }
    
    private func colorMenuText(name: String, color: NSColor) -> Text {
        var dot = AttributedString("● ")
        dot.foregroundColor = Color(nsColor: color)
        let text = AttributedString(name)
        return Text(dot + text)
    }
}

// MARK: - 独立原生手绘按钮（带滑块下拉）
struct DrawButtonView: View {
    @ObservedObject var state: AppState
    @State private var isShowingPopover = false
    
    var body: some View {
        Button(action: {
            if state.activeType == .ink {
                // 如果已经是画笔状态，再次点击弹出粗细调节菜单
                isShowingPopover.toggle()
            } else {
                // 如果不是画笔状态，切换到画笔
                state.activeType = .ink
            }
        }) {
            Label(state.L("Draw"), systemImage: "scribble.variable")
                .foregroundColor(state.activeType == .ink ? .accentColor : .primary)
        }
        .popover(isPresented: $isShowingPopover) {
            VStack {
                Text(state.L("Line Weight") + ": \(String(format: "%.1f", state.currentLineWidth))")
                    .font(.caption)
                // 只修改新笔迹的默认宽度；已提交笔迹的几何和原生附件保持一致。
                Slider(value: $state.currentLineWidth, in: CGFloat(AnnotationDefaults.lineWidthRange.lowerBound)...CGFloat(AnnotationDefaults.lineWidthRange.upperBound), step: 0.5)
                    .frame(width: 150)
            }
            .padding()

        }
    }
}

// MARK: - 批注二次编辑面板
/// 当你在 PDF 里选中了某条高亮，屏幕会弹出一个浮窗，允许修改颜色或删除。
struct AnnotationEditorView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    var body: some View {
        VStack(spacing: 15) {
            Text(state.L("Annotation Editor")).font(.headline).padding(.top)
            
            // 颜色选择排排坐
            HStack(spacing: 20) {
                ForEach([("Blue", PlatformColor.platformBlue), ("Red", PlatformColor.platformRed), ("Yellow", PlatformColor.platformYellow), ("Green", PlatformColor.platformGreen), ("Purple", PlatformColor.platformPurple)], id: \.0) { name, color in
                    Button(action: {
                        if let annot = state.selectedAnnotation {
                            StandardInk.setColor(color, to: annot)
                            // 同一批次的碎片同步改色。
                            state.pdfView.syncBatchColor(for: annot)
                            
                            // 同步工具颜色与持久化回调。
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
                    .accessibilityLabel(state.L(name))
                }
            }
            
            Divider()
            
            // 删除按钮，role: .destructive 会让它自动变成醒目的红色警示语
            Button(role: .destructive, action: {
                state.deleteSelectedAnnotation()
                uiState.isShowingAnnotationEditor = false
            }) {
                Label(state.L("Delete Annotation"), systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).padding(.horizontal)
        }
        .padding()
        .frame(width: 250) // 限制宽度，让浮窗不要显得太大太笨重
    }
}

class ColorPanelManager: NSObject {
    static let shared = ColorPanelManager()
    private var colorUpdateCallback: ((NSColor) -> Void)?
    
    func show(initialColor: NSColor, onUpdate: @escaping (NSColor) -> Void) {
        self.colorUpdateCallback = onUpdate
        
        let panel = NSColorPanel.shared
        // 系统颜色面板由各个 ColorPicker 共用；每次打开都重新指定目标，
        // 防止设置页改色后，工具栏的颜色回调仍被交给另一个控件。
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        panel.color = initialColor
        panel.showsAlpha = false
        panel.mode = .RGB
        
        panel.makeKeyAndOrderFront(nil)
    }
    
    @objc private func colorDidChange(_ sender: NSColorPanel) {
        colorUpdateCallback?(sender.color)
    }
}
