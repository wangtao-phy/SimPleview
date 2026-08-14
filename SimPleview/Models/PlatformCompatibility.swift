import SwiftUI
import PDFKit
import Combine

import AppKit

/// 类型别名：将 AppKit 类型统一命名为简短别名，便于全 App 复用。
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformView = NSView
typealias PlatformViewController = NSViewController

// MARK: - 统一颜色入口
extension PlatformColor {
    static var platformBlue: PlatformColor { .systemBlue }
    static var platformYellow: PlatformColor { .systemYellow }
    static var platformRed: PlatformColor { .systemRed }
    static var platformGreen: PlatformColor { .systemGreen }
    static var platformPurple: PlatformColor { .systemPurple }
    static var platformControlBackground: PlatformColor { .controlBackgroundColor }
    static var platformClear: PlatformColor { .clear }
}

// MARK: - PDFPage 缩略图统一入口
extension PDFPage {
    /// 统一提取 PDF 页面缩略图。原生 `thumbnail(of:for:)` 已完美处理 rotation 与 cropBox。
    nonisolated func platformThumbnail(of size: CGSize, for box: PDFDisplayBox) -> PlatformImage {
        return self.thumbnail(of: size, for: box)
    }
}

// MARK: - SwiftUI Image 便捷初始化
extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

// MARK: - 视图重绘统一入口
extension PlatformView {
    func setPlatformNeedsDisplay() {
        self.needsDisplay = true
    }
}

// MARK: - 平台工具箱
struct PlatformUtils {
    static var isMacOS: Bool { true }
    static var isiOS: Bool { false }

    static func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func updateWindows() {
        NSApp.updateWindows()
    }
}
