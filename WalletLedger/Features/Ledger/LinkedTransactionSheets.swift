import SwiftUI

struct LinkedSetupSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let parent: LedgerTransaction
    let mode: TransactionGroupMode
    @State private var people: Int
    @State private var count: Int
    @State private var interval: InstallmentPlanMetadata.Interval
    @State private var days: Int
    @State private var method: InstallmentPlanMetadata.FeeMethod
    @State private var fee: String
    @State private var error = false

    init(parent: LedgerTransaction, mode: TransactionGroupMode) {
        self.parent = parent; self.mode = mode
        _people = State(initialValue: parent.splitMetadata?.participantCount ?? 2)
        let plan = parent.installmentMetadata
        _count = State(initialValue: plan?.count ?? 12)
        _interval = State(initialValue: plan?.interval ?? .monthly)
        _days = State(initialValue: plan?.intervalDays ?? 30)
        _method = State(initialValue: plan?.feeMethod ?? .totalFee)
        _fee = State(initialValue: String((plan?.fee ?? 0) * (plan?.feeMethod == .monthlyInterest ? 100 : 1)))
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode == .split {
                    Stepper("People: \(people)", value: $people, in: 2...50)
                    Text("Includes you").foregroundStyle(.secondary)
                } else if mode == .installment {
                    Stepper("Installments: \(count)", value: $count, in: 2...360)
                    Picker("Interval", selection: $interval) {
                        Text("Monthly").tag(InstallmentPlanMetadata.Interval.monthly)
                        Text("Custom Days").tag(InstallmentPlanMetadata.Interval.customDays)
                    }
                    if interval == .customDays { Stepper("Custom Days: \(days)", value: $days, in: 1...3650) }
                    Picker("Fee Method", selection: $method) {
                        Text("Total Fee").tag(InstallmentPlanMetadata.FeeMethod.totalFee)
                        Text("Monthly Interest").tag(InstallmentPlanMetadata.FeeMethod.monthlyInterest)
                    }
                    TextField(method == .totalFee ? "Total Fee Amount" : "Monthly Rate %", text: $fee).keyboardType(.decimalPad)
                    if parent.groupMode == .installment { Text("Saving replaces the entire installment schedule, including edited payments.").foregroundStyle(.secondary) }
                } else {
                    Text("This expense and its reimbursements are excluded from personal expense, income, budget, and tax totals.")
                }
                if error { Text("The plan could not be saved. Check the amounts and existing settlements.").foregroundStyle(.red) }
            }
            .navigationTitle(mode == .split ? "Split Expense" : mode == .installment ? "Installments" : "Reimbursement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let plan = InstallmentPlanMetadata(count: count, interval: interval, intervalDays: days, feeMethod: method, fee: (Double(fee) ?? -1) / (method == .monthlyInterest ? 100 : 1))
                        if store.configureLinked(parent.id, mode: mode, people: people, plan: plan) { dismiss() } else { error = true }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SplitSettlementSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let parent: LedgerTransaction
    @State private var selectedChildIDs: Set<UUID> = []
    @State private var error = false

    var pendingSettlements: [LedgerTransaction] {
        TransactionSemantics.children(of: parent, in: store.state)
            .filter { $0.linkedTransactionKind == .splitSettlement && $0.linkedStatus == .pending }
    }

    var body: some View {
        NavigationStack {
            Form {
                if pendingSettlements.isEmpty {
                    Text("All settlements are completed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pendingSettlements) { child in
                        Toggle(isOn: Binding(
                            get: { selectedChildIDs.contains(child.id) },
                            set: { if $0 { selectedChildIDs.insert(child.id) } else { selectedChildIDs.remove(child.id) } }
                        )) {
                            HStack {
                                Text(child.note ?? "Settlement")
                                Spacer()
                                Text(child.currency.symbol + String(format: "%.2f", child.amount))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if error { Text("The settlement could not be saved.").foregroundStyle(.red) }
            }
            .navigationTitle("Settlement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Settle") {
                        for id in selectedChildIDs {
                            _ = store.completeSettlement(id)
                        }
                        dismiss()
                    }
                    .disabled(selectedChildIDs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
