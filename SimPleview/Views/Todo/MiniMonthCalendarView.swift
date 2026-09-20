import SwiftUI
@preconcurrency import EventKit

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
        ScheduleDateFormatters.monthHeader.string(from: date)
    }

    private func eventsForDate(_ date: Date) -> [EKEvent] {
        events.filter { ev in
            calendar.isDate(ev.startDate, inSameDayAs: date) ||
            calendar.isDate(ev.endDate, inSameDayAs: date) ||
            (ev.startDate <= date && ev.endDate >= date)
        }
    }
}
