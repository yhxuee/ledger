import SwiftUI

struct BudgetDetailView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var privacy: PrivacyController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
    @State private var editing = false
    private var detail: BudgetBreakdown { LedgerCalculations.budgetBreakdown(store.state) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MONTHLY BUDGET").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack { summaryMetric("Budget", detail.budget); summaryMetric("Spent", detail.spent); summaryMetric("Remaining", detail.remaining) }
                        ProgressView(value: privacy.isLocked ? 0 : min(max(detail.ratio, 0), 1)).tint(detail.ratio > 1 ? .red : LedgerPalette.coral)
                        SensitiveValueText("\(Int((detail.ratio * 100).rounded()))% used", maskLength: 6).font(.caption).foregroundStyle(.secondary)
                    }.padding(18).ledgerGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    LazyVStack(spacing: 10) {
                        ForEach(detail.lines) { line in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack { Text(line.title).font(.headline); Spacer(); SensitiveMoneyText(amount: line.remaining, currency: line.currency).font(.subheadline.bold()) }
                                HStack { SensitiveMoneyText(amount: line.spent, currency: line.currency).font(.caption); Text("of").font(.caption).foregroundStyle(.secondary); SensitiveMoneyText(amount: line.budget, currency: line.currency).font(.caption) }
                                ProgressView(value: privacy.isLocked ? 0 : min(max(line.ratio, 0), 1)).tint(line.ratio > 1 ? .red : LedgerPalette.coral)
                            }.padding(16).ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        if detail.lines.isEmpty { ContentUnavailableView("No Budget Allocations", systemImage: "chart.pie", description: Text("Use Edit to configure a monthly budget.")) }
                    }
                }.padding()
            }
            .background(LedgerBackground()).navigationTitle("Budget Detail").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(primaryActionColor)
                    .accessibilityLabel("Done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        editing = true
                    }
                }
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    BudgetEditorView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    editing = false
                                } label: {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.circle)
                                .tint(primaryActionColor)
                                .accessibilityLabel("Done")
                            }
                        }
                }
            }
        }
    }
    private func summaryMetric(_ title: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); SensitiveMoneyText(amount: amount, currency: detail.currency, compact: true).font(.headline).minimumScaleFactor(0.65).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
