import SwiftUI
import PDFKit

/// 专门负责标注工具的工具栏组件（包括高亮、下划线、手绘、颜色选择等）
struct AnnotationToolbarGroup: CustomizableToolbarContent {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "AnnotationTools", placement: .principal) {
            HStack(spacing: 8) {
                Picker(state.L("Annotation Tools"), selection: $state.activeType) {
                    Label(state.L("none"), systemImage: "cursorarrow").tag(AnnotationType.none)
                    Label(state.L("highlight"), systemImage: "highlighter").tag(AnnotationType.highlight)
                    Label(state.L("underline"), systemImage: "underline").tag(AnnotationType.underline)
                    Label(state.L("strikeout"), systemImage: "strikethrough").tag(AnnotationType.strikeout)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                ColorPickerMenu(state: state)
            }
            .disabled(state.fileURL == nil)
        }
        
        // 护眼背景色按钮
        ToolbarItem(id: "BackgroundColor", placement: .primaryAction) {
            Menu {
                Button(action: { state.pageBackgroundColor = .default }) {
                    #if os(macOS)
                    colorMenuText(name: state.L("Default Background") != "Default Background" ? state.L("Default Background") : "默认背景", color: .white)
                    #else
                    Label(state.L("Default Background") != "Default Background" ? state.L("Default Background") : "默认背景", systemImage: "doc")
                    #endif
                }
                Button(action: { state.pageBackgroundColor = .green }) {
                    #if os(macOS)
                    colorMenuText(name: state.L("Eye-care Green") != "Eye-care Green" ? state.L("Eye-care Green") : "护眼绿", color: NSColor(red: 0.78, green: 0.93, blue: 0.8, alpha: 1.0))
                    #else
                    Label(state.L("Eye-care Green") != "Eye-care Green" ? state.L("Eye-care Green") : "护眼绿", systemImage: "leaf")
                    #endif
                }
                Button(action: { state.pageBackgroundColor = .yellow }) {
                    #if os(macOS)
                    colorMenuText(name: state.L("Soft Yellow") != "Soft Yellow" ? state.L("Soft Yellow") : "柔和黄", color: NSColor(red: 0.96, green: 0.9, blue: 0.75, alpha: 1.0))
                    #else
                    Label(state.L("Soft Yellow") != "Soft Yellow" ? state.L("Soft Yellow") : "柔和黄", systemImage: "sun.max")
                    #endif
                }
                Button(action: { state.pageBackgroundColor = .black }) {
                    #if os(macOS)
                    colorMenuText(name: state.L("Dark Mode") != "Dark Mode" ? state.L("Dark Mode") : "暗黑模式", color: .black)
                    #else
                    Label(state.L("Dark Mode") != "Dark Mode" ? state.L("Dark Mode") : "暗黑模式", systemImage: "moon")
                    #endif
                }
            } label: {
                Label(state.L("Background Color") != "Background Color" ? state.L("Background Color") : "背景颜色", systemImage: "circle.lefthalf.filled")
            }
            .disabled(state.fileURL == nil)
        }
        
        // 独立原生手绘按钮（带滑块下拉）
        ToolbarItem(id: "Draw", placement: .primaryAction) {
            DrawButtonView(state: state)
                .disabled(state.fileURL == nil)
        }
        
        // 签名按钮
        ToolbarItem(id: "Signature", placement: .primaryAction) {
            Button(action: {
                uiState.isShowingSignaturePopover.toggle()
            }) {
                Label(state.L("Signature"), systemImage: "signature")
            }
            .help(state.L("Add Signature"))
            .disabled(state.fileURL == nil)
            .popover(isPresented: $uiState.isShowingSignaturePopover, arrowEdge: .bottom) {
                SignaturePopoverView(state: state, uiState: uiState)
            }
        }
    }
    
    #if os(macOS)
    private func colorMenuText(name: String, color: NSColor) -> Text {
        var dot = AttributedString("● ")
        dot.foregroundColor = Color(nsColor: color)
        
        // 为了在深浅色模式下都有良好的辨识度，如果颜色过亮且当前是浅色模式，或者颜色过暗且是深色模式，可能需要细微边框。
        // 但 AttributedString 不支持边框，我们尽量让颜色本身纯粹即可。对于白色/黑色可以稍微加点灰度。
        var displayColor = color
        if color == .white {
            displayColor = NSColor(white: 0.9, alpha: 1.0) // 避免纯白在白底上看不见
        } else if color == .black {
            displayColor = NSColor(white: 0.2, alpha: 1.0)
        }
        dot.foregroundColor = Color(nsColor: displayColor)
        
        let text = AttributedString(name)
        return Text(dot + text)
    }
    #endif
}
