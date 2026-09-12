import Foundation
@preconcurrency import EventKit
import Combine
import AppKit

/// [理论物理与系统架构：宏观时间投影引擎 EventManager]
/// 该管理器作为 SimPleview 内部状态流形向 macOS 系统宏观时间流形的规范联络 (Gauge Connection)。
/// 它封装了底层 `EventKit.EKEventStore`，实现：
/// 1. 待办事项 (Reminders)：离散投影本征态的检测、完成度跃迁 (Completion) 与持久化落盘。
///    - 自动创建并默认挂载于专属的『SimPleview阅读』分类列表。
/// 2. 日程安排 (Events)：紧致时间区间的截取、世界线规划与日历归档。
/// 3. 实时双向退相干保护：通过监听 `.EKEventStoreChanged` 维持与系统原生“提醒事项”和“日历”的完全同构。
@MainActor
final class EventManager: ObservableObject {
    static let shared = EventManager()
    
    // 底层 EventKit 核心存储对象 (单例生命周期内保持复用，支持动态 reset 重建)
    private(set) var eventStore = EKEventStore()
    
    // 响应式状态发布
    @Published var reminderAuthStatus: EKAuthorizationStatus = .notDetermined
    @Published var calendarAuthStatus: EKAuthorizationStatus = .notDetermined
    
    @Published var reminders: [EKReminder] = []
    @Published var events: [EKEvent] = []
    
    @Published var isLoadingReminders: Bool = false
    @Published var isLoadingEvents: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    // 权限便捷判定
    var hasReminderAccess: Bool {
        if #available(macOS 14.0, *) {
            return reminderAuthStatus == .fullAccess || reminderAuthStatus == .authorized
        } else {
            return reminderAuthStatus == .authorized
        }
    }
    
    var hasCalendarAccess: Bool {
        if #available(macOS 14.0, *) {
            return calendarAuthStatus == .fullAccess || calendarAuthStatus == .authorized || calendarAuthStatus == .writeOnly
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
    
    private init() {
        updateAuthStatuses()
        setupStoreObserver()
    }
    
    /// 刷新当前系统对提醒与日历的授权状态
    func updateAuthStatuses() {
        reminderAuthStatus = EKEventStore.authorizationStatus(for: .reminder)
        calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
    }
    
    /// 重置存储并重新检测权限 (用于用户在系统设置修改权限后切回)
    func resetStoreAndAuth() {
        eventStore.reset()
        updateAuthStatuses()
        Task {
            await refreshAll()
        }
    }
    
    /// 注册系统原生日历/提醒数据库变更通知 (实现与 macOS 原生 App 的实时双向退相干同步)
    private func setupStoreObserver() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: eventStore)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.refreshAll()
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
            print("[EventManager] 请求提醒事项权限失败: \(error)")
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
            var granted: Bool = false
            if #available(macOS 14.0, *) {
                do {
                    granted = try await eventStore.requestFullAccessToEvents()
                } catch {
                    print("[EventManager] requestFullAccessToEvents error: \(error)")
                }
                if !granted {
                    do {
                        granted = try await eventStore.requestAccess(to: .event)
                    } catch {
                        print("[EventManager] fallback requestAccess(to: .event) error: \(error)")
                    }
                }
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            updateAuthStatuses()
            if granted {
                await fetchEvents()
            }
            return granted
        } catch {
            print("[EventManager] 请求日历权限失败: \(error)")
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
        isLoadingReminders = true
        defer { isLoadingReminders = false }
        
        let predicate = eventStore.predicateForReminders(in: nil)
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventStore.fetchReminders(matching: predicate) { [weak self] list in
                DispatchQueue.main.async {
                    guard let self = self else {
                        continuation.resume()
                        return
                    }
                    let fetched = list ?? []
                    self.reminders = fetched.sorted { r1, r2 in
                        if r1.isCompleted != r2.isCompleted {
                            return !r1.isCompleted && r2.isCompleted
                        }
                        let d1 = r1.dueDateComponents?.date ?? Date.distantFuture
                        let d2 = r2.dueDateComponents?.date ?? Date.distantFuture
                        return d1 < d2
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    /// 从 macOS 原生数据库拉取指定时间段内的日历日程 (默认显示前后 30 天/60 天)
    func fetchEvents(
        from startDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date(),
        to endDate: Date = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    ) async {
        guard hasCalendarAccess else { return }
        isLoadingEvents = true
        defer { isLoadingEvents = false }
        
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let list = eventStore.events(matching: predicate)
        
        self.events = list.sorted { $0.startDate < $1.startDate }
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
            print("[EventManager] 创建『SimPleview阅读』分类列表失败: \(error)")
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
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "未获得提醒事项访问权限"])
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
        guard hasReminderAccess else { return }
        reminder.isCompleted.toggle()
        if reminder.isCompleted {
            reminder.completionDate = Date()
        } else {
            reminder.completionDate = nil
        }
        try eventStore.save(reminder, commit: true)
        await fetchReminders()
    }
    
    /// 删除待办事项
    func deleteReminder(_ reminder: EKReminder) async throws {
        guard hasReminderAccess else { return }
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
            print("[EventManager] 创建『SimPleview阅读』日历分类失败: \(error)")
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
        calendar: EKCalendar? = nil
    ) async throws -> EKEvent {
        guard hasCalendarAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "未获得日历访问权限"])
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        event.notes = notes
        event.calendar = calendar ?? getOrCreateSimPleviewEventCalendar() ?? defaultEventCalendar()
        
        try eventStore.save(event, span: .thisEvent, commit: true)
        await fetchEvents()
        return event
    }
    
    /// 修改并保存已有日程信息
    func updateEvent(
        _ event: EKEvent,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        notes: String?,
        calendar: EKCalendar?
    ) async throws {
        guard hasCalendarAccess else {
            throw NSError(domain: "EventManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "未获得日历访问权限"])
        }
        
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        event.notes = notes
        if let cal = calendar {
            event.calendar = cal
        }
        
        try eventStore.save(event, span: .thisEvent, commit: true)
        await fetchEvents()
    }
    
    /// 删除日历日程
    func deleteEvent(_ event: EKEvent) async throws {
        guard hasCalendarAccess else { return }
        try eventStore.remove(event, span: .thisEvent, commit: true)
        await fetchEvents()
    }
}
