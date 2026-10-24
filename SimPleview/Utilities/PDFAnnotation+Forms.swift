import PDFKit

extension PDFAnnotation {
    /// 只记录当前进程确实创建或核实过的字段；弱引用不延长文档与标注寿命。
    @MainActor private static let generatedFormFields = NSHashTable<PDFAnnotation>.weakObjects()

    @MainActor func markAppGeneratedFormField() {
        Self.generatedFormFields.add(self)
    }

    /// PDFKit 会把父字段的 /T、/FT 展平，而且读取 /Parent 仍可能返回 nil。
    /// 因此从文件读入的字段必须核对原始字典；无法确认的字段保留原文档上下文。
    @MainActor var isAppGeneratedFormField: Bool {
        guard type == "Widget", widgetFieldType == .text,
              let name = fieldName, name.hasPrefix("SimPleview.Form.") else { return false }
        if Self.generatedFormFields.contains(self) { return true }
        guard let dictionary = page?.pageRef?.dictionary else { return false }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return false }
        var matched = false
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var source: CGPDFDictionaryRef?, rawName: CGPDFStringRef?
            guard CGPDFArrayGetDictionary(annotations, index, &source), let source,
                  CGPDFDictionaryGetString(source, "T", &rawName), let rawName,
                  CGPDFStringCopyTextString(rawName) as String? == name else { continue }
            // 重复字段名无法与活动对象唯一对应，不能据此放行局部复制。
            guard !matched else { return false }
            var parent: CGPDFObjectRef?, kids: CGPDFObjectRef?
            var subtype: UnsafePointer<CChar>?, fieldType: UnsafePointer<CChar>?
            var rectangle: CGPDFArrayRef?
            guard !CGPDFDictionaryGetObject(source, "Parent", &parent),
                  !CGPDFDictionaryGetObject(source, "Kids", &kids),
                  CGPDFDictionaryGetName(source, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Widget",
                  CGPDFDictionaryGetName(source, "FT", &fieldType), let fieldType,
                  String(cString: fieldType) == "Tx",
                  CGPDFDictionaryGetArray(source, "Rect", &rectangle), let rectangle,
                  CGPDFArrayGetCount(rectangle) == 4 else { return false }
            let expected = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]
            for axis in 0..<4 {
                var coordinate: CGPDFReal = 0
                guard CGPDFArrayGetNumber(rectangle, axis, &coordinate),
                      abs(coordinate - expected[axis]) < 0.01 else { return false }
            }
            matched = true
        }
        return matched
    }

    @MainActor var requiresOriginalFormContext: Bool { type == "Widget" && !isAppGeneratedFormField }

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
