import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: LedgerStore
    @Binding var selectedAccountID: UUID?
    @State private var showAccountPicker = false
    @State private var showTransactionEditor = false
    @State private var editingTransaction: LedgerTransaction?

    private var selected: AccountViewModel? { selectedAccountID.flatMap { id in store.accounts.first { $0.id == id } } }
    private var transactions: [LedgerTransaction] { LedgerCalculations.transactions(store.state, accountID: selectedAccountID) }
    private var usage: (budget: Double, spent: Double, ratio: Double) { selected.map { LedgerCalculations.budgetUsage(store.state, account: $0.account) } ?? LedgerCalculations.budgetUsage(store.state) }
    private var usageCurrency: CurrencyCode { selected?.account.currency ?? store.state.settings.baseCurrency }
    private var summary: AnalyticsSummary { LedgerCalculations.analytics(store.state, range: .week, accountID: selectedAccountID) }

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) { hero.frame(minWidth: 320, maxWidth: 520); metrics.frame(minWidth: 360, maxWidth: .infinity) }
                VStack(spacing: 16) { hero; metrics }
            }
            .padding(.horizontal).padding(.top, 8)
            latest.padding(.horizontal).padding(.top, 18).padding(.bottom, 30)
        }
        .navigationTitle(selected?.account.name ?? "Overview")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                GlassIconButton(systemName: "plus", label: "Add transaction", prominent: true) { showTransactionEditor = true }
                GlassIconButton(systemName: "ellipsis", label: "Choose account") { showAccountPicker = true }
            }
        }
        .sheet(isPresented: $showAccountPicker) { AccountPickerView(selectedAccountID: $selectedAccountID) }
        .sheet(isPresented: $showTransactionEditor) { TransactionEditorView() }
        .sheet(item: $editingTransaction) { TransactionEditorView(transaction: $0) }
    }

    private var hero: some View {
        Button { showAccountPicker = true } label: {
            AccountCardView(account: selected, portfolioBalance: LedgerCalculations.portfolioBalance(store.state), baseCurrency: store.state.settings.baseCurrency)
        }.buttonStyle(.plain)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
            MetricCard("Account Balance") {
                Text(LedgerFormat.money(selected?.balance ?? LedgerCalculations.portfolioBalance(store.state), currency: selected?.account.currency ?? store.state.settings.baseCurrency))
                    .font(.title2.bold()).minimumScaleFactor(0.65).lineLimit(1)
                Text(selected == nil ? "Converted to \(store.state.settings.baseCurrency.rawValue)" : selected!.account.type.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            MetricCard("Weekly Activity") {
                MiniActivityChart(buckets: summary.buckets)
                Text(LedgerFormat.money(summary.total, currency: store.state.settings.baseCurrency, compact: true)).font(.headline.bold())
            }
            MetricCard("Budget / Remain") {
                Text(LedgerFormat.money(usage.budget - usage.spent, currency: usageCurrency)).font(.title2.bold()).minimumScaleFactor(0.65).lineLimit(1)
                ProgressView(value: min(max(usage.ratio, 0), 1)).tint(usage.ratio > 1 ? .red : LedgerPalette.coral)
                Text("\(Int(usage.ratio * 100))% of monthly budget used").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var latest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest Transactions").font(.title2.bold())
            LazyVStack(spacing: 0) {
                ForEach(transactions.prefix(8)) { item in
                    Button { editingTransaction = item } label: { TransactionRow(transaction: item, category: category(item.categoryID)).padding(.horizontal, 15).padding(.vertical, 7) }
                        .buttonStyle(.plain)
                    if item.id != transactions.prefix(8).last?.id { Divider().padding(.leading, 67) }
                }
                if transactions.isEmpty { ContentUnavailableView("No Transactions", systemImage: "tray", description: Text("Add the first entry for this account.")) }
            }
            .ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func category(_ id: LedgerCategoryID) -> LedgerCategory { store.state.categories.first { $0.id == id } ?? SeedData.categories.first { $0.id == id } ?? LedgerCategory(id: .other, name: "Other", detail: "Everything else", symbol: "dollarsign.circle.fill", colorHex: "62B28F") }
}

private struct MiniActivityChart: View {
    let buckets: [AnalyticsBucket]
    var body: some View {
        let maximum = max(buckets.map(\.value).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(buckets) { bucket in RoundedRectangle(cornerRadius: 3).fill(LedgerPalette.coral.gradient).frame(height: max(4, 34 * bucket.value / maximum)) }
        }.frame(height: 36)
    }
}

private struct AccountPickerView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedAccountID: UUID?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: -36) {
                    Button { selectedAccountID = nil; dismiss() } label: { AccountCardView(account: nil, portfolioBalance: LedgerCalculations.portfolioBalance(store.state), baseCurrency: store.state.settings.baseCurrency, compact: true) }.buttonStyle(.plain)
                    ForEach(store.accounts) { item in Button { selectedAccountID = item.id; dismiss() } label: { AccountCardView(account: item, baseCurrency: store.state.settings.baseCurrency, compact: true) }.buttonStyle(.plain) }
                }.padding()
            }.navigationTitle("Wallet").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
