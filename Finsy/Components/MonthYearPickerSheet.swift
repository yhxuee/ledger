import SwiftUI

struct MonthYearPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedDate: Date

    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }

    private let calendar = Calendar.current
    private let now = Date.now

    @State private var displayedYear: Int

    init(selectedDate: Binding<Date>) {
        self._selectedDate = selectedDate
        let currentCal = Calendar.current
        let year = currentCal.component(.year, from: selectedDate.wrappedValue)
        self._displayedYear = State(initialValue: year)
    }

    private var currentYear: Int { calendar.component(.year, from: now) }
    private var currentMonth: Int { calendar.component(.month, from: now) }

    private var selectedYear: Int { calendar.component(.year, from: selectedDate) }
    private var selectedMonthIndex: Int { calendar.component(.month, from: selectedDate) }

    private let monthSymbols: [String] = {
        let formatter = DateFormatter()
        return formatter.monthSymbols ?? [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
    }()

    private let shortMonthSymbols: [String] = {
        let formatter = DateFormatter()
        return formatter.shortMonthSymbols ?? [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
        ]
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Year Header with chevrons
                HStack {
                    Button {
                        if displayedYear > currentYear - 10 {
                            displayedYear -= 1
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .ledgerGlass(in: Circle())
                    }
                    .disabled(displayedYear <= currentYear - 10)

                    Spacer()

                    Text(String(displayedYear))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        if displayedYear < currentYear {
                            displayedYear += 1
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(displayedYear >= currentYear ? .tertiary : .primary)
                            .padding(10)
                            .ledgerGlass(in: Circle())
                    }
                    .disabled(displayedYear >= currentYear)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // 3x4 Month Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                    ForEach(1...12, id: \.self) { monthNumber in
                        let isFuture = (displayedYear == currentYear && monthNumber > currentMonth) || (displayedYear > currentYear)
                        let isSelected = (displayedYear == selectedYear && monthNumber == selectedMonthIndex)

                        Button {
                            if !isFuture {
                                selectMonth(year: displayedYear, month: monthNumber)
                                dismiss()
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text(shortMonthSymbols[monthNumber - 1])
                                    .font(.headline.weight(.semibold))
                                Text(monthSymbols[monthNumber - 1])
                                    .font(.caption2)
                                    .opacity(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(primaryActionColor)
                                } else {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                }
                            }
                            .foregroundStyle(isSelected ? Color.white : (isFuture ? Color.secondary.opacity(0.4) : Color.primary))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .disabled(isFuture)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)

                Spacer()
            }
            .background(LedgerBackground())
            .navigationTitle("Select Month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func selectMonth(year: Int, month: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        if let date = calendar.date(from: components) {
            selectedDate = date
        }
    }
}
