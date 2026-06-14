import Foundation
import PDFKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 专门处理图像查看、转换为临时 PDF 以及保存回图像的独立模块
final class ImageDocumentManager {
    
    /// 检查文件 URL 是否为支持的图像格式
    nonisolated static func isImageFile(url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp"]
        return imageExts.contains(ext)
    }
    
    /// 从图像文件创建一个单页的内存级 PDFDocument 壳
    nonisolated static func createPDFDocument(fromImageURL url: URL) -> PDFDocument? {
        guard let image = PlatformImage(contentsOfFile: url.path) else {
            return nil
        }
        
        let pdfDocument = PDFDocument()
        guard let pdfPage = PDFPage(image: image) else {
            return nil
        }
        
        pdfDocument.insert(pdfPage, at: 0)
        return pdfDocument
    }
    
    /// 将包含手绘/批注的单页 PDFDocument 栅格化，并导回原始图像格式
    /// - Parameters:
    ///   - pdfDocument: 包含批注的 PDF 壳
    ///   - url: 原始图像文件的路径（决定输出格式）
    /// - Returns: 是否成功保存
    static func exportPDFDocumentToOriginalImageFormat(pdfDocument: PDFDocument, originalURL url: URL, targetSize: CGSize? = nil) -> Bool {
        guard let page = pdfDocument.page(at: 0) else { return false }
        
        let mediaBox = page.bounds(for: .cropBox)
        let finalSize = targetSize ?? mediaBox.size
        
        #if os(macOS)
        let width = Int(finalSize.width)
        let height = Int(finalSize.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            return false
        }
        
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" || ext == "bmp" {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        
        // 如果用户指定了尺寸，则在上下文中缩放
        let scaleX = finalSize.width / mediaBox.width
        let scaleY = finalSize.height / mediaBox.height
        context.scaleBy(x: scaleX, y: scaleY)
        
        // 包装为 NSGraphicsContext 使得 AppKit 底层的 annotation 可以正常使用笔刷绘制
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        
        page.draw(with: .cropBox, to: context)
        
        // 显式烧录所有标注
        for annot in page.annotations {
            // 1. 常规原生绘制 (VectorSignatureAnnotation 会走这个路径)
            annot.draw(with: .cropBox, in: context)
            
            // 2. [核心黑科技] 渲染 SimPleview 特有的分块存储墨迹 (绕过 macOS 无法保存 Ink 的 Bug)
            if (annot.type ?? "") == "Ink" {
                var pathStr = ""
                var chunkIndex = 0
                while true {
                    let keyStr = chunkIndex == 0 ? "/SimPlePath" : "/SimPlePath\(chunkIndex)"
                    if let chunk = annot.value(forAnnotationKey: PDFAnnotationKey(rawValue: keyStr)) as? String {
                        pathStr += chunk
                        chunkIndex += 1
                    } else {
                        break
                    }
                }
                
                if !pathStr.isEmpty {
                    let pairs = pathStr.split(separator: ";")
                    if !pairs.isEmpty {
                        let bPath = NSBezierPath()
                        for (i, pair) in pairs.enumerated() {
                            let coords = pair.split(separator: ",")
                            if coords.count == 3 {
                                let type = coords[0]
                                if let x = Double(coords[1]), let y = Double(coords[2]) {
                                    let point = NSPoint(x: x, y: y)
                                    if type == "M" { bPath.move(to: point) }
                                    else if type == "L" { bPath.line(to: point) }
                                }
                            } else if coords.count == 2 {
                                if let x = Double(coords[0]), let y = Double(coords[1]) {
                                    let point = NSPoint(x: x, y: y)
                                    if i == 0 { bPath.move(to: point) }
                                    else { bPath.line(to: point) }
                                }
                            }
                        }
                        
                        context.saveGState()
                        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = nsContext
                        
                        annot.color.setStroke()
                        bPath.lineWidth = annot.border?.lineWidth ?? 3.0
                        bPath.lineCapStyle = .round
                        bPath.lineJoinStyle = .round
                        bPath.stroke()
                        
                        NSGraphicsContext.restoreGraphicsState()
                        context.restoreGState()
                    }
                }
            }
        }
        
        NSGraphicsContext.restoreGraphicsState()
        
        guard let cgImage = context.makeImage() else { return false }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        
        let data: Data?
        
        if ext == "png" {
            data = bitmapRep.representation(using: .png, properties: [:])
        } else if ext == "jpg" || ext == "jpeg" {
            // 降低压缩比，减小体积
            data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        } else if ext == "tiff" || ext == "tif" {
            data = bitmapRep.representation(using: .tiff, properties: [:])
        } else if ext == "bmp" {
            data = bitmapRep.representation(using: .bmp, properties: [:])
        } else if ext == "gif" {
            data = bitmapRep.representation(using: .gif, properties: [:])
        } else {
            data = bitmapRep.representation(using: .png, properties: [:])
        }
        
        guard let finalData = data else { return false }
        
        do {
            try finalData.write(to: url, options: .atomic)
            return true
        } catch {
            print("Failed to write image data to \(url.path): \(error)")
            return false
        }
        #else
        let finalSize = targetSize ?? mediaBox.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // 保持原图 1x 比例，避免体积膨胀
        let renderer = UIGraphicsImageRenderer(size: finalSize, format: format)
        let ext = url.pathExtension.lowercased()
        
        let image = renderer.image { ctx in
            if ext == "jpg" || ext == "jpeg" || ext == "bmp" {
                UIColor.white.set()
                ctx.fill(CGRect(origin: .zero, size: finalSize))
            }
            
            // CoreGraphics 坐标系翻转
            ctx.cgContext.translateBy(x: 0, y: finalSize.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            
            let scaleX = finalSize.width / mediaBox.width
            let scaleY = finalSize.height / mediaBox.height
            ctx.cgContext.scaleBy(x: scaleX, y: scaleY)
            
            page.draw(with: .cropBox, to: ctx.cgContext)
            
            for annotation in page.annotations {
                annotation.draw(with: .cropBox, in: ctx.cgContext)
            }
        }
        
        let data: Data?
        
        if ext == "png" {
            data = image.pngData()
        } else if ext == "jpg" || ext == "jpeg" {
            data = image.jpegData(compressionQuality: 0.8)
        } else {
            data = image.pngData()
        }
        
        guard let finalData = data else { return false }
        
        do {
            try finalData.write(to: url, options: .atomic)
            return true
        } catch {
            print("Failed to write image data to \(url.path): \(error)")
            return false
        }
        #endif
    }
    
    #if os(macOS)
    
    // 用于桥接 NSPopUpButton 和 NSTextField 的委托类
    class SavePanelAccessoryDelegate: NSObject, NSTextFieldDelegate {
        let panel: NSSavePanel
        let types: [UTType]
        let originalSize: CGSize
        
        var targetSize: CGSize
        weak var widthField: NSTextField?
        weak var heightField: NSTextField?
        
        init(panel: NSSavePanel, types: [UTType], originalSize: CGSize) {
            self.panel = panel
            self.types = types
            self.originalSize = originalSize
            self.targetSize = originalSize
            super.init()
        }
        
        @objc func formatChanged(_ sender: NSPopUpButton) {
            let selectedIndex = sender.indexOfSelectedItem
            if selectedIndex >= 0 && selectedIndex < types.count {
                panel.allowedContentTypes = [types[selectedIndex]]
            }
        }
        
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let wField = widthField,
                  let hField = heightField else { return }
            
            let aspectRatio = originalSize.width / max(1, originalSize.height)
            
            if field == wField {
                if let w = Double(wField.stringValue), w > 0 {
                    let h = w / aspectRatio
                    hField.stringValue = String(format: "%.0f", h)
                    targetSize = CGSize(width: w, height: h)
                }
            } else if field == hField {
                if let h = Double(hField.stringValue), h > 0 {
                    let w = h * aspectRatio
                    wField.stringValue = String(format: "%.0f", w)
                    targetSize = CGSize(width: w, height: h)
                }
            }
        }
    }
    
    @MainActor
    static func promptSaveAs(pdfDocument: PDFDocument, originalURL: URL, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Save Image As", comment: "")
        let ext = originalURL.pathExtension.lowercased()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName)-copy"
        
        let types: [UTType] = [.pdf, .png, .jpeg, .tiff]
        let typeNames = ["PDF Document", "PNG Image", "JPEG Image", "TIFF Image"]
        
        // 默认选中当前图像的格式
        var defaultIndex = 1
        if ext == "pdf" { defaultIndex = 0 }
        else if ext == "jpg" || ext == "jpeg" { defaultIndex = 2 }
        else if ext == "tiff" || ext == "tif" { defaultIndex = 3 }
        
        panel.allowedContentTypes = [types[defaultIndex]]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        
        let originalSize = pdfDocument.page(at: 0)?.bounds(for: .cropBox).size ?? .zero
        let delegate = SavePanelAccessoryDelegate(panel: panel, types: types, originalSize: originalSize)
        
        // 创建格式选择和像素大小的 Accessory View
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        
        // Format 行
        let formatLabel = NSTextField(labelWithString: NSLocalizedString("Format:", comment: ""))
        formatLabel.frame = NSRect(x: 10, y: 35, width: 60, height: 20)
        let popup = NSPopUpButton(frame: NSRect(x: 75, y: 33, width: 150, height: 24))
        popup.addItems(withTitles: typeNames.map { NSLocalizedString($0, comment: "") })
        popup.selectItem(at: defaultIndex)
        popup.target = delegate
        popup.action = #selector(SavePanelAccessoryDelegate.formatChanged(_:))
        
        // Size 行
        let sizeLabel = NSTextField(labelWithString: NSLocalizedString("Size (px):", comment: ""))
        sizeLabel.frame = NSRect(x: 10, y: 5, width: 65, height: 20)
        
        let widthField = NSTextField(frame: NSRect(x: 75, y: 5, width: 60, height: 20))
        widthField.stringValue = String(format: "%.0f", originalSize.width)
        widthField.delegate = delegate
        delegate.widthField = widthField
        
        let crossLabel = NSTextField(labelWithString: "x")
        crossLabel.frame = NSRect(x: 140, y: 5, width: 15, height: 20)
        
        let heightField = NSTextField(frame: NSRect(x: 155, y: 5, width: 60, height: 20))
        heightField.stringValue = String(format: "%.0f", originalSize.height)
        heightField.delegate = delegate
        delegate.heightField = heightField
        
        accessoryView.addSubview(formatLabel)
        accessoryView.addSubview(popup)
        accessoryView.addSubview(sizeLabel)
        accessoryView.addSubview(widthField)
        accessoryView.addSubview(crossLabel)
        accessoryView.addSubview(heightField)
        
        panel.accessoryView = accessoryView
        
        // 防止阻塞，捕获 delegate 保持其存活
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let savedExt = url.pathExtension.lowercased()
                let success: Bool
                if savedExt == "pdf" {
                    success = pdfDocument.write(to: url)
                } else {
                    success = exportPDFDocumentToOriginalImageFormat(pdfDocument: pdfDocument, originalURL: url, targetSize: delegate.targetSize)
                }
                completion(success ? url : nil)
            } else {
                completion(nil)
            }
            
            // 为了保持 delegate 存活
            _ = delegate
        }
    }
    #endif
}
