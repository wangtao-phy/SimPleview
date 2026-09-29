import Foundation
import CoreGraphics
import PDFKit
import PencilKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 不可变的矢量快照，后台导出不读取活动画布。
nonisolated struct InkShape: @unchecked Sendable {
    let path: CGPath
    let transform: CGAffineTransform
    let color: CGColor
    let width: CGFloat
}

nonisolated enum VectorInk {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    static let idKey = PDFAnnotationKey(rawValue: "/SPVInkID")
    static let drawingKey = PDFAnnotationKey(rawValue: "/SPVPadDrawingV1")
    static let groupKey = PDFAnnotationKey(rawValue: "/SPVPadInkGroup")
    static let transformKey = PDFAnnotationKey(rawValue: "/SPVInkTransform")
    static let indexKey = PDFAnnotationKey(rawValue: "/SPVPadInkIndex")
    static let brushKey = PDFAnnotationKey(rawValue: "/SPVPadBrush")
    static let opacityKey = PDFAnnotationKey(rawValue: "/SimPleInkOpacity")

    static func drawing(in annotation: PDFAnnotation) throws -> PKDrawing? {
        guard let text = annotation.value(forAnnotationKey: drawingKey) as? String else { return nil }
        guard text.utf8.count <= 32*1024*1024, let data = Data(base64Encoded: text) else {
            throw Failure.message("笔迹编辑数据损坏或过大，已保留原 PDF。")
        }
        let drawing = try PKDrawing(data: data)
        guard annotation.value(forAnnotationKey: brushKey) as? String == "monoline" else {
            throw Failure.message("此笔迹来自尚不支持的编辑格式，保留 PDF 外观。")
        }
        // PencilKit 的序列化回读可能把 monoline 标成 pen。文件明确记录了
        // 经过导出校验的笔刷种类，只恢复这一种；不能把任意外部钢笔强制转成等宽笔。
        return PKDrawing(strokes: drawing.strokes.map { original in
            var stroke = original
            stroke.ink = PKInk(.monoline, color: original.ink.color)
            return stroke
        })
    }

    /// 首版限定原生等宽笔。沿原生曲线采样只用于可重建的 PDF 中心线；
    /// 原始控制点仍完整保存在 PKDrawing 中，不依赖图片或屏幕分辨率。
    static func shapes(from drawing: PKDrawing) throws -> [InkShape] {
        var result: [InkShape] = [], total = 0
        for stroke in drawing.strokes {
            guard stroke.ink.inkType == .monoline else { throw Failure.message("此笔刷尚未通过跨端验证，请使用实线笔。") }
            let t = stroke.transform
            let sx = hypot(t.a,t.b), sy = hypot(t.c,t.d)
            guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite), sx > 0,
                  abs(sx-sy) < 0.001, abs(t.a*t.c+t.b*t.d) < 0.001 else {
                throw Failure.message("笔迹包含尚不支持的非等比变形，已保留原文件。")
            }
            let path = CGMutablePath()
            // 已知为折线的原生笔迹直接导出原顶点，不重新采样，避免保存一轮
            // 就增加一批近共线点，也无需保存可以从这些顶点重建的编辑附件。
            if let points = linearPoints(of: stroke), let first = points.first {
                let width = stroke.path[0].size.width
                guard width.isFinite, width > 0, width < 10_000,
                      points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1_000_000 && abs($0.y) < 1_000_000 }) else {
                    throw Failure.message("笔迹包含无效坐标，已停止保存。")
                }
                total += points.count
                guard total <= 2_000_000 else { throw Failure.message("本页笔迹过于复杂，请分到更多页面。") }
                try Task.checkCancellation()
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.001, y: first.y)) }
                result.append(InkShape(path: path.copy()!, transform: t, color: stroke.ink.color.cgColor, width: width))
                continue
            }
            var width: CGFloat?
            // 原生整笔橡皮通常直接删除笔划；有遮罩时仅导出未被擦除的中心线区间。
            let ranges: [ClosedRange<CGFloat>?] = stroke.mask == nil ? [nil] : stroke.maskedPathRanges.map { $0.lowerBound...$0.upperBound }
            for range in ranges {
                var points: [CGPoint] = []
                for point in stroke.path.interpolatedPoints(in: range, by: .distance(0.35)) {
                    total += 1
                    if total.isMultiple(of: 1024) { try Task.checkCancellation() }
                    guard total <= 2_000_000 else { throw Failure.message("本页笔迹过于复杂，请分到更多页面。") }
                    let p = point.location, w = max(point.size.width,point.size.height)
                    guard p.x.isFinite, p.y.isFinite, w.isFinite, w > 0, w < 10000,
                          abs(p.x) < 1_000_000, abs(p.y) < 1_000_000 else { throw Failure.message("笔迹包含无效坐标，已停止保存。") }
                    if width == nil { width = w }
                    points.append(p)
                }
                let reduced = simplified(points, tolerance: min(0.025, (width ?? 1)/16))
                if let start = reduced.first { path.move(to:start) }
                for point in reduced.dropFirst() { path.addLine(to:point) }
                // PDF Ink 对单个点的支持不一致，用远低于像素尺度的短线保留点按。
                if reduced.count == 1, let start = reduced.first { path.addLine(to:CGPoint(x:start.x+0.001,y:start.y)) }
            }
            if let width { result.append(InkShape(path:path.copy()!,transform:t,color:stroke.ink.color.cgColor,width:width)) }
        }
        return result
    }

    /// 删除近共线采样点，最大偏差为 0.025 PDF 点（8 倍放大仅 0.2 像素）。
    /// 每 256 段独立简化，避免长而复杂的笔迹触发全局递归的二次方开销。
    /// 原生编辑数据保持原样，简化只作用于供其他阅读器显示的标准 InkList。
    private static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        for first in stride(from: 0, to: points.count-1, by: 256) {
            let last = min(first+256, points.count-1)
            keep[first] = true; keep[last] = true
            var ranges = [(first,last)]
            while let (a,b) = ranges.popLast() {
                guard b > a+1 else { continue }
                let dx = points[b].x-points[a].x, dy = points[b].y-points[a].y
                let length = dx*dx+dy*dy
                var largest = tolerance*tolerance, split: Int?
                for i in (a+1)..<b {
                    let x = points[i].x-points[a].x, y = points[i].y-points[a].y
                    let t = length > 0 ? min(1,max(0,(x*dx+y*dy)/length)) : 0
                    let distance = pow(x-t*dx,2)+pow(y-t*dy,2)
                    if distance > largest { largest = distance; split = i }
                }
                if let split { keep[split] = true; ranges.append((a,split)); ranges.append((split,b)) }
            }
        }
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }

    static func draw(_ shapes: [InkShape], pageBounds: CGRect, in context: CGContext) {
        context.saveGState()
        context.translateBy(x:pageBounds.minX,y:pageBounds.maxY)
        context.scaleBy(x:1,y:-1)
        for shape in shapes {
            context.saveGState(); context.concatenate(shape.transform)
            context.setStrokeColor(shape.color); context.setLineWidth(shape.width)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.addPath(shape.path); context.strokePath(); context.restoreGState()
        }
        context.restoreGState()
    }

    /// 两端共用标准 InkList 和原生编辑附件。空 SimPlePath 标记让 Mac
    /// 使用高清矢量覆盖层，其他 PDF 阅读器仍可直接显示标准笔迹。
    static func annotations(drawing: PKDrawing, bounds: CGRect) throws -> [PDFAnnotation] {
        let shapes = try shapes(from:drawing), group = UUID().uuidString
        let linear = shapes.count == drawing.strokes.count
            ? drawing.strokes.map { linearPoints(of: $0) != nil } : Array(repeating: false, count: shapes.count)
        let native = shapes.count == drawing.strokes.count
            ? drawing.strokes.enumerated().filter { !linear[$0.offset] }.map(\.element) : drawing.strokes
        var annotations: [PDFAnnotation] = [], metadata: PDFAnnotation?
        var nativeIndex = 0
        for (index,shape) in shapes.enumerated() {
            let flip = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:bounds.height)
            var transform = shape.transform.concatenating(flip)
            guard let transformed = shape.path.copy(using:&transform) else { continue }
            let strokeWidth = shape.width*hypot(shape.transform.a,shape.transform.b)
            // 标注矩形只包围本笔迹，避免 Mac 上点页面空白处也选中整页手绘。
            let inkBounds = transformed.boundingBoxOfPath.offsetBy(dx:bounds.minX,dy:bounds.minY)
                .insetBy(dx:-strokeWidth/2,dy:-strokeWidth/2)
            var local = CGAffineTransform(translationX:bounds.minX-inkBounds.minX,y:bounds.minY-inkBounds.minY)
            guard let localPath = transformed.copy(using:&local) else { continue }
            #if canImport(UIKit)
            // 使用 PDFKit 的公开路径接口。InkList 的公开写入值不是数值数组；
            // 直接传数组会在真机内部向 NSArray 发送路径方法并触发 ObjC 异常，
            // Swift 的 do/catch 无法拦截。序列化后的标准坐标由 PDFKit 生成。
            let annotation = PDFAnnotation(bounds:inkBounds,forType:.ink,withProperties:nil)
            annotation.add(UIBezierPath(cgPath:localPath))
            annotation.color = UIColor(cgColor:shape.color)
            #else
            let annotation = PDFAnnotation(bounds:inkBounds,forType:.ink,withProperties:nil)
            annotation.add(NSBezierPath(cgPath:localPath))
            annotation.color = NSColor(cgColor:shape.color) ?? .black
            #endif
            let border = PDFBorder(); border.lineWidth = strokeWidth
            annotation.border = border
            annotation.setValue(UUID().uuidString, forAnnotationKey: idKey)
            annotation.userName = "B-PAD-\(group)-\(index)"
            annotation.setValue("",forAnnotationKey:PDFAnnotationKey(rawValue:"/SimPlePath"))
            annotation.setValue(shape.color.alpha,forAnnotationKey:opacityKey)
            if linear[index], !shape.transform.isIdentity {
                // 六个仿射参数足以保留 PencilKit 的缩放绘制方式，避免将变换
                // 展平后重开时笔刷边缘稍变；无需给折线再附一份完整 PKDrawing。
                let t = shape.transform
                annotation.setValue([t.a, t.b, t.c, t.d, t.tx, t.ty].map { String(Double($0)) }.joined(separator: ","),
                                    forAnnotationKey: transformKey)
            }
            if !linear[index] {
                annotation.setValue(group, forAnnotationKey: groupKey)
                annotation.setValue(nativeIndex, forAnnotationKey: indexKey)
                nativeIndex += 1
                if metadata == nil { metadata = annotation }
            }
            annotation.shouldPrint = true
            annotations.append(annotation)
        }
        // 只有无法从折线完整重建的笔迹才保存原生附件，每组只附一次。
        // AnnotationKit 会丢弃未知 Data 属性，故使用 ASCII 编码。
        if let metadata {
            metadata.setValue(PKDrawing(strokes: native).dataRepresentation().base64EncodedString(), forAnnotationKey: drawingKey)
            metadata.setValue("monoline", forAnnotationKey: brushKey)
        }
        return annotations
    }


    /// 标准 InkList 是当前外观的依据，原生附件只用于恢复仍匹配的笔画。
    /// 单笔删除、改色或重排不能让整组退回 PDFKit 的位图标注层，更不能复活旧笔迹。
    static func takeEditableDrawing(from page: PDFPage) throws -> PKDrawing {
        let annotations = page.annotations, bounds = page.bounds(for: .cropBox)
        let originals = nativeOriginals(in: annotations, bounds: bounds)
        var strokes: [PKStroke] = []
        for annotation in annotations where annotation.type == "Ink" && annotation.shouldDisplay {
            try Task.checkCancellation()
            let recovered = editableDrawing(for: annotation, originals: originals, bounds: bounds)?.strokes
            guard let recovered, !recovered.isEmpty else { continue }
            strokes += recovered
            // Mac 上附在手绘上的文字评论单独保留为便签，不因切换到原生画布丢失。
            if let text = annotation.contents, !text.isEmpty {
                let note = PDFAnnotation(bounds: CGRect(x: annotation.bounds.minX, y: annotation.bounds.maxY - 24,
                    width: 24, height: 24), forType: .text, withProperties: nil)
                note.contents = text; note.color = annotation.color
                note.modificationDate = annotation.modificationDate
                page.addAnnotation(note)
            }
            page.removeAnnotation(annotation)
        }
        return PKDrawing(strokes: strokes)
    }
    static func matches(_ a:PDFAnnotation,_ b:PDFAnnotation) -> Bool {
        guard abs((a.border?.lineWidth ?? 0)-(b.border?.lineWidth ?? 0)) < 0.01,
              let ac=a.color.cgColor.converted(to:CGColorSpaceCreateDeviceRGB(),intent:.defaultIntent,options:nil)?.components,
              let bc=b.color.cgColor.converted(to:CGColorSpaceCreateDeviceRGB(),intent:.defaultIntent,options:nil)?.components,
              zip(ac.prefix(3),bc.prefix(3)).allSatisfy({abs($0-$1)<0.01}),
              abs(((a.value(forAnnotationKey:opacityKey) as? NSNumber)?.doubleValue ?? Double(a.color.cgColor.alpha)) - ((b.value(forAnnotationKey:opacityKey) as? NSNumber)?.doubleValue ?? Double(b.color.cgColor.alpha))) < 0.01 else { return false }
        func coordinates(_ annotation:PDFAnnotation) -> [CGPoint] {
            var points: [CGPoint] = []
            for path in annotation.paths ?? [] {
                path.cgPath.applyWithBlock { item in
                    let element=item.pointee
                    if element.type == .moveToPoint || element.type == .addLineToPoint {
                        points.append(CGPoint(x:element.points[0].x+annotation.bounds.minX,y:element.points[0].y+annotation.bounds.minY))
                    }
                }
            }
            return points
        }
        let ap=coordinates(a),bp=coordinates(b)
        return !ap.isEmpty && ap.count == bp.count && zip(ap,bp).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y)<0.02 }
    }
}


nonisolated extension VectorInk {
    /// 按单笔身份恢复原生控制点；旧组内其他笔画被删除或重排不影响这一笔。
    /// 调用方负责可见性判断，Mac 的高清覆盖层会暂时隐藏 PDFKit 原生标注层。
    typealias NativeOriginals = [String: (drawing: PKDrawing, expected: [PDFAnnotation])]

    /// 每组只解码一次；页内数百笔不重复解码整页附件。
    static func nativeOriginals(in annotations: [PDFAnnotation], bounds: CGRect) -> NativeOriginals {
        var result: NativeOriginals = [:]
        for metadata in annotations {
            guard let group = metadata.value(forAnnotationKey: groupKey) as? String,
                  result[group] == nil, let drawing = try? drawing(in: metadata),
                  let expected = try? self.annotations(drawing: drawing, bounds: bounds),
                  expected.count == drawing.strokes.count else { continue }
            result[group] = (drawing, expected)
        }
        return result
    }

    static func editableDrawing(for annotation: PDFAnnotation, originals: NativeOriginals, bounds: CGRect) -> PKDrawing? {
        if let group = annotation.value(forAnnotationKey: groupKey) as? String,
           let (original, expected) = originals[group] {
            let prefix = "B-PAD-\(group)-", name = annotation.userName ?? ""
            let index = (annotation.value(forAnnotationKey: indexKey) as? NSNumber)?.intValue
                ?? (name.hasPrefix(prefix) ? Int(name.dropFirst(prefix.count)) : nil)
            if let index, original.strokes.indices.contains(index), matches(annotation, expected[index]) {
                return PKDrawing(strokes: [original.strokes[index]])
            }
        }
        return standardDrawing(in: annotation, pageBounds: bounds)
    }

    /// 两端使用相同的原生变换，不改变控制点，不把笔迹转成图片。
    static func transformed(_ drawing: PKDrawing, by transform: CGAffineTransform) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.map { stroke in
            PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform.concatenating(transform),
                     mask: stroke.mask, randomSeed: stroke.randomSeed)
        })
    }
}
