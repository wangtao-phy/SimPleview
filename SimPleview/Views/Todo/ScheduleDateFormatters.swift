import Foundation

// MARK: - 静态时间格式化缓存 (消除高频重绘时的多余堆内存分配)

@MainActor enum ScheduleDateFormatters {
    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    static let monthHeader: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月"
        return f
    }()

    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dateAndHour: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    static let allDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 全天"
        return f
    }()

    static let todayDue: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "今天 HH:mm"
        return f
    }()

    static let tomorrowDue: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "明天 HH:mm"
        return f
    }()

    static let otherDue: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
