import Foundation
@preconcurrency import EventKit

// MARK: - 日程高级选项：重复与提醒类型模型 (完全同构于 macOS 原生日历)

/// 日程重复周期类型 (完全同构于 macOS 原生日历)
enum EventRecurrenceOption: String, CaseIterable, Identifiable {
    case none = "none"
    case daily = "daily"
    case weekly = "weekly"
    case biweekly = "biweekly"
    case monthly = "monthly"
    case yearly = "yearly"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .none: return "无"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .biweekly: return "每两周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }

    static func from(rule: EKRecurrenceRule?) -> EventRecurrenceOption {
        guard let rule else { return .none }
        switch rule.frequency {
        case .daily:
            return .daily
        case .weekly:
            return rule.interval == 2 ? .biweekly : .weekly
        case .monthly:
            return .monthly
        case .yearly:
            return .yearly
        @unknown default:
            return .none
        }
    }

    func toRecurrenceRule() -> EKRecurrenceRule? {
        switch self {
        case .none:
            return nil
        case .daily:
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekly:
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .biweekly:
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case .monthly:
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly:
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }
}

/// 日程提醒偏置类型 (完全同构于 macOS 原生日历)
enum EventAlertOption: String, CaseIterable, Identifiable {
    case none = "none"
    case atTime = "atTime"
    case before5m = "before5m"
    case before15m = "before15m"
    case before30m = "before30m"
    case before1h = "before1h"
    case before2h = "before2h"
    case before1d = "before1d"
    case before2d = "before2d"

    var id: String { rawValue }

    var relativeOffset: TimeInterval? {
        switch self {
        case .none: return nil
        case .atTime: return 0
        case .before5m: return -300
        case .before15m: return -900
        case .before30m: return -1800
        case .before1h: return -3600
        case .before2h: return -7200
        case .before1d: return -86400
        case .before2d: return -172800
        }
    }

    var localizedTitle: String {
        switch self {
        case .none: return "无"
        case .atTime: return "日程发生时"
        case .before5m: return "5 分钟前"
        case .before15m: return "15 分钟前"
        case .before30m: return "30 分钟前"
        case .before1h: return "1 小时前"
        case .before2h: return "2 小时前"
        case .before1d: return "1 天前"
        case .before2d: return "2 天前"
        }
    }

    static func from(alarm: EKAlarm?) -> EventAlertOption {
        guard let alarm else { return .none }
        let offset = alarm.relativeOffset
        if abs(offset) < 1 { return .atTime }
        if abs(offset - (-300)) < 10 { return .before5m }
        if abs(offset - (-900)) < 10 { return .before15m }
        if abs(offset - (-1800)) < 10 { return .before30m }
        if abs(offset - (-3600)) < 10 { return .before1h }
        if abs(offset - (-7200)) < 10 { return .before2h }
        if abs(offset - (-86400)) < 10 { return .before1d }
        if abs(offset - (-172800)) < 10 { return .before2d }
        return .atTime
    }
}
