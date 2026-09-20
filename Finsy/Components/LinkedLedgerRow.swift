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
    var action: () -> Bool
    var enabled: Bool = true
}

/// Dynamic multi-action swipe reveal following finger drag with Apple Notes-style elastic reveal and Liquid Glass actions.
struct TransactionMultiSwipeReveal<Content: View>: View {
    @Environment(\.revealedTransactionID) private var revealedTransactionID
    let transactionID: UUID
    let leftActions: [SwipeActionItem]   // Physical slots [1, 2]: [outer, inner]
    let rightActions: [SwipeActionItem]  // Physical slots [3, 4]: [inner, outer]
    let onContentTap: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isLockedHorizontal = false
    @State private var isLockedVertical = false
    @State private var lastSwipeEndTime: Date = .distantPast

    private let standardWidth: CGFloat = 72
    private let cellGap: CGFloat = 5

    private var leftRestingWidth: CGFloat {
        let count = CGFloat(leftActions.count)
        guard count > 0 else { return 0 }
        return count * standardWidth + max(0, count - 1) * cellGap
    }

    private var rightRestingWidth: CGFloat {
        let count = CGFloat(rightActions.count)
        guard count > 0 else { return 0 }
        return count * standardWidth + max(0, count - 1) * cellGap
    }

    private var leftSnapThreshold: CGFloat { leftRestingWidth * 0.45 }
    private var rightSnapThreshold: CGFloat { rightRestingWidth * 0.45 }

    private func rubberBand(extra: CGFloat) -> CGFloat {
        guard extra > 0 else { return 0 }
        return (1.0 - (1.0 / ((extra * 0.55 / 100.0) + 1.0))) * 45.0
    }

    private func leftActionWidth(index: Int, totalDrag: CGFloat) -> CGFloat {
        let count = leftActions.count
        guard count > 0, totalDrag > 0 else { return 0 }
        if count == 1 {
            if totalDrag <= standardWidth {
                return totalDrag
            } else {
                return standardWidth + rubberBand(extra: totalDrag - standardWidth)
            }
        }
        // count == 2:
        // Physical layout in HStack: [Slot 1 (outer, index 0), Slot 2 (inner, index 1)]
        // Slot 2 is near transaction and grows first (2 → 1 reveal)
        if index == 1 {
            return min(totalDrag, standardWidth)
        } else {
            let threshold = standardWidth + cellGap
            if totalDrag <= threshold {
                return 0
            } else if totalDrag <= threshold + standardWidth {
                return totalDrag - threshold
            } else {
                return standardWidth + rubberBand(extra: totalDrag - (threshold + standardWidth))
            }
        }
    }

    private func rightActionWidth(index: Int, totalDrag: CGFloat) -> CGFloat {
        let count = rightActions.count
        guard count > 0, totalDrag > 0 else { return 0 }
        if count == 1 {
            if totalDrag <= standardWidth {
                return totalDrag
            } else {
                return standardWidth + rubberBand(extra: totalDrag - standardWidth)
            }
        }
        // count == 2:
        // Physical layout in HStack: [Slot 3 (inner, index 0), Slot 4 (outer, index 1)]
        // Slot 3 is near transaction and grows first (3 → 4 reveal)
        if index == 0 {
            return min(totalDrag, standardWidth)
        } else {
            let threshold = standardWidth + cellGap
            if totalDrag <= threshold {
                return 0
            } else if totalDrag <= threshold + standardWidth {
                return totalDrag - threshold
            } else {
                return standardWidth + rubberBand(extra: totalDrag - (threshold + standardWidth))
            }
        }
    }

    @ViewBuilder
    private var leftActionLane: some View {
        if !leftActions.isEmpty && offset > 0 {
            HStack(spacing: cellGap) {
                ForEach(leftActions.indices, id: \.self) { i in
                    let w = leftActionWidth(index: i, totalDrag: offset)
                    if w > 0.5 {
                        dynamicActionButton(item: leftActions[i], width: w)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(width: offset, alignment: .leading)
            .frame(maxHeight: .infinity)
            .clipped()
        }
    }

    @ViewBuilder
    private var rightActionLane: some View {
        if !rightActions.isEmpty && offset < 0 {
            HStack(spacing: cellGap) {
                ForEach(rightActions.indices, id: \.self) { i in
                    let w = rightActionWidth(index: i, totalDrag: -offset)
                    if w > 0.5 {
                        dynamicActionButton(item: rightActions[i], width: w)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(width: -offset, alignment: .trailing)
            .frame(maxHeight: .infinity)
            .clipped()
        }
    }

    private func dynamicActionButton(item: SwipeActionItem, width: CGFloat) -> some View {
        let dynamicRadius = min(18, max(6, width / 2))
        let shape = RoundedRectangle(cornerRadius: dynamicRadius, style: .continuous)
        let tintOpacity: Double = item.id == "delete" ? 0.32 : 0.22

        return Button {
            let success = item.action()
            if success {
                if revealedTransactionID.wrappedValue == transactionID {
                    revealedTransactionID.wrappedValue = nil
                }
                withAnimation(.snappy(duration: 0.20)) {
                    offset = 0
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .scaleEffect(iconScale(width: width))
                    .opacity(iconOpacity(width: width))

                if width >= 44 {
                    Text(LocalizedStringKey(item.title))
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .opacity(textOpacity(width: width))
                }
            }
            .foregroundStyle(.white)
            .frame(width: min(width, standardWidth))
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(
                item.color.opacity(tintOpacity)
                    .clipShape(shape)
            )
            .ledgerGlass(interactive: true, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
    }

    private func iconScale(width: CGFloat) -> CGFloat {
        if width < 25 { return 0.5 }
        if width < 50 { return 0.5 + 0.5 * ((width - 25) / 25) }
        return 1.0
    }

    private func iconOpacity(width: CGFloat) -> Double {
        if width < 15 { return 0 }
        if width < 40 { return Double((width - 15) / 25) }
        return 1.0
    }

    private func textOpacity(width: CGFloat) -> Double {
        if width < 44 { return 0 }
        if width < 64 { return Double((width - 44) / 20) }
        return 1.0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content()
                .offset(x: offset)
                .contentShape(Rectangle())
                .zIndex(1)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { handleDragChange($0) }
                        .onEnded { handleDragEnd($0) }
                )
                .onTapGesture {
                    handleContentTap()
                }

            if !leftActions.isEmpty && offset > 0 {
                leftActionLane
                    .frame(width: offset, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)
            }
        }
        .overlay(alignment: .trailing) {
            if !rightActions.isEmpty && offset < 0 {
                rightActionLane
                    .frame(width: -offset, alignment: .trailing)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)
            }
        }
        .clipped()
        .onChange(of: revealedTransactionID.wrappedValue) { _, newID in
            if newID != transactionID && offset != 0 && !isDragging {
                withAnimation(.snappy(duration: 0.20)) {
                    offset = 0
                }
            }
        }
        .onDisappear {
            if revealedTransactionID.wrappedValue == transactionID {
                revealedTransactionID.wrappedValue = nil
            }
            offset = 0
            isDragging = false
            isLockedHorizontal = false
            isLockedVertical = false
        }
    }

    private func handleDragChange(_ value: DragGesture.Value) {
        let dx = value.translation.width
        let dy = value.translation.height

        if !isLockedHorizontal && !isLockedVertical {
            // Check vertical movement first (or if user scrolls while row is open)
            if abs(dy) > abs(dx) * 1.5 || (abs(dy) >= 16 && abs(dy) > abs(dx)) {
                isLockedVertical = true
                if offset != 0 {
                    withAnimation(.snappy(duration: 0.18)) {
                        offset = 0
                        if revealedTransactionID.wrappedValue == transactionID {
                            revealedTransactionID.wrappedValue = nil
                        }
                    }
                }
                return
            }

            // Check if swipe direction has no actions
            if (dx > 0 && leftActions.isEmpty && offset <= 0) || (dx < 0 && rightActions.isEmpty && offset >= 0) {
                isLockedVertical = true
                return
            }

            // Check conclusive horizontal commitment
            if abs(dx) >= 20 && abs(dx) >= abs(dy) * 1.8 {
                isLockedHorizontal = true
                isDragging = true
                dragStartOffset = offset
                if let revealed = revealedTransactionID.wrappedValue, revealed != transactionID {
                    revealedTransactionID.wrappedValue = nil
                }
            } else {
                // Ambiguous or sub-threshold distance: do not modify offset or lock
                return
            }
        }

        if isLockedVertical {
            return
        }

        guard isLockedHorizontal else { return }
        isDragging = true

        let raw = dragStartOffset + dx
        var clamped = raw
        if clamped > 0 && leftActions.isEmpty {
            clamped = 0
        } else if clamped < 0 && rightActions.isEmpty {
            clamped = 0
        }

        let maxResting = clamped >= 0 ? leftRestingWidth : rightRestingWidth
        let magnitude = abs(clamped)
        let actualMagnitude: CGFloat
        if magnitude <= maxResting {
            actualMagnitude = magnitude
        } else {
            actualMagnitude = maxResting + rubberBand(extra: magnitude - maxResting)
        }

        // Direct assignment without withAnimation
        offset = clamped >= 0 ? actualMagnitude : -actualMagnitude
    }

    private func handleDragEnd(_ value: DragGesture.Value) {
        let wasLocked = isLockedHorizontal
        isDragging = false
        isLockedHorizontal = false
        isLockedVertical = false
        lastSwipeEndTime = Date()

        guard wasLocked else { return }

        let current = offset
        withAnimation(.snappy(duration: 0.20)) {
            if current >= leftSnapThreshold && !leftActions.isEmpty {
                offset = leftRestingWidth
                revealedTransactionID.wrappedValue = transactionID
            } else if current <= -rightSnapThreshold && !rightActions.isEmpty {
                offset = -rightRestingWidth
                revealedTransactionID.wrappedValue = transactionID
            } else {
                offset = 0
                if revealedTransactionID.wrappedValue == transactionID {
                    revealedTransactionID.wrappedValue = nil
                }
            }
        }
    }

    private func handleContentTap() {
        if isDragging || Date().timeIntervalSince(lastSwipeEndTime) < 0.20 {
            return
        }
        if offset != 0 {
            withAnimation(.snappy(duration: 0.20)) {
                offset = 0
                if revealedTransactionID.wrappedValue == transactionID {
                    revealedTransactionID.wrappedValue = nil
                }
            }
            return
        }
        if let revealed = revealedTransactionID.wrappedValue, revealed != transactionID {
            withAnimation(.snappy(duration: 0.20)) {
                revealedTransactionID.wrappedValue = nil
            }
            return
        }
        onContentTap()
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
    @State private var isDropTargeted = false

    private var parent: LedgerTransaction { store.index.transactionsByID[transaction.id] ?? transaction }
    private var children: [LedgerTransaction] { TransactionSemantics.children(of: parent, in: store.state, index: store.index) }
    private var isGroupParent: Bool { parent.groupMode != nil }

    private var groupStatus: GroupStatusPresentation? {
        TransactionSemantics.statusPresentation(for: parent, in: store.state, index: store.index)
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
                        action: {
                            guard store.refundInstallmentParent(parent) != nil else {
                                store.presentedError = "No refundable installment amount."
                                return false
                            }
                            revealedTransactionID.wrappedValue = nil
                            return true
                        }
                    )
                ]
            } else if parent.groupMode == .combinedPayment {
                if TransactionSemantics.combinedPaymentIsRefundable(parent, in: store.state, index: store.index) {
                    return [
                        SwipeActionItem(
                            id: "refund",
                            title: "Refund",
                            systemImage: "arrow.uturn.backward",
                            color: .blue,
                            action: {
                                guard store.refundCombinedPayment(parentID: parent.id) else {
                                    store.presentedError = "Failed to refund combined payment."
                                    return false
                                }
                                revealedTransactionID.wrappedValue = nil
                                return true
                            }
                        )
                    ]
                }
                return []
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
                            action: {
                                guard store.completeSettlement(parent.id) else {
                                    store.presentedError = "Failed to complete settlement."
                                    return false
                                }
                                revealedTransactionID.wrappedValue = nil
                                return true
                            }
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
                            action: {
                                guard store.payInstallmentEarly(parent.id) else {
                                    store.presentedError = "Failed to pay installment early."
                                    return false
                                }
                                revealedTransactionID.wrappedValue = nil
                                return true
                            }
                        )
                    ]
                }
                return []
            case .splitSelfExpense, .reimbursementOriginal, .reimbursementIncome, .refundOriginal, .refundIncome,
                 .combinedPaymentItem, .combinedPaymentRefund, .combinedPaymentRefundSupport:
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
                        action: {
                            guard store.refundPurchaseChild(parent) != nil else {
                                store.presentedError = "Failed to refund purchase item."
                                return false
                            }
                            revealedTransactionID.wrappedValue = nil
                            return true
                        }
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
                    action: {
                        guard store.refundTransaction(parent) != nil else {
                            store.presentedError = "Failed to refund transaction."
                            return false
                        }
                        revealedTransactionID.wrappedValue = nil
                        return true
                    }
                )
            ]
        }

        return []
    }

    private var rightSwipeActions: [SwipeActionItem] {
        if isGroupParent {
            // Split, Installment, Reimbursement, Refund, Combined Payment parent: left swipe Delete only
            return [
                SwipeActionItem(
                    id: "delete",
                    title: "Delete",
                    systemImage: "trash",
                    color: .red,
                    action: {
                        store.deleteTransaction(parent)
                        revealedTransactionID.wrappedValue = nil
                        return true
                    }
                )
            ]
        }

        // Group children never support Delete, except combined payment items
        if let kind = parent.linkedTransactionKind {
            if kind == .combinedPaymentItem {
                return [
                    SwipeActionItem(
                        id: "delete",
                        title: "Delete",
                        systemImage: "trash",
                        color: .red,
                        action: {
                            store.deleteTransaction(parent)
                            revealedTransactionID.wrappedValue = nil
                            return true
                        }
                    )
                ]
            }
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
                    action: {
                        store.deleteTransaction(parent)
                        revealedTransactionID.wrappedValue = nil
                        return true
                    }
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
                    action: {
                        store.deleteTransaction(parent)
                        revealedTransactionID.wrappedValue = nil
                        return true
                    }
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
        let distinctAccounts = Set(children.map(\.accountID)).count
        let subtitle = parent.groupMode == .combinedPayment
            ? "Combined Payment · \(distinctAccounts) accounts"
            : nil

        applyDragAndDrop(to:
            TransactionMultiSwipeReveal(
                transactionID: parent.id,
                leftActions: leftSwipeActions,
                rightActions: rightSwipeActions,
                onContentTap: {
                    withAnimation(.snappy) { expanded.toggle() }
                }
            ) {
                TransactionRow(
                    transaction: parent,
                    category: category(parent),
                    showsDate: showsDate,
                    groupStatus: groupStatus,
                    disclosure: expanded ? .expanded : .collapsed,
                    subtitleOverride: subtitle
                )
                .padding(.horizontal, 14)
                .contextMenu { configurationMenu }
            }
        )
    }

    @ViewBuilder
    private var swipeableRow: some View {
        applyDragAndDrop(to:
            TransactionMultiSwipeReveal(
                transactionID: parent.id,
                leftActions: leftSwipeActions,
                rightActions: rightSwipeActions,
                onContentTap: {
                    if !parent.isLockedByReversal { editing = parent }
                }
            ) {
                TransactionRow(
                    transaction: parent,
                    category: category(parent),
                    showsDate: showsDate,
                    groupStatus: nil,
                    disclosure: .standard
                )
                .padding(.horizontal, 14)
                .contextMenu { configurationMenu }
            }
        )
    }

    @ViewBuilder
    private var plainNonSwipeableRow: some View {
        applyDragAndDrop(to:
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
        )
    }

    private var isStandaloneExpenseDraggable: Bool {
        parent.type == .expense &&
        parent.deletedAt == nil &&
        parent.parentTransactionID == nil &&
        parent.groupMode == nil &&
        parent.purchaseSessionID == nil &&
        parent.reversalOfTransactionID == nil &&
        parent.reversalTransactionID == nil
    }

    private var isDetachableCombinedPaymentChild: Bool {
        guard parent.linkedTransactionKind == .combinedPaymentItem,
              let parentID = parent.parentTransactionID,
              parent.deletedAt == nil else { return false }
        guard let groupParent = store.index.transactionsByID[parentID], groupParent.deletedAt == nil else { return false }
        return !TransactionSemantics.combinedPaymentHasActiveRefund(groupParent, in: store.state, index: store.index)
    }

    private var isDraggable: Bool {
        isStandaloneExpenseDraggable || isDetachableCombinedPaymentChild
    }

    private func handleDrop(items: [String]) -> Bool {
        guard let firstStr = items.first, let draggedID = UUID(uuidString: firstStr), draggedID != parent.id else { return false }
        guard let dragged = store.index.transactionsByID[draggedID], dragged.deletedAt == nil else { return false }
        if isGroupParent && parent.groupMode == .combinedPayment {
            if dragged.parentTransactionID == parent.id { return false }
            let success = store.addTransactionToCombinedPayment(dragged, into: parent)
            if success {
                HapticFeedback.selection(enabled: preferences.value.hapticFeedbackEnabled)
            }
            return success
        } else if store.canCombine(dragged, parent) {
            let created = store.combineTransactions(first: parent, second: dragged)
            if created != nil {
                HapticFeedback.selection(enabled: preferences.value.hapticFeedbackEnabled)
                return true
            }
        }
        return false
    }

    @ViewBuilder
    private func applyDragAndDrop<Content: View>(to content: Content) -> some View {
        let highlighted = content
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.green.opacity(isDropTargeted ? 0.8 : 0), lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.green.opacity(isDropTargeted ? 0.12 : 0))
                    )
            )

        if isDraggable {
            highlighted
                .draggable(parent.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items: items)
                } isTargeted: { targeted in
                    withAnimation(.snappy(duration: 0.2)) { isDropTargeted = targeted }
                }
        } else if isGroupParent && parent.groupMode == .combinedPayment {
            highlighted
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items: items)
                } isTargeted: { targeted in
                    withAnimation(.snappy(duration: 0.2)) { isDropTargeted = targeted }
                }
        } else {
            content
        }
    }

    private func category(_ transaction: LedgerTransaction) -> LedgerCategory {
        store.index.categoriesByID[transaction.categoryID] ?? SeedData.expenseCategories[0]
    }

    private func swipeActionItem(for action: TransactionSwipeAction) -> SwipeActionItem {
        switch action {
        case .reimburse:
            return SwipeActionItem(
                id: "reimburse",
                title: "Reimburse",
                systemImage: "arrow.uturn.backward.circle",
                color: .purple,
                action: {
                    guard store.configureReimbursement(parentID: parent.id) else {
                        store.presentedError = "Failed to configure reimbursement."
                        return false
                    }
                    revealedTransactionID.wrappedValue = nil
                    return true
                }
            )
        case .refund:
            return SwipeActionItem(
                id: "refund",
                title: "Refund",
                systemImage: "arrow.uturn.backward",
                color: .blue,
                action: {
                    guard store.convertExpenseToRefundGroup(parent) else {
                        store.presentedError = "Failed to create refund group."
                        return false
                    }
                    revealedTransactionID.wrappedValue = nil
                    return true
                }
            )
        case .delete:
            return SwipeActionItem(
                id: "delete",
                title: "Delete",
                systemImage: "trash",
                color: .red,
                action: {
                    store.deleteTransaction(parent)
                    revealedTransactionID.wrappedValue = nil
                    return true
                }
            )
        case .split:
            return SwipeActionItem(
                id: "split",
                title: "Split",
                systemImage: "person.2",
                color: .teal,
                action: {
                    setupMode = .split
                    revealedTransactionID.wrappedValue = nil
                    return true
                }
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
            if TransactionSemantics.isEligibleForInstallment(parent, in: store.state, index: store.index) {
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
            } else if mode == .combinedPayment {
                if !TransactionSemantics.combinedPaymentHasActiveRefund(parent, in: store.state, index: store.index) {
                    Button {
                        store.ungroupCombinedPayment(parent)
                    } label: {
                        Label("Ungroup Combined Payment", systemImage: "rectangle.split.2x1.slash")
                    }
                }
            }
            if mode != .combinedPayment {
                Button {
                    editing = parent
                } label: {
                    Label("Edit Transaction", systemImage: "square.and.pencil")
                }
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
            Button {
                editing = parent
            } label: {
                Label("Edit Transaction", systemImage: "square.and.pencil")
            }
            if parent.linkedTransactionKind == .combinedPaymentItem {
                Button(role: .destructive) {
                    store.deleteTransaction(parent)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
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
                    if revealedTransactionID.wrappedValue != nil {
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
