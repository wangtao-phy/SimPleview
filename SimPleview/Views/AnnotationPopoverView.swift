import SwiftUI
import PDFKit
import Combine

#if os(macOS)
/// [教程注释：悬浮气泡视图 (AnnotationPopoverView)]
/// 当用户在 PDF 页面上点击标注时，这个视图会被包装在原生的 NSPopover 中弹出来。
/// 这样用户就可以在原位“所见即所得”地修改这个标注的备注，不需要把鼠标长途跋涉移到左侧边栏。
struct AnnotationPopoverView: View {
    let annotation: PDFAnnotation
    let onContentsChanged: (PDFAnnotation, String) -> Void
    
    @State private var text: String
    @State private var isSyncing = false
    
    init(annotation: PDFAnnotation, onContentsChanged: @escaping (PDFAnnotation, String) -> Void) {
        self.annotation = annotation
        self.onContentsChanged = onContentsChanged
        // [核心修复]：必须在初始化时直接赋予真实值，而不能等于 ""！
        // 否则 SwiftUI 的 onReceive 会在视图刚挂载（onAppear 还没来得及运行）的瞬间，
        // 带着默认的 "" 触发第一次回调，直接把底层数据全部清空！
        self._text = State(initialValue: annotation.simPleNote)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // [顶部元数据信息栏]
            HStack(spacing: 8) {
                // 颜色指示圆点
                Circle()
                    .fill(Color(annotation.color))
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                
                // 标注类型文本（高亮、下划线等）
                Text(annotation.typeDisplay)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // 页码提示
                if let page = annotation.page, let index = page.document?.index(for: page) {
                    Text("P\(index + 1)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(6)
                }
            }
            
            Divider()
            
            // [备注输入框：使用原生 TextEditor 解决对齐和字体过大的问题]
            TextEditor(text: $text)
                .font(.system(size: 13, weight: .regular))
                .scrollContentBackground(.hidden) // 隐藏原生的白色滚动背景，透出 NSPopover 的高斯模糊材质
                .padding(4)
                .background(Color.clear) // 保证完全透明
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1) // 边框也稍微调淡一点，更显原生
                )
                .onDisappear {
                    // [节约模式下的防御性同步]
                    // 无论什么模式，关闭悬浮窗时都进行最后一次兜底同步
                    if text != annotation.simPleNote {
                        onContentsChanged(annotation, text)
                    }
                }
                .onReceive(Just(text)) { newValue in
                    // [P0修复] isSyncing 防护：阻断 onReceive→objectWillChange→body→onReceive 的潜在无限循环
                    guard !isSyncing else { return }
                    // 性能模式：极速实时同步（所见即所得）
                    if MemoryMode.current.policy.syncAnnotationsInRealtime {
                        if newValue != annotation.simPleNote {
                            isSyncing = true
                            onContentsChanged(annotation, newValue)
                            DispatchQueue.main.async { isSyncing = false }
                        }
                    }
                }
                .onAppear {
                    // 每次被赋予全新的 showID 时，触发 onAppear 强行抓取真实的 contents
                    text = annotation.simPleNote
                }
        }
        .padding(12)
        .frame(width: 280, height: 160, alignment: .top) // 根据用户要求：直接写死固定尺寸，杜绝动画测算造成的跳动
    }
}
#endif
