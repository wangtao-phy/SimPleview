import PDFKit
import UIKit

/// 仅替换 PDF 正文的选字菜单，不修改搜索框、聊天输入框等控件的编辑菜单。
// UIKit 在主线程调用菜单委托；SDK 的 Objective-C 协议尚未标注 MainActor。
@MainActor final class ReadingPDFView: PDFView, @preconcurrency UIEditMenuInteractionDelegate {
    weak var session: NotebookSession?
    private lazy var annotationMenu = UIEditMenuInteraction(delegate: self)
    private var annotationActions: [UIMenuElement] = []
    private var annotationRect = CGRect.zero

    func showAnnotationMenu(in rect: CGRect, addText: @escaping () -> Void, delete: @escaping () -> Void) {
        if annotationMenu.view == nil { addInteraction(annotationMenu) }
        clearSelection()
        annotationRect = rect
        annotationActions = [
            UIAction(title: "添加文字") { _ in addText() },
            UIAction(title: "删除", attributes: .destructive) { _ in delete() }
        ]
        annotationMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: "annotation" as NSString,
            sourcePoint: CGPoint(x: rect.midX, y: rect.midY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: annotationActions)
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        annotationRect
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system === UIMenuSystem.context,
              let session, !session.isReadOnly,
              let selection = currentSelection, !(selection.string ?? "").isEmpty else { return }
        let items: [(String, PDFAnnotationSubtype)] = [
            ("高亮", .highlight), ("下划线", .underline), ("删除线", .strikeOut)
        ]
        let actions = items.map { title, type in
            UIAction(title: title) { [weak session] _ in session?.markSelection(type) }
        }
        // 使用自己的完整菜单，不依赖系统动作的私有 selector 或翻译后的标题。
        // 保留复制；查询、翻译、网页搜索等系统扩展不混入 PDF 标注菜单。
        let copy = UIAction(title: "复制") { [weak self] _ in self?.copy(nil) }
        builder.replaceChildren(ofMenu: .root) { _ in
            [UIMenu(options: .displayInline, children: actions + [copy])]
        }
    }
}
