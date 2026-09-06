import AppKit
import PDFKit

/// PDFKit 的 paths API 使用批注局部坐标。文件保留标准 InkList；主视图
/// 同时以原始路径直接描边，不能为了标准化存储删除原有的高清手绘绘制。
@MainActor
enum StandardInk {
    private static let opacityKey = PDFAnnotationKey(rawValue: "/SimPleInkOpacity")
    private static let screenHiddenKey = PDFAnnotationKey(rawValue: "/SimPleScreenHiddenInk")
    private static let originalFlagsKey = PDFAnnotationKey(rawValue: "/SimPleInkOriginalFlags")

    /// 关闭 PDFKit 的原生屏幕批注层，连同其缓存位图一起移除。仅处理本应用
    /// 有可用矢量路径的手绘；用户原本隐藏的其他批注不能被意外重新显示。
    @discardableResult
    static func prepareForScreen(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.type == "Ink", isAppInk(annotation),
              annotation.shouldDisplay || isScreenHidden(annotation),
              !pagePaths(of: annotation).isEmpty else { return false }
        if !isScreenHidden(annotation) {
            let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
            annotation.setValue(flags, forAnnotationKey: originalFlagsKey)
            annotation.setValue(true, forAnnotationKey: screenHiddenKey)
        }
        if annotation.shouldDisplay { annotation.shouldDisplay = false }
        // NoView 只约束屏幕显示，PDFKit 某些缓存/缩略图通道仍会绘制。
        // 再设置标准 Hidden 位（bit 1），让原生图像通道完全不生成这份墨迹。
        // 原始 flags 已独立保存，导出副本恢复原值；矢量快照不依赖这些显示位。
        let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
        if flags & 2 == 0 { annotation.setValue(flags | 2, forAnnotationKey: .flags) }
        return true
    }

    static func isScreenHidden(_ annotation: PDFAnnotation) -> Bool {
        (annotation.value(forAnnotationKey: screenHiddenKey) as? NSNumber)?.boolValue == true
    }

    static func prepareForScreen(in document: PDFDocument) {
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] { prepareForScreen(annotation) }
        }
    }

    /// 只能用于独立的保存/导出副本，不能临时翻转正在显示的文档再翻回去。
    /// 恢复标准可见性并去掉屏幕专用标记，确保外部阅读器不会把笔迹隐藏。
    @discardableResult
    static func restoreExportVisibility(in copy: PDFDocument) -> Bool {
        var changed = false
        for index in 0..<copy.pageCount {
            for annotation in copy.page(at: index)?.annotations ?? [] where isScreenHidden(annotation) {
                guard annotation.type == "Ink", isAppInk(annotation) else { continue }
                if let original = annotation.value(forAnnotationKey: originalFlagsKey) as? NSNumber {
                    annotation.setValue(original, forAnnotationKey: .flags)
                } else {
                    // 兼容未记录原 flags 的早期屏幕隐藏标记。
                    let flags = (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
                    annotation.setValue(flags & ~2, forAnnotationKey: .flags)
                    annotation.shouldDisplay = true
                }
                annotation.color = displayColor(of: annotation)
                annotation.removeValue(forAnnotationKey: screenHiddenKey)
                annotation.removeValue(forAnnotationKey: originalFlagsKey)
                changed = true
            }
        }
        return changed
    }

    static func exportData(of page: PDFPage) -> Data? {
        guard let data = page.dataRepresentation else { return nil }
        guard page.annotations.contains(where: isScreenHidden) else { return data }
        return exportData(from: data)
    }

    static func exportData(of document: PDFDocument) -> Data? {
        guard let data = document.dataRepresentation() else { return nil }
        return exportData(from: data)
    }

    private static func exportData(from data: Data) -> Data? {
        guard let copy = PDFDocument(data: data) else { return nil }
        guard restoreExportVisibility(in: copy) else { return data }
        return copy.dataRepresentation()
    }

    static func setColor(_ color: NSColor, to annotation: PDFAnnotation) {
        if annotation.color != color { annotation.color = color }
        if annotation.type == "Ink", isAppInk(annotation) {
            // PDFKit 重开文件后 color 不一定保留 alpha（透明度可能只在 AP
            // 外观流里）。单独记录原值，保证直接矢量描边不会突然变深。
            annotation.setValue(color.alphaComponent, forAnnotationKey: opacityKey)
        }
    }

    static func displayColor(of annotation: PDFAnnotation) -> NSColor {
        guard annotation.type == "Ink", isAppInk(annotation),
              let opacity = annotation.value(forAnnotationKey: opacityKey) as? NSNumber,
              opacity.doubleValue.isFinite, (0...1).contains(opacity.doubleValue) else { return annotation.color }
        return annotation.color.withAlphaComponent(CGFloat(opacity.doubleValue))
    }

    /// 新文件只保留空标记，坐标来自标准 InkList；旧文件的非空文本路径
    /// 继续支持。此标记不能用于签名迁移，调用方须先确认批注类型为 Ink。
    static func isAppInk(_ annotation: PDFAnnotation) -> Bool {
        annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/SimPlePath")) is String
    }

    /// 标准路径优先，保留真实的多笔划和曲线；还没有 InkList 的旧文件使用
    /// 原版 /SimPlePath 页坐标。这里只返回副本，后台不得读写 PDFAnnotation。
    static func pagePaths(of annotation: PDFAnnotation) -> [NSBezierPath] {
        if let paths = annotation.paths, !paths.isEmpty {
            return paths.compactMap { path in
                guard let copy = path.copy() as? NSBezierPath else { return nil }
                copy.transform(using: AffineTransform(translationByX: annotation.bounds.minX, byY: annotation.bounds.minY))
                return copy
            }
        }
        guard let path = legacyPagePath(of: annotation) else { return [] }
        return [path]
    }

    static func add(pagePaths: [NSBezierPath], to annotation: PDFAnnotation) {
        for pagePath in pagePaths {
            guard let localPath = pagePath.copy() as? NSBezierPath else { continue }
            let transform = AffineTransform(translationByX: -annotation.bounds.minX,
                                            byY: -annotation.bounds.minY)
            localPath.transform(using: transform)
            annotation.add(localPath)
        }
    }

    /// 旧版本仅保存 /SimPlePath。迁移只补齐缺少的 InkList，并保留原始字段，
    /// 不覆盖已有标准笔迹。返回值用于标记需要保存；读取本身不改写磁盘。
    static func migrate(in document: PDFDocument) -> Bool {
        var changed = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Ink" {
                guard annotation.paths?.isEmpty != false else { continue }
                if let path = legacyPagePath(of: annotation) {
                    add(pagePaths: [path], to: annotation)
                    changed = true
                }
            }
        }
        return changed
    }

    private static func legacyPagePath(of annotation: PDFAnnotation) -> NSBezierPath? {
        var chunks: [String] = [], length = 0
        for chunkIndex in 0..<1024 {
            let key = chunkIndex == 0 ? "/SimPlePath" : "/SimPlePath\(chunkIndex)"
            guard let text = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: key)) as? String else { break }
            length += text.utf8.count
            guard length <= 8_000_000 else { return nil }
            chunks.append(text)
        }
        let path = NSBezierPath()
        var hasPoint = false
        for token in chunks.joined().split(separator: ";") {
            let values = token.split(separator: ",")
            let offset = values.count == 3 ? 1 : 0
            guard values.count == 2 || values.count == 3,
                  let x = Double(values[offset]), let y = Double(values[offset + 1]),
                  x.isFinite, y.isFinite, abs(x) < 1_000_000, abs(y) < 1_000_000 else { continue }
            let point = NSPoint(x: x, y: y)
            if !hasPoint || (offset == 1 && values[0] == "M") {
                path.move(to: point); hasPoint = true
            } else { path.line(to: point) }
        }
        return path.elementCount > 1 ? path : nil
    }
}
