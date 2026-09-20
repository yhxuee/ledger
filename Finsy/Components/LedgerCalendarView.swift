import SwiftUI

struct LedgerCalendarView: View {
    @Binding var selection: Date
    let transactions: [LedgerTransaction]
    let accounts: [LedgerAccount]
    @State private var displayedMonth: Date

    private let calendar = Calendar.current
    private let weekdays = ["S", "M", "T", "W", "T", "F", "S"]

    init(selection: Binding<Date>, transactions: [LedgerTransaction], accounts: [LedgerAccount]) {
        _selection = selection
        self.transactions = transactions
        self.accounts = accounts
        let components = Calendar.current.dateComponents([.year, .month], from: selection.wrappedValue)
        _displayedMonth = State(initialValue: Calendar.current.date(from: components) ?? selection.wrappedValue)
    }

    private var totalGridCells: Int {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) ?? displayedMonth
        let leading = calendar.component(.weekday, from: first) - 1
        let daysInMonth = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        return (leading + daysInMonth) > 35 ? 42 : 35
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text(displayedMonth.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 8)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 2) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 18)
                }
                ForEach(0..<totalGridCells, id: \.self) { index in
                    if let date = date(for: index) {
                        Button { selection = date } label: {
                            let colors = Array(markerColors(for: date).prefix(4))
                            let isSelected = calendar.isDate(date, inSameDayAs: selection)
                            VStack(spacing: 2) {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.body.weight(isSelected ? .bold : .regular))
                                HStack(spacing: 2) {
                                    ForEach(Array(colors.enumerated()), id: \.offset) { item in
                                        Circle().fill(item.element).frame(width: 4, height: 4)
                                    }
                                }.frame(height: 4)
                            }
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    } else {
                        Color.clear.frame(height: 34)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .onChange(of: selection) { _, date in
            displayedMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        }
    }

    private func moveMonth(_ value: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { displayedMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth }
    }

    private func date(for index: Int) -> Date? {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) ?? displayedMonth
        let leading = calendar.component(.weekday, from: first) - 1
        let day = index - leading + 1
        guard let range = calendar.range(of: .day, in: .month, for: first), range.contains(day) else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: first)
    }

    private func markerColors(for date: Date) -> [Color] {
        let ids = transactions
            .filter { $0.type == .expense && calendar.isDate($0.occurredAt, inSameDayAs: date) }
            .map(\.accountID)
        var seen = Set<UUID>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let account = accounts.first(where: { $0.id == id }) else { return nil }
            return Color(hex: account.cardStyle.startHex)
        }
    }
}
