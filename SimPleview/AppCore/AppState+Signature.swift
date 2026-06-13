import SwiftUI
import PDFKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import Combine
import os

extension AppState {
    
    // MARK: - Signature Feature
    
    func processAndInsertSignature(imageURL: URL) {
        guard let transparentCGImage = createTransparentSignature(from: imageURL) else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let page = self.pdfView.currentPage else { return }
            
            // 计算合适的大小，限制最大宽度为 200
            let cgWidth = CGFloat(transparentCGImage.width)
            let cgHeight = CGFloat(transparentCGImage.height)
            let targetWidth: CGFloat = min(200, cgWidth)
            let targetHeight = cgHeight * (targetWidth / cgWidth)
            
            // 放在页面中心
            let pageBounds = page.bounds(for: .cropBox)
            let x = pageBounds.midX - targetWidth / 2
            let y = pageBounds.midY - targetHeight / 2
            let bounds = NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
            
            _ = self.annotationManager.applySignature(cgImage: transparentCGImage, bounds: bounds, to: page, pdfView: self.pdfView) { index in
                self.thumbnailManager.cancelThumbnail(for: index)
                self.thumbnailManager.removeThumbnail(for: index)
                self.generateThumbnail(for: index)
            }
            
            // 触发整体状态刷新
            DispatchQueue.main.async {
                self.isDirty = true
                self.annotationManager.objectWillChange.send()
            }
        }
    }
    
    // [核心基础设施：签名专属文件夹管理]
    func getSignatureDirectory() -> URL {
        return DirectoryManager.shared.getDirectory(for: "signature")
    }
    
    // 从外部导入一张新图片作为签名，保存到专属文件夹中
    func importSignature(from url: URL) throws -> URL {
        let signatureDir = getSignatureDirectory()
        // 生成唯一安全的文件名以防重名覆盖
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let newURL = signatureDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        
        try FileManager.default.copyItem(at: url, to: newURL)
        return newURL
    }
    
    #if os(macOS)
    private func createTransparentSignature(from imageURL: URL) -> CGImage? {
        // [极重要修复]: 必须应用图片的 EXIF 方向信息！否则手机拍的签名会因为方向不对而被挤压变形，导致“极其模糊”。
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard let ciImage = CIImage(contentsOf: imageURL, options: options) else { return nil }
        
        // 1. 获取灰度图（提取明暗信息）
        let monoFilter = CIFilter.photoEffectMono()
        monoFilter.inputImage = ciImage
        guard let monoImage = monoFilter.outputImage else { return nil }
        
        // 2. 反相（白底变黑，黑色/深色笔迹变白）
        let invertFilter = CIFilter.colorInvert()
        invertFilter.inputImage = monoImage
        guard let inverted = invertFilter.outputImage else { return nil }
        
        // 3. 增加对比度，确保笔迹部分的 Alpha 足够不透明
        let contrastFilter = CIFilter.colorControls()
        contrastFilter.inputImage = inverted
        contrastFilter.contrast = 3.0
        guard let maskImage = contrastFilter.outputImage else { return nil }
        
        // 4. 使用提取出的 mask 作为 Alpha 遮罩，将原图抠出来（保留原色）
        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = ciImage
        blendFilter.backgroundImage = CIImage(color: CIColor.clear).cropped(to: ciImage.extent)
        blendFilter.maskImage = maskImage
        guard let finalCIImage = blendFilter.outputImage else { return nil }
        
        let context = CIContext(options: nil)
        return context.createCGImage(finalCIImage, from: finalCIImage.extent)
    }
    #endif
}
