import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// 图形服务故障时的只读显示。独占自己的 PDFDocument，在串行后台执行器
/// 上生成屏幕图像；不创建 PDFView/PKCanvasView，不修改文件和矢量标注。
actor SoftwarePageRenderer {
    private let data: Data
    private var document: PDFDocument?
    private let cache = NSCache<NSString, NSData>()

    init(data: Data) {
        self.data = data
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 12
    }

    func image(page index: Int, maximumDimension: Int) throws -> Data {
        try Task.checkCancellation()
        let dimension = min(4096, max(256, maximumDimension))
        let key = "\(index):\(dimension)" as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        if document == nil { document = PDFDocument(data: data) }
        guard let document, let page = document.page(at: index), let reference = page.pageRef else {
            throw PadError.message("无法读取此页。")
        }
        let box = page.bounds(for: .cropBox)
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0 else {
            throw PadError.message("此页尺寸无效。")
        }
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(dimension) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PadError.message("此页显示内存不足。")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        page.draw(with: .cropBox, to: context)
        try Task.checkCancellation()
        // PNG 不引入 JPEG 的笔迹边缘压缩噪点；这只是临时显示缓存，不存入 PDF。
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw PadError.message("无法生成页面预览。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PadError.message("页面预览生成失败。") }
        try Task.checkCancellation()
        let result = output as Data
        cache.setObject(result as NSData, forKey: key, cost: result.count)
        return result
    }

    func clearCache() { cache.removeAllObjects(); document = nil }
}
