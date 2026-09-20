import Foundation

/// 两种界面语言分别缓存格式化器；不把首次使用时的中文格式永久固定下来。
/// 仅由主执行器使用，时区跟随系统；日期选择器由面板的 locale 环境统一控制。
@MainActor enum ScheduleDateFormatters {
    enum Style: Hashable { case dayHeader, monthHeader, timeOnly, dateAndHour, otherDue }
    private static var cache: [AppLanguage: [Style: DateFormatter]] = [:]

    static func string(_ date: Date, style: Style, language: AppLanguage) -> String {
        if let formatter = cache[language]?[style] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        switch style {
        case .dayHeader: formatter.setLocalizedDateFormatFromTemplate("MMM d EEEE")
        case .monthHeader: formatter.setLocalizedDateFormatFromTemplate("yyyy MMMM")
        case .timeOnly: formatter.dateFormat = "HH:mm"
        case .dateAndHour, .otherDue: formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
        }
        cache[language, default: [:]][style] = formatter
        return formatter.string(from: date)
    }

    static func due(_ date: Date, language: AppLanguage, calendar: Calendar = .current) -> String {
        let time = string(date, style: .timeOnly, language: language)
        if calendar.isDateInToday(date) { return L.s("Today", language) + " " + time }
        if calendar.isDateInTomorrow(date) { return L.s("Tomorrow", language) + " " + time }
        return string(date, style: .otherDue, language: language)
    }

    static func weekdays(language: AppLanguage, calendar: Calendar) -> [String] {
        var localized = calendar
        localized.locale = language.locale
        let symbols = localized.shortStandaloneWeekdaySymbols
        // 表头与日期网格必须使用同一个 firstWeekday，支持用户以周一开始一周。
        let offset = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + offset) % 7] }
    }
}
