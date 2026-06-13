import SwiftUI
import PDFKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import Combine
import os
import Vision

extension AppState {
    
    // MARK: - Signature Feature
    
    func processAndInsertSignature(imageURL: URL) {
        guard let transparentCGImage = createTransparentSignature(from: imageURL) else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let page = self.pdfView.currentPage else { return }
            
            let cgWidth = CGFloat(transparentCGImage.width)
            let cgHeight = CGFloat(transparentCGImage.height)
            let targetWidth: CGFloat = min(200, cgWidth)
            let targetHeight = cgHeight * (targetWidth / cgWidth)
            
            let pageBounds = page.bounds(for: .cropBox)
            let x = pageBounds.midX - targetWidth / 2
            let y = pageBounds.midY - targetHeight / 2
            let bounds = NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
            
            // [Vision 极客黑科技] 将位图提取为矢量路径
            guard let (path, avgColor) = self.extractVectorPathAndColor(from: transparentCGImage) else { return }
            let annotation = VectorSignatureAnnotation(path: path, color: avgColor, bounds: bounds)
            
            _ = self.annotationManager.applySignature(annotation: annotation, to: page, pdfView: self.pdfView) { index in
                self.thumbnailManager.cancelThumbnail(for: index)
                self.thumbnailManager.removeThumbnail(for: index)
                self.generateThumbnail(for: index)
            }
            
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
    
    // [Vision 黑科技：矢量提取]
    func extractVectorPathAndColor(from cgImage: CGImage) -> (CGPath, PlatformColor)? {
        // 1. 提取颜色：我们抽样非透明像素，求平均颜色
        let color = extractAverageDarkColor(from: cgImage)
        
        // 2. 图像预处理：VNDetectContoursRequest 对黑底白字效果最好。
        // 原图是透明底、深色字。我们将透明底填充为黑色，字变成白色。
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        
        // 黑底
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // 将原图绘制为白色：用原图作为 mask 绘制白色
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: cgImage)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        
        guard let maskImage = context.makeImage() else { return nil }
        
        // 3. 执行 Vision 请求
        let requestHandler = VNImageRequestHandler(cgImage: maskImage, options: [:])
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0 // 强化对比度
        request.detectsDarkOnLight = false // 我们做的是黑底白字
        
        do {
            try requestHandler.perform([request])
            if let obs = request.results?.first as? VNContoursObservation {
                // normalizedPath 返回的是归一化路径 (0~1)，且 y 轴朝上，与 PDFKit 完美契合！
                return (obs.normalizedPath, color)
            }
        } catch {
            print("Vision failed: \(error)")
        }
        
        return nil
    }
    
    // 简单的颜色采样：取非透明且较暗像素的平均值
    private func extractAverageDarkColor(from cgImage: CGImage) -> PlatformColor {
        let thumbWidth = 50
        let thumbHeight = 50
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bitmapData = [UInt8](repeating: 0, count: thumbWidth * thumbHeight * 4)
        
        guard let context = CGContext(data: &bitmapData, width: thumbWidth, height: thumbHeight, bitsPerComponent: 8, bytesPerRow: thumbWidth * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return PlatformColor.black
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        
        var rSum: Int = 0
        var gSum: Int = 0
        var bSum: Int = 0
        var count: Int = 0
        
        for i in 0..<(thumbWidth * thumbHeight) {
            let offset = i * 4
            let r = Int(bitmapData[offset])
            let g = Int(bitmapData[offset + 1])
            let b = Int(bitmapData[offset + 2])
            let a = Int(bitmapData[offset + 3])
            
            // 过滤掉透明和过白的像素
            if a > 100 {
                let brightness = (r * 299 + g * 587 + b * 114) / 1000
                if brightness < 200 {
                    rSum += r
                    gSum += g
                    bSum += b
                    count += 1
                }
            }
        }
        
        if count > 0 {
            #if os(macOS)
            return NSColor(calibratedRed: CGFloat(rSum/count)/255.0, green: CGFloat(gSum/count)/255.0, blue: CGFloat(bSum/count)/255.0, alpha: 1.0)
            #else
            return UIColor(red: CGFloat(rSum/count)/255.0, green: CGFloat(gSum/count)/255.0, blue: CGFloat(bSum/count)/255.0, alpha: 1.0)
            #endif
        }
        
        return PlatformColor.black
    }
}
