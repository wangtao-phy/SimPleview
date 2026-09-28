import SwiftUI

/// 独立的系统表单不继承 PDF 页面的缩放、旋转或标注菜单锚点。
/// 草稿属于本次编辑，保存时才写回明确的标注目标。
struct AnnotationTextEditor: View {
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text: String

    init(request: AnnotationTextRequest, save: @escaping (String) -> Void) {
        self.save = save
        _text = State(initialValue: request.annotation?.contents ?? "")
    }
    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .focused($focused)
                .accessibilityLabel("笔记内容")
                .padding(16)
                .navigationTitle("添加文字")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save(text); dismiss() }
                    }
                }
        }
        .presentationSizing(.form)
        .task { focused = true }
    }
}
