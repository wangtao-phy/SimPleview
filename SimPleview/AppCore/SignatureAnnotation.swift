#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit

/// 自定义签名图片标注类
/// 用于将通过 CoreImage 去背后的透明签名图片作为贴纸渲染在 PDF 页面上。
class SignatureAnnotation: PDFAnnotation {
    var image: PlatformImage?
    
    // 初始化标注
    init(image: PlatformImage, bounds: CGRect) {
        self.image = image
        // 声明为 Stamp 类型，以提供更好的原生交互支持
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }
    
    // [P1修复] 确保所有重写的方法都是 nonisolated，以符合 PDFAnnotation 的要求
    nonisolated override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable : Any]?) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    // 重写绘制方法，将透明签名图片绘制到标注的边界内
    nonisolated override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image = image else { return }
        #if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        #else
        guard let cgImage = image.cgImage else { return }
        #endif
        
        // 绘制图像（这里需要注意 PDF 的坐标系原点在左下角，CoreGraphics 绘制默认也对应左下角，所以通常不需要翻转）
        context.draw(cgImage, in: bounds)
    }
}
