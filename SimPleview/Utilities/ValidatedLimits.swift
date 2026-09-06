import Foundation

/// 偏好设置和文档元数据都视为可损坏输入。先排除 NaN/无穷值，再钳位，
/// 最后才转换为整数/纳秒；直接 UInt64(Double.infinity) 会使进程陷阱退出。
nonisolated enum ValidatedLimits {
    static func seconds(_ text: String, fallback: Double = 15, maximum: Double = 86_400) -> Double {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0 else { return fallback }
        return min(value, maximum)
    }

    static func count(_ value: Double, fallback: Int, range: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return fallback }
        return Int(min(Double(range.upperBound), max(Double(range.lowerBound), value)))
    }
}
