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
        switch type {
        case .pdf:
            try generateBlankPDF(width: width, height: height, targetURL: targetURL, backgroundColor: backgroundColor)
        case .png, .jpeg:
            try generateBlankImage(type: type, width: width, height: height, targetURL: targetURL, backgroundColor: backgroundColor)
        }
    }
    
    private static func generateBlankPDF(width: CGFloat, height: CGFloat, targetURL: URL, backgroundColor: NSColor) throws {
        // 创建一个空 PDF
        let pdfDoc = PDFDocument()
        
        // 创建一个指定大小的空白图像
        let imageSize = NSSize(width: width, height: height)
        let blankImage = NSImage(size: imageSize)
        blankImage.lockFocus()
        backgroundColor.set()
        NSRect(origin: .zero, size: imageSize).fill()
        blankImage.unlockFocus()
        
        // 用空白图像创建一个页面
        if let page = PDFPage(image: blankImage) {
            pdfDoc.insert(page, at: 0)
        }
        
        // 保存到磁盘
        if !pdfDoc.write(to: targetURL) {
            throw NSError(domain: "DocumentGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write PDF to disk."])
        }
    }
    
    private static func generateBlankImage(type: DocumentType, width: CGFloat, height: CGFloat, targetURL: URL, backgroundColor: NSColor) throws {
        let imageSize = NSSize(width: width, height: height)
        let blankImage = NSImage(size: imageSize)
        
        blankImage.lockFocus()
        backgroundColor.set()
        NSRect(origin: .zero, size: imageSize).fill()
        blankImage.unlockFocus()
        
        guard let cgImage = blankImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "DocumentGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate CGImage."])
        }
        
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        
        let fileType: NSBitmapImageRep.FileType
        switch type {
        case .png: fileType = .png
        case .jpeg: fileType = .jpeg
        default: fileType = .png
        }
        
        guard let data = bitmapRep.representation(using: fileType, properties: [:]) else {
            throw NSError(domain: "DocumentGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to generate image data."])
        }
        
        try data.write(to: targetURL)
    }
}
#endif
