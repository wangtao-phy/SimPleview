import AppKit

/// 所有窗口共用一个按实际像素字节计费的 LRU。不能同时用额外强引用字典
/// “保活”已淘汰图像。这里的上限只覆盖缓存；可见视图和正在渲染的图像另计。
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    struct Key: Hashable { let owner: UUID; let page: Int }
    private struct Entry { let image: NSImage; let bytes: Int; var access: UInt64 }
    private var entries: [Key: Entry] = [:]
    private(set) var totalBytes = 0
    private var clock: UInt64 = 0
    let byteLimit: Int

    init(byteLimit: Int = 192 * 1024 * 1024) { self.byteLimit = max(0, byteLimit) }

    func image(owner: UUID, page: Int) -> NSImage? {
        let key = Key(owner: owner, page: page)
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: NSImage, owner: UUID, page: Int) {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let (bytes, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.height)
        guard !overflow, bytes > 0, bytes <= byteLimit else { return }
        let key = Key(owner: owner, page: page)
        remove(key)
        clock &+= 1
        entries[key] = Entry(image: image, bytes: bytes, access: clock)
        totalBytes += bytes
        // 每个窗口最多占总预算的三分之一，避免一个长文档挤掉所有其他窗口。
        while entries.filter({ $0.key.owner == owner }).values.reduce(0, { $0 + $1.bytes }) > byteLimit / 3 {
            guard let oldest = entries.filter({ $0.key.owner == owner }).min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
        while totalBytes > byteLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
    }

    func remove(owner: UUID, page: Int? = nil) {
        for key in entries.keys.filter({ $0.owner == owner && (page == nil || $0.page == page) }) { remove(key) }
    }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { totalBytes -= entry.bytes }
    }
}
