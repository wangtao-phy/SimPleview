import SwiftUI
@preconcurrency import EventKit

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

                Text(state.L("New Event Slot Hint"))
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
        ScheduleDateFormatters.string(date, style: .dayHeader, language: state.appLanguage)
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
                                Text(state.L("Add Event Here"))
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
