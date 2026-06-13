import SwiftUI
import PDFKit

/// 专门负责标注工具的工具栏组件（包括高亮、下划线、手绘、颜色选择等）
struct AnnotationToolbarGroup: CustomizableToolbarContent {
    @ObservedObject var state: AppState
    
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
        
        // 独立原生手绘按钮（带滑块下拉）
        ToolbarItem(id: "Draw", placement: .primaryAction) {
            DrawButtonView(state: state)
                .disabled(state.fileURL == nil)
        }
        

    }
}
