import SwiftUI
import PDFKit

/// 封面只渲染第一页，串行后台读取；缓存限制在 12 MiB，不持有 PDFDocument。
private actor DocumentCoverCache {
    static let shared = DocumentCoverCache()
    private let cache = NSCache<NSString, NSData>()
    init() { cache.totalCostLimit = 12 * 1024 * 1024; cache.countLimit = 60 }

    func cover(_ url: URL) -> Data? {
        guard !Task.isCancelled else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var result: Data?, error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { target in
            guard !Task.isCancelled else { return }
            let values = try? target.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let key = "\(url.absoluteString)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)" as NSString
            if let cached = cache.object(forKey: key) { result = cached as Data; return }
            result = autoreleasepool {
                guard let doc = PDFDocument(url: target), !doc.isLocked, let page = doc.page(at: 0) else { return nil }
                defer { withExtendedLifetime(doc) {} }
                // 封面不需要 PDFView 的 GPU 分块管线。使用小型 CPU 位图，
                // 图形编译服务失效时仍能显示书架，且不启动 PencilKit/Metal。
                guard let reference = page.pageRef else { return nil }
                let box = page.bounds(for: .cropBox)
                guard [box.width, box.height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
                let rotated = page.rotation % 180 != 0
                let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
                let scale = min(280 / size.width, 380 / size.height)
                let width = max(1, Int((size.width * scale).rounded(.up)))
                let height = max(1, Int((size.height * scale).rounded(.up)))
                guard let context = CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
                context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                page.draw(with: .cropBox, to: context)
                guard let image = context.makeImage() else { return nil }
                return UIImage(cgImage: image).pngData()
            }
            if let result, !Task.isCancelled { cache.setObject(result as NSData, forKey: key, cost: result.count) }
        }
        return Task.isCancelled ? nil : result
    }
}

struct DocumentCoverView: View {
    let url: URL
    let title: String
    var folder = false
    var revision = 0
    @State private var image: UIImage?
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground))
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(6)
                } else {
                    Image(systemName: folder ? "folder.fill" : "doc.richtext")
                        .font(.system(size: 42)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 190)
            Text(title).font(.subheadline).lineLimit(2).frame(height: 40, alignment: .top)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .task(id: revision) {
            guard !folder else { return }
            let data = await DocumentCoverCache.shared.cover(url)
            guard !Task.isCancelled else { return }
            image = data.flatMap(UIImage.init(data:))
        }
        // 离开可见网格后释放解码图像；再次出现可从有上限的压缩缓存恢复。
        .onDisappear { image = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
