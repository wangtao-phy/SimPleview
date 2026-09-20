import SwiftUI
@preconcurrency import EventKit

// MARK: - 新建待办事项表单弹窗 (默认归档至『SimPleview阅读』)

struct AddReminderSheetView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool = true
    @State private var dueDate: Date
    @State private var selectedCalendar: EKCalendar?
    @State private var isSaving = false
    @State private var errorMessage: String?

    let eventManager: EventManager

    init(state: AppState, defaultTitle: String, defaultNotes: String, eventManager: EventManager) {
        self.state = state
        self._title = State(initialValue: defaultTitle)
        self._notes = State(initialValue: defaultNotes)
        self.eventManager = eventManager
        // 初始化不创建系统列表；点击保存时才按默认分类落盘。
        let readingCal = eventManager.availableReminderCalendars().first { $0.title == EventManager.readingCalendarTitle }
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
                        Text(EventManager.displayTitle(of: cal, language: state.appLanguage)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // 标题输入
            VStack(alignment: .leading, spacing: 4) {
                Text(state.L("Task Title"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(state.L("Task Example"), text: $title)
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
                    if !calendars.contains(where: { $0.title == EventManager.readingCalendarTitle }) {
                        Text(state.L("SimPleview Reading")).tag(nil as EKCalendar?)
                    }
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        Text(EventManager.displayTitle(of: cal, language: state.appLanguage)).tag(cal as EKCalendar?)
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

                Button(state.L("Add to Reminders")) {
                    guard !isSaving else { return }
                    isSaving = true
                    errorMessage = nil
                    Task {
                        defer { isSaving = false }
                        do {
                            _ = try await eventManager.createReminder(
                                title: title,
                                dueDate: hasDueDate ? dueDate : nil,
                                notes: notes.isEmpty ? nil : notes,
                                calendar: selectedCalendar
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
            dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400)
            hasDueDate = true
        }
    }
}
