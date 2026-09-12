import SwiftUI
import EventKit

/// [理论物理与用户界面：待办与日程侧边栏 TodoSidebarView]
/// 该视图作为 SimPleview 读者的外延时间管理终端：
/// 1. 投影待办事项 (Reminders)：展示离散完成态任务，支持实时勾选、快捷添加与过期高亮。
/// 2. 投影日历日程 (Events)：展示时间轴上的连续研读日程，支持按日期聚类与颜色区分。
/// 3. 文献引力锚定：支持一键捕获当前 PDF 文档名及页码，在创建事项时自动附注，实现文献到 macOS 原生系统的时空跃迁。
struct TodoSidebarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var uiState: UIState
    @ObservedObject var eventManager = EventManager.shared
    
    // 子标签切换：0 为待办事项 (Reminders)，1 为日程安排 (Schedule)
    @State private var selectedSubTab: Int = 0
    
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
                HStack(spacing: 8) {
                    // 仅看本文献切换
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            filterCurrentDocOnly.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: filterCurrentDocOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 12))
                            Text(state.L("Filter Current Paper"))
                                .font(.system(size: 11))
                        }
                        .foregroundColor(filterCurrentDocOnly ? .accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(filterCurrentDocOnly ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(6)
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
                            .font(.system(size: 12))
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
            .padding(10)
            
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
    
    // MARK: - 待办事项列表组件
    
    @ViewBuilder
    private var remindersContentView: some View {
        if !eventManager.hasReminderAccess {
            permissionGuideView(typeTitle: state.L("Reminders"))
        } else {
            let filteredList = eventManager.reminders.filter { reminder in
                guard filterCurrentDocOnly else { return true }
                guard !currentDocTitle.isEmpty else { return true }
                let inNotes = reminder.notes?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
                let inTitle = reminder.title?.localizedCaseInsensitiveContains(currentDocTitle) ?? false
                return inNotes || inTitle
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
                List {
                    ForEach(filteredList, id: \.calendarItemIdentifier) { reminder in
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
                .listStyle(.plain)
            }
        }
    }
    
    // MARK: - 日程安排列表组件
    
    @ViewBuilder
    private var scheduleContentView: some View {
        if !eventManager.hasCalendarAccess {
            permissionGuideView(typeTitle: state.L("Schedule"))
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
    
    // MARK: - 权限缺省与引导视图
    
    @ViewBuilder
    private func permissionGuideView(typeTitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            
            Text(state.L("Permission Required"))
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            
            Text("SimPleview 需要访问您的系统\(typeTitle)，以直接与 macOS 原生 App 保持双向同步。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Button(action: {
                Task {
                    await eventManager.requestAllAccess()
                }
            }) {
                Text(state.L("Authorize Reminders & Calendar"))
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            
            Button(action: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Text(state.L("Open System Settings"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
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
                    .font(.system(size: 16))
                    .foregroundColor(reminder.isCompleted ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            
            // 文本与元数据
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title ?? "未命名待办")
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(reminder.isCompleted)
                    .foregroundColor(reminder.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
                
                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
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
                                .font(.system(size: 10))
                        }
                        .foregroundColor(isOverdue ? .red : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isOverdue ? Color.red.opacity(0.1) : Color.primary.opacity(0.04))
                        .cornerRadius(4)
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
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(4)
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
        .padding(.vertical, 4)
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
                    .font(.system(size: 13, weight: .medium))
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
                    .cornerRadius(4)
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

// MARK: - 新建待办事项表单弹窗

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
        self._selectedCalendar = State(initialValue: eventManager.defaultReminderCalendar())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.L("Add Task"))
                .font(.headline)
            
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
            
            // 分类列表选择
            let calendars = eventManager.availableReminderCalendars()
            if calendars.count > 1 {
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
