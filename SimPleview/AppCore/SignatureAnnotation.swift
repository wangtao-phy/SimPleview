#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit

/// 自定义签名图片标注类
/// 用于将通过 CoreImage 去背后的透明签名图片作为贴纸渲染在 PDF 页面上。
class SignatureAnnotation: PDFAnnotation {
    nonisolated(unsafe) var customCGImage: CGImage?
    
    // 初始化标注
    init(cgImage: CGImage, bounds: CGRect) {
        self.customCGImage = cgImage
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
        guard let cgImage = customCGImage else { return }
        
        
        context.saveGState()
        // [核心修复]：强制使用高质量抗锯齿和插值采样
        // 在 macOS Sequoia 中，PDFKit 给定的默认上下文在执行大幅度缩放时，
        // 采样质量极低（会呈现马赛克或严重模糊）。必须显式提升插值质量！
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        
        // 绘制图像（这里需要注意 PDF 的坐标系原点在左下角，CoreGraphics 绘制默认也对应左下角，所以通常不需要翻转）
        context.draw(cgImage, in: bounds)
        
        context.restoreGState()
    }
}

/// 一个使用矢量路径 (CGPath) 绘制的高清无损签名标注
class VectorSignatureAnnotation: PDFAnnotation {
    
    // 我们保存一个 CGPath
    nonisolated(unsafe) let vectorPath: CGPath
    let themeColor: PlatformColor
    
    init(path: CGPath, color: PlatformColor, bounds: CGRect) {
        self.vectorPath = path
        self.themeColor = color
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.color = color
    }
    
    nonisolated override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable : Any]?) {
        fatalError("init(bounds:forType:withProperties:) has not been implemented")
    }
    
    nonisolated required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    nonisolated override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // [极客级绘制]
        // 由于我们传入的 CGPath 是 normalized 坐标 (0~1)，
        // 我们需要在绘制前将它放缩到当前的 bounds
        
        context.saveGState()
        
        // 1. 移动到起始点
        context.translateBy(x: bounds.minX, y: bounds.minY)
        
        // 2. 根据 bounds 缩放 normalized path
        context.scaleBy(x: bounds.width, y: bounds.height)
        
        // 3. 设置绘制颜色
        context.setFillColor(themeColor.cgColor)
        
        // 4. 添加路径并填充 (使用 even-odd 规则填充，以保留圈里的空白，但 VNDetectContoursRequest 生成的 contour 用 fill 即可正确镂空)
        context.addPath(vectorPath)
        context.fillPath() // 默认是非零环绕规则，由于 Vision 提取的内外轮廓方向相反，此规则恰好完美实现“环形填充”！
        
        context.restoreGState()
    }
}

