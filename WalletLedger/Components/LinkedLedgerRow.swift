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

/// Works inside the existing ScrollView/LazyVStack; native List swipeActions are not required.
struct TransactionSwipeReveal<Content: View>: View {
    @Environment(\.revealedTransactionID) private var revealedTransactionID
    let transactionID: UUID
    let actionTitle: String
    let actionOnRightSwipe: Bool
    let actionEnabled: Bool
    let deleteEnabled: Bool
    let action: () -> Void
    let delete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isLockedHorizontal = false
    @State private var isLockedVertical = false

    private let revealWidth: CGFloat = 88
    private let releaseThreshold: CGFloat = 68

    private var leftActionAvailable: Bool {
        actionOnRightSwipe ? actionEnabled : deleteEnabled
    }

    private var rightActionAvailable: Bool {
        actionOnRightSwipe ? deleteEnabled : actionEnabled
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if leftActionAvailable {
                    ZStack(alignment: .leading) {
                        Color.clear
                        leftActionButton
                            .frame(width: revealWidth, alignment: .leading)
                    }
                    .frame(width: max(0, offset), alignment: .leading)
                    .clipped()
                }
                Spacer(minLength: 0)
                if rightActionAvailable {
                    ZStack(alignment: .trailing) {
                        Color.clear
                        rightActionButton
                            .frame(width: revealWidth, alignment: .trailing)
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
            DragGesture(minimumDistance: 32)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if !isLockedHorizontal && !isLockedVertical {
                        if abs(dx) >= abs(dy) * 1.8 {
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
                    if clampedRaw > 0 && !leftActionAvailable {
                        clampedRaw = 0
                    } else if clampedRaw < 0 && !rightActionAvailable {
                        clampedRaw = 0
                    }

                    let magnitude = abs(clampedRaw)
                    let rubberBanded: CGFloat
                    if magnitude <= revealWidth {
                        rubberBanded = magnitude
                    } else {
                        let extra = magnitude - revealWidth
                        rubberBanded = revealWidth + extra * 0.20
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
                        if current >= releaseThreshold && leftActionAvailable {
                            offset = revealWidth
                            revealedTransactionID.wrappedValue = transactionID
                        } else if current <= -releaseThreshold && rightActionAvailable {
                            offset = -revealWidth
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

    @ViewBuilder
    private var leftActionButton: some View {
        if actionOnRightSwipe {
            refundButton
        } else {
            deleteButton
        }
    }

    @ViewBuilder
    private var rightActionButton: some View {
        if actionOnRightSwipe {
            deleteButton
        } else {
            refundButton
        }
    }

    private var refundButton: some View {
        Button {
            action()
            withAnimation(.snappy) {
                offset = 0
                if revealedTransactionID.wrappedValue == transactionID {
                    revealedTransactionID.wrappedValue = nil
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(actionTitle))
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(width: 74)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.blue)
            )
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(!actionEnabled)
    }

    private var deleteButton: some View {
        Button {
            delete()
            withAnimation(.snappy) {
                offset = 0
                if revealedTransactionID.wrappedValue == transactionID {
                    revealedTransactionID.wrappedValue = nil
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey("Delete"))
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(width: 74)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.red)
            )
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(!deleteEnabled)
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
    @State private var settling = false
    @State private var reimbursement: LedgerTransaction?

    private var parent: LedgerTransaction { store.state.transactions.first { $0.id == transaction.id } ?? transaction }
    private var children: [LedgerTransaction] { TransactionSemantics.children(of: parent, in: store.state) }
    private var isGroupParent: Bool { parent.groupMode != nil }
    private var title: String { "Refund" }
    private var actionEnabled: Bool {
        guard parent.deletedAt == nil, !parent.isLockedByReversal, parent.groupMode == nil else { return false }
        if parent.linkedTransactionKind == .installment {
            return parent.occurredAt <= .now
        }
        return true
    }
    private var deleteEnabled: Bool {
        parent.linkedTransactionKind != .installment
    }
    private var swipeAllowed: Bool {
        !isGroupParent && (actionEnabled || deleteEnabled)
    }
    private var leading: Bool {
        preferences.value.swipeActionOrientation == .refundLeadingDeleteTrailing
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
                if parent.groupMode != .installment {
                    TransactionRow(transaction: parent, category: category(parent), showsDate: true, disclosure: .none)
                        .padding(.leading, 30).padding(.trailing, 14)
                }
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
        .sheet(item: $reimbursement) { TransactionEditorView(transaction: $0, isLinkedDraft: true) }
        .sheet(isPresented: $settling) { SplitSettlementSheet(parent: parent) }
        .sheet(isPresented: Binding(get: { setupMode != nil }, set: { if !$0 { setupMode = nil } })) {
            if let setupMode { LinkedSetupSheet(parent: parent, mode: setupMode) }
        }
    }

    @ViewBuilder
    private var groupParentRow: some View {
        let attention = TransactionSemantics.attention(parent, in: store.state)
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
                attention: attention,
                disclosure: expanded ? .expanded : .collapsed
            )
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
        .background {
            if attention != nil {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.red.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.24), lineWidth: 0.8)
                    )
                    .padding(.horizontal, 6)
            }
        }
        .contextMenu { configurationMenu }
    }

    @ViewBuilder
    private var swipeableRow: some View {
        TransactionSwipeReveal(
            transactionID: parent.id,
            actionTitle: title,
            actionOnRightSwipe: leading,
            actionEnabled: actionEnabled,
            deleteEnabled: deleteEnabled,
            action: performAction,
            delete: { store.deleteTransaction(parent) }
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
                    attention: nil,
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
                attention: nil,
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

    private func performAction() {
        if parent.groupMode == .split { settling = true }
        else if parent.groupMode == .reimbursement { reimbursement = store.reimbursementDraft(for: parent) }
        else { store.refundTransaction(parent) }
    }

    @ViewBuilder private var configurationMenu: some View {
        if TransactionSemantics.eligible(parent) {
            Button {
                setupMode = .split
            } label: {
                Label("Split Expense", systemImage: "person.2")
            }
            Button {
                _ = store.configureLinked(parent.id, mode: .reimbursement)
            } label: {
                Label("Mark for Reimbursement", systemImage: "arrow.uturn.backward.circle")
            }
            if store.state.accounts.first(where: { $0.id == parent.accountID })?.type == .credit {
                Button {
                    setupMode = .installment
                } label: {
                    Label("Set Installments", systemImage: "calendar.badge.clock")
                }
            }
        } else if let mode = parent.groupMode {
            if mode == .split {
                if !TransactionSemantics.outstandingSlots(parent, in: store.state).isEmpty {
                    Button {
                        performAction()
                    } label: {
                        Label("Settle", systemImage: "checkmark.circle")
                    }
                }
                Button {
                    setupMode = .split
                } label: {
                    Label("Edit Split", systemImage: "pencil")
                }
            } else if mode == .reimbursement {
                if TransactionSemantics.remainingReimbursement(parent, in: store.state) > 0 {
                    Button {
                        performAction()
                    } label: {
                        Label("Reimburse", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                Button {
                    setupMode = .reimbursement
                } label: {
                    Label("Edit Reimbursement", systemImage: "pencil")
                }
            } else {
                Button {
                    setupMode = mode
                } label: {
                    Label("Edit Installment Plan", systemImage: "pencil")
                }
            }
            if !parent.isLockedByReversal {
                Button {
                    editing = parent
                } label: {
                    Label("Edit Transaction", systemImage: "square.and.pencil")
                }
            }
        }
        if !isGroupParent && actionEnabled {
            Button {
                performAction()
            } label: {
                Label(title, systemImage: "arrow.uturn.backward")
            }
        }
        if parent.linkedTransactionKind != .installment {
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

