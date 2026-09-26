import SwiftUI
import Charts
import UIKit

struct TaxCategorySummary: Identifiable, Sendable {
    var id: LedgerCategoryID { category.id }
    let category: LedgerCategory
    let taxAmount: Double
}

struct TaxAnalyticsPage: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @EnvironmentObject private var privacy: PrivacyController
    @Binding var range: AnalyticsRange
    let customRange: ClosedRange<Date>?
    let categories: Set<LedgerCategoryID>
    let accountIDs: Set<UUID>

    @State private var exportItem: ExportImageItem?
    private var dateBounds: (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        if let customRange {
            let start = calendar.startOfDay(for: customRange.lowerBound)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customRange.upperBound)) ?? customRange.upperBound
            return (start, end)
        } else {
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            let start: Date
            switch range {
            case .week:
                start = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: today) - 1), to: today) ?? today
            case .month:
                start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
            case .sixMonths, .year:
                let month = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
                start = calendar.date(byAdding: .month, value: range == .sixMonths ? -5 : -11, to: month) ?? month
            }
            return (start, end)
        }
    }

    private var dateRangeString: String {
        let bounds = dateBounds
        let calendar = Calendar.current
        let lastDay = calendar.date(byAdding: .day, value: -1, to: bounds.end) ?? bounds.start
        return "\(shortDate(bounds.start)) \u{2013} \(shortDate(lastDay))"
    }

    private func shortDate(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        let year = (components.year ?? 0) % 100
        return preferences.value.dateFormat == .monthDay
            ? String(format: "%02d/%02d/%02d", month, day, year)
            : String(format: "%02d/%02d/%02d", day, month, year)
    }

    private struct TaxRequest: Hashable, Sendable {
        var bookID: UUID
        var revision: UInt64
        var start: Date
        var end: Date
        var categories: Set<LedgerCategoryID>
        var accounts: Set<UUID>
    }
    @State private var completedRequest: TaxRequest?
    @State private var cachedSummaries: [TaxCategorySummary] = []
    private var requestedTax: TaxRequest {
        let bounds = dateBounds
        return TaxRequest(bookID: store.activeBookID, revision: store.financialRevision,
            start: bounds.start, end: bounds.end, categories: categories, accounts: accountIDs)
    }
    private var summaries: [TaxCategorySummary] { completedRequest == requestedTax ? cachedSummaries : [] }

    nonisolated private static func buildSummaries(request: TaxRequest, state: LedgerState, index: LedgerIndex) -> [TaxCategorySummary] {
        let bounds = (start: request.start, end: request.end)
        var totals: [LedgerCategoryID: Double] = [:]

        for transaction in index.sortedActiveTransactions {
            guard transaction.occurredAt >= bounds.start, transaction.occurredAt < bounds.end,
                  request.accounts.isEmpty || request.accounts.contains(transaction.accountID),
                  let taxResult = TransactionSemantics.taxEffect(transaction, in: state, to: state.settings.baseCurrency, index: index),
                  request.categories.isEmpty || request.categories.contains(taxResult.categoryID)
            else { continue }

            totals[taxResult.categoryID, default: 0] += taxResult.amount
        }

        return totals.compactMap { (categoryID, total) -> TaxCategorySummary? in
            guard total > 0.0001,
                  let category = state.categories.first(where: { $0.id == categoryID })
                                 ?? SeedData.categories.first(where: { $0.id == categoryID })
            else { return nil }
            return TaxCategorySummary(category: category, taxAmount: total)
        }.sorted {
            if abs($0.taxAmount - $1.taxAmount) > 0.0001 {
                return $0.taxAmount > $1.taxAmount
            }
            return $0.category.displayName.localizedStandardCompare($1.category.displayName) == .orderedAscending
        }
    }

    private var totalTax: Double {
        summaries.reduce(0) { $0 + $1.taxAmount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(AnalyticsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if completedRequest != requestedTax {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                pieChartView

                TaxReceiptView(
                    summaries: summaries,
                    totalTax: totalTax,
                    currency: store.state.settings.baseCurrency,
                    dateRangeString: dateRangeString,
                    isExport: false,
                    onExport: exportReceipt
                )
                .disabled(completedRequest != requestedTax)


            }
            .padding()
        }
        .task(id: requestedTax) {
            let request = requestedTax
            guard completedRequest != request else { return }
            let state = store.state
            let index = store.index
            let worker = Task.detached(priority: .userInitiated) { Self.buildSummaries(request: request, state: state, index: index) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            cachedSummaries = result
            completedRequest = request
        }
        .sheet(item: $exportItem) { item in
            ShareActivitySheet(items: [item.image])
                .presentationDetents([.medium, .large])
        }

    }

    private var pieChartView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tax Breakdown").font(.headline)
                Spacer()
                SensitiveMoneyText(amount: totalTax, currency: store.state.settings.baseCurrency, compact: true)
                    .font(.title3.bold())
            }

            if privacy.isLocked || summaries.isEmpty {
                ContentUnavailableView("No Recorded Tax", systemImage: "chart.pie")
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                Chart(summaries) { summary in
                    SectorMark(
                        angle: .value("Tax", summary.taxAmount),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .foregroundStyle(Color(hex: summary.category.colorHex))
                    .cornerRadius(4)
                }
                .chartLegend(.hidden)
                .frame(height: 190)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                    ForEach(summaries) { item in
                        HStack {
                            Circle().fill(Color(hex: item.category.colorHex)).frame(width: 8, height: 8)
                            Text(item.category.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(percent(item.taxAmount, total: totalTax)).font(.caption.bold())
                        }
                    }
                }
            }
        }
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func percent(_ value: Double, total: Double) -> String {
        guard value.isFinite, value >= 0, total.isFinite, total > 0 else { return "0%" }
        let p = (value / total * 100).rounded()
        guard p.isFinite else { return "0%" }
        return "\(Int(p))%"
    }


    @MainActor
    private func exportReceipt() {
        guard !privacy.isLocked, !summaries.isEmpty else { return }
        let view = TaxReceiptView(summaries: summaries, totalTax: totalTax,
            currency: store.state.settings.baseCurrency, dateRangeString: dateRangeString,
            isExport: true).environmentObject(privacy)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        if let image = renderer.uiImage { exportItem = ExportImageItem(image: image) }
    }
}

struct TaxReceiptView: View {
    let summaries: [TaxCategorySummary]
    let totalTax: Double
    let currency: CurrencyCode
    var dateRangeString: String? = nil
    var isExport: Bool = false
    var onExport: (() -> Void)? = nil
    @EnvironmentObject private var privacy: PrivacyController

    var body: some View {
        if isExport {
            exportContent
        } else {
            onscreenContent
        }
    }

    private var onscreenContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TAX RECEIPT")
                    .font(.system(.headline, design: .monospaced))
                Spacer()
                Button {
                    onExport?()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                }
                .disabled(privacy.isLocked || summaries.isEmpty)
                .accessibilityLabel("Export Receipt")
            }

            Divider()

            if summaries.isEmpty {
                Text("No recorded tax in this period")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(summaries) { item in
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: item.category.colorHex)).frame(width: 6, height: 6)
                            Text(item.category.name)
                                .lineLimit(1)
                            Spacer()
                            SensitiveMoneyText(amount: item.taxAmount, currency: currency)
                        }
                        .font(.system(.caption, design: .monospaced))
                        if item.id != summaries.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .trailing, spacing: 4) {
                Text("TOTAL TAX")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                SensitiveMoneyText(
                    amount: totalTax,
                    currency: currency
                )
                .font(.system(
                    size: 34,
                    weight: .bold,
                    design: .default
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var exportContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FINSY")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                Text("TAX RECEIPT")
                    .font(.system(.title3, design: .monospaced).bold())
                if let dateRangeString {
                    Text(dateRangeString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(summaries) { item in
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: item.category.colorHex)).frame(width: 6, height: 6)
                        Text(item.category.name)
                            .lineLimit(1)
                        Spacer()
                        Text(LedgerFormat.money(item.taxAmount, currency: currency))
                    }
                    .font(.system(.subheadline, design: .monospaced))
                }
            }

            Divider()

            VStack(alignment: .trailing, spacing: 4) {
                Text("TOTAL TAX")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(LedgerFormat.money(totalTax, currency: currency))
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 340)
        .padding(.vertical, 8)
        .background(Color.white, in: SerratedTicketShape())
        .foregroundStyle(Color.black)
    }
}

private struct ExportImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ShareActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
