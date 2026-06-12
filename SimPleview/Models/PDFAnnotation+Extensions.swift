import Foundation
import PDFKit

extension PDFAnnotation {
    /// 用于替代原生的 `contents` 属性。
    /// 因为只要 `contents` 有值，PDFKit 就会强制绘制一个原生的黄色便签小标记。
    /// 为了彻底隐藏该标记，我们将备注数据存在原生的 subject 字段中（通常不触发标记）。
    var simPleNote: String {
        get {
            if let subj = self.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj")) as? String, !subj.isEmpty {
                return subj
            }
            return self.contents ?? ""
        }
        set {
            if newValue.isEmpty {
                self.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj"))
            } else {
                self.setValue(newValue, forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj"))
            }
            // 关键：必须赋值 nil，彻底从 PDF 字典中抹去 contents 键
            self.contents = nil 
        }
    }
}
