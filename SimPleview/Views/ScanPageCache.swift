import CoreGraphics
import Foundation

/// 只持有不可变 CoreGraphics 页面；后台不能访问活动的 PDFPage 或 PDFAnnotation。
nonisolated struct ScanPage: @unchecked Sendable {
    let reference: CGPDFPage
    let transform: CGAffineTransform
    let bounds: CGRect

    var displayBounds: CGRect { bounds.applying(transform).standardized }

    /// 扫描页通常包含大幅 Image XObject。小图标不值得建立整页缓存；
    /// 未识别的嵌套资源直接使用 PDFKit，不能为了优化改变文档内容。
    static func containsLargeImage(_ page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyFunction(objects, { _, object, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?, width: CGPDFInteger = 0, height: CGPDFInteger = 0
            if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
               String(cString: subtype) == "Image",
               CGPDFDictionaryGetInteger(dictionary, "Width", &width),
               CGPDFDictionaryGetInteger(dictionary, "Height", &height),
               width >= 1000, height >= 1000 {
                info?.assumingMemoryBound(to: Bool.self).pointee = true
            }
        }, &found)
        return found
    }
}

/// 扫描页的多块瓦片共用一次按屏幕分辨率绘制的结果，避免每块重新解码大图。
/// 每窗口至多 48 MiB、单页至多 24 MiB；高倍缩放超限时回退原生瓦片，不降清晰度。
nonisolated final class ScanPageCache: @unchecked Sendable {
    private struct Key: Hashable {
        let page: ObjectIdentifier
        let geometry: [CGFloat]
        let width: Int
        let height: Int
    }
    // 持有页面引用，使对象地址在缓存有效期内不会被新页复用，避免删页后串图。
    private struct Entry { let source: CGPDFPage; let image: CGImage; let bytes: Int; var access: UInt64 }
    private let stateLock = NSLock()
    // 只有瓦片工作线程等待首次生成；清缓存只取 stateLock，不等待解码完成。
    private let renderLock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0
    private var pausedUntil = Date.distantPast
    private let byteLimit = 48 * 1024 * 1024

    func removeAll(pauseFor seconds: TimeInterval = 0) {
        stateLock.withLock {
            generation &+= 1; entries.removeAll(); bytes = 0
            pausedUntil = Date().addingTimeInterval(seconds)
        }
    }

    func image(for page: ScanPage, scale: CGFloat) -> CGImage? {
        let rect = page.displayBounds
        let w = ceil(rect.width * scale), h = ceil(rect.height * scale)
        guard scale.isFinite, scale > 0, w.isFinite, h.isFinite, w > 0, h > 0,
              w * h * 4 <= Double(24 * 1024 * 1024) else { return nil }
        let width = Int(w), height = Int(h), t = page.transform
        let key = Key(page: ObjectIdentifier(page.reference),
            geometry: [rect.minX, rect.minY, rect.width, rect.height, t.a, t.b, t.c, t.d, t.tx, t.ty],
            width: width, height: height)
        func cached() -> CGImage? {
            stateLock.withLock {
                guard var entry = entries[key] else { return nil }
                clock &+= 1; entry.access = clock; entries[key] = entry
                return entry.image
            }
        }
        if let image = cached() { return image }
        let version = stateLock.withLock { Date() >= pausedUntil ? generation : nil }
        guard let version else { return nil }
        renderLock.lock()
        defer { renderLock.unlock() }
        if let image = cached() { return image }
        guard stateLock.withLock({ generation == version }) else { return nil }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.concatenate(t)
        context.interpolationQuality = .high
        context.drawPDFPage(page.reference)
        guard let image = context.makeImage() else { return nil }
        let cost = image.bytesPerRow * image.height
        stateLock.withLock {
            guard generation == version else { return }
            while bytes + cost > byteLimit, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
                if let removed = entries.removeValue(forKey: oldest) { bytes -= removed.bytes }
            }
            clock &+= 1; entries[key] = Entry(source: page.reference, image: image, bytes: cost, access: clock); bytes += cost
        }
        return image
    }
}
