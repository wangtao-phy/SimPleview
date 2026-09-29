import PDFKit
import PencilKit

extension VectorInk {
    /// Mac 的 InkList 本来就是矢量。将其提升为与 iPad 相同的原生笔迹，
    /// 不截图，也不按像素密度插点；只接收本应用可验证的等宽折线笔。
    static func standardDrawing(in annotation: PDFAnnotation, pageBounds: CGRect) -> PKDrawing? {
        guard annotation.type == "Ink", annotation.shouldDisplay,
              !(annotation.userName ?? "").hasPrefix("S-"),
              annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/SimPlePath")) is String,
              let width = annotation.border?.lineWidth, width.isFinite, width > 0, width < 10_000 else { return nil }
        var polylines: [[CGPoint]] = [], valid = true, count = 0
        if let paths = annotation.paths, !paths.isEmpty {
            for path in paths {
                var points: [CGPoint] = []
                path.cgPath.applyWithBlock { item in
                    guard valid else { return }
                    let element = item.pointee
                    switch element.type {
                    case .moveToPoint, .addLineToPoint:
                        if element.type == .moveToPoint, !points.isEmpty { polylines.append(points); points = [] }
                        let local = element.points[0]
                        let point = CGPoint(x: local.x + annotation.bounds.minX, y: local.y + annotation.bounds.minY)
                        count += 1
                        guard count <= 100_000, finite(point) else { valid = false; return }
                        points.append(point)
                    default:
                        // 不能把未知曲线或闭合填充悄悄改成折线；保留原标注外观。
                        valid = false
                    }
                }
                if !points.isEmpty { polylines.append(points) }
            }
        } else {
            // 兼容早期 Mac 只保存页坐标文本的手绘。拒绝部分解析，避免缺笔。
            var text = ""
            for index in 0..<1024 {
                let key = PDFAnnotationKey(rawValue: index == 0 ? "/SimPlePath" : "/SimPlePath\(index)")
                guard let chunk = annotation.value(forAnnotationKey: key) as? String else { break }
                guard text.utf8.count + chunk.utf8.count <= 8_000_000 else { return nil }
                text += chunk
            }
            var points: [CGPoint] = []
            for token in text.split(separator: ";") {
                let values = token.split(separator: ",")
                let offset = values.count == 3 ? 1 : 0
                guard values.count == 2 || (values.count == 3 && ["M", "L"].contains(String(values[0]))),
                      let x = Double(values[offset]), let y = Double(values[offset + 1]) else { return nil }
                let point = CGPoint(x: x, y: y)
                count += 1
                guard count <= 100_000, finite(point) else { return nil }
                if offset == 1, values[0] == "M", !points.isEmpty { polylines.append(points); points = [] }
                points.append(point)
            }
            if !points.isEmpty { polylines.append(points) }
        }
        guard valid, !polylines.isEmpty, finite(pageBounds.origin),
              pageBounds.width.isFinite, pageBounds.height.isFinite else { return nil }
        let opacity = (annotation.value(forAnnotationKey: opacityKey) as? NSNumber)?.doubleValue
            ?? Double(annotation.color.cgColor.alpha)
        guard opacity.isFinite, (0...1).contains(opacity) else { return nil }
        guard let transform = storedTransform(in: annotation) else { return nil }
        let inverse = transform.inverted(), sourceWidth = width / hypot(transform.a, transform.b)
        guard sourceWidth.isFinite, sourceWidth > 0, sourceWidth < 10_000 else { return nil }
        let localLines = polylines.map { points in
            points.map { CGPoint(x: $0.x - pageBounds.minX, y: pageBounds.maxY - $0.y).applying(inverse) }
        }
        guard localLines.allSatisfy({ $0.allSatisfy(finite) }) else { return nil }
        let ink = PKInk(.monoline, color: annotation.color.withAlphaComponent(CGFloat(opacity)))
        let date = annotation.modificationDate ?? Date(timeIntervalSince1970: 0)
        let strokes = localLines.map { points in
            var controls: [PKStrokePoint] = []
            controls.reserveCapacity(points.count * 3)
            for location in points {
                // PencilKit 使用三次均匀 B 样条。每个折线顶点重复三次，
                // 相邻顶点间仍是原来的直线，转角不被样条平滑、也不发生过冲。
                for _ in 0..<3 {
                    controls.append(PKStrokePoint(location: location, timeOffset: Double(controls.count) / 120,
                        size: CGSize(width: sourceWidth, height: sourceWidth), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                }
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: date), transform: transform)
        }
        return PKDrawing(strokes: strokes)
    }

    private static func storedTransform(in annotation: PDFAnnotation) -> CGAffineTransform? {
        guard let value = annotation.value(forAnnotationKey: transformKey) else { return .identity }
        guard let text = value as? String, text.utf8.count <= 512 else { return nil }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { Double($0) }
        guard parts.count == 6, values.count == 6, values.allSatisfy(\.isFinite) else { return nil }
        let t = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        let sx = hypot(t.a, t.b), sy = hypot(t.c, t.d)
        guard sx > 0, abs(sx - sy) < 0.001, abs(t.a * t.c + t.b * t.d) < 0.001,
              (t.a * t.d - t.b * t.c).isFinite, t.a * t.d - t.b * t.c != 0 else { return nil }
        return t
    }

    /// 本导入器生成的等宽折线可以仅凭 InkList 按原生坐标精度重建，不必再存一份
    /// PKDrawing 附件。只接受完整三重顶点及固定笔刷参数，其他原生笔迹仍保留附件。
    static func linearPoints(of stroke: PKStroke) -> [CGPoint]? {
        let path = stroke.path
        guard stroke.mask == nil, path.count > 0, path.count.isMultiple(of: 3) else { return nil }
        let size = path[0].size
        guard size.width == size.height else { return nil }
        var vertices: [CGPoint] = []
        for first in stride(from: 0, to: path.count, by: 3) {
            let location = path[first].location
            for index in first..<(first + 3) {
                let point = path[index]
                guard point.location == location, point.size == size,
                      abs(point.opacity - 1) < 0.0001, abs(point.force - 1) < 0.0001,
                      abs(point.azimuth) < 0.0001,
                      abs(point.altitude - .pi / 2) < 0.0001 else { return nil }
            }
            vertices.append(location)
        }
        return vertices
    }

    private static func finite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) < 1_000_000 && abs(point.y) < 1_000_000
    }
}
