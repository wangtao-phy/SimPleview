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

    func localizedTitle(in language: AppLanguage) -> String {
        switch self {
        case .none: return L.s("No Repeat", language)
        case .daily: return L.s("Repeat Daily", language)
        case .weekly: return L.s("Repeat Weekly", language)
        case .biweekly: return L.s("Repeat Biweekly", language)
        case .monthly: return L.s("Repeat Monthly", language)
        case .yearly: return L.s("Repeat Yearly", language)
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

    func localizedTitle(in language: AppLanguage) -> String {
        switch self {
        case .none: return L.s("No Alert", language)
        case .atTime: return L.s("At Event Time", language)
        case .before5m: return L.s("5 Minutes Before", language)
        case .before15m: return L.s("15 Minutes Before", language)
        case .before30m: return L.s("30 Minutes Before", language)
        case .before1h: return L.s("1 Hour Before", language)
        case .before2h: return L.s("2 Hours Before", language)
        case .before1d: return L.s("1 Day Before", language)
        case .before2d: return L.s("2 Days Before", language)
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
