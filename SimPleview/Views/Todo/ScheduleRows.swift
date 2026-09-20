import SwiftUI
@preconcurrency import EventKit

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
            return ScheduleDateFormatters.todayDue.string(from: date)
        } else if cal.isDateInTomorrow(date) {
            return ScheduleDateFormatters.tomorrowDue.string(from: date)
        } else {
            return ScheduleDateFormatters.otherDue.string(from: date)
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
            return ScheduleDateFormatters.allDay.string(from: event.startDate)
        }

        let cal = Calendar.current
        if cal.isDate(event.startDate, inSameDayAs: event.endDate) {
            let startStr = ScheduleDateFormatters.timeOnly.string(from: event.startDate)
            let endStr = ScheduleDateFormatters.timeOnly.string(from: event.endDate)
            return "\(startStr) - \(endStr)"
        } else {
            let startStr = ScheduleDateFormatters.dateAndHour.string(from: event.startDate)
            let endStr = ScheduleDateFormatters.dateAndHour.string(from: event.endDate)
            return "\(startStr) - \(endStr)"
        }
    }
}
