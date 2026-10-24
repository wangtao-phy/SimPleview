import CoreGraphics
import Foundation
@preconcurrency import PDFKit

/// 只分析独立页面的矢量边框；不渲染、不做 OCR，也不把单独横线猜成表单。
/// PDF 的裁剪路径不等于可见边框：只有实际描边或填充的细矩形才参加闭合判断。
nonisolated enum PDFFormGeometry {
    private struct Edge {
        var axis: CGFloat
        var lower: CGFloat
        var upper: CGFloat
    }
    private struct Graphics {
        var transform = CGAffineTransform.identity
        var clip: CGRect
        var width: CGFloat = 1
        var fill: Bool = true
        var stroke: Bool = true
        var fillComponents = 1
        var strokeComponents = 1
        var fillAlpha: CGFloat = 1
        var strokeAlpha: CGFloat = 1
    }
    private final class Context {
        var horizontal: [Edge] = []
        var vertical: [Edge] = []
        var obstacles: [CGRect] = []
        var operations = 0
        var failed = false
        var graphics: Graphics
        var stack: [Graphics] = []
        var segments: [(CGPoint, CGPoint)] = []
        var rectangles: [CGRect] = []
        var point = CGPoint.zero
        var start = CGPoint.zero
        var pathBounds = CGRect.null
        var curved = false
        var pendingClip = false

        init(graphics: Graphics) { self.graphics = graphics }
        static func take(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) -> Context? {
            guard let info else { return nil }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            context.operations += 1
            if Task.isCancelled || context.operations > 100_000 ||
                context.horizontal.count + context.vertical.count > 2_048 ||
                context.obstacles.count > 1_024 ||
                context.segments.count + context.rectangles.count > 4_096 {
                context.failed = true
                CGPDFScannerStop(scanner)
                return nil
            }
            return context
        }
        func include(_ point: CGPoint) { pathBounds = pathBounds.union(CGRect(origin: point, size: .zero)) }
        func line(to next: CGPoint) { segments.append((point, next)); include(next); point = next }
        func edge(_ first: CGPoint, _ last: CGPoint) {
            let clip = graphics.clip.insetBy(dx: -0.8, dy: -0.8)
            guard clip.contains(first), clip.contains(last) else { return }
            if abs(first.y - last.y) < 0.2, abs(first.x - last.x) >= 12 {
                horizontal.append(Edge(axis: (first.y + last.y) / 2,
                    lower: min(first.x, last.x), upper: max(first.x, last.x)))
            } else if abs(first.x - last.x) < 0.2, abs(first.y - last.y) >= 12 {
                vertical.append(Edge(axis: (first.x + last.x) / 2,
                    lower: min(first.y, last.y), upper: max(first.y, last.y)))
            }
        }
        func obstacle(_ bounds: CGRect) {
            let visible = bounds.intersection(graphics.clip)
            if !visible.isNull, !visible.isEmpty { obstacles.append(visible) }
        }
        func finish(fill: Bool, stroke: Bool) {
            if fill && graphics.fill && graphics.fillAlpha > 0.01 {
                for rectangle in rectangles {
                    // Word 等生成器常把表格边框写成 0.5pt 左右的填充矩形。
                    if rectangle.height <= 3 && rectangle.width >= 12 {
                        edge(CGPoint(x: rectangle.minX, y: rectangle.midY), CGPoint(x: rectangle.maxX, y: rectangle.midY))
                    } else if rectangle.width <= 3 && rectangle.height >= 12 {
                        edge(CGPoint(x: rectangle.midX, y: rectangle.minY), CGPoint(x: rectangle.midX, y: rectangle.maxY))
                    } else { obstacle(rectangle) }
                }
                if !segments.isEmpty || curved { obstacle(pathBounds) }
            }
            if stroke && graphics.stroke && graphics.strokeAlpha > 0.01 {
                let scale = max(hypot(graphics.transform.a, graphics.transform.b), hypot(graphics.transform.c, graphics.transform.d))
                if curved || graphics.width * scale > 3 || segments.contains(where: {
                    abs($0.0.x - $0.1.x) > 0.2 && abs($0.0.y - $0.1.y) > 0.2
                }) { obstacle(pathBounds) }
                else {
                    for (first, last) in segments { edge(first, last) }
                    for rectangle in rectangles {
                        edge(CGPoint(x: rectangle.minX, y: rectangle.minY), CGPoint(x: rectangle.maxX, y: rectangle.minY))
                        edge(CGPoint(x: rectangle.minX, y: rectangle.maxY), CGPoint(x: rectangle.maxX, y: rectangle.maxY))
                        edge(CGPoint(x: rectangle.minX, y: rectangle.minY), CGPoint(x: rectangle.minX, y: rectangle.maxY))
                        edge(CGPoint(x: rectangle.maxX, y: rectangle.minY), CGPoint(x: rectangle.maxX, y: rectangle.maxY))
                    }
                }
            }
            if pendingClip {
                // 非矩形裁剪的内部不能仅凭外接矩形推断可见性，保守停止此绘图状态。
                graphics.clip = rectangles.count == 1 && segments.isEmpty && !curved
                    ? graphics.clip.intersection(rectangles[0]) : .null
            }
            segments.removeAll(keepingCapacity: true); rectangles.removeAll(keepingCapacity: true)
            pathBounds = .null; curved = false; pendingClip = false
        }
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = [CGPDFReal](repeating: 0, count: count)
        for index in (0..<count).reversed() {
            guard CGPDFScannerPopNumber(scanner, &values[index]), values[index].isFinite else { return nil }
        }
        return values
    }
    private static func name(_ scanner: CGPDFScannerRef) -> String? {
        var value: UnsafePointer<CChar>?
        return CGPDFScannerPopName(scanner, &value) ? value.map(String.init(cString:)) : nil
    }
    private static func color(_ scanner: CGPDFScannerRef, count: Int) -> Bool {
        guard count > 0, let values = numbers(scanner, count) else { return false }
        if count == 4 { return values[3] > 0.02 || values.prefix(3).contains { $0 > 0.02 } }
        return values.contains { $0 < 0.98 }
    }
    private static func components(_ scanner: CGPDFScannerRef) -> Int {
        guard let value = name(scanner) else { return 0 }
        func count(_ value: String) -> Int {
            switch value {
            case "DeviceGray", "CalGray": return 1
            case "DeviceRGB", "CalRGB": return 3
            case "DeviceCMYK": return 4
            default: return 0
            }
        }
        if count(value) > 0 { return count(value) }
        guard let resource = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ColorSpace", value) else { return 0 }
        var directName: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(resource, .name, &directName), let directName { return count(String(cString: directName)) }
        var array: CGPDFArrayRef?, kind: UnsafePointer<CChar>?
        guard CGPDFObjectGetValue(resource, .array, &array), let array,
              CGPDFArrayGetName(array, 0, &kind), let kind else { return 0 }
        let type = String(cString: kind)
        if count(type) > 0 { return count(type) }
        // PDFKit 单页快照通常把颜色改写为 /Cs1 等 ICC 资源，不能只认设备名称。
        // 仅解释具有确定设备分量的常见空间，图案/专色不凭操作数猜颜色。
        var profile: CGPDFStreamRef?, amount: CGPDFInteger = 0
        guard type == "ICCBased", CGPDFArrayGetStream(array, 1, &profile), let profile,
              let dictionary = CGPDFStreamGetDictionary(profile),
              CGPDFDictionaryGetInteger(dictionary, "N", &amount), [1, 3, 4].contains(amount) else { return 0 }
        return amount
    }
    private static func table() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
            guard let c = Context.take(scanner, info) else { return }
            guard c.stack.count < 64 else { c.failed = true; CGPDFScannerStop(scanner); return }
            c.stack.append(c.graphics)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
            guard let c = Context.take(scanner, info), let saved = c.stack.popLast() else { return }
            c.graphics = saved
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let c = Context.take(scanner, info), let n = PDFFormGeometry.numbers(scanner, 6) else { return }
            let transform = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(c.graphics.transform)
            guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite) else {
                c.failed = true; CGPDFScannerStop(scanner); return
            }
            c.graphics.transform = transform
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            guard let c = Context.take(scanner, info), let n = PDFFormGeometry.numbers(scanner, 1) else { return }
            c.graphics.width = max(0, n[0])
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let c = Context.take(scanner, info), let n = PDFFormGeometry.numbers(scanner, 2) else { return }
            c.point = CGPoint(x: n[0], y: n[1]).applying(c.graphics.transform)
            c.start = c.point; c.include(c.point)
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let c = Context.take(scanner, info), let n = PDFFormGeometry.numbers(scanner, 2) else { return }
            c.line(to: CGPoint(x: n[0], y: n[1]).applying(c.graphics.transform))
        }
        CGPDFOperatorTableSetCallback(table, "h") { scanner, info in
            guard let c = Context.take(scanner, info) else { return }; c.line(to: c.start)
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let c = Context.take(scanner, info), let n = PDFFormGeometry.numbers(scanner, 4) else { return }
            let transform = c.graphics.transform
            let rectangle = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).applying(transform)
            if abs(transform.b) < 0.001 && abs(transform.c) < 0.001 || abs(transform.a) < 0.001 && abs(transform.d) < 0.001 {
                c.rectangles.append(rectangle); c.pathBounds = c.pathBounds.union(rectangle)
            } else { c.curved = true; c.pathBounds = c.pathBounds.union(rectangle) }
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let c = Context.take(scanner, info), let n = PDFFormGeometry.numbers(scanner, 6) else { return }
            c.curved = true
            for index in stride(from: 0, to: 6, by: 2) {
                c.point = CGPoint(x: n[index], y: n[index + 1]).applying(c.graphics.transform); c.include(c.point)
            }
        }
        let curve: CGPDFOperatorCallback = { scanner, info in
            guard let c = Context.take(scanner, info), let n = PDFFormGeometry.numbers(scanner, 4) else { return }
            c.curved = true
            for index in stride(from: 0, to: 4, by: 2) {
                c.point = CGPoint(x: n[index], y: n[index + 1]).applying(c.graphics.transform); c.include(c.point)
            }
        }
        for op in ["v", "y"] { CGPDFOperatorTableSetCallback(table, op, curve) }
        let clip: CGPDFOperatorCallback = { scanner, info in
            guard let c = Context.take(scanner, info) else { return }; c.pendingClip = true
        }
        for op in ["W", "W*"] { CGPDFOperatorTableSetCallback(table, op, clip) }
        CGPDFOperatorTableSetCallback(table, "n") { scanner, info in Context.take(scanner, info)?.finish(fill: false, stroke: false) }
        let fill: CGPDFOperatorCallback = { scanner, info in Context.take(scanner, info)?.finish(fill: true, stroke: false) }
        for op in ["f", "F", "f*"] { CGPDFOperatorTableSetCallback(table, op, fill) }
        let stroke: CGPDFOperatorCallback = { scanner, info in Context.take(scanner, info)?.finish(fill: false, stroke: true) }
        CGPDFOperatorTableSetCallback(table, "S", stroke)
        CGPDFOperatorTableSetCallback(table, "s") { scanner, info in
            guard let c = Context.take(scanner, info) else { return }
            if !c.segments.isEmpty { c.line(to: c.start) }
            c.finish(fill: false, stroke: true)
        }
        let both: CGPDFOperatorCallback = { scanner, info in Context.take(scanner, info)?.finish(fill: true, stroke: true) }
        for op in ["B", "B*"] { CGPDFOperatorTableSetCallback(table, op, both) }
        let closeBoth: CGPDFOperatorCallback = { scanner, info in
            guard let c = Context.take(scanner, info) else { return }
            if !c.segments.isEmpty { c.line(to: c.start) }
            c.finish(fill: true, stroke: true)
        }
        for op in ["b", "b*"] { CGPDFOperatorTableSetCallback(table, op, closeBoth) }
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.fill = PDFFormGeometry.color(scanner, count: 1); c.graphics.fillComponents = 1 }
        CGPDFOperatorTableSetCallback(table, "G") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.stroke = PDFFormGeometry.color(scanner, count: 1); c.graphics.strokeComponents = 1 }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.fill = PDFFormGeometry.color(scanner, count: 3); c.graphics.fillComponents = 3 }
        CGPDFOperatorTableSetCallback(table, "RG") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.stroke = PDFFormGeometry.color(scanner, count: 3); c.graphics.strokeComponents = 3 }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.fill = PDFFormGeometry.color(scanner, count: 4); c.graphics.fillComponents = 4 }
        CGPDFOperatorTableSetCallback(table, "K") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.stroke = PDFFormGeometry.color(scanner, count: 4); c.graphics.strokeComponents = 4 }
        CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.fillComponents = PDFFormGeometry.components(scanner); c.graphics.fill = false }
        CGPDFOperatorTableSetCallback(table, "CS") { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.strokeComponents = PDFFormGeometry.components(scanner); c.graphics.stroke = false }
        let sc: CGPDFOperatorCallback = { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.fill = PDFFormGeometry.color(scanner, count: c.graphics.fillComponents) }
        let SC: CGPDFOperatorCallback = { scanner, info in guard let c = Context.take(scanner, info) else { return }; c.graphics.stroke = PDFFormGeometry.color(scanner, count: c.graphics.strokeComponents) }
        for op in ["sc", "scn"] { CGPDFOperatorTableSetCallback(table, op, sc) }
        for op in ["SC", "SCN"] { CGPDFOperatorTableSetCallback(table, op, SC) }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            guard let c = Context.take(scanner, info), let key = PDFFormGeometry.name(scanner),
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", key) else { return }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return }
            var alpha: CGPDFReal = 1
            if CGPDFDictionaryGetNumber(dictionary, "ca", &alpha) { c.graphics.fillAlpha = alpha }
            if CGPDFDictionaryGetNumber(dictionary, "CA", &alpha) { c.graphics.strokeAlpha = alpha }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let c = Context.take(scanner, info), let key = PDFFormGeometry.name(scanner),
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", key) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            if String(cString: subtype) == "Image" {
                c.obstacle(CGRect(x: 0, y: 0, width: 1, height: 1).applying(c.graphics.transform))
            } else {
                // 未展开的 Form/图形不当作空白内容。常见图片和嵌套图形均保留原件。
                var box: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "BBox", &box), let box, CGPDFArrayGetCount(box) == 4 {
                    var values = [CGPDFReal](repeating: 0, count: 4)
                    guard (0..<4).allSatisfy({ CGPDFArrayGetNumber(box, $0, &values[$0]) && values[$0].isFinite }) else {
                        c.obstacle(c.graphics.clip); return
                    }
                    do {
                        var transform = c.graphics.transform, matrix: CGPDFArrayRef?
                        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix {
                            var n = [CGPDFReal](repeating: 0, count: 6)
                            guard CGPDFArrayGetCount(matrix) == 6,
                                  (0..<6).allSatisfy({ CGPDFArrayGetNumber(matrix, $0, &n[$0]) && n[$0].isFinite }) else {
                                c.obstacle(c.graphics.clip); return
                            }
                            transform = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(transform)
                        }
                        c.obstacle(CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1]).applying(transform))
                    }
                } else { c.obstacle(c.graphics.clip) }
            }
        }
        // 文本操作也计入预算，巨大/异常页面不会让新增分析无限运行。
        let count: CGPDFOperatorCallback = { scanner, info in _ = Context.take(scanner, info) }
        for op in ["BT", "ET", "Tj", "TJ", "'", "\"", "Td", "TD", "Tm", "T*", "Tf", "Tc", "Tw", "Tz", "TL", "Tr", "Ts", "d", "J", "j", "M", "ri", "i"] {
            CGPDFOperatorTableSetCallback(table, op, count)
        }
        let unknownImage: CGPDFOperatorCallback = { scanner, info in
            guard let c = Context.take(scanner, info) else { return }; c.obstacle(c.graphics.clip)
        }
        for op in ["sh", "BI", "ID", "EI"] { CGPDFOperatorTableSetCallback(table, op, unknownImage) }
        return table
    }

    private static func merged(_ edges: [Edge]) -> [Edge] {
        var groups: [[Edge]] = []
        for edge in edges.sorted(by: { $0.axis < $1.axis }) {
            if let last = groups.last, abs(last[0].axis - edge.axis) <= 0.8 {
                groups[groups.count - 1].append(edge)
            } else { groups.append([edge]) }
        }
        var result: [Edge] = []
        for group in groups {
            var joined: [Edge] = []
            for edge in group.sorted(by: { $0.lower < $1.lower }) {
                if let last = joined.last, edge.lower <= last.upper + 1 {
                    joined[joined.count - 1].upper = max(last.upper, edge.upper)
                } else { joined.append(Edge(axis: group[0].axis, lower: edge.lower, upper: edge.upper)) }
            }
            result.append(contentsOf: joined)
        }
        return result
    }

    static func candidates(on page: PDFPage) -> [PDFFormDetection.Candidate] {
        guard !Task.isCancelled, let reference = page.pageRef, let table = table() else { return [] }
        let bounds = page.bounds(for: .cropBox)
        let context = Context(graphics: Graphics(clip: bounds))
        let scanner = CGPDFScannerCreate(CGPDFContentStreamCreateWithPage(reference), table,
            Unmanaged.passUnretained(context).toOpaque())
        guard CGPDFScannerScan(scanner), !context.failed, !Task.isCancelled,
              context.horizontal.count + context.vertical.count <= 2_048, context.obstacles.count <= 1_024 else { return [] }
        let horizontal = merged(context.horizontal).sorted { $0.axis > $1.axis }
        let vertical = merged(context.vertical)
        var result: [PDFFormDetection.Candidate] = []
        var comparisons = 0, cells = 0
        for top in horizontal {
            guard !Task.isCancelled else { return [] }
            let sides = vertical.filter { $0.axis >= top.lower - 1 && $0.axis <= top.upper + 1 &&
                $0.upper >= top.axis - 1 && $0.lower < top.axis - 10 }.sorted { $0.axis < $1.axis }
            for (left, right) in zip(sides, sides.dropFirst()) {
                let width = right.axis - left.axis
                guard width >= 24, width <= bounds.width * 0.95 else { continue }
                var lowerEdge: Edge?
                for edge in horizontal {
                    comparisons += 1
                    guard comparisons <= 100_000, !Task.isCancelled else { return [] }
                    if edge.axis < top.axis - 12 && edge.lower <= left.axis + 1 && edge.upper >= right.axis - 1 &&
                        left.lower <= edge.axis + 1 && right.lower <= edge.axis + 1 {
                        lowerEdge = edge; break
                    }
                }
                guard let bottom = lowerEdge else { continue }
                let cell = CGRect(x: left.axis, y: bottom.axis, width: width, height: top.axis - bottom.axis)
                guard cell.height <= bounds.height * 0.5, cell.width * cell.height <= bounds.width * bounds.height * 0.3 else { continue }
                cells += 1
                guard cells <= 512, !Task.isCancelled else { return [] }
                var input = cell.insetBy(dx: 4, dy: min(3, cell.height * 0.12))
                // 格内若还有分隔线或其它矢量线条，不能把图形/合并格外框当成空格。
                guard !horizontal.contains(where: { input.minY < $0.axis && $0.axis < input.maxY &&
                    min(input.maxX, $0.upper) - max(input.minX, $0.lower) > 4 }),
                      !vertical.contains(where: { input.minX < $0.axis && $0.axis < input.maxX &&
                    min(input.maxY, $0.upper) - max(input.minY, $0.lower) > 4 }) else { continue }
                guard !context.obstacles.contains(where: { $0.intersects(input) }) else { continue }
                let selection = page.selection(for: input)
                let text = (selection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    // 带 1)、2) 等题号的回答框仍是空格；输入区避开题号，不覆盖原字。
                    guard let selection, text.range(of: "^[0-9]{1,3}[).:]$", options: .regularExpression) != nil else { continue }
                    input.origin.x = max(input.minX, selection.bounds(for: page).maxX + 4)
                    input.size.width = cell.maxX - 4 - input.minX
                }
                guard input.width >= 24, input.height >= 10 else { continue }
                result.append(PDFFormDetection.Candidate(bounds: input, fontSize: min(12, max(6, input.height * 0.8)),
                    legacyIndex: nil, text: "", isMultiline: input.height >= 40))
                if result.count >= 256 { return result }
            }
        }
        return result
    }
}
