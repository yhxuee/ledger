import SwiftUI

/// Works inside the existing ScrollView/LazyVStack; native List swipeActions are not required.
struct TransactionSwipeReveal<Content: View>: View {
    let actionTitle: String
    let actionOnRightSwipe: Bool
    let actionEnabled: Bool
    let deleteEnabled: Bool
    let action: () -> Void
    let delete: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var dragging = false

    var body: some View {
        ZStack {
            HStack {
                if offset > 0 { actionButton(primary: actionOnRightSwipe) }
                Spacer(minLength: 0)
                if offset < 0 { actionButton(primary: !actionOnRightSwipe) }
            }
            content().offset(x: offset)
        }
        .clipped()
        .simultaneousGesture(DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                dragging = true
                offset = min(100, max(-100, value.translation.width))
            }
            .onEnded { _ in
                guard dragging else { return }
                withAnimation(.snappy) { offset = abs(offset) > 45 ? (offset > 0 ? 92 : -92) : 0 }
                dragging = false
            })
    }

    private func actionButton(primary: Bool) -> some View {
        Button {
            if primary { action() } else { delete() }
            withAnimation { offset = 0 }
        } label: {
            Text(LocalizedStringKey(primary ? actionTitle : "Delete"))
                .font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 88).frame(maxHeight: .infinity)
                .background(primary ? Color.blue : Color.red)
        }
        .buttonStyle(.plain)
        .disabled(primary ? !actionEnabled : !deleteEnabled)
    }
}

struct LinkedLedgerRow: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    let transaction: LedgerTransaction
    var showsDate = false
    @State private var expanded = false
    @State private var editing: LedgerTransaction?
    @State private var setupMode: TransactionGroupMode?
    @State private var settling = false
    @State private var reimbursement: LedgerTransaction?

    private var parent: LedgerTransaction { store.state.transactions.first { $0.id == transaction.id } ?? transaction }
    private var children: [LedgerTransaction] { TransactionSemantics.children(of: parent, in: store.state) }
    private var title: String { parent.groupMode == .split ? "Settle" : parent.groupMode == .reimbursement ? "Reimburse" : "Refund" }
    private var actionEnabled: Bool {
        if parent.groupMode == .split { return !TransactionSemantics.outstandingSlots(parent, in: store.state).isEmpty }
        if parent.groupMode == .reimbursement { return TransactionSemantics.remainingReimbursement(parent, in: store.state) > 0 }
        return parent.groupMode == nil && parent.parentTransactionID == nil && !parent.isLockedByReversal
    }
    private var leading: Bool {
        if parent.groupMode == .split { return preferences.value.splitActionOnRightSwipe }
        if parent.groupMode == .reimbursement { return preferences.value.reimbursementActionOnRightSwipe }
        return preferences.value.swipeActionOrientation == .refundLeadingDeleteTrailing
    }

    var body: some View {
        VStack(spacing: 0) {
            TransactionSwipeReveal(actionTitle: title, actionOnRightSwipe: leading, actionEnabled: actionEnabled,
                deleteEnabled: parent.linkedTransactionKind != .installment, action: performAction,
                delete: { store.deleteTransaction(parent) }) {
                Button {
                    if parent.groupMode != nil { withAnimation(.snappy) { expanded.toggle() } }
                    else if !parent.isLockedByReversal { editing = parent }
                } label: {
                    TransactionRow(transaction: parent, category: category(parent), showsDate: showsDate,
                        attention: TransactionSemantics.attention(parent, in: store.state))
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.plain)
                .contextMenu { configurationMenu }
            }
            if expanded {
                if parent.groupMode != .installment {
                    TransactionRow(transaction: parent, category: category(parent), showsDate: true)
                        .padding(.leading, 30).padding(.trailing, 14)
                }
                ForEach(children) { child in
                    Divider().padding(.leading, 52)
                    VStack(alignment: .leading, spacing: 0) {
                        if child.linkedTransactionKind == .installment {
                            Text("\(child.linkedTransactionIndex ?? 1) / \(parent.installmentMetadata?.count ?? children.count)")
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 44)
                        }
                        AnyView(LinkedLedgerRow(transaction: child, showsDate: true)).padding(.leading, 22)
                    }
                }
            }
        }
        .sheet(item: $editing) { TransactionEditorView(transaction: $0) }
        .sheet(item: $reimbursement) { TransactionEditorView(transaction: $0, isLinkedDraft: true) }
        .sheet(isPresented: $settling) { SplitSettlementSheet(parent: parent) }
        .sheet(isPresented: Binding(get: { setupMode != nil }, set: { if !$0 { setupMode = nil } })) {
            if let setupMode { LinkedSetupSheet(parent: parent, mode: setupMode) }
        }
    }

    private func category(_ transaction: LedgerTransaction) -> LedgerCategory {
        store.state.categories.first { $0.id == transaction.categoryID } ?? SeedData.expenseCategories[0]
    }

    private func performAction() {
        if parent.groupMode == .split { settling = true }
        else if parent.groupMode == .reimbursement { reimbursement = store.reimbursementDraft(for: parent) }
        else { store.refundTransaction(parent) }
    }

    @ViewBuilder private var configurationMenu: some View {
        if TransactionSemantics.eligible(parent) {
            Button("Split Expense") { setupMode = .split }
            Button("Mark for Reimbursement") { _ = store.configureLinked(parent.id, mode: .reimbursement) }
            if store.state.accounts.first(where: { $0.id == parent.accountID })?.type == .credit {
                Button("Set Installments") { setupMode = .installment }
            }
        } else if let mode = parent.groupMode {
            Button(mode == .split ? "Edit Split" : mode == .reimbursement ? "Edit Reimbursement" : "Edit Installment Plan") { setupMode = mode }
        }
        if actionEnabled { Button(LocalizedStringKey(title), action: performAction) }
        if parent.linkedTransactionKind != .installment { Button("Delete", role: .destructive) { store.deleteTransaction(parent) } }
    }
}

struct LedgerEntryRow: View {
    @EnvironmentObject private var store: LedgerStore
    let entry: LedgerPresentationEntry
    var showsDate = false
    @State private var expanded = false

    var body: some View {
        switch entry {
        case .transaction(let item), .linkedGroup(let item, _):
            LinkedLedgerRow(transaction: item, showsDate: showsDate)
        case .purchase(let session, let children, _):
            VStack(spacing: 0) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "cart.fill").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                            .background(.primary.opacity(0.08), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.name).font(.body.weight(.semibold)).lineLimit(1)
                            Text("\(children.count) items · Purchase").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        SensitiveMoneyText(amount: PurchaseLedgerPresentation.displayedTotal(children, session: session, rates: store.state.settings.rates), currency: session.currency, maxIntegerDigits: 4)
                            .font(.subheadline.monospacedDigit().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(children.contains { TransactionSemantics.attention($0, in: store.state) != nil } ? Color.red.opacity(0.06) : Color.clear)
                }.buttonStyle(.plain)
                if expanded {
                    ForEach(children) { child in
                        Divider().padding(.leading, 67)
                        LinkedLedgerRow(transaction: child, showsDate: showsDate).padding(.leading, 22)
                    }
                }
            }
        }
    }
}
