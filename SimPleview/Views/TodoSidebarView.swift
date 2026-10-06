import SwiftUI
@preconcurrency import EventKit

/// 持有待办面板的浏览状态和 EventManager，协调筛选、授权与新建操作。
/// 月历、时间轴、列表行和编辑表单分别位于 Views/Todo，沿用同一管理器。
struct TodoSidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    @StateObject private var eventManager = EventManager()
    
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
    @State private var operationError: String?
    @State private var showingAddReminderSheet: Bool = false
    // 时间与展示身份一起传入 sheet，避免首次打开时捕获到旧的预填状态。
    private struct EventSlot: Identifiable {
        let id = UUID()
        let start: Date
    }
    @State private var eventSlot: EventSlot?
    
    // 当前文献坐标
    private var currentDocTitle: String {
        state.fileURL?.deletingPathExtension().lastPathComponent ?? state.fileName
    }
    
    private var currentPageNumber: Int {
        state.liveState.currentPageIndex + 1
    }
    
    private var currentContextCitation: String {
        guard !currentDocTitle.isEmpty else { return "" }
        return L.format("Paper Citation", state.appLanguage, currentDocTitle, currentPageNumber)
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
                                Text(EventManager.displayTitle(of: cal, language: state.appLanguage)).tag(cal.calendarIdentifier)
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
                    .help(state.L("Refresh"))
                    
                    // 新建按钮 (+)
                    Button(action: {
                        if selectedSubTab == 0 {
                            showingAddReminderSheet = true
                        } else {
                            let cal = Calendar.current
                            let baseHour = cal.isDateInToday(selectedDate) ? cal.component(.hour, from: Date()) : 9
                            let start = cal.date(bySettingHour: baseHour, minute: 0, second: 0, of: selectedDate) ?? selectedDate
                            eventSlot = EventSlot(start: start)
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
            
            // 待办与日程内容
            Group {
                if selectedSubTab == 0 {
                    remindersContentView
                } else {
                    scheduleContentView
                }
            }
        }
        .environment(\.locale, state.appLanguage.locale)
        .alert(state.L("Operation Failed"), isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) {
            Button(state.L("OK"), role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .task {
            eventManager.updateAuthStatuses()
            await eventManager.fetchEventsForMonth(currentCalendarMonth)
            await eventManager.fetchReminders()
        }
        // 当应用重获焦点时（例如用户在系统设置中勾选允许后切回），自动重检权限与拉取数据
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            eventManager.recheckAuthorization()
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
        .sheet(item: $eventSlot) { slot in
            AddEventSheetView(
                state: state,
                defaultTitle: !currentDocTitle.isEmpty ? L.format("Reading Paper", state.appLanguage, currentDocTitle) : "",
                defaultNotes: currentContextCitation,
                initialStartDate: slot.start,
                eventManager: eventManager
            )
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
            
            // 将未完成与已完成事项分别分组
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
                                    language: state.appLanguage,
                                        reminder: reminder,
                                        currentDocTitle: currentDocTitle,
                                        showCalendarBadge: false,
                                        onToggle: {
                                            Task {
                                                do { try await eventManager.toggleReminderCompletion(reminder) }
                                                catch { operationError = error.localizedDescription }
                                            }
                                        },
                                        onDelete: {
                                            Task {
                                                do { try await eventManager.deleteReminder(reminder) }
                                                catch { operationError = error.localizedDescription }
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
                                    language: state.appLanguage,
                                    reminder: reminder,
                                    currentDocTitle: currentDocTitle,
                                    showCalendarBadge: true,
                                    onToggle: {
                                        Task {
                                            do { try await eventManager.toggleReminderCompletion(reminder) }
                                            catch { operationError = error.localizedDescription }
                                        }
                                    },
                                    onDelete: {
                                        Task {
                                            do { try await eventManager.deleteReminder(reminder) }
                                            catch { operationError = error.localizedDescription }
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
            
            Text(EventManager.displayTitle(of: cal, language: state.appLanguage))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
            
            if cal.title == EventManager.readingCalendarTitle {
                Text(state.L("App List"))
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
                            eventSlot = EventSlot(start: start)
                        }
                    },
                    onDeleteEvent: { ev in
                        Task {
                            do { try await eventManager.deleteEvent(ev) }
                            catch { operationError = error.localizedDescription }
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
            
            Text(isDenied ? state.L("Permission Not Enabled") : state.L("Permission Required"))
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            
            Text(isDenied
                 ? L.format("Schedule Access Denied", state.appLanguage, title, state.L(isCalendar ? "Calendar" : "Reminders"))
                 : L.format("Schedule Access Purpose", state.appLanguage, title))
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
                .disabled(isCalendar ? eventManager.isRequestingCalendarAccess : eventManager.isRequestingReminderAccess)
                
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
                    eventManager.recheckAuthorization()
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
