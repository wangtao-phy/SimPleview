import SwiftUI
import PDFKit

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
