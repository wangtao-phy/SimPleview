import SwiftUI
@preconcurrency import EventKit

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
    @State private var isSaving = false
    @State private var errorMessage: String?
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

        // 表单初始化只读取分类；确实点击保存时才创建专属列表，取消不写入系统。
        let defaultCal = eventManager.availableEventCalendars().first { $0.title == EventManager.readingCalendarTitle }
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
                        Text(EventManager.displayTitle(of: cal, language: state.appLanguage)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Event Title"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(state.L("Event Example"), text: $title)
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
                        Text(opt.localizedTitle(in: state.appLanguage)).tag(opt)
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
                        if !calendars.contains(where: { $0.title == EventManager.readingCalendarTitle }) {
                            Text(state.L("SimPleview Reading")).tag(nil as EKCalendar?)
                        }
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            HStack {
                                Circle().fill(Color(nsColor: cal.color)).frame(width: 6, height: 6)
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

            // 提醒
            HStack {
                Text(state.L("Alert"))
                    .font(.caption2)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Notes"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(state.L("Notes"), text: $notes)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Divider()

            HStack {
                Button(state.L("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(state.L("Add to Calendar")) {
                    guard !isSaving else { return }
                    isSaving = true
                    errorMessage = nil
                    Task {
                        defer { isSaving = false }
                        do {
                            _ = try await eventManager.createEvent(
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
                        } catch {
                            // 保存失败保留输入，允许修正后重试。
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
