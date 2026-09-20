import SwiftUI
@preconcurrency import EventKit

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
                        Text(opt.localizedTitle(in: state.appLanguage)).tag(opt)
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
                                Text(EventManager.displayTitle(of: cal, language: state.appLanguage))
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
                        Text(opt.localizedTitle(in: state.appLanguage)).tag(opt)
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
                    guard !isSaving else { return }
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do {
                            try await eventManager.deleteEvent(event)
                            onDismiss()
                        } catch { errorMessage = error.localizedDescription }
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
                .help(state.L("Delete Event"))
                .disabled(isSaving)

                Spacer()

                Button(state.L("Cancel")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(state.L("Save")) {
                    guard !isSaving else { return }
                    isSaving = true
                    Task {
                        do {
                            let finalEnd = isAllDay ? endDate : (endDate >= startDate ? endDate : startDate.addingTimeInterval(7200))
                            try await eventManager.updateEvent(
                                event,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? state.L("Untitled Event") : title,
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
