import SwiftUI

struct TaxAnalyticsPage: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Binding var range: AnalyticsRange
    let customRange: ClosedRange<Date>?
    let categories: Set<LedgerCategoryID>
    let accountIDs: Set<UUID>

    private struct Entry: Identifiable {
        let transaction: LedgerTransaction
        let value: Double
        var id: UUID { transaction.id }
        var originalTax: Double { (transaction.taxAmount ?? 0) * (transaction.isReversal ? -1 : 1) }
    }

    private var entries: [Entry] {
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        if let customRange {
            start = calendar.startOfDay(for: customRange.lowerBound)
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customRange.upperBound)) ?? customRange.upperBound
        } else {
            end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            switch range {
            case .week:
                start = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: today) - 1), to: today) ?? today
            case .month:
                start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
            case .sixMonths, .year:
                let month = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
                start = calendar.date(byAdding: .month, value: range == .sixMonths ? -5 : -11, to: month) ?? month
            }
        }
        return store.state.transactions.compactMap { transaction -> Entry? in
            guard transaction.type == .expense || transaction.type == .income,
                  transaction.occurredAt >= start, transaction.occurredAt < end,
                  categories.isEmpty || categories.contains(transaction.categoryID),
                  accountIDs.isEmpty || accountIDs.contains(transaction.accountID),
                  let value = LedgerCalculations.taxEffect(transaction, in: store.state, to: store.state.settings.baseCurrency),
                  value != 0 else { return nil }
            return Entry(transaction: transaction, value: value)
        }.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if $0.transaction.occurredAt != $1.transaction.occurredAt { return $0.transaction.occurredAt > $1.transaction.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func title(_ transaction: LedgerTransaction) -> String {
        let note = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return note.isEmpty ? (store.state.categories.first { $0.id == transaction.categoryID }?.name ?? "Transaction") : note
    }

    private func sourceType(_ transaction: LedgerTransaction) -> LedgerTransactionType {
        if let original = transaction.reversalOfTransactionID,
           let source = store.state.transactions.first(where: { $0.id == original }) { return source.type }
        return transaction.type
    }

    private func shortDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        return preferences.value.dateFormat == .monthDay
            ? String(format: "%02d/%02d", month, day)
            : String(format: "%02d/%02d", day, month)
    }

    var body: some View {
        let rows = entries
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Highest Tax").font(.headline)
                    if let highest = rows.first(where: { $0.value > 0 }) {
                        Text(title(highest.transaction)).font(.title3.bold())
                        HStack(spacing: 4) {
                            Text(preferences.value.dateFormat.transactionDateString(from: highest.transaction.occurredAt))
                            Text("\u{00B7}")
                            Text(sourceType(highest.transaction) == .income ? "Income" : "Expense")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SensitiveValueText(LedgerMoneyFormat.code(highest.originalTax, currency: highest.transaction.currency))
                                .font(.title2.bold())
                            if highest.transaction.currency != store.state.settings.baseCurrency {
                                HStack(spacing: 2) {
                                    Text("(\u{2248} ")
                                    SensitiveMoneyText(amount: highest.value, currency: store.state.settings.baseCurrency)
                                    Text(")")
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No recorded tax").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("TAX RECEIPT").font(.system(.headline, design: .monospaced))
                    Divider()
                    if rows.isEmpty {
                        Text("No recorded tax in this period")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(rows) { entry in
                                HStack(alignment: .center, spacing: 8) {
                                    Text("\(sourceType(entry.transaction) == .income ? "INC" : "EXP")  \(shortDate(entry.transaction.occurredAt))")
                                        .foregroundStyle(.secondary)
                                    Text(title(entry.transaction))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    SensitiveValueText(LedgerMoneyFormat.code(entry.originalTax, currency: entry.transaction.currency))
                                        .multilineTextAlignment(.trailing)
                                }
                                .font(.system(.caption, design: .monospaced))
                                if entry.id != rows.last?.id { Divider() }
                            }
                        }
                    }
                    Divider()
                    Text("TOTAL TAX").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    SensitiveMoneyText(amount: rows.reduce(0) { $0 + $1.value }, currency: store.state.settings.baseCurrency)
                        .font(.system(size: 34, weight: .bold, design: .default))
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .padding(18)
                .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding()
        }
    }
}
