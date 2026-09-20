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
    struct Slot: Identifiable {
        var id: Int
        var selected = false
        var amount: String
        var currency: CurrencyCode
    }
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let parent: LedgerTransaction
    @State private var accountID: UUID?
    @State private var slots: [Slot] = []
    @State private var error = false

    var body: some View {
        NavigationStack {
            Form {
                AccountSelectorMenu(accounts: store.accounts.map(\.account), selection: $accountID, title: "Receiving Account")
                ForEach($slots) { $slot in
                    VStack {
                        Toggle("Person \(slot.id + 1)", isOn: $slot.selected)
                        HStack {
                            TransactionCurrencyPicker(selection: $slot.currency)
                            TextField("Amount", text: $slot.amount).keyboardType(.decimalPad)
                        }
                    }
                }
                if error { Text("The settlement could not be saved.").foregroundStyle(.red) }
            }
            .navigationTitle("Settlement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Settle") { save() }
                        .disabled(accountID == nil || !slots.contains(where: \.selected) || slots.filter(\.selected).contains(where: { (Double($0.amount) ?? 0) <= 0 }))
                }
            }
            .onAppear {
                accountID = parent.accountID
                slots = TransactionSemantics.outstandingSlots(parent, in: store.state).map {
                    Slot(id: $0, amount: String(format: "%.2f", parent.amount / Double(parent.splitMetadata?.participantCount ?? 2)), currency: parent.currency)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let accountID else { return }
        for slot in slots where slot.selected {
            guard let amount = Double(slot.amount), store.addRecovery(parentID: parent.id, kind: .splitSettlement, slot: slot.id,
                accountID: accountID, amount: amount, currency: slot.currency,
                accountCurrency: store.state.accounts.first(where: { $0.id == accountID })?.defaultPocket(for: slot.currency)) else { error = true; return }
            slots.removeAll { $0.id == slot.id }
        }
        dismiss()
    }
}
