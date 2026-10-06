import CoreImage
import ImageIO
import PDFKit

extension ImageDocumentManager {
    /// 在后台将图片嵌入单页 PDF。页面尺寸是点，图像尺寸是像素，两者不必相同：
    /// 只缩放绘制坐标，保留原始像素，不为“提高 DPI”制造无用的放大位图。
    nonisolated static func insertionPDF(from url: URL, pageSize: CGSize) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return insertionPDF(from: source, pageSize: pageSize)
    }

    nonisolated static func insertionPDF(from data: Data, pageSize: CGSize) -> Data? {
        guard data.count <= 200 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return insertionPDF(from: source, pageSize: pageSize)
    }

    private nonisolated static func insertionPDF(from source: CGImageSource, pageSize: CGSize) -> Data? {
        // 先检查元数据再解码，防止畸形文件引发超大像素分配。只取静态首帧。
        guard pageSize.width.isFinite, pageSize.height.isFinite,
              pageSize.width > 0, pageSize.height > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 16_384, height.doubleValue <= 16_384,
              width.doubleValue * height.doubleValue <= 100_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        // EXIF 的旋转与镜像只变换 PDF 绘制坐标，不经过 Core Image 渲染或重新采样。
        let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
        let transform = CIImage(cgImage: image).orientationTransform(forExifOrientation: orientation)
        let pixels = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let oriented = pixels.applying(transform)
        let scale = min(pageSize.width / oriented.width, pageSize.height / oriented.height)
        var bounds = CGRect(origin: .zero, size: pageSize)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { return nil }
        context.beginPDFPage(nil)
        // 等比居中并保留白色页边，透明 PNG 不产生黑底，也不拉伸或裁掉内容。
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.translateBy(x: (pageSize.width - oriented.width * scale) / 2,
                            y: (pageSize.height - oriented.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -oriented.minX, y: -oriented.minY)
        context.concatenate(transform)
        context.draw(image, in: pixels)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
