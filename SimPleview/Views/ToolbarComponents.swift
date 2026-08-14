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
                Slider(value: $state.currentLineWidth, in: 2...6, step: 0.5)
                    .frame(width: 150)
            }
            .padding()
            // 实时同步给选中的手绘标注
            .onChange(of: state.currentLineWidth) { _, newValue in
                if let annot = state.selectedAnnotation {
                    let types: Set<String> = ["Ink"]
                    if types.contains(annot.type ?? "") {
                        let newBorder = annot.border?.copy() as? PDFBorder ?? PDFBorder()
                        newBorder.lineWidth = newValue
                        annot.border = newBorder
                        
                        // 顺带同步同一批次的笔画
                        if let batchID = annot.userName, let doc = state.pdfView.document {
                            if let basePage = annot.page {
                                let baseIndex = doc.index(for: basePage)
                                let start = max(0, baseIndex - 2)
                                let end = min(doc.pageCount, baseIndex + 3)
                                for i in start..<end {
                                    if let page = doc.page(at: i) {
                                        for a in page.annotations where a.userName == batchID && a != annot {
                                            let batchBorder = a.border?.copy() as? PDFBorder ?? PDFBorder()
                                            batchBorder.lineWidth = newValue
                                            a.border = batchBorder
                                        }
                                    }
                                }
                            }
                        }
                        state.pdfView.setPlatformNeedsDisplay()
                    }
                }
            }
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
