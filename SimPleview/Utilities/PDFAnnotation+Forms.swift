import PDFKit

extension PDFAnnotation {
    /// Widget 的 /T 是字段名，PDFKit 的普通批注 userName 可能始终返回 nil。
    /// 本应用生成字段用唯一字段名参与撤销，其他标注沿用原有批次。
    var historyIdentifier: String? {
        if type == "Widget", let fieldName, fieldName.hasPrefix("SimPleview.Form.") { return fieldName }
        return userName
    }

    /// Apple 的填表提示仍可能保存为 FreeText；保留其原生行为，避免当作用户批注改色或删除。
    var isFormFieldPresentation: Bool {
        let kind = (type ?? "").lowercased()
        return kind == "widget" || (kind == "freetext" &&
            (value(forAnnotationKey: PDFAnnotationKey(rawValue: "/AAPL:SFF")) as? NSNumber)?.boolValue == true)
    }
}
