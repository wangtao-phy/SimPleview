import Foundation
@preconcurrency import EventKit
import Combine
import AppKit
import os

/// 每个待办面板拥有自己的 EventKit 存储和浏览月份，避免多窗口互相覆盖日程。
/// 通知只触发合并刷新；面板关闭后，订阅随管理器释放。
@MainActor
final class EventManager: ObservableObject {
    let eventStore: EKEventStore
    
    // 响应式状态发布
    @Published var reminderAuthStatus: EKAuthorizationStatus = .notDetermined
    @Published var calendarAuthStatus: EKAuthorizationStatus = .notDetermined
    
    @Published var reminders: [EKReminder] = []
    @Published var events: [EKEvent] = []
    
    @Published var isLoadingReminders: Bool = false
    @Published var isLoadingEvents: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var remindersNeedRefresh = false
    private var eventStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    private var eventEnd = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    
    private func text(_ key: String) -> String {
        L.s(key, UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .zh)
    }

    // 权限便捷判定
    var hasReminderAccess: Bool {
        if #available(macOS 14.0, *) {
            return reminderAuthStatus == .fullAccess
        } else {
            return reminderAuthStatus == .authorized
        }
    }
    
    var hasCalendarAccess: Bool {
        if #available(macOS 14.0, *) {
            // 只写权限不能读取日程或分类列表，不能把它当作日历已授权。
            return calendarAuthStatus == .fullAccess
        } else {
            return calendarAuthStatus == .authorized
        }
    }
    
    var isReminderDenied: Bool {
        reminderAuthStatus == .denied || reminderAuthStatus == .restricted
    }
    
    var isCalendarDenied: Bool {
        calendarAuthStatus == .denied || calendarAuthStatus == .restricted
    }
    
    init(eventStore: EKEventStore = EKEventStore(), observesChanges: Bool = true) {
        self.eventStore = eventStore
        updateAuthStatuses()
        if observesChanges { setupStoreObserver() }
    }
    
    /// 刷新当前系统对提醒与日历的授权状态
    func updateAuthStatuses() {
        reminderAuthStatus = EKEventStore.authorizationStatus(for: .reminder)
        calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
        if !hasReminderAccess { reminders = [] }
        if !hasCalendarAccess { events = [] }
    }
    
    /// 回到应用时只重检权限，不 reset：reset 会使表单持有的日历/日程对象失效。
    func recheckAuthorization() {
        updateAuthStatuses()
        Task { [weak self] in
            await self?.refreshAll()
        }
    }
    
    /// 一次保存可能连续触发多条系统通知，短暂合并，避免反复全量读取。
    private func setupStoreObserver() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: eventStore)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.refreshAll()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 权限请求 (Authorization)
    
    /// 请求系统“提醒事项”访问权限
    @discardableResult
    func requestReminderAccess() async -> Bool {
        updateAuthStatuses()
        if isReminderDenied {
            openReminderPrivacySettings()
            return false
        }
        
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToReminders()
            } else {
                granted = try await eventStore.requestAccess(to: .reminder)
            }
            updateAuthStatuses()
            if granted {
                await fetchReminders()
            }
            return granted
        } catch {
            Logger.view.error("请求提醒事项权限失败: \(error)")
            updateAuthStatuses()
            return false
        }
    }
    
    /// 请求系统“日历”访问权限
    @discardableResult
    func requestCalendarAccess() async -> Bool {
        updateAuthStatuses()
        if isCalendarDenied {
            openCalendarPrivacySettings()
            return false
        }
        
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            updateAuthStatuses()
            if granted {
                await fetchEvents()
            }
            return granted
        } catch {
            Logger.view.error("请求日历权限失败: \(error)")
            updateAuthStatuses()
            return false
        }
    }
    
    /// 一键打开 macOS 系统设置隐私与安全性 -> 提醒事项
    func openReminderPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// 一键打开 macOS 系统设置隐私与安全性 -> 日历
    func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// 一键请求两项权限
    func requestAllAccess() async {
        _ = await requestReminderAccess()
        _ = await requestCalendarAccess()
    }
    
    // MARK: - 数据拉取 (Fetch Operators)
    
    /// 全量刷新数据
    func refreshAll() async {
        updateAuthStatuses()
        if hasReminderAccess {
            await fetchReminders()
        }
        if hasCalendarAccess {
            await fetchEvents()
        }
    }
    
    /// 从 macOS 原生数据库拉取待办事项
    func fetchReminders() async {
        guard hasReminderAccess else { return }
        // 同一时刻只保留一次查询；查询期间的变化在结束后补读，旧结果不会覆盖新结果。
        guard !isLoadingReminders else { remindersNeedRefresh = true; return }
        isLoadingReminders = true
        defer { isLoadingReminders = false }
        repeat {
            remindersNeedRefresh = false
            let predicate = eventStore.predicateForReminders(in: nil)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                eventStore.fetchReminders(matching: predicate) { [weak self] list in
                    DispatchQueue.main.async {
                        defer { continuation.resume() }
                        guard let self, self.hasReminderAccess, let list else { return }
                        self.reminders = list.sorted { r1, r2 in
                            if r1.isCompleted != r2.isCompleted { return !r1.isCompleted }
                            let d1 = r1.dueDateComponents?.date ?? Date.distantFuture
                            let d2 = r2.dueDateComponents?.date ?? Date.distantFuture
                            if d1 != d2 { return d1 < d2 }
                            return r1.calendarItemIdentifier < r2.calendarItemIdentifier
                        }
                    }
                }
            }
        } while remindersNeedRefresh && hasReminderAccess && !Task.isCancelled
    }

    /// 保留当前浏览的月份范围，新增、删除和系统通知不会把远处月份刷成空白。
    func fetchEvents(from startDate: Date? = nil, to endDate: Date? = nil) async {
        if let startDate { eventStart = startDate }
        if let endDate { eventEnd = endDate }
        guard hasCalendarAccess, eventStart < eventEnd else { return }
        isLoadingEvents = true
        defer { isLoadingEvents = false }
        let predicate = eventStore.predicateForEvents(withStart: eventStart, end: eventEnd, calendars: nil)
        events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - 提醒事项分类列表 (Calendars & SimPleview阅读)
    
    /// 获取可用的提醒事项列表（列表分类）
    func availableReminderCalendars() -> [EKCalendar] {
        guard hasReminderAccess else { return [] }
        return eventStore.calendars(for: .reminder)
    }
    
    /// 默认提醒事项列表
    func defaultReminderCalendar() -> EKCalendar? {
        return eventStore.defaultCalendarForNewReminders() ?? availableReminderCalendars().first
    }
    
    /// 获取或自动创建“SimPleview阅读”专属提醒事项分类列表
    func getOrCreateSimPleviewCalendar() -> EKCalendar? {
        guard hasReminderAccess else { return nil }
        
        let reminderCalendars = eventStore.calendars(for: .reminder)
        if let existing = reminderCalendars.first(where: { $0.title == "SimPleview阅读" }) {
            return existing
        }
        
        // 自动新建“SimPleview阅读”列表
        // 查找支持创建 Reminders 的 Source (优先选择默认列表所在的 source，通常为 iCloud 或本地)
        guard let source = eventStore.defaultCalendarForNewReminders()?.source 
                ?? eventStore.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local })
                ?? eventStore.sources.first else {
            return defaultReminderCalendar()
        }
        
        let newCal = EKCalendar(for: .reminder, eventStore: eventStore)
        newCal.title = "SimPleview阅读"
        newCal.source = source
        newCal.color = NSColor.systemIndigo
        
        do {
            try eventStore.saveCalendar(newCal, commit: true)
            return newCal
        } catch {
            Logger.view.error("创建提醒事项列表失败: \(error)")
            return defaultReminderCalendar()
        }
    }
    
    /// 新建待办事项 (默认归档至“SimPleview阅读”列表)
    @discardableResult
    func createReminder(
        title: String,
        dueDate: Date? = nil,
        notes: String? = nil,
        priority: Int = 0,
        calendar: EKCalendar? = nil
    ) async throws -> EKReminder {
        guard hasReminderAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: text("Reminder Access Required")])
        }
        
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "EventManager", code: 400, userInfo: [NSLocalizedDescriptionKey: text("Title Required")])
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority
        // 默认落入“SimPleview阅读”分类列表
        reminder.calendar = calendar ?? getOrCreateSimPleviewCalendar() ?? defaultReminderCalendar()
        
        if let due = dueDate {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.dueDateComponents = components
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        
        try eventStore.save(reminder, commit: true)
        await fetchReminders()
        return reminder
    }
    
    /// 切换待办事项的完成状态 (0 <-> 1 态跃迁)
    func toggleReminderCompletion(_ reminder: EKReminder) async throws {
        guard hasReminderAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: text("Reminder Access Required")])
        }
        let wasCompleted = reminder.isCompleted, oldCompletionDate = reminder.completionDate
        reminder.isCompleted.toggle()
        if reminder.isCompleted {
            reminder.completionDate = Date()
        } else {
            reminder.completionDate = nil
        }
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            // EKReminder 是引用对象；写盘失败必须恢复列表中的勾选状态。
            objectWillChange.send()
            reminder.isCompleted = wasCompleted
            reminder.completionDate = oldCompletionDate
            throw error
        }
        await fetchReminders()
    }
    
    /// 删除待办事项
    func deleteReminder(_ reminder: EKReminder) async throws {
        guard hasReminderAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: text("Reminder Access Required")])
        }
        try eventStore.remove(reminder, commit: true)
        await fetchReminders()
    }
    
    /// 拉取指定月份周边的日程数据
    func fetchEventsForMonth(_ month: Date) async {
        let cal = Calendar.current
        guard let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let endOfMonth = cal.date(byAdding: .month, value: 1, to: startOfMonth) else { return }
        let s = cal.date(byAdding: .day, value: -14, to: startOfMonth) ?? startOfMonth
        let e = cal.date(byAdding: .day, value: 14, to: endOfMonth) ?? endOfMonth
        await fetchEvents(from: s, to: e)
    }
    
    // MARK: - 日历日程 CRUD
    
    /// 获取可用的日历列表（如个人、工作、学术等分类）
    func availableEventCalendars() -> [EKCalendar] {
        guard hasCalendarAccess else { return [] }
        return eventStore.calendars(for: .event)
    }
    
    /// 默认日历分类
    func defaultEventCalendar() -> EKCalendar? {
        return eventStore.defaultCalendarForNewEvents ?? availableEventCalendars().first
    }
    
    /// 获取或自动创建“SimPleview阅读”专属日历分类列表
    func getOrCreateSimPleviewEventCalendar() -> EKCalendar? {
        guard hasCalendarAccess else { return nil }
        let eventCalendars = eventStore.calendars(for: .event)
        if let existing = eventCalendars.first(where: { $0.title == "SimPleview阅读" }) {
            return existing
        }
        
        guard let source = eventStore.defaultCalendarForNewEvents?.source 
                ?? eventStore.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local })
                ?? eventStore.sources.first else {
            return defaultEventCalendar()
        }
        
        let newCal = EKCalendar(for: .event, eventStore: eventStore)
        newCal.title = "SimPleview阅读"
        newCal.source = source
        newCal.color = NSColor.systemIndigo
        
        do {
            try eventStore.saveCalendar(newCal, commit: true)
            return newCal
        } catch {
            Logger.view.error("创建日历失败: \(error)")
            return defaultEventCalendar()
        }
    }
    
    /// 新建日历日程 (默认归档至“SimPleview阅读”)
    @discardableResult
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        notes: String? = nil,
        calendar: EKCalendar? = nil,
        recurrence: EventRecurrenceOption = .none,
        alert: EventAlertOption = .none
    ) async throws -> EKEvent {
        guard hasCalendarAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: text("Calendar Access Required")])
        }
        
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "EventManager", code: 400, userInfo: [NSLocalizedDescriptionKey: text("Title Required")])
        }
        guard endDate >= startDate else {
            throw NSError(domain: "EventManager", code: 400, userInfo: [NSLocalizedDescriptionKey: text("Invalid Event Dates")])
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        event.notes = notes
        event.calendar = calendar ?? getOrCreateSimPleviewEventCalendar() ?? defaultEventCalendar()
        
        if let rule = recurrence.toRecurrenceRule() {
            event.recurrenceRules = [rule]
        }
        
        if let offset = alert.relativeOffset {
            event.alarms = [EKAlarm(relativeOffset: offset)]
        }
        
        try eventStore.save(event, span: .thisEvent, commit: true)
        await fetchEvents()
        return event
    }
    
    /// 修改并保存已有日程信息 (支持重复日程与提前提醒设置)
    func updateEvent(
        _ event: EKEvent,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        notes: String?,
        calendar: EKCalendar?,
        recurrence: EventRecurrenceOption = .none,
        alert: EventAlertOption = .none
    ) async throws {
        guard hasCalendarAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: text("Calendar Access Required")])
        }
        
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "EventManager", code: 400, userInfo: [NSLocalizedDescriptionKey: text("Title Required")])
        }
        guard endDate >= startDate else {
            throw NSError(domain: "EventManager", code: 400, userInfo: [NSLocalizedDescriptionKey: text("Invalid Event Dates")])
        }

        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        event.notes = notes
        if let cal = calendar {
            event.calendar = cal
        }
        
        // 更新重复规则
        if let rule = recurrence.toRecurrenceRule() {
            event.recurrenceRules = [rule]
        } else {
            event.recurrenceRules = nil
        }
        
        // 更新提醒
        if let offset = alert.relativeOffset {
            event.alarms = [EKAlarm(relativeOffset: offset)]
        } else {
            event.alarms = nil
        }
        
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            // 列表重新读取已保存值，编辑表单仍保留用户输入用于重试。
            await fetchEvents()
            throw error
        }
        await fetchEvents()
    }
    
    /// 删除日历日程
    func deleteEvent(_ event: EKEvent) async throws {
        guard hasCalendarAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: text("Calendar Access Required")])
        }
        try eventStore.remove(event, span: .thisEvent, commit: true)
        await fetchEvents()
    }
}

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
