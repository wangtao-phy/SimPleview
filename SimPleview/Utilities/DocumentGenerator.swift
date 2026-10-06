import Foundation
import PDFKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

struct DocumentGenerator {
    
    enum DocumentType: String, CaseIterable, Identifiable {
        case pdf = "PDF"
        case png = "PNG"
        case jpeg = "JPEG"
        var id: String { self.rawValue }
        
        var ext: String {
            switch self {
            case .pdf: return "pdf"
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }
    
    static func generateBlankDocument(
        type: DocumentType,
        width: CGFloat,
        height: CGFloat,
        targetURL: URL,
        backgroundColor: NSColor = .white
    ) throws {
        guard FilePreferences.validSize(CGSize(width: width, height: height)) else { throw CocoaError(.fileWriteInvalidFileName) }
        switch type {
        case .pdf:
            try generateBlankPDF(width: width, height: height, targetURL: targetURL, backgroundColor: backgroundColor)
        case .png, .jpeg:
            try generateBlankImage(type: type, width: width, height: height, targetURL: targetURL, backgroundColor: backgroundColor)
        }
    }
    
    private static func generateBlankPDF(width: CGFloat, height: CGFloat, targetURL: URL, backgroundColor: NSColor) throws {
        // 空白 PDF 直接写矢量填充，尺寸不依赖屏幕倍率，也无需创建整页位图。
        var bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.setFillColor(backgroundColor.cgColor)
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        try (output as Data).write(to: targetURL, options: .atomic)
    }
    
    private static func generateBlankImage(type: DocumentType, width: CGFloat, height: CGFloat, targetURL: URL, backgroundColor: NSColor) throws {
        // 按像素创建位图，不使用 lockFocus 的屏幕倍率；同一尺寸在 Retina
        // 与普通屏幕上输出一致，同时避免隐式放大四倍的像素分配。
        let pixelWidth = Int(width.rounded(.down)), pixelHeight = Int(height.rounded(.down))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let cgImage = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        
        let fileType: NSBitmapImageRep.FileType
        switch type {
        case .png: fileType = .png
        case .jpeg: fileType = .jpeg
        default: fileType = .png
        }
        
        guard let data = bitmapRep.representation(using: fileType, properties: type == .jpeg ? [.compressionFactor: FilePreferences.jpegQuality()] : [:]) else {
            throw NSError(domain: "DocumentGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to generate image data."])
        }
        
        try data.write(to: targetURL, options: .atomic)
    }
}
#endif
