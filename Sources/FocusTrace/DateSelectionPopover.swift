import SwiftUI

struct DateSelectionPopover: View {
    let date: Date
    let onSelect: (Date) -> Void
    @State private var month: Date
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 7)

    init(date: Date, onSelect: @escaping (Date) -> Void) {
        self.date = date
        self.onSelect = onSelect
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: date)!.start)
    }

    private var days: [Date] {
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return (0..<42).map { calendar.date(byAdding: .day, value: $0 - offset, to: month)! }
    }

    private var weekdays: [String] {
        var labels = calendar
        labels.locale = Locale(identifier: "en_US")
        return (0..<7).map { labels.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US"))))
                    .font(AppType.heading)
                Spacer(minLength: 0)
                monthButton(-1)
                monthButton(1)
            }.padding(.bottom, 10)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, label in
                    Text(label).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 28, height: 18)
                        .accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day in dayButton(day) }
            }

            Divider().padding(.top, 10).padding(.bottom, 6)
            Button { onSelect(Date()) } label: {
                Text("Today").font(AppType.caption)
                    .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(QuietButtonStyle())
        }
        .padding(12).frame(width: 244)
        .foregroundStyle(.primary).tint(.gray)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func monthButton(_ offset: Int) -> some View {
        Button { month = calendar.date(byAdding: .month, value: offset, to: month)! } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(offset > 0 && calendar.isDate(month, equalTo: Date(), toGranularity: .month))
        .accessibilityLabel(offset < 0 ? "Previous month" : "Next month")
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let today = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let future = calendar.startOfDay(for: day) > calendar.startOfDay(for: Date())
        return Button { onSelect(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 12, weight: selected ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(inMonth ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(selected ? Color.primary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    if today {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
                    }
                }.contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle()).disabled(future)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(Locale(identifier: "en_US"))))
        .accessibilityValue(today ? "Today" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
