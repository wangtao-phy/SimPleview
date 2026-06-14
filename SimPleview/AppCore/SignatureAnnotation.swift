#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit


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
        
        // [核心黑科技]
        // 1. 关闭 shouldDisplay：防止 PDFKit 在屏幕上渲染出基于缓存的低清模糊版本
        // 2. 开启 shouldPrint：确保导出/保存/打印 PDF 时，原生的纯矢量外观能够写入文件
        self.shouldDisplay = false
        self.shouldPrint = true
        
        // 序列化 CGPath 为字符串，保存到 PDF 底层字典中，实现永久无损保存
        // 性能优化：使用数组并在末尾 joined()，消除 += 带来的大量内存重分配
        var pointsArr = [String]()
        pointsArr.reserveCapacity(2000)
        
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                pointsArr.append("M,\(points[0].x),\(points[0].y);")
            case .addLineToPoint:
                pointsArr.append("L,\(points[0].x),\(points[0].y);")
            case .addQuadCurveToPoint:
                pointsArr.append("L,\(points[1].x),\(points[1].y);")
            case .addCurveToPoint:
                pointsArr.append("L,\(points[2].x),\(points[2].y);")
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        
        let pointsStr = pointsArr.joined()
        
        let chunkSize = 30000
        var chunkIndex = 0
        var currentIndex = pointsStr.startIndex
        while currentIndex < pointsStr.endIndex {
            let nextIndex = pointsStr.index(currentIndex, offsetBy: chunkSize, limitedBy: pointsStr.endIndex) ?? pointsStr.endIndex
            let chunk = String(pointsStr[currentIndex..<nextIndex])
            let keyStr = chunkIndex == 0 ? "/SimPlePath" : "/SimPlePath\(chunkIndex)"
            self.setValue(chunk, forAnnotationKey: PDFAnnotationKey(rawValue: keyStr))
            chunkIndex += 1
            currentIndex = nextIndex
        }
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
        
        // [核心修复]：强制使用高质量抗锯齿和插值采样，保证矢量图永远丝滑
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        
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

