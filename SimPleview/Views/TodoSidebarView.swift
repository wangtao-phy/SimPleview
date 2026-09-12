import SwiftUI
@preconcurrency import EventKit

/// [理论物理与用户界面：待办与日程侧边栏 TodoSidebarView]
/// 该视图作为 SimPleview 读者的外延时间管理终端：
/// 1. 待办事项 (Reminders)：分类同步，支持按系统列表（如『SimPleview阅读』、工作、个人）进行过滤与分段呈现，避免全部杂乱堆叠。
///    - 新增事项默认且自动归档至新建的『SimPleview阅读』原生分类下。
/// 2. 日程安排 (Events)：展示时间轴上的连续研读日程，支持按日期聚类与日历分类色条。
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
    
    // 弹窗表单状态
    @State private var showingAddReminderSheet: Bool = false
    @State private var showingAddEventSheet: Bool = false
    
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
                                HStack(spacing: 4) {
                                    Text(cal.title)
                                }
                                .tag(cal.calendarIdentifier)
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
            }
        }
        .sheet(isPresented: $showingAddReminderSheet) {
            AddReminderSheetView(
                state: state,
                defaultTitle: "",
                defaultNotes: currentContextCitation,
                eventManager: eventManager
            )
        }
        .sheet(isPresented: $showingAddEventSheet) {
            AddEventSheetView(
                state: state,
                defaultTitle: !currentDocTitle.isEmpty ? "研读: \(currentDocTitle)" : "",
                defaultNotes: currentContextCitation,
                eventManager: eventManager
            )
        }
    }
    
    // MARK: - 待办事项列表组件 (分类同步与分组呈现)
    
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
            
            if filteredList.isEmpty {
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
                // 按分类列表组织 Grouped Sections，与 macOS 原生提醒保持完全同构
                let calendarsWithItems = eventManager.availableReminderCalendars().filter { cal in
                    filteredList.contains(where: { $0.calendar?.calendarIdentifier == cal.calendarIdentifier })
                }
                
                List {
                    ForEach(calendarsWithItems, id: \.calendarIdentifier) { cal in
                        let items = filteredList.filter { $0.calendar?.calendarIdentifier == cal.calendarIdentifier }
                        if !items.isEmpty {
                            Section(header: reminderSectionHeader(cal: cal, count: items.count)) {
                                ForEach(items, id: \.calendarItemIdentifier) { reminder in
                                    ReminderRowView(
                                        reminder: reminder,
                                        currentDocTitle: currentDocTitle,
                                        onToggle: {
                                            Task {
                                                try? await eventManager.toggleReminderCompletion(reminder)
                                            }
                                        },
                                        onDelete: {
                                            Task {
                                                try? await eventManager.deleteReminder(reminder)
                                            }
                                        }
                                    )
                                }
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
    
    // MARK: - 日程安排列表组件
    
    @ViewBuilder
    private var scheduleContentView: some View {
        if !eventManager.hasCalendarAccess {
            permissionGuideView(
                isCalendar: true,
                title: state.L("Schedule"),
                isDenied: eventManager.isCalendarDenied
            )
        } else {
            let filteredEvents = eventManager.events.filter { event in
                guard filterCurrentDocOnly else { return true }
                guard !currentDocTitle.isEmpty else { return true }
                let inNotes = event.notes?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
                let inTitle = event.title?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
                return inNotes || inTitle
            }
            
            if filteredEvents.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "calendar")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(state.L("No Events Found"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button(action: { showingAddEventSheet = true }) {
                        Text(state.L("Add Event"))
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
                    ForEach(filteredEvents, id: \.eventIdentifier) { event in
                        EventRowView(
                            event: event,
                            currentDocTitle: currentDocTitle,
                            onDelete: {
                                Task {
                                    try? await eventManager.deleteEvent(event)
                                }
                            }
                        )
                    }
                }
                .listStyle(.plain)
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
            
            if isDenied {
                // 若已被拒绝，提供直达 macOS 系统设置的动作
                Button(action: {
                    if isCalendar {
                        eventManager.openCalendarPrivacySettings()
                    } else {
                        eventManager.openReminderPrivacySettings()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape.fill")
                        Text(state.L("Open System Settings"))
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                
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
            } else {
                // 尚未做过决定时，执行原生权限请求
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
                
                Button(action: {
                    if isCalendar {
                        eventManager.openCalendarPrivacySettings()
                    } else {
                        eventManager.openReminderPrivacySettings()
                    }
                }) {
                    Text(state.L("Open System Settings"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 待办单行视图组件

struct ReminderRowView: View {
    let reminder: EKReminder
    let currentDocTitle: String
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
            let f = DateFormatter()
            f.dateFormat = "今天 HH:mm"
            return f.string(from: date)
        } else if cal.isDateInTomorrow(date) {
            let f = DateFormatter()
            f.dateFormat = "明天 HH:mm"
            return f.string(from: date)
        } else {
            let f = DateFormatter()
            f.dateFormat = "M月d日 HH:mm"
            return f.string(from: date)
        }
    }
}

// MARK: - 日程单行视图组件

struct EventRowView: View {
    let event: EKEvent
    let currentDocTitle: String
    let onDelete: () -> Void
    
    @State private var isHovered: Bool = false
    
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
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Text("删除日程")
            }
        }
    }
    
    private func formatEventTime(_ event: EKEvent) -> String {
        let f = DateFormatter()
        if event.isAllDay {
            f.dateFormat = "M月d日 全天"
            return f.string(from: event.startDate)
        }
        
        let cal = Calendar.current
        if cal.isDate(event.startDate, inSameDayAs: event.endDate) {
            f.dateFormat = "M月d日 HH:mm"
            let startStr = f.string(from: event.startDate)
            let fEnd = DateFormatter()
            fEnd.dateFormat = "HH:mm"
            return "\(startStr) - \(fEnd.string(from: event.endDate))"
        } else {
            f.dateFormat = "M/d HH:mm"
            return "\(f.string(from: event.startDate)) - \(f.string(from: event.endDate))"
        }
    }
}

// MARK: - 新建待办事项表单弹窗 (默认归档至『SimPleview阅读』)

struct AddReminderSheetView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool = true
    @State private var dueDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var selectedCalendar: EKCalendar?
    
    let eventManager: EventManager
    
    init(state: AppState, defaultTitle: String, defaultNotes: String, eventManager: EventManager) {
        self.state = state
        self._title = State(initialValue: defaultTitle)
        self._notes = State(initialValue: defaultNotes)
        self.eventManager = eventManager
        // 核心优化：默认选中或创建『SimPleview阅读』分类列表
        let readingCal = eventManager.getOrCreateSimPleviewCalendar() ?? eventManager.defaultReminderCalendar()
        self._selectedCalendar = State(initialValue: readingCal)
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
                        HStack {
                            Text(cal.title)
                        }
                        .tag(cal as EKCalendar?)
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
                        try? await eventManager.createReminder(
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
    }
}

// MARK: - 新建日程表单弹窗

struct AddEventSheetView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String
    @State private var notes: String
    @State private var isAllDay: Bool = false
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var selectedCalendar: EKCalendar?
    
    let eventManager: EventManager
    
    init(state: AppState, defaultTitle: String, defaultNotes: String, eventManager: EventManager) {
        self.state = state
        self._title = State(initialValue: defaultTitle)
        self._notes = State(initialValue: defaultNotes)
        self.eventManager = eventManager
        self._selectedCalendar = State(initialValue: eventManager.defaultEventCalendar())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.L("Add Event"))
                .font(.headline)
            
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
            
            let calendars = eventManager.availableEventCalendars()
            if calendars.count > 1 {
                Picker(state.L("Calendar"), selection: $selectedCalendar) {
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        Text(cal.title).tag(cal as EKCalendar?)
                    }
                }
                .pickerStyle(.menu)
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
                        try? await eventManager.createEvent(
                            title: title,
                            startDate: startDate,
                            endDate: endDate,
                            isAllDay: isAllDay,
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
    }
}
