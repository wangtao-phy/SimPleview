import AppKit

/// 全应用共用按实际位图字节计费的 LRU。单本书可以使用剩余预算，淘汰时
/// 优先保留各窗口的可见页；视图正在显示的图像及渲染中的临时数据另计。
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    struct Key: Hashable { let owner: UUID; let page: Int }
    private struct Entry {
        let image: NSImage
        let pixels: CGSize
        let bytes: Int
        var access: UInt64
    }
    private var entries: [Key: Entry] = [:]
    private var visible: [UUID: Set<Int>] = [:]
    private(set) var totalBytes = 0
    private var clock: UInt64 = 0
    let byteLimit: Int
    private var currentLimit: Int

    init(byteLimit: Int = 192 * 1024 * 1024) {
        self.byteLimit = max(0, byteLimit)
        currentLimit = self.byteLimit
    }

    func image(owner: UUID, page: Int) -> NSImage? {
        let key = Key(owner: owner, page: page)
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry
        return entry.image
    }

    func contains(owner: UUID, page: Int, pixels: CGSize) -> Bool {
        guard let entry = entries[Key(owner: owner, page: page)] else { return false }
        // PDFKit 保持长宽比时会向下取整一个像素，不能因此把同尺寸图像反复判为不足。
        return entry.pixels.width + 1 >= pixels.width && entry.pixels.height + 1 >= pixels.height
    }

    func setVisible(_ pages: Set<Int>, owner: UUID) { visible[owner] = pages }

    func insert(_ image: NSImage, owner: UUID, page: Int) {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let (bytes, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.height)
        guard !overflow, bytes > 0, bytes <= currentLimit else { return }
        let key = Key(owner: owner, page: page)
        remove(key)
        clock &+= 1
        entries[key] = Entry(image: image, pixels: CGSize(width: bitmap.width, height: bitmap.height), bytes: bytes, access: clock)
        totalBytes += bytes
        evictIfNeeded()
    }

    /// 压力解除前维持较低预算，避免一次清理后马上填回原来的容量。
    func trim(to bytes: Int) {
        currentLimit = min(byteLimit, max(0, bytes))
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while totalBytes > currentLimit {
            let hidden = entries.filter { !(visible[$0.key.owner]?.contains($0.key.page) ?? false) }
            guard let oldest = (hidden.isEmpty ? entries : hidden).min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
    }

    /// 插入、删除和重排只改变缓存所属页码，不重新绘制内容未变的页面。
    func remap(owner: UUID, pages: [Int: Int]) {
        let old = entries.filter { $0.key.owner == owner }
        let visiblePages = visible[owner] ?? []
        remove(owner: owner)
        for (key, entry) in old {
            guard let page = pages[key.page] else { continue }
            entries[Key(owner: owner, page: page)] = entry
            totalBytes += entry.bytes
        }
        visible[owner] = Set(visiblePages.compactMap { pages[$0] })
    }

    func remove(owner: UUID, page: Int? = nil) {
        for key in entries.keys.filter({ $0.owner == owner && (page == nil || $0.page == page) }) { remove(key) }
        if page == nil { visible[owner] = nil }
    }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { totalBytes -= entry.bytes }
    }
}
