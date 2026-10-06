import SwiftUI
import PDFKit

/// 专门负责标注工具的工具栏组件（高亮、下划线、删除线和颜色）
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
                Button {
                    state.areAnnotationsVisible.toggle()
                } label: {
                    Image(systemName: state.areAnnotationsVisible ? "eye" : "eye.slash")
                }
                .help(state.areAnnotationsVisible ? state.L("Hide All Annotations") : state.L("Show All Annotations"))
                .accessibilityLabel(state.areAnnotationsVisible ? state.L("Hide All Annotations") : state.L("Show All Annotations"))
            }
            .disabled(state.fileURL == nil)
        }
    }
}
