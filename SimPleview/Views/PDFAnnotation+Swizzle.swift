import Foundation
import PDFKit
import ObjectiveC

/// 只在 CustomPDFView 的一次原生绘制调用内屏蔽将由我们矢量描边的批注。
/// 不改变 shouldDisplay、颜色或 InkList，保存/打印/其他 PDFView 仍使用标准外观。
/// 作用域在线程本地，嵌套绘制结束后恢复旧值，不能影响其他窗口或后台导出。
nonisolated enum VectorInkDrawingScope {
    private static let key = "com.simpleview.vectorInkDrawingScope"
    static let installed: Bool = {
        guard let original = class_getInstanceMethod(PDFAnnotation.self, #selector(PDFAnnotation.draw(with:in:))),
              let replacement = class_getInstanceMethod(PDFAnnotation.self, #selector(PDFAnnotation.simpleview_draw(with:in:))) else { return false }
        method_exchangeImplementations(original, replacement)
        return true
    }()

    static func perform(suppressing ids: Set<ObjectIdentifier>, body: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = ids
        defer {
            if let previous { dictionary[key] = previous }
            else { dictionary.removeObject(forKey: key) }
        }
        body()
    }

    static func suppresses(_ annotation: PDFAnnotation) -> Bool {
        (Thread.current.threadDictionary[key] as? Set<ObjectIdentifier>)?.contains(ObjectIdentifier(annotation)) == true
    }
}

extension PDFAnnotation {
    @objc dynamic nonisolated func simpleview_draw(with box: PDFDisplayBox, in context: CGContext) {
        // 不访问任何可变批注字段或 AppKit 路径，只按主线程快照里的对象标识判断。
        if VectorInkDrawingScope.suppresses(self) { return }
        // 交换实现之后，这个名字指向 PDFKit 原始实现。
        simpleview_draw(with: box, in: context)
    }
}
