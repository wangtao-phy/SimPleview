import CoreGraphics
import Foundation
import PDFKit
import os

/// 页面身份与几何快照。reference 仅用于身份和保活，后台绘图使用独立 PDF 数据。
nonisolated struct ScanPage: @unchecked Sendable {
    let reference: CGPDFPage
    let transform: CGAffineTransform
    let bounds: CGRect

    @MainActor static func capture(_ page: PDFPage) -> ScanPage? {
        guard page.annotations.isEmpty, let reference = page.pageRef,
              containsLargeImage(reference) else { return nil }
        return ScanPage(reference: reference, transform: page.transform(for: .cropBox),
                        bounds: page.bounds(for: .cropBox))
    }

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

/// 正文优先：瓦片线程只查已完成图像，未命中立即回退 PDFKit，绝不等待整页解码。
/// 主线程每轮至多准备一份单页数据，后台用自己的 CGPDFDocument 生成屏幕图像。
/// 各窗口共用一个预备队列；缓存每窗口 48 MiB、单页 24 MiB，关闭/内存压力可取消。
final class ScanPageCache {
    nonisolated private struct Key: Hashable, Sendable {
        let page: ObjectIdentifier
        let geometry: [CGFloat]
        let width: Int
        let height: Int
    }
    nonisolated private struct Entry: Sendable {
        let source: ScanPage // 保留身份对象，避免缓存有效时地址被其他页面复用。
        let image: CGImage
        let bytes: Int
        var access: UInt64
    }
    nonisolated private struct Images: Sendable {
        var entries: [Key: Entry] = [:]
        var bytes = 0
        var clock: UInt64 = 0
    }
    private struct Request {
        weak var page: PDFPage?
        let scan: ScanPage
        let key: Key
    }
    nonisolated private let images = OSAllocatedUnfairLock(initialState: Images())
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var pending: [Request] = []
    private var operation: BlockOperation?
    private var activeKey: Key?
    private var snapshotTask: Task<Void, Never>?
    private var pausedUntil = ContinuousClock.now
    private var generation: UInt = 0
    private let byteLimit = 48 * 1024 * 1024

    deinit { snapshotTask?.cancel(); operation?.cancel() }

    func removeAll(pauseFor seconds: TimeInterval = 0) {
        generation &+= 1
        snapshotTask?.cancel(); snapshotTask = nil
        operation?.cancel(); operation = nil; activeKey = nil
        pending.removeAll()
        pausedUntil = .now.advanced(by: .seconds(seconds))
        images.withLock { $0 = Images() }
    }

    nonisolated private static func key(for scan: ScanPage, scale: CGFloat) -> Key? {
        let rect = scan.displayBounds, t = scan.transform
        let w = ceil(rect.width * scale), h = ceil(rect.height * scale)
        guard scale.isFinite, scale > 0, w.isFinite, h.isFinite, w > 0, h > 0,
              w * h * 4 <= Double(24 * 1024 * 1024) else { return nil }
        return Key(page: ObjectIdentifier(scan.reference),
            geometry: [rect.minX, rect.minY, rect.width, rect.height, t.a, t.b, t.c, t.d, t.tx, t.ty],
            width: Int(w), height: Int(h))
    }

    /// 热路径只取一次短锁；没有等待后台任务、序列化或读取活动 PDFKit 对象。
    nonisolated func image(for scan: ScanPage, scale: CGFloat) -> CGImage? {
        guard let key = Self.key(for: scan, scale: scale) else { return nil }
        return images.withLock { state in
            guard var entry = state.entries[key] else { return nil }
            state.clock &+= 1; entry.access = state.clock; state.entries[key] = entry
            return entry.image
        }
    }

    /// 调用者按可见页、相邻页顺序传入。不断滚动时替换待办范围，已离开的
    /// 页面不再生成；正在解码的任务只允许结束，不强行中断系统绘图。
    func update(pages: [PDFPage], scale: CGFloat) {
        guard ContinuousClock.now >= pausedUntil else { return }
        var seen = Set<Key>()
        let requests: [Request] = pages.compactMap { page in
            guard let scan = ScanPage.capture(page), let key = Self.key(for: scan, scale: scale),
                  seen.insert(key).inserted else { return nil }
            return Request(page: page, scan: scan, key: key)
        }
        if let activeKey, !seen.contains(activeKey) { operation?.cancel() }
        pending = requests.filter {
            ($0.key != activeKey || operation?.isCancelled == true) && image(for: $0.scan, scale: scale) == nil
        }
        scheduleNext()
    }

    private func scheduleNext() {
        guard snapshotTask == nil, operation == nil, !pending.isEmpty else { return }
        snapshotTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self else { return }
            self.snapshotTask = nil
            guard !self.pending.isEmpty else { return }
            let request = self.pending.removeFirst()
            guard let page = request.page, page.document != nil, page.annotations.isEmpty,
                  let data = page.dataRepresentation else { self.scheduleNext(); return }
            self.enqueue(data: data, request: request)
        }
    }

    private func enqueue(data: Data, request: Request) {
        let version = generation, key = request.key, scan = request.scan
        let work = BlockOperation()
        work.addExecutionBlock { [weak self, weak work] in
            guard let work, !work.isCancelled else { return }
            let image = autoreleasepool { Self.render(data: data, scan: scan, key: key) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operation === work else { return }
                if !work.isCancelled, self.generation == version, let image {
                    self.images.withLock { state in
                        let cost = image.bytesPerRow * image.height
                        if let old = state.entries.removeValue(forKey: key) { state.bytes -= old.bytes }
                        while state.bytes + cost > self.byteLimit,
                              let oldest = state.entries.min(by: { $0.value.access < $1.value.access })?.key {
                            if let entry = state.entries.removeValue(forKey: oldest) { state.bytes -= entry.bytes }
                        }
                        state.clock &+= 1
                        state.entries[key] = Entry(source: scan, image: image, bytes: cost, access: state.clock)
                        state.bytes += cost
                    }
                }
            }
        }
        // 尚未开始就被取消的 BlockOperation 不执行工作闭包，但一定执行完成回调。
        // 清理必须放在这里，否则快速往返滚动会把调度器永久卡在“正在生成”。
        work.completionBlock = { [weak self, weak work] in
            guard let work else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operation === work else { return }
                self.operation = nil; self.activeKey = nil
                self.scheduleNext()
            }
        }
        operation = work; activeKey = key
        Self.queue.addOperation(work)
    }

    nonisolated private static func render(data: Data, scan: ScanPage, key: Key) -> CGImage? {
        // CGPDFDocument 也有内部可变缓存，不能把主视图的 pageRef 拿来同时解码。
        // 这里的文档只在本工作项中使用，完成后只交出不可变 CGImage。
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1),
              let context = CGContext(data: nil, width: key.width, height: key.height, bitsPerComponent: 8,
                bytesPerRow: key.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = scan.displayBounds
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: key.width, height: key.height))
        context.scaleBy(x: CGFloat(key.width) / rect.width, y: CGFloat(key.height) / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.concatenate(scan.transform)
        context.interpolationQuality = .high
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
