import Foundation
@preconcurrency import EventKit
import Combine

/// [理论物理与系统架构：宏观时间投影引擎 EventManager]
/// 该管理器作为 SimPleview 内部状态流形向 macOS 系统宏观时间流形的规范联络 (Gauge Connection)。
/// 它封装了底层 `EventKit.EKEventStore`，实现：
/// 1. 待办事项 (Reminders)：离散投影本征态的检测、完成度跃迁 (Completion) 与持久化落盘。
/// 2. 日程安排 (Events)：紧致时间区间的截取、世界线规划与日历归档。
/// 3. 实时双向退相干保护：通过监听 `.EKEventStoreChanged` 维持与系统原生“提醒事项”和“日历”的完全同构。
@MainActor
final class EventManager: ObservableObject {
    static let shared = EventManager()
    
    // 底层 EventKit 核心存储对象 (单例生命周期内保持复用，避免重复初始化开销)
    private let eventStore = EKEventStore()
    
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
            return calendarAuthStatus == .fullAccess || calendarAuthStatus == .authorized
        } else {
            return calendarAuthStatus == .authorized
        }
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
            print("[EventManager] 请求日历权限失败: \(error)")
            updateAuthStatuses()
            return false
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
    
    /// 从 macOS 原生数据库拉取指定时间段内的日历日程 (默认显示前后 30 天)
    func fetchEvents(
        from startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date(),
        to endDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    ) async {
        guard hasCalendarAccess else { return }
        isLoadingEvents = true
        defer { isLoadingEvents = false }
        
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let list = eventStore.events(matching: predicate)
        
        self.events = list.sorted { $0.startDate < $1.startDate }
    }
    
    // MARK: - 提醒事项 CRUD
    
    /// 获取可用的提醒事项列表（列表分类）
    func availableReminderCalendars() -> [EKCalendar] {
        guard hasReminderAccess else { return [] }
        return eventStore.calendars(for: .reminder)
    }
    
    /// 默认提醒事项列表
    func defaultReminderCalendar() -> EKCalendar? {
        return eventStore.defaultCalendarForNewReminders() ?? availableReminderCalendars().first
    }
    
    /// 新建待办事项
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
        reminder.calendar = calendar ?? defaultReminderCalendar()
        
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
    
    /// 新建日历日程
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
        event.calendar = calendar ?? defaultEventCalendar()
        
        try eventStore.save(event, span: .thisEvent, commit: true)
        await fetchEvents()
        return event
    }
    
    /// 删除日历日程
    func deleteEvent(_ event: EKEvent) async throws {
        guard hasCalendarAccess else { return }
        try eventStore.remove(event, span: .thisEvent, commit: true)
        await fetchEvents()
    }
}
