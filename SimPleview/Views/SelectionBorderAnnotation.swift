import PDFKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 自定义的“选中状态”辅助批注。
/// 它的唯一使命是在页面上画一个半透明的蓝色边框，如果是处于多段高亮的最下方，还会附加一个“便签”图标。
class SelectionBorderAnnotation: PDFAnnotation {
    
    // 是否为当前批次中位置最靠下的批注，只有最靠下的才绘制便签图标
    nonisolated(unsafe) var isLowest: Bool = false
    
    nonisolated override init(bounds: CGRect, forType type: PDFAnnotationSubtype, withProperties properties: [AnyHashable : Any]?) {
        super.init(bounds: bounds, forType: type, withProperties: properties)
        setupProperties()
    }
    
    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupProperties()
    }
    
    nonisolated private func setupProperties() {
        self.shouldPrint = false
        self.isReadOnly = true
        self.userName = "SYSTEM_BORDER" // 标记为系统实体，避免被保存或意外编辑
        
        #if os(macOS)
        let accentColor: NSColor
        if #available(macOS 10.14, *) {
            accentColor = NSColor.controlAccentColor
        } else {
            accentColor = NSColor.systemBlue
        }
        self.color = accentColor.withAlphaComponent(0.8)
        #else
        self.color = UIColor.systemBlue.withAlphaComponent(0.8)
        self.interiorColor = .clear
        #endif
    }
    
    #if os(macOS)
    nonisolated override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // macOS 上如果调用 super.draw 可能会有默认的 square 样式，但自己绘制能保证细致的控制
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        
        let path = NSBezierPath(roundedRect: self.bounds, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        self.color.setStroke()
        path.stroke()
        
        // 如果是最低点的边框，我们画一个便签图标
        if isLowest {
            if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil) {
                let tintColor = self.color.withAlphaComponent(0.85)
                let finalIcon: NSImage
                if #available(macOS 12.0, *) {
                    let config = NSImage.SymbolConfiguration(hierarchicalColor: tintColor)
                    finalIcon = image.withSymbolConfiguration(config) ?? image
                } else {
                    finalIcon = image
                }
                
                // 将图标锚定在框的右下角
                let iconSize = CGSize(width: 14, height: 14)
                let iconRect = CGRect(x: self.bounds.maxX - iconSize.width,
                                      y: self.bounds.minY - iconSize.height - 2,
                                      width: iconSize.width, height: iconSize.height)
                
                finalIcon.draw(in: iconRect)
            }
        }
        
        NSGraphicsContext.restoreGraphicsState()
    }
    #endif
}
