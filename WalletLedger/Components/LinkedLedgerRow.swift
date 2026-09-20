import SwiftUI

private struct RevealedTransactionIDKey: EnvironmentKey {
    static let defaultValue: Binding<UUID?> = .constant(nil)
}

extension EnvironmentValues {
    var revealedTransactionID: Binding<UUID?> {
        get { self[RevealedTransactionIDKey.self] }
        set { self[RevealedTransactionIDKey.self] = newValue }
    }
}

struct SwipeActionItem: Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var color: Color
    var action: () -> Void
    var enabled: Bool = true
}

/// Progressive multi-action swipe reveal following finger drag, snapping open or closed.
struct TransactionMultiSwipeReveal<Content: View>: View {
    @Environment(\.revealedTransactionID) private var revealedTransactionID
    let transactionID: UUID
    let leftActions: [SwipeActionItem]   // Revealed when swiping right
    let rightActions: [SwipeActionItem]  // Revealed when swiping left
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isLockedHorizontal = false
    @State private var isLockedVertical = false

    private let buttonWidth: CGFloat = 74
    private let buttonSpacing: CGFloat = 6
    private let sidePadding: CGFloat = 6

    private var leftTotalWidth: CGFloat {
        guard !leftActions.isEmpty else { return 0 }
        return CGFloat(leftActions.count) * buttonWidth + CGFloat(leftActions.count - 1) * buttonSpacing + sidePadding * 2
    }

    private var rightTotalWidth: CGFloat {
        guard !rightActions.isEmpty else { return 0 }
        return CGFloat(rightActions.count) * buttonWidth + CGFloat(rightActions.count - 1) * buttonSpacing + sidePadding * 2
    }

    private var leftReleaseThreshold: CGFloat { leftTotalWidth * 0.55 }
    private var rightReleaseThreshold: CGFloat { rightTotalWidth * 0.55 }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if !leftActions.isEmpty {
                    ZStack(alignment: .leading) {
                        Color.clear
                        HStack(spacing: buttonSpacing) {
                            ForEach(leftActions) { item in
                                actionButton(item)
                            }
                        }
                        .padding(.horizontal, sidePadding)
                        .frame(width: leftTotalWidth, alignment: .leading)
                    }
                    .frame(width: max(0, offset), alignment: .leading)
                    .clipped()
                }

                Spacer(minLength: 0)

                if !rightActions.isEmpty {
                    ZStack(alignment: .trailing) {
                        Color.clear
                        HStack(spacing: buttonSpacing) {
                            ForEach(rightActions) { item in
                                actionButton(item)
                            }
                        }
                        .padding(.horizontal, sidePadding)
                        .frame(width: rightTotalWidth, alignment: .trailing)
                    }
                    .frame(width: max(0, -offset), alignment: .trailing)
                    .clipped()
                }
            }

            content()
                .offset(x: offset)
                .contentShape(Rectangle())
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if !isLockedHorizontal && !isLockedVertical {
                        if abs(dx) >= abs(dy) * 1.5 {
                            isLockedHorizontal = true
                            dragStartOffset = offset
                            if let revealed = revealedTransactionID.wrappedValue, revealed != transactionID {
                                revealedTransactionID.wrappedValue = nil
                            }
                        } else {
                            isLockedVertical = true
                            if offset != 0 {
                                withAnimation(.snappy) {
                                    offset = 0
                                    if revealedTransactionID.wrappedValue == transactionID {
                                        revealedTransactionID.wrappedValue = nil
                                    }
                                }
                            }
                            return
                        }
                    }
                    guard isLockedHorizontal else { return }
                    isDragging = true

                    let raw = dragStartOffset + dx
                    var clampedRaw = raw
                    if clampedRaw > 0 && leftActions.isEmpty {
                        clampedRaw = 0
                    } else if clampedRaw < 0 && rightActions.isEmpty {
                        clampedRaw = 0
                    }

                    let maxAllowed = clampedRaw >= 0 ? leftTotalWidth : rightTotalWidth
                    let magnitude = abs(clampedRaw)
                    let rubberBanded: CGFloat
                    if magnitude <= maxAllowed {
                        rubberBanded = magnitude
                    } else {
                        let extra = magnitude - maxAllowed
                        rubberBanded = maxAllowed + extra * 0.20
                    }
                    offset = clampedRaw >= 0 ? rubberBanded : -rubberBanded
                }
                .onEnded { _ in
                    guard isLockedHorizontal else {
                        isLockedHorizontal = false
                        isLockedVertical = false
                        isDragging = false
                        return
                    }
                    isDragging = false
                    isLockedHorizontal = false
                    isLockedVertical = false

                    let current = offset
                    withAnimation(.snappy) {
                        if current >= leftReleaseThreshold && !leftActions.isEmpty {
                            offset = leftTotalWidth
                            revealedTransactionID.wrappedValue = transactionID
                        } else if current <= -rightReleaseThreshold && !rightActions.isEmpty {
                            offset = -rightTotalWidth
                            revealedTransactionID.wrappedValue = transactionID
                        } else {
                            offset = 0
                            if revealedTransactionID.wrappedValue == transactionID {
                                revealedTransactionID.wrappedValue = nil
                            }
                        }
                    }
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                if offset != 0 {
                    withAnimation(.snappy) {
                        offset = 0
                        if revealedTransactionID.wrappedValue == transactionID {
                            revealedTransactionID.wrappedValue = nil
                        }
                    }
                }
            }
        )
        .onChange(of: revealedTransactionID.wrappedValue) { _, newID in
            if newID != transactionID && offset != 0 && !isDragging {
                withAnimation(.snappy) {
                    offset = 0
                }
            }
        }
    }

    private func actionButton(_ item: SwipeActionItem) -> some View {
        Button {
            item.action()
            withAnimation(.snappy) {
                offset = 0
                if revealedTransactionID.wrappedValue == transactionID {
                    revealedTransactionID.wrappedValue = nil
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(item.title))
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(width: buttonWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(item.color)
            )
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
    }
}

struct LinkedLedgerRow: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var preferences: AppPreferencesStore
    @Environment(\.revealedTransactionID) private var revealedTransactionID
    let transaction: LedgerTransaction
    var showsDate = false
    @State private var expanded = false
    @State private var editing: LedgerTransaction?
    @State private var setupMode: TransactionGroupMode?

    private var parent: LedgerTransaction { store.state.transactions.first { $0.id == transaction.id } ?? transaction }
    private var children: [LedgerTransaction] { TransactionSemantics.children(of: parent, in: store.state) }
    private var isGroupParent: Bool { parent.groupMode != nil }

    private var groupStatus: GroupStatusPresentation? {
        TransactionSemantics.statusPresentation(for: parent, in: store.state)
    }

    private var leftSwipeActions: [SwipeActionItem] {
        if isGroupParent {
            if parent.groupMode == .installment {
                // Installment parent right swipe: Refund
                return [
                    SwipeActionItem(
                        id: "refund",
                        title: "Refund",
                        systemImage: "arrow.uturn.backward",
                        color: .blue,
                        action: { _ = store.refundInstallmentParent(parent) }
                    )
                ]
            }
            // Split, Reimbursement, Refund parent: left swipe only (no right swipe actions)
            return []
        }

        // Group children
        if let kind = parent.linkedTransactionKind {
            switch kind {
            case .splitSettlement:
                if parent.linkedStatus == .pending {
                    return [
                        SwipeActionItem(
                            id: "complete",
                            title: "Complete",
                            systemImage: "checkmark.circle",
                            color: .green,
                            action: { _ = store.completeSettlement(parent.id) }
                        )
                    ]
                }
                return []
            case .installment:
                if !parent.isEffectivelyCompleted {
                    return [
                        SwipeActionItem(
                            id: "payEarly",
                            title: "Pay Early",
                            systemImage: "checkmark.circle",
                            color: .green,
                            action: { _ = store.payInstallmentEarly(parent.id) }
                        )
                    ]
                }
                return []
            case .splitSelfExpense, .reimbursementOriginal, .reimbursementIncome, .refundOriginal, .refundIncome:
                return []
            }
        }

        // Purchase child
        if parent.purchaseSessionID != nil {
            if !parent.isRefunded {
                return [
                    SwipeActionItem(
                        id: "refund",
                        title: "Refund",
                        systemImage: "arrow.uturn.backward",
                        color: .blue,
                        action: { _ = store.refundPurchaseChild(parent) }
                    )
                ]
            }
            return []
        }

        // Normal Standalone Transactions
        if parent.type == .expense && TransactionSemantics.eligible(parent) {
            let actions = preferences.value.transactionSwipeActions
            let slot0 = actions.indices.contains(0) ? actions[0] : .reimburse
            let slot1 = actions.indices.contains(1) ? actions[1] : .refund
            return [swipeActionItem(for: slot0), swipeActionItem(for: slot1)]
        } else if parent.type == .income && !parent.isLockedByReversal {
            return [
                SwipeActionItem(
                    id: "refund",
                    title: "Refund",
                    systemImage: "arrow.uturn.backward",
                    color: .blue,
                    action: { _ = store.refundTransaction(parent) }
                )
            ]
        }

        return []
    }

    private var rightSwipeActions: [SwipeActionItem] {
        if isGroupParent {
            // Split, Installment, Reimbursement, Refund parent: left swipe Delete only
            return [
                SwipeActionItem(
                    id: "delete",
                    title: "Delete",
                    systemImage: "trash",
                    color: .red,
                    action: { store.deleteTransaction(parent) }
                )
            ]
        }

        // Group children never support Delete
        if parent.linkedTransactionKind != nil {
            return []
        }

        // Purchase child: supports Delete
        if parent.purchaseSessionID != nil {
            return [
                SwipeActionItem(
                    id: "delete",
                    title: "Delete",
                    systemImage: "trash",
                    color: .red,
                    action: { store.deleteTransaction(parent) }
                )
            ]
        }

        // Normal Standalone Transactions
        if parent.type == .expense && TransactionSemantics.eligible(parent) {
            let actions = preferences.value.transactionSwipeActions
            let slot2 = actions.indices.contains(2) ? actions[2] : .delete
            let slot3 = actions.indices.contains(3) ? actions[3] : .split
            return [swipeActionItem(for: slot2), swipeActionItem(for: slot3)]
        } else {
            return [
                SwipeActionItem(
                    id: "delete",
                    title: "Delete",
                    systemImage: "trash",
                    color: .red,
                    action: { store.deleteTransaction(parent) }
                )
            ]
        }
    }

    private var swipeAllowed: Bool {
        !leftSwipeActions.isEmpty || !rightSwipeActions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if isGroupParent {
                groupParentRow
            } else if swipeAllowed {
                swipeableRow
            } else {
                plainNonSwipeableRow
            }
            if expanded {
                ForEach(children) { child in
                    Divider().padding(.leading, 52)
                    VStack(alignment: .leading, spacing: 0) {
                        if child.linkedTransactionKind == .installment {
                            Text("\(child.linkedTransactionIndex ?? 1) / \(parent.installmentMetadata?.count ?? children.count)")
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 44)
                        }
                        LinkedLedgerRow(transaction: child, showsDate: true).padding(.leading, 22)
                    }
                }
            }
        }
        .sheet(item: $editing) { TransactionEditorView(transaction: $0) }
        .sheet(isPresented: Binding(get: { setupMode != nil }, set: { if !$0 { setupMode = nil } })) {
            if let setupMode { LinkedSetupSheet(parent: parent, mode: setupMode) }
        }
    }

    @ViewBuilder
    private var groupParentRow: some View {
        TransactionMultiSwipeReveal(
            transactionID: parent.id,
            leftActions: leftSwipeActions,
            rightActions: rightSwipeActions
        ) {
            Button {
                if let revealed = revealedTransactionID.wrappedValue, revealed != parent.id {
                    withAnimation(.snappy) { revealedTransactionID.wrappedValue = nil }
                    return
                }
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                TransactionRow(
                    transaction: parent,
                    category: category(parent),
                    showsDate: showsDate,
                    groupStatus: groupStatus,
                    disclosure: expanded ? .expanded : .collapsed
                )
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .contextMenu { configurationMenu }
        }
    }

    @ViewBuilder
    private var swipeableRow: some View {
        TransactionMultiSwipeReveal(
            transactionID: parent.id,
            leftActions: leftSwipeActions,
            rightActions: rightSwipeActions
        ) {
            Button {
                if let revealed = revealedTransactionID.wrappedValue, revealed != parent.id {
                    withAnimation(.snappy) { revealedTransactionID.wrappedValue = nil }
                    return
                }
                if !parent.isLockedByReversal { editing = parent }
            } label: {
                TransactionRow(
                    transaction: parent,
                    category: category(parent),
                    showsDate: showsDate,
                    groupStatus: nil,
                    disclosure: .standard
                )
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .contextMenu { configurationMenu }
        }
    }

    @ViewBuilder
    private var plainNonSwipeableRow: some View {
        Button {
            if let revealed = revealedTransactionID.wrappedValue, revealed != parent.id {
                withAnimation(.snappy) { revealedTransactionID.wrappedValue = nil }
                return
            }
            if !parent.isLockedByReversal { editing = parent }
        } label: {
            TransactionRow(
                transaction: parent,
                category: category(parent),
                showsDate: showsDate,
                groupStatus: nil,
                disclosure: .standard
            )
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
        .contextMenu { configurationMenu }
    }

    private func category(_ transaction: LedgerTransaction) -> LedgerCategory {
        store.state.categories.first { $0.id == transaction.categoryID } ?? SeedData.expenseCategories[0]
    }

    private func swipeActionItem(for action: TransactionSwipeAction) -> SwipeActionItem {
        switch action {
        case .reimburse:
            return SwipeActionItem(
                id: "reimburse",
                title: "Reimburse",
                systemImage: "arrow.uturn.backward.circle",
                color: .purple,
                action: { _ = store.configureReimbursement(parentID: parent.id) }
            )
        case .refund:
            return SwipeActionItem(
                id: "refund",
                title: "Refund",
                systemImage: "arrow.uturn.backward",
                color: .blue,
                action: { _ = store.convertExpenseToRefundGroup(parent) }
            )
        case .delete:
            return SwipeActionItem(
                id: "delete",
                title: "Delete",
                systemImage: "trash",
                color: .red,
                action: { store.deleteTransaction(parent) }
            )
        case .split:
            return SwipeActionItem(
                id: "split",
                title: "Split",
                systemImage: "person.2",
                color: .teal,
                action: { setupMode = .split }
            )
        }
    }

    @ViewBuilder private var configurationMenu: some View {
        if TransactionSemantics.eligible(parent) {
            Button {
                setupMode = .split
            } label: {
                Label("Split Expense", systemImage: "person.2")
            }
            Button {
                _ = store.configureReimbursement(parentID: parent.id)
            } label: {
                Label("Reimbursement", systemImage: "arrow.uturn.backward.circle")
            }
            if store.state.accounts.first(where: { $0.id == parent.accountID })?.type == .credit {
                Button {
                    setupMode = .installment
                } label: {
                    Label("Set Installments", systemImage: "calendar.badge.clock")
                }
            }
            Button {
                editing = parent
            } label: {
                Label("Edit Transaction", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                store.deleteTransaction(parent)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else if let mode = parent.groupMode {
            if mode == .split {
                Button {
                    setupMode = .split
                } label: {
                    Label("Edit Split", systemImage: "person.2")
                }
            } else if mode == .installment {
                Button {
                    setupMode = .installment
                } label: {
                    Label("Edit Installment Plan", systemImage: "calendar.badge.clock")
                }
            }
            Button {
                editing = parent
            } label: {
                Label("Edit Transaction", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                store.deleteTransaction(parent)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else if parent.purchaseSessionID != nil {
            if !parent.isRefunded {
                Button {
                    _ = store.refundPurchaseChild(parent)
                } label: {
                    Label("Refund", systemImage: "arrow.uturn.backward")
                }
            }
            Button(role: .destructive) {
                store.deleteTransaction(parent)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else if parent.linkedTransactionKind != nil {
            // Group children: Edit only, never Delete!
            Button {
                editing = parent
            } label: {
                Label("Edit Transaction", systemImage: "square.and.pencil")
            }
        } else {
            Button {
                editing = parent
            } label: {
                Label("Edit Transaction", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                store.deleteTransaction(parent)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct LedgerEntryRow: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.revealedTransactionID) private var revealedTransactionID
    let entry: LedgerPresentationEntry
    var showsDate = false
    @State private var expanded = false

    var body: some View {
        switch entry {
        case .transaction(let item), .linkedGroup(let item, _):
            LinkedLedgerRow(transaction: item, showsDate: showsDate)
        case .purchase(let session, let children, _):
            VStack(spacing: 0) {
                Button {
                    if let revealed = revealedTransactionID.wrappedValue {
                        withAnimation(.snappy) { revealedTransactionID.wrappedValue = nil }
                        return
                    }
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
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
                }
                .buttonStyle(.plain)
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
