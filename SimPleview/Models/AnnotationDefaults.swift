import Foundation

/// 新笔迹和新标注使用的粗细；校验旧偏好，避免非有限值进入 PDF 绘图。
@MainActor
enum AnnotationDefaults {
    static let lineWidthRange = 0.5...6.0
    static func lineWidth(in defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.object(forKey: "defaultLineWidth") as? Double ?? 3.0
        return CGFloat(value.isFinite ? min(lineWidthRange.upperBound, max(lineWidthRange.lowerBound, value)) : 3.0)
    }
}
