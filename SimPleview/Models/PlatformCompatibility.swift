import SwiftUI
import PDFKit
import Combine

/// [教程注释：跨平台抽象层]
/// 这个文件是实现 macOS 和 iOS 代码共用（跨平台开发）的关键技巧。
/// 通过 `#if os(macOS)` 这种编译指令 (Conditional Compilation Block)，
/// 我们可以让编译器在 macOS 下编译一段代码，在 iOS 下编译另一段代码。

#if os(macOS)
import AppKit

// [核心概念：typealias (类型别名)]
// 给现有的类型起一个新名字。在这里，我们把 macOS 专属的 NSColor 统一命名为 PlatformColor。
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformView = NSView
typealias PlatformViewController = NSViewController
#else
import UIKit

// 在 iOS 下，我们把 UIKit 专属的 UIColor 也命名为 PlatformColor。
// 这样在我们的跨平台业务代码中，只需要使用 `PlatformColor`，它就能在编译时自动匹配对应平台的正确类！
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
typealias PlatformView = UIView
typealias PlatformViewController = UIViewController
#endif

// [教程注释：对类型别名进行扩展]
// 扩展 (Extension) 可以为现有的类型添加新的静态属性或方法。
extension PlatformColor {
    // 提供统一的蓝色。这样无论在 Mac 还是 iPhone 上，调用 PlatformColor.platformBlue 都能拿到正确的系统蓝色。
    static var platformBlue: PlatformColor {
        #if os(macOS)
        return .systemBlue
        #else
        return .systemBlue
        #endif
    }
    
    static var platformYellow: PlatformColor {
        #if os(macOS)
        return .systemYellow
        #else
        return .systemYellow
        #endif
    }
    
    static var platformRed: PlatformColor {
        #if os(macOS)
        return .systemRed
        #else
        return .systemRed
        #endif
    }
    
    static var platformGreen: PlatformColor {
        #if os(macOS)
        return .systemGreen
        #else
        return .systemGreen
        #endif
    }
    
    static var platformPurple: PlatformColor {
        #if os(macOS)
        return .systemPurple
        #else
        return .systemPurple
        #endif
    }
    
    // [逻辑流程：适配深色模式背景]
    // 这里的背景色在 iOS 和 macOS 下的名字不同，通过别名完美屏蔽了这些细微差异。
    static var platformControlBackground: PlatformColor {
        #if os(macOS)
        return .controlBackgroundColor
        #else
        return .systemBackground
        #endif
    }
    
    static var platformClear: PlatformColor {
        #if os(macOS)
        return .clear
        #else
        return .clear
        #endif
    }
}

/// [教程注释：扩展原生 PDFKit 类]
extension PDFPage {
    // 统一各个平台提取 PDF 页面缩略图的方法。虽然目前名字一样，但有时候两个平台的 API 会有细微的参数差别，
    // 把它们包裹在一个自定义函数里能有效隔离风险。
    nonisolated func platformThumbnail(of size: CGSize, for box: PDFDisplayBox) -> PlatformImage {
        // 节约模式：手动使用底层的 CGContext 绘制缩略图，避免原生 thumbnail() 产生的底层缓存
        if MemoryMode.current == .saving {
            #if os(macOS)
            let img = NSImage(size: size)
            img.lockFocus()
            guard let context = NSGraphicsContext.current?.cgContext else {
                img.unlockFocus()
                return self.thumbnail(of: size, for: box)
            }
            // 填充白底，防止没背景的 PDF 显示黑底
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            
            let pageRect = self.bounds(for: box)
            let scaleX = size.width / pageRect.width
            let scaleY = size.height / pageRect.height
            let scale = min(scaleX, scaleY)
            
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            
            self.draw(with: box, to: context)
            img.unlockFocus()
            return img
            #else
            let format = UIGraphicsImageRendererFormat()
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.image { ctx in
                let cgContext = ctx.cgContext
                cgContext.setFillColor(UIColor.white.cgColor)
                cgContext.fill(CGRect(origin: .zero, size: size))
                
                let pageRect = self.bounds(for: box)
                let scaleX = size.width / pageRect.width
                let scaleY = size.height / pageRect.height
                let scale = min(scaleX, scaleY)
                
                // iOS 的 CoreGraphics 坐标系翻转
                cgContext.translateBy(x: 0, y: size.height)
                cgContext.scaleBy(x: 1.0, y: -1.0)
                
                cgContext.scaleBy(x: scale, y: scale)
                cgContext.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
                
                self.draw(with: box, to: cgContext)
            }
            #endif
        } else {
            // 性能模式下，我们依赖系统的极限缓存来保证最高顺滑度
            #if os(macOS)
            return self.thumbnail(of: size, for: box)
            #else
            return self.thumbnail(of: size, for: box)
            #endif
        }
    }
}

/// [教程注释：扩展 SwiftUI 的 Image]
/// 让 SwiftUI 的 Image 能够直接接收我们上面定义的 `PlatformImage`。
extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// [教程注释：统一视图刷新机制]
/// macOS 使用 `needsDisplay = true` 来要求系统重绘视图。
/// iOS 使用 `setNeedsDisplay()` 方法。
/// 这里我们将它们统一为一个方法。
extension PlatformView {
    func setPlatformNeedsDisplay() {
        #if os(macOS)
        self.needsDisplay = true
        #else
        self.setNeedsDisplay()
        #endif
    }
}

/// [教程注释：全局平台工具箱]
struct PlatformUtils {
    // [核心概念：静态计算属性]
    // 可以在运行时查询当前是哪个平台，方便在 UI 中做一些细微的动态调整。
    static var isMacOS: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
    
    static var isiOS: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
    
    // [逻辑流程：平台独占功能]
    // “在访达中显示” 只有 macOS 才有，如果是 iOS 调用这个方法，编译时会变成一个空函数，什么也不做。
    static func revealInFinder(url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
    
    static func updateWindows() {
        #if os(macOS)
        NSApp.updateWindows()
        #endif
    }
}
