import Foundation
import CoreGraphics
@preconcurrency import PDFKit

/// 只分析后台独占的页面副本。已有标准字段、Apple 明确的表单提示和连续下划线
/// 各自处理，不把普通横线、表格边框或正文省略号猜成输入框。
nonisolated enum PDFFormDetection {
    struct Candidate: Sendable {
        let bounds: CGRect
        let fontSize: CGFloat
        let legacyIndex: Int?
        /// nil 表示旧提示的可见内容无法可靠恢复；主线程必须保留它，不能覆盖。
        let text: String?
        var isMultiline = false
    }

    struct Input: Sendable {
        let page: PDFPageRenderInput
        let hints: [Candidate]
    }

    /// PDFKit 的单页导出会丢掉 Apple 自定义表单键。先从活动页抽取只读值，
    /// 再生成单页快照；不把活动 PDFPage/Annotation 传给后台，也不重绘未知外观。
    @MainActor static func capture(_ page: PDFPage, source: PDFRenderSource?) -> Input? {
        guard !Task.isCancelled else { return nil }
        let annotations = page.annotations
        var hints: [Candidate] = []
        for (index, annotation) in annotations.enumerated() {
            guard !Task.isCancelled else { return nil }
            guard annotation.type == "FreeText",
                  (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/AAPL:SFF")) as? NSNumber)?.boolValue == true,
                  valid(annotation.bounds) else { continue }
            let bounds = annotation.bounds
            let contents = annotation.contents
            let text: String?
            if let contents, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = contents
            } else {
                // 归档中的占位字符（例如 a）不是可见答案；只接受已证明为空的 AP。
                // 非空/未知 AP 或另有富文本时返回 nil，后续必须保留旧提示。
                text = emptyAppearance(at: index, matching: bounds, page: page) ? "" : nil
            }
            let fontSize = min(annotation.font?.pointSize ?? bounds.height * 0.8, bounds.height * 0.8)
            hints.append(Candidate(bounds: bounds, fontSize: max(4, min(24, fontSize)),
                                   legacyIndex: index, text: text))
        }
        guard !Task.isCancelled, let snapshot = PDFPageRenderInput.capture(page, source: source) else { return nil }
        return Input(page: snapshot, hints: hints)
    }

    static func candidates(input: Input) -> [Candidate] {
        autoreleasepool {
            guard !Task.isCancelled, let document = PDFDocument(data: input.page.data),
                  input.page.index >= 0, input.page.index < document.pageCount,
                  let page = document.page(at: input.page.index), !document.isLocked else { return [] }
            // 缓存页面固有的填空几何。当前 Widget 的覆盖在显示/点击时判断，
            // 避免字段删除或撤销后，这个位置永远留在旧的“已占用”缓存中。
            var occupied: [CGRect] = []
            var result: [Candidate] = []
            for hint in input.hints {
                guard !Task.isCancelled else { return [] }
                guard valid(hint.bounds), !covered(hint.bounds, by: occupied) else { continue }
                result.append(hint)
                occupied.append(hint.bounds)
            }
            guard !Task.isCancelled else { return [] }
            let text = page.string ?? ""
            let matches = (try? NSRegularExpression(pattern: "_{3,}"))?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            for match in matches {
                guard !Task.isCancelled else { return [] }
                guard let selection = page.selection(for: match.range) else { continue }
                for line in selection.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    guard valid(bounds), !covered(bounds, by: occupied) else { continue }
                    result.append(Candidate(bounds: bounds, fontSize: max(4, min(24, bounds.height * 0.8)),
                                            legacyIndex: nil, text: ""))
                    occupied.append(bounds)
                }
            }
            for candidate in PDFFormGeometry.candidates(on: page) {
                guard !Task.isCancelled else { return [] }
                guard !covered(candidate.bounds, by: occupied) else { continue }
                result.append(candidate)
                occupied.append(candidate.bounds)
            }
            return Task.isCancelled ? [] : readingOrder(result)
        }
    }

    private static func valid(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite && bounds.maxX.isFinite && bounds.maxY.isFinite
            && bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }

    private static func covered(_ bounds: CGRect, by regions: [CGRect]) -> Bool {
        let area = bounds.width * bounds.height
        return regions.contains {
            let overlap = bounds.intersection($0)
            let otherArea = $0.width * $0.height
            // 较小的系统提示位于大格子内时也算同一位置，不能再叠加一个大字段。
            return otherArea > 0 && !overlap.isNull && overlap.width * overlap.height >= min(area, otherArea) * 0.5
        }
    }

    /// PDFKit 与底层 Annots 必须在索引、类型和矩形上完全对应。若解析器重新排序
    /// 或对象不一致，就放弃“空”的推断，不能误删同位置的其它旧标注。
    @MainActor private static func emptyAppearance(at index: Int, matching bounds: CGRect, page: PDFPage) -> Bool {
        guard let reference = page.pageRef, let dictionary = reference.dictionary else { return false }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array,
              index < CGPDFArrayGetCount(array) else { return false }
        var annotation: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(array, index, &annotation), let annotation else { return false }
        var richText: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(annotation, "RC", &richText) else { return false }
        var subtype: UnsafePointer<CChar>?
        var rectangle: CGPDFArrayRef?
        guard CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "FreeText",
              CGPDFDictionaryGetArray(annotation, "Rect", &rectangle), let rectangle,
              CGPDFArrayGetCount(rectangle) == 4 else { return false }
        var coordinates = [CGPDFReal](repeating: 0, count: 4)
        for axis in 0..<4 {
            guard CGPDFArrayGetNumber(rectangle, axis, &coordinates[axis]) else { return false }
        }
        let expected = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]
        guard zip(coordinates, expected).allSatisfy({ abs($0 - $1) < 0.01 }) else { return false }
        var appearance: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        guard CGPDFDictionaryGetDictionary(annotation, "AP", &appearance), let appearance,
              CGPDFDictionaryGetStream(appearance, "N", &stream), let stream,
              let data = CGPDFStreamCopyData(stream, &format),
              let source = String(data: data as Data, encoding: .ascii) else { return false }
        var balance = 0
        for token in source.split(whereSeparator: \.isWhitespace) {
            if token == "q" { balance += 1 }
            else if token == "Q", balance > 0 { balance -= 1 }
            else { return false }
        }
        return balance == 0
    }

    /// 先按纵坐标分行，再在同一行内由左至右；避免浮点高度的小差异把两栏填空交错。
    private static func readingOrder(_ candidates: [Candidate]) -> [Candidate] {
        let vertical = candidates.sorted { $0.bounds.midY > $1.bounds.midY }
        var rows: [[Candidate]] = []
        for candidate in vertical {
            if let anchor = rows.last?.first,
               abs(anchor.bounds.midY - candidate.bounds.midY) <= max(2, min(anchor.bounds.height, candidate.bounds.height) * 0.3) {
                rows[rows.count - 1].append(candidate)
            } else { rows.append([candidate]) }
        }
        return rows.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }
}
