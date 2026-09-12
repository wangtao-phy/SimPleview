import SwiftUI
@preconcurrency import EventKit

/// [理论物理与用户界面：待办与日程侧边栏 TodoSidebarView]
/// 该视图作为 SimPleview 读者的外延时间管理终端：
/// 1. 待办事项 (Reminders)：
///    - 分类同步：未完成事项按系统分类列表（如『SimPleview阅读』、工作、个人等）进行清晰的分段呈现；
///    - 完备归并：已完成事项（$\lambda = 1$）统一从各自具体分类中移出，归集到底部专属的『已完成』区域；
///    - 默认流形：新增事项默认且自动归档至新建的『SimPleview阅读』原生分类列表。
/// 2. 日程安排 (Schedule)：
///    - 底部微型月历 (Mini Month Calendar)：支持年月切换、查看当月日程分布（日期下方附带与所属日历颜色一致的圆点）；
///    - 主视图日程流 (Day Schedule Timeline)：点击月历日期在上方主要区域查看该日日程，并支持在对应时间槽【双击】直接添加日程；
///    - 默认归类：双击添加日程默认选定『SimPleview阅读』日历分类，且支持自由更换分类。
/// 3. 文献引力锚定：一键捕获当前 PDF 文档名及页码并自动注入备注，实现文献与 macOS 原生生态的瞬时跃迁。
struct TodoSidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    @ObservedObject var eventManager = EventManager.shared
    
    // 子标签切换：0 为待办事项 (Reminders)，1 为日程安排 (Schedule)
    @State private var selectedSubTab: Int = 0
    
    // 提醒事项分类列表筛选：默认为 "ALL" (显示全部列表并分节分组)，亦可单选『SimPleview阅读』等
    @State private var selectedReminderCalendarID: String = "ALL"
    
    // 过滤模式：仅看与当前文献关联的事项
    @State private var filterCurrentDocOnly: Bool = false
    
    // 日历当前选中日期与当前浏览月份
    @State private var selectedDate: Date = Date()
    @State private var currentCalendarMonth: Date = Date()
    
    // 弹窗表单状态与预填参数
    @State private var showingAddReminderSheet: Bool = false
    @State private var showingAddEventSheet: Bool = false
    @State private var presetEventStartDate: Date? = nil
    @State private var presetEventEndDate: Date? = nil
    
    // 当前文献坐标
    private var currentDocTitle: String {
        state.fileURL?.deletingPathExtension().lastPathComponent ?? state.fileName
    }
    
    private var currentPageNumber: Int {
        state.liveState.currentPageIndex + 1
    }
    
    private var currentContextCitation: String {
        guard !currentDocTitle.isEmpty else { return "" }
        return "来自文献: 《\(currentDocTitle)》 第 \(currentPageNumber) 页"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // [顶栏控制台]
            VStack(spacing: 8) {
                // 1. 二级子标签选择器 (待办 / 日程)
                Picker("", selection: $selectedSubTab) {
                    Text(state.L("Reminders")).tag(0)
                    Text(state.L("Schedule")).tag(1)
                }
                .pickerStyle(.segmented)
                
                // 2. 工具栏与过滤栏
                HStack(spacing: 6) {
                    // 如果处于待办事项模式，显示分类列表筛选器
                    if selectedSubTab == 0 && eventManager.hasReminderAccess {
                        let calendars = eventManager.availableReminderCalendars()
                        Picker("", selection: $selectedReminderCalendarID) {
                            Text(state.L("All Lists")).tag("ALL")
                            ForEach(calendars, id: \.calendarIdentifier) { cal in
                                Text(cal.title).tag(cal.calendarIdentifier)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: 130)
                    }
                    
                    // 仅看本文献切换
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            filterCurrentDocOnly.toggle()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: filterCurrentDocOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 11))
                            Text(state.L("Filter Current Paper"))
                                .font(.system(size: 10))
                        }
                        .foregroundColor(filterCurrentDocOnly ? .accentColor : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(filterCurrentDocOnly ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help(state.L("Filter Current Paper"))
                    
                    Spacer()
                    
                    // 刷新按钮
                    Button(action: {
                        Task {
                            await eventManager.refreshAll()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("刷新")
                    
                    // 新建按钮 (+)
                    Button(action: {
                        if selectedSubTab == 0 {
                            showingAddReminderSheet = true
                        } else {
                            let cal = Calendar.current
                            let baseHour = cal.isDateInToday(selectedDate) ? cal.component(.hour, from: Date()) : 9
                            let start = cal.date(bySettingHour: baseHour, minute: 0, second: 0, of: selectedDate) ?? selectedDate
                            let end = cal.date(byAdding: .hour, value: 2, to: start) ?? start.addingTimeInterval(7200)
                            presetEventStartDate = start
                            presetEventEndDate = end
                            showingAddEventSheet = true
                        }
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(selectedSubTab == 0 ? state.L("Add Task") : state.L("Add Event"))
                }
            }
            .padding(8)
            
            Divider()
            
            // [核心内容流形]
            Group {
                if selectedSubTab == 0 {
                    remindersContentView
                } else {
                    scheduleContentView
                }
            }
        }
        .onAppear {
            eventManager.updateAuthStatuses()
            Task {
                await eventManager.refreshAll()
                await eventManager.fetchEventsForMonth(currentCalendarMonth)
            }
        }
        // 当应用重获焦点时（例如用户在系统设置中勾选允许后切回），自动重检权限与拉取数据
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            eventManager.resetStoreAndAuth()
        }
        .sheet(isPresented: $showingAddReminderSheet) {
            AddReminderSheetView(
                state: state,
                defaultTitle: "",
                defaultNotes: currentContextCitation,
                eventManager: eventManager
            )
            .id(showingAddReminderSheet)
        }
        .sheet(isPresented: $showingAddEventSheet) {
            AddEventSheetView(
                state: state,
                defaultTitle: !currentDocTitle.isEmpty ? "研读: \(currentDocTitle)" : "",
                defaultNotes: currentContextCitation,
                initialStartDate: presetEventStartDate,
                initialEndDate: presetEventEndDate,
                eventManager: eventManager
            )
            .id("\(presetEventStartDate?.timeIntervalSince1970 ?? 0)_\(showingAddEventSheet)")
        }
    }
    
    // MARK: - 待办事项列表组件 (分类呈现与已完成归集)
    
    @ViewBuilder
    private var remindersContentView: some View {
        if !eventManager.hasReminderAccess {
            permissionGuideView(
                isCalendar: false,
                title: state.L("Reminders"),
                isDenied: eventManager.isReminderDenied
            )
        } else {
            let baseList = eventManager.reminders.filter { reminder in
                guard filterCurrentDocOnly else { return true }
                guard !currentDocTitle.isEmpty else { return true }
                let inNotes = reminder.notes?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
                let inTitle = reminder.title?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
                return inNotes || inTitle
            }
            
            // 如果用户选择了特定分类列表，进行精准切片
            let filteredList = baseList.filter { reminder in
                guard selectedReminderCalendarID != "ALL" else { return true }
                return reminder.calendar?.calendarIdentifier == selectedReminderCalendarID
            }
            
            // 核心物理优化：将未完成与已完成彻底解耦
            let uncompletedList = filteredList.filter { !$0.isCompleted }
            let completedList = filteredList.filter { $0.isCompleted }
            
            if uncompletedList.isEmpty && completedList.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checklist")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(state.L("No Reminders Found"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button(action: { showingAddReminderSheet = true }) {
                        Text(state.L("Add Task"))
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // 1. 未完成事项：按所属具体分类列表(EKCalendar)优雅呈现
                    let calendarsWithUncompleted = eventManager.availableReminderCalendars().filter { cal in
                        uncompletedList.contains(where: { $0.calendar?.calendarIdentifier == cal.calendarIdentifier })
                    }
                    
                    ForEach(calendarsWithUncompleted, id: \.calendarIdentifier) { cal in
                        let items = uncompletedList.filter { $0.calendar?.calendarIdentifier == cal.calendarIdentifier }
                        if !items.isEmpty {
                            Section(header: reminderSectionHeader(cal: cal, count: items.count)) {
                                ForEach(items, id: \.calendarItemIdentifier) { reminder in
                                    ReminderRowView(
                                        reminder: reminder,
                                        currentDocTitle: currentDocTitle,
                                        showCalendarBadge: false,
                                        onToggle: {
                                            Task {
                                                _ = try? await eventManager.toggleReminderCompletion(reminder)
                                            }
                                        },
                                        onDelete: {
                                            Task {
                                                _ = try? await eventManager.deleteReminder(reminder)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    
                    // 2. 已完成事项：全部归拢到底部专属『已完成』Section，不在具体分类内占位
                    if !completedList.isEmpty {
                        Section(header: completedSectionHeader(count: completedList.count)) {
                            ForEach(completedList, id: \.calendarItemIdentifier) { reminder in
                                ReminderRowView(
                                    reminder: reminder,
                                    currentDocTitle: currentDocTitle,
                                    showCalendarBadge: true,
                                    onToggle: {
                                        Task {
                                            _ = try? await eventManager.toggleReminderCompletion(reminder)
                                        }
                                    },
                                    onDelete: {
                                        Task {
                                            _ = try? await eventManager.deleteReminder(reminder)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
    
    @ViewBuilder
    private func reminderSectionHeader(cal: EKCalendar, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: cal.color))
                .frame(width: 8, height: 8)
            
            Text(cal.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
            
            if cal.title == "SimPleview阅读" {
                Text("App专属")
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            }
            
            Spacer()
            
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private func completedSectionHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            Text(state.L("Completed"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - 日程安排复合视图：主要区域(当天日程轴) + 底部小月历
    
    @ViewBuilder
    private var scheduleContentView: some View {
        if !eventManager.hasCalendarAccess {
            permissionGuideView(
                isCalendar: true,
                title: state.L("Schedule"),
                isDenied: eventManager.isCalendarDenied
            )
        } else {
            VStack(spacing: 0) {
                // [主视图区域] 显示选中日期的详细时间流与日程
                DayScheduleTimelineView(
                    state: state,
                    eventManager: eventManager,
                    selectedDate: selectedDate,
                    events: eventManager.events,
                    filterCurrentDocOnly: filterCurrentDocOnly,
                    currentDocTitle: currentDocTitle,
                    onDoubleTapHour: { hour in
                        let cal = Calendar.current
                        if let start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: selectedDate) {
                            presetEventStartDate = start
                            presetEventEndDate = cal.date(byAdding: .hour, value: 2, to: start) ?? start.addingTimeInterval(7200)
                        }
                        showingAddEventSheet = true
                    },
                    onDeleteEvent: { ev in
                        Task {
                            _ = try? await eventManager.deleteEvent(ev)
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()
                
                // [底部微型小月历] 显示当月日程圆点与日期跳转
                MiniMonthCalendarView(
                    state: state,
                    selectedDate: $selectedDate,
                    currentMonth: $currentCalendarMonth,
                    events: eventManager.events,
                    onSelectDate: { date in
                        selectedDate = date
                    },
                    onMonthChanged: { newMonth in
                        Task {
                            await eventManager.fetchEventsForMonth(newMonth)
                        }
                    }
                )
                .background(Color.primary.opacity(0.02))
            }
        }
    }
    
    // MARK: - 权限缺省与指引视图 (支持一键授权与系统设置深层唤醒)
    
    @ViewBuilder
    private func permissionGuideView(isCalendar: Bool, title: String, isDenied: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: isDenied ? "exclamationmark.triangle.fill" : "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(isDenied ? .red : .orange)
            
            Text(isDenied ? "权限未开启或已被拒绝" : state.L("Permission Required"))
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            
            Text(isDenied
                 ? "macOS 系统已限制访问\(title)。请在『系统设置 > 隐私与安全性 > \(isCalendar ? "日历" : "提醒事项")』中允许 SimPleview。"
                 : "SimPleview 需要访问您的系统\(title)，以实现与 macOS 原生 App 的双向实时同步。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            // 动作按钮组
            VStack(spacing: 8) {
                // 1. 请求系统原生弹窗授权
                Button(action: {
                    Task {
                        if isCalendar {
                            await eventManager.requestCalendarAccess()
                        } else {
                            await eventManager.requestReminderAccess()
                        }
                    }
                }) {
                    Text("\(state.L("Authorize Access")) \(title)")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                
                // 2. 前往系统设置
                Button(action: {
                    if isCalendar {
                        eventManager.openCalendarPrivacySettings()
                    } else {
                        eventManager.openReminderPrivacySettings()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                        Text(state.L("Open System Settings"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                // 3. 重新检测按钮
                Button(action: {
                    eventManager.resetStoreAndAuth()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(state.L("Check Again"))
                    }
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 静态时间格式化缓存 (消除高频重绘时的多余堆内存分配)

private enum DateFormatters {
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

// MARK: - 模拟微型小月历组件 (MiniMonthCalendarView)

struct MiniMonthCalendarView: View {
    @ObservedObject var state: AppState
    @Binding var selectedDate: Date
    @Binding var currentMonth: Date
    let events: [EKEvent]
    let onSelectDate: (Date) -> Void
    let onMonthChanged: (Date) -> Void
    
    private let calendar = Calendar.current
    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    
    // 计算当前月份的元数据
    private var monthMetadata: (start: Date, days: Int, leadOffset: Int) {
        let comps = calendar.dateComponents([.year, .month], from: currentMonth)
        let start = calendar.date(from: comps) ?? currentMonth
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let firstWeekday = calendar.component(.weekday, from: start)
        let leadOffset = (firstWeekday - calendar.firstWeekday + 7) % 7
        return (start, days, leadOffset)
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // 月历头部控制：年月指示与月份切换
            HStack(spacing: 8) {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text(formatMonthHeader(currentMonth))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentMonth = Date()
                        selectedDate = Date()
                    }
                    onMonthChanged(currentMonth)
                }) {
                    Text(state.L("Today"))
                        .font(.system(size: 9))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .help("回到今天")
                
                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            
            // 星期列指示
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 6)
            
            // 日历日期数字网格
            let meta = monthMetadata
            let totalCells = meta.leadOffset + meta.days
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<totalCells, id: \.self) { index in
                    if index < meta.leadOffset {
                        Color.clear.frame(height: 22)
                    } else {
                        let dayNum = index - meta.leadOffset + 1
                        let dayDate = calendar.date(byAdding: .day, value: dayNum - 1, to: meta.start) ?? meta.start
                        let isSelected = calendar.isDate(dayDate, inSameDayAs: selectedDate)
                        let isToday = calendar.isDateInToday(dayDate)
                        let dayEvents = eventsForDate(dayDate)
                        
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                onSelectDate(dayDate)
                            }
                        }) {
                            VStack(spacing: 1) {
                                Text("\(dayNum)")
                                    .font(.system(size: 10, weight: (isSelected || isToday) ? .bold : .regular))
                                    .foregroundColor(isSelected ? .white : (isToday ? .accentColor : .primary))
                                
                                // 日程颜色圆点：若该日存在日程，绘制与所属分类完全同构的彩色圆点
                                if !dayEvents.isEmpty {
                                    HStack(spacing: 2) {
                                        let uniqueColors = Array(Set(dayEvents.compactMap { $0.calendar?.color })).prefix(3)
                                        ForEach(0..<uniqueColors.count, id: \.self) { cIdx in
                                            Circle()
                                                .fill(isSelected ? Color.white : Color(nsColor: uniqueColors[cIdx]))
                                                .frame(width: 3.5, height: 3.5)
                                        }
                                    }
                                } else {
                                    Color.clear.frame(height: 3.5)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .background(isSelected ? Color.accentColor : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }
    
    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: currentMonth) {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentMonth = newMonth
            }
            onMonthChanged(newMonth)
        }
    }
    
    private func formatMonthHeader(_ date: Date) -> String {
        DateFormatters.monthHeader.string(from: date)
    }
    
    private func eventsForDate(_ date: Date) -> [EKEvent] {
        events.filter { ev in
            calendar.isDate(ev.startDate, inSameDayAs: date) ||
            calendar.isDate(ev.endDate, inSameDayAs: date) ||
            (ev.startDate <= date && ev.endDate >= date)
        }
    }
}

// MARK: - 主视图：单日日程时间轴 (DayScheduleTimelineView)

struct DayScheduleTimelineView: View {
    @ObservedObject var state: AppState
    let eventManager: EventManager
    let selectedDate: Date
    let events: [EKEvent]
    let filterCurrentDocOnly: Bool
    let currentDocTitle: String
    let onDoubleTapHour: (Int) -> Void
    let onDeleteEvent: (EKEvent) -> Void
    
    private let calendar = Calendar.current
    
    // 筛选出属于选中日期的日程
    private var eventsOfDay: [EKEvent] {
        let dayEvents = events.filter { ev in
            calendar.isDate(ev.startDate, inSameDayAs: selectedDate) ||
            calendar.isDate(ev.endDate, inSameDayAs: selectedDate) ||
            (ev.startDate <= selectedDate && ev.endDate >= selectedDate)
        }
        
        guard filterCurrentDocOnly, !currentDocTitle.isEmpty else { return dayEvents }
        return dayEvents.filter { ev in
            let inNotes = ev.notes?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
            let inTitle = ev.title?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
            return inNotes || inTitle
        }
    }
    
    private var allDayEvents: [EKEvent] {
        eventsOfDay.filter { $0.isAllDay }
    }
    
    private var timedEvents: [EKEvent] {
        eventsOfDay.filter { !$0.isAllDay }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶端：日期指示栏
            HStack {
                Text(formatDayHeader(selectedDate))
                    .font(.system(size: 13, weight: .bold))
                
                if calendar.isDateInToday(selectedDate) {
                    Text(state.L("Today"))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(3)
                }
                
                Spacer()
                
                Text("双击时间槽新建")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))
            
            Divider()
            
            // 时间轴滚动区域
            ScrollView {
                VStack(spacing: 0) {
                    // 全天事件区域
                    if !allDayEvents.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(allDayEvents, id: \.eventIdentifier) { ev in
                                AllDayEventRowView(
                                    event: ev,
                                    eventManager: eventManager,
                                    state: state,
                                    onDelete: { onDeleteEvent(ev) }
                                )
                            }
                        }
                        .padding(8)
                        Divider()
                    }
                    
                    // 24 小时时间槽 (以 07:00 至 23:00 为主视界)
                    ForEach(7...23, id: \.self) { hour in
                        let hourEvents = timedEvents.filter { ev in
                            let h = calendar.component(.hour, from: ev.startDate)
                            return h == hour
                        }
                        
                        HourlySlotRow(
                            hour: hour,
                            events: hourEvents,
                            eventManager: eventManager,
                            state: state,
                            currentDocTitle: currentDocTitle,
                            onDoubleTap: { onDoubleTapHour(hour) },
                            onDeleteEvent: onDeleteEvent
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private func formatDayHeader(_ date: Date) -> String {
        DateFormatters.dayHeader.string(from: date)
    }
}

// MARK: - 单小时槽位视图 (HourlySlotRow)

struct HourlySlotRow: View {
    let hour: Int
    let events: [EKEvent]
    let eventManager: EventManager
    @ObservedObject var state: AppState
    let currentDocTitle: String
    let onDoubleTap: () -> Void
    let onDeleteEvent: (EKEvent) -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // 时间标尺
            Text(String(format: "%02d:00", hour))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
                .padding(.top, 2)
            
            // 内容区域
            VStack(alignment: .leading, spacing: 4) {
                if events.isEmpty {
                    // 空白时间槽：支持双击手势快速创建
                    HStack {
                        if isHovered {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 8))
                                Text("双击在此时间添加日程")
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.accentColor.opacity(0.8))
                        } else {
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 1)
                        }
                        Spacer()
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onDoubleTap()
                    }
                } else {
                    // 已有日程卡片
                    ForEach(events, id: \.eventIdentifier) { ev in
                        EventRowView(
                            event: ev,
                            eventManager: eventManager,
                            state: state,
                            currentDocTitle: currentDocTitle,
                            onDelete: { onDeleteEvent(ev) }
                        )
                        .padding(4)
                        .background(Color.primary.opacity(0.03))
                        .cornerRadius(4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 待办单行视图组件

struct ReminderRowView: View {
    let reminder: EKReminder
    let currentDocTitle: String
    var showCalendarBadge: Bool = false
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered: Bool = false
    
    private var isOverdue: Bool {
        guard let due = reminder.dueDateComponents?.date, !reminder.isCompleted else { return false }
        return due < Date()
    }
    
    private var isLinkedToCurrentDoc: Bool {
        guard !currentDocTitle.isEmpty else { return false }
        let inNotes = reminder.notes?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
        let inTitle = reminder.title?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
        return inNotes || inTitle
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 圆圈勾选框
            Button(action: onToggle) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(reminder.isCompleted ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            
            // 文本与元数据
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title ?? "未命名待办")
                    .font(.system(size: 12, weight: .medium))
                    .strikethrough(reminder.isCompleted)
                    .foregroundColor(reminder.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
                
                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                HStack(spacing: 6) {
                    // 原分类标签（主要在已完成区域显示）
                    if showCalendarBadge, let cal = reminder.calendar {
                        HStack(spacing: 3) {
                            Circle().fill(Color(nsColor: cal.color)).frame(width: 5, height: 5)
                            Text(cal.title)
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(3)
                    }
                    
                    // 截止日期徽章
                    if let due = reminder.dueDateComponents?.date {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                            Text(formatDueDate(due))
                                .font(.system(size: 9))
                        }
                        .foregroundColor(isOverdue ? .red : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isOverdue ? Color.red.opacity(0.1) : Color.primary.opacity(0.04))
                        .cornerRadius(3)
                    }
                    
                    // 当前文献锚定标签
                    if isLinkedToCurrentDoc {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9))
                            Text("本文献")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(3)
                    }
                }
            }
            
            Spacer()
            
            // 悬浮删除按钮
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("删除此事项")
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(action: onToggle) {
                Text(reminder.isCompleted ? "标记为未完成" : "标记为已完成")
            }
            Button(role: .destructive, action: onDelete) {
                Text("删除待办")
            }
        }
    }
    
    private func formatDueDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return DateFormatters.todayDue.string(from: date)
        } else if cal.isDateInTomorrow(date) {
            return DateFormatters.tomorrowDue.string(from: date)
        } else {
            return DateFormatters.otherDue.string(from: date)
        }
    }
}

// MARK: - 全天日程单行视图组件 (AllDayEventRowView)

struct AllDayEventRowView: View {
    let event: EKEvent
    let eventManager: EventManager
    @ObservedObject var state: AppState
    let onDelete: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var showingEditPopover: Bool = false
    
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                .frame(width: 3, height: 16)
            Text(event.title ?? "全天日程")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Text("全天")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("删除此日程")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            showingEditPopover = true
        }
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingEditPopover, arrowEdge: .trailing) {
            EditEventPopoverView(
                event: event,
                eventManager: eventManager,
                state: state,
                onDismiss: { showingEditPopover = false }
            )
        }
        .contextMenu {
            Button(state.L("Edit Event")) {
                showingEditPopover = true
            }
            Button(role: .destructive, action: onDelete) {
                Text(state.L("Delete Event"))
            }
        }
    }
}

// MARK: - 日程单行视图组件 (EventRowView)

struct EventRowView: View {
    let event: EKEvent
    let eventManager: EventManager
    @ObservedObject var state: AppState
    let currentDocTitle: String
    let onDelete: () -> Void
    
    @State private var isHovered: Bool = false
    @State private var showingEditPopover: Bool = false
    
    private var isLinkedToCurrentDoc: Bool {
        guard !currentDocTitle.isEmpty else { return false }
        let inNotes = event.notes?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
        let inTitle = event.title?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
        return inNotes || inTitle
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 日历分类色条
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: event.calendar?.color ?? .systemBlue))
                .frame(width: 3)
                .padding(.vertical, 2)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? "未命名日程")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                // 时间显示
                Text(formatEventTime(event))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
                
                if isLinkedToCurrentDoc {
                    HStack(spacing: 2) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                        Text("本文献")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(3)
                }
            }
            
            Spacer()
            
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("删除此日程")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            showingEditPopover = true
        }
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingEditPopover, arrowEdge: .trailing) {
            EditEventPopoverView(
                event: event,
                eventManager: eventManager,
                state: state,
                onDismiss: { showingEditPopover = false }
            )
        }
        .contextMenu {
            Button(state.L("Edit Event")) {
                showingEditPopover = true
            }
            Button(role: .destructive, action: onDelete) {
                Text(state.L("Delete Event"))
            }
        }
    }
    
    private func formatEventTime(_ event: EKEvent) -> String {
        if event.isAllDay {
            return DateFormatters.allDay.string(from: event.startDate)
        }
        
        let cal = Calendar.current
        if cal.isDate(event.startDate, inSameDayAs: event.endDate) {
            let startStr = DateFormatters.timeOnly.string(from: event.startDate)
            let endStr = DateFormatters.timeOnly.string(from: event.endDate)
            return "\(startStr) - \(endStr)"
        } else {
            let startStr = DateFormatters.dateAndHour.string(from: event.startDate)
            let endStr = DateFormatters.dateAndHour.string(from: event.endDate)
            return "\(startStr) - \(endStr)"
        }
    }
}

// MARK: - 悬浮原生日程详情与修改弹窗 (EditEventPopoverView)

struct EditEventPopoverView: View {
    let event: EKEvent
    let eventManager: EventManager
    @ObservedObject var state: AppState
    let onDismiss: () -> Void
    
    @State private var title: String
    @State private var isAllDay: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var selectedCalendar: EKCalendar?
    @State private var recurrence: EventRecurrenceOption
    @State private var alert: EventAlertOption
    @State private var notes: String
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil
    
    init(event: EKEvent, eventManager: EventManager, state: AppState, onDismiss: @escaping () -> Void) {
        self.event = event
        self.eventManager = eventManager
        self.state = state
        self.onDismiss = onDismiss
        
        self._title = State(initialValue: event.title ?? "")
        self._isAllDay = State(initialValue: event.isAllDay)
        self._startDate = State(initialValue: event.startDate)
        self._endDate = State(initialValue: event.endDate)
        self._selectedCalendar = State(initialValue: event.calendar)
        self._recurrence = State(initialValue: EventRecurrenceOption.from(rule: event.recurrenceRules?.first))
        self._alert = State(initialValue: EventAlertOption.from(alarm: event.alarms?.first))
        self._notes = State(initialValue: event.notes ?? "")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶端：日历色标与标题输入
            HStack(spacing: 8) {
                if let cal = selectedCalendar {
                    Circle()
                        .fill(Color(nsColor: cal.color))
                        .frame(width: 10, height: 10)
                }
                TextField(state.L("Event Name"), text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.top, 2)
            
            Divider()
            
            // 全天切换
            Toggle(state.L("All Day"), isOn: $isAllDay)
                .font(.caption)
            
            // 起止时间选择器
            VStack(spacing: 8) {
                HStack {
                    Text(state.L("Start Time"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .leading)
                    DatePicker("", selection: $startDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                    Spacer()
                }
                
                HStack {
                    Text(state.L("End Time"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .leading)
                    DatePicker("", selection: $endDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                    Spacer()
                }
            }
            .onChange(of: startDate) { _, newStart in
                if endDate <= newStart {
                    endDate = Calendar.current.date(byAdding: .hour, value: 2, to: newStart) ?? newStart.addingTimeInterval(7200)
                }
            }
            
            // 重复日程选项 (与 macOS 原生一致)
            HStack {
                Text(state.L("Repeat"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                
                Picker("", selection: $recurrence) {
                    ForEach(EventRecurrenceOption.allCases) { opt in
                        Text(opt.localizedTitle).tag(opt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
            }
            
            // 日历分类切换
            let calendars = eventManager.availableEventCalendars()
            if !calendars.isEmpty {
                HStack {
                    Text(state.L("Calendar"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .leading)
                    
                    Picker("", selection: $selectedCalendar) {
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: cal.color)).frame(width: 7, height: 7)
                                Text(cal.title)
                            }
                            .tag(cal as EKCalendar?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                }
            }
            
            // 提醒选项 (与 macOS 原生一致)
            HStack {
                Text(state.L("Alert"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                
                Picker("", selection: $alert) {
                    ForEach(EventAlertOption.allCases) { opt in
                        Text(opt.localizedTitle).tag(opt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
            }
            
            // 备注信息
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Notes"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $notes)
                    .font(.system(size: 11))
                    .frame(height: 52)
                    .padding(3)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(4)
            }
            
            if let err = errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            
            Divider()
            
            // 底部操作区：左侧删除，右侧取消与存储
            HStack {
                Button(role: .destructive, action: {
                    Task {
                        _ = try? await eventManager.deleteEvent(event)
                        onDismiss()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text(state.L("Delete Event"))
                            .font(.caption)
                    }
                    .foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("删除此日程")
                
                Spacer()
                
                Button("取消") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button(state.L("Save")) {
                    Task {
                        isSaving = true
                        do {
                            let finalEnd = isAllDay ? endDate : (endDate >= startDate ? endDate : startDate.addingTimeInterval(7200))
                            try await eventManager.updateEvent(
                                event,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名日程" : title,
                                startDate: startDate,
                                endDate: finalEnd,
                                isAllDay: isAllDay,
                                notes: notes.isEmpty ? nil : notes,
                                calendar: selectedCalendar,
                                recurrence: recurrence,
                                alert: alert
                            )
                            onDismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isSaving = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - 新建待办事项表单弹窗 (默认归档至『SimPleview阅读』)

struct AddReminderSheetView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool = true
    @State private var dueDate: Date
    @State private var selectedCalendar: EKCalendar?
    
    let eventManager: EventManager
    
    init(state: AppState, defaultTitle: String, defaultNotes: String, eventManager: EventManager) {
        self.state = state
        self._title = State(initialValue: defaultTitle)
        self._notes = State(initialValue: defaultNotes)
        self.eventManager = eventManager
        let readingCal = eventManager.getOrCreateSimPleviewCalendar() ?? eventManager.defaultReminderCalendar()
        self._selectedCalendar = State(initialValue: readingCal)
        
        // 核心优化 1：提醒事项默认截止时间为当前时间的 1 天以后
        let defaultDue = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
        self._hasDueDate = State(initialValue: true)
        self._dueDate = State(initialValue: defaultDue)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(state.L("Add Task"))
                    .font(.headline)
                Spacer()
                if let cal = selectedCalendar {
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: cal.color)).frame(width: 8, height: 8)
                        Text(cal.title).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            // 标题输入
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Task Title"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("例如：精读第三节哈密顿量推导", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            
            // 截止时间
            Toggle(state.L("Due Date"), isOn: $hasDueDate)
                .font(.caption)
            
            if hasDueDate {
                DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
            
            // 分类列表选择 (默认优先指向『SimPleview阅读』)
            let calendars = eventManager.availableReminderCalendars()
            if !calendars.isEmpty {
                Picker(state.L("List"), selection: $selectedCalendar) {
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        Text(cal.title).tag(cal as EKCalendar?)
                    }
                }
                .pickerStyle(.menu)
            }
            
            // 备注 (自动附注文献页码)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Notes"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(state.L("Notes"), text: $notes)
                    .textFieldStyle(.roundedBorder)
            }
            
            Divider()
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("添加至提醒事项") {
                    Task {
                        _ = try? await eventManager.createReminder(
                            title: title,
                            dueDate: hasDueDate ? dueDate : nil,
                            notes: notes.isEmpty ? nil : notes,
                            calendar: selectedCalendar
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
            hasDueDate = true
        }
    }
}

// MARK: - 新建日程表单弹窗 (默认归类为『SimPleview阅读』分类，亦可自由更改分类)

struct AddEventSheetView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String
    @State private var notes: String
    @State private var isAllDay: Bool = false
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var selectedCalendar: EKCalendar?
    @State private var recurrence: EventRecurrenceOption = .none
    @State private var alert: EventAlertOption = .none
    
    let eventManager: EventManager
    let initialStartDate: Date?
    let initialEndDate: Date?
    
    init(
        state: AppState,
        defaultTitle: String,
        defaultNotes: String,
        initialStartDate: Date? = nil,
        initialEndDate: Date? = nil,
        eventManager: EventManager
    ) {
        self.state = state
        self._title = State(initialValue: defaultTitle)
        self._notes = State(initialValue: defaultNotes)
        self.eventManager = eventManager
        self.initialStartDate = initialStartDate
        self.initialEndDate = initialEndDate
        
        let start = initialStartDate ?? Date()
        // 核心优化 2：默认日程跨度为 2 小时
        let end = initialEndDate ?? (Calendar.current.date(byAdding: .hour, value: 2, to: start) ?? start.addingTimeInterval(7200))
        self._startDate = State(initialValue: start)
        self._endDate = State(initialValue: end)
        
        // 默认自动选定或创建『SimPleview阅读』分类，亦可自由更改
        let defaultCal = eventManager.getOrCreateSimPleviewEventCalendar() ?? eventManager.defaultEventCalendar()
        self._selectedCalendar = State(initialValue: defaultCal)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(state.L("Add Event"))
                    .font(.headline)
                Spacer()
                if let cal = selectedCalendar {
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: cal.color)).frame(width: 8, height: 8)
                        Text(cal.title).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Event Title"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("例如：文献阅读与推导研讨", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            
            Toggle(state.L("All Day"), isOn: $isAllDay)
                .font(.caption)
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.L("Start Time")).font(.caption2).foregroundColor(.secondary)
                    DatePicker("", selection: $startDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.L("End Time")).font(.caption2).foregroundColor(.secondary)
                    DatePicker("", selection: $endDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            
            // 重复日程
            HStack {
                Text(state.L("Repeat"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                
                Picker("", selection: $recurrence) {
                    ForEach(EventRecurrenceOption.allCases) { opt in
                        Text(opt.localizedTitle).tag(opt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
            }
            
            // 所属日历分类选择器：默认『SimPleview阅读』，用户可自由改动分类
            let calendars = eventManager.availableEventCalendars()
            if !calendars.isEmpty {
                HStack {
                    Text(state.L("Calendar"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .leading)
                    
                    Picker("", selection: $selectedCalendar) {
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            HStack {
                                Circle().fill(Color(nsColor: cal.color)).frame(width: 6, height: 6)
                                Text(cal.title)
                            }
                            .tag(cal as EKCalendar?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                }
            }
            
            // 提醒
            HStack {
                Text(state.L("Alert"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                
                Picker("", selection: $alert) {
                    ForEach(EventAlertOption.allCases) { opt in
                        Text(opt.localizedTitle).tag(opt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Notes"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(state.L("Notes"), text: $notes)
                    .textFieldStyle(.roundedBorder)
            }
            
            Divider()
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("添加至日历") {
                    Task {
                        _ = try? await eventManager.createEvent(
                            title: title,
                            startDate: startDate,
                            endDate: endDate,
                            isAllDay: isAllDay,
                            notes: notes.isEmpty ? nil : notes,
                            calendar: selectedCalendar,
                            recurrence: recurrence,
                            alert: alert
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let s = initialStartDate { startDate = s }
            if let e = initialEndDate { endDate = e }
        }
        .onChange(of: startDate) { _, newStart in
            if endDate <= newStart {
                endDate = Calendar.current.date(byAdding: .hour, value: 2, to: newStart) ?? newStart.addingTimeInterval(7200)
            }
        }
    }
}
