import Foundation
import CoreGraphics

/// 文件流程共用的默认值。偏好及输入都经过相同的有限值、尺寸上限检查，
/// 避免损坏的偏好让图片分配过大的位图；PDF 尺寸单位为 pt，图片为 px。
enum FilePreferences {
    enum Paper: String, CaseIterable, Identifiable {
        case custom = "Custom", a4 = "A4", a3 = "A3", b5 = "B5", letter = "US Letter"
        var id: String { rawValue }
        var size: CGSize? {
            switch self {
            case .custom: nil
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .a3: CGSize(width: 841.89, height: 1190.55)
            case .b5: CGSize(width: 498.90, height: 708.66)
            case .letter: CGSize(width: 612, height: 792)
            }
        }
    }
    static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
            && size.width <= 16_384 && size.height <= 16_384 && size.width * size.height <= 100_000_000
    }
    static func newSize(defaults: UserDefaults = .standard) -> CGSize {
        if let paper = defaults.string(forKey: "newFilePaper").flatMap(Paper.init(rawValue:)), let size = paper.size { return size }
        let size = CGSize(width: defaults.object(forKey: "newFileWidth") as? Double ?? 1600,
                          height: defaults.object(forKey: "newFileHeight") as? Double ?? 800)
        return validSize(size) ? size : CGSize(width: 1600, height: 800)
    }
    static func insertedSize(reference: CGSize, defaults: UserDefaults = .standard) -> CGSize {
        switch defaults.string(forKey: "insertPagePaper") ?? "Match" {
        case "New": return newSize(defaults: defaults)
        case let value: return Paper(rawValue: value)?.size ?? (validSize(reference) ? reference : CGSize(width: 595.28, height: 841.89))
        }
    }
    static func imageSize(original: CGSize, defaults: UserDefaults = .standard) -> CGSize {
        let scale = defaults.object(forKey: "imageExportScale") as? Double ?? 1
        let size = CGSize(width: original.width * scale, height: original.height * scale)
        return validSize(size) ? size : original
    }
    static func jpegQuality(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: "jpegExportQuality") as? Double ?? 0.8
        return value.isFinite ? min(1, max(0.1, value)) : 0.8
    }
}
