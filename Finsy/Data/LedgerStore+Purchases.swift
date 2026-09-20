import Foundation

extension LedgerStore {
    /// Dismisses the inline bridge notice. The identical notice is not shown again for the
    /// current purchase, so it cannot reappear on the next item tap.
    func dismissPurchaseSyncWarning() {
        suppressedPurchaseSyncWarning = purchaseSyncWarning
        purchaseSyncWarning = nil
    }

    /// Records a nonfatal bridge notice.
    ///
    /// - Repeats of the same notice are dropped, so item taps never spam the Purchase screens.
    /// - A dismissed notice stays dismissed until the bridge state changes.
    /// - A successful bridge clears a stale notice and resets the dismissal, so a later
    ///   failure is reported again.
    func reportPurchaseSyncWarning(_ message: String?) {
        guard let message, !message.isEmpty else {
            if purchaseSyncWarning != nil { purchaseSyncWarning = nil }
            suppressedPurchaseSyncWarning = nil
            return
        }
        guard suppressedPurchaseSyncWarning != message else { return }
        if purchaseSyncWarning != message { purchaseSyncWarning = message }
    }

    /// Category identification colors attached to Live Activity item rows.
    var purchaseActivityCategoryColors: [String: String] {
        Dictionary(state.categories.map { ($0.id.rawValue, $0.colorHex) }, uniquingKeysWith: { first, _ in first })
    }

    var recurringRules: [RecurringRule] { (state.recurringRules ?? []).filter { $0.deletedAt == nil } }
    var purchaseSessions: [PurchaseSession] { (state.purchaseSessions ?? []).filter { $0.status != .cancelled }.sorted { $0.createdAt > $1.createdAt } }

    func savePurchaseSession(_ session: PurchaseSession) {
        var updated = session
        updated.ledgerBookID = activeBookID
        updated.updatedAt = .now
        updated.normalizeSections()
        mutateState(.purchaseOnly) { state in
            var sessions = state.purchaseSessions ?? []
            if let index = sessions.firstIndex(where: { $0.id == updated.id }) { sessions[index] = updated } else { sessions.append(updated) }
            state.purchaseSessions = sessions
        }
        scheduleSave()
    }

struct PurchasePersistenceFingerprint: Equatable, Sendable {
    let id: UUID
    let status: PurchaseSessionStatus
    let updatedAt: Date?
    let linkedTransactionIDs: Set<UUID>
}

extension LedgerStore {
    func persistenceFingerprint(for session: PurchaseSession) -> PurchasePersistenceFingerprint {
        PurchasePersistenceFingerprint(
            id: session.id,
            status: session.status,
            updatedAt: session.updatedAt,
            linkedTransactionIDs: Set(session.items.compactMap(\.linkedTransactionID))
        )
    }

    @discardableResult
    func startPurchaseSession(_ sessionID: UUID, activityStarter: any PurchaseActivityStarting = PurchaseLiveActivityController.shared) async throws -> PurchaseActivityOutcome {
        guard var session = purchaseSessions.first(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        guard session.status == .draft else { throw PurchaseFinalizationError.notReady }
        try PurchaseRules.validatePayment(session, in: state)
        try PurchaseRules.validateItems(session, in: state)
        // Local-first: the purchase becomes active and is durably persisted before any
        // App Group / ActivityKit work runs. Those steps can never fail the start.
        let previousSession = session
        session.status = .active
        session.startedAt = .now
        session.completedAt = nil
        for index in session.items.indices { session.items[index].isCompleted = false; session.items[index].completedAt = nil }
        session.updatedAt = .now
        savePurchaseSession(session)
        let expectedFingerprint = persistenceFingerprint(for: session)
        do {
            try await persistDurableAsync()
        } catch {
            mutateState(.purchaseOnly) { state in
                guard var sessions = state.purchaseSessions,
                      let i = sessions.firstIndex(where: { $0.id == sessionID })
                else { return }
                guard persistenceFingerprint(for: sessions[i]) == expectedFingerprint else { return }
                sessions[i] = previousSession
                state.purchaseSessions = sessions
            }
            commitActiveBook()
            scheduleSave()
            throw error
        }
        purchaseSyncWarning = nil
        suppressedPurchaseSyncWarning = nil
        guard let persistedSession = purchaseSessions.first(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        #if DEBUG
        PurchaseActivityDiagnostics.logStart(session: persistedSession)
        #endif
        return await publish(session: persistedSession, requestActivity: true, activityStarter: activityStarter)
    }

    /// Mirrors a committed session to the App Group bridge and the Live Activity.
    /// Never throws and never rolls back local state; bridge problems become warnings.
    @discardableResult
    func publish(session: PurchaseSession, requestActivity: Bool, activityStarter: any PurchaseActivityStarting = PurchaseLiveActivityController.shared) async -> PurchaseActivityOutcome {
        let outcome = await activityStarter.publish(session: session, categoryColors: purchaseActivityCategoryColors, requestActivityIfNeeded: requestActivity)
        reportPurchaseSyncWarning(outcome.warning)
        #if DEBUG
        PurchaseActivityDiagnostics.log(outcome: outcome, session: session)
        #endif
        return outcome
    }

    /// Bridges the current stored session (used after local mutations).
    @discardableResult
    func publishPurchase(sessionID: UUID, requestActivity: Bool? = nil, activityStarter: any PurchaseActivityStarting = PurchaseLiveActivityController.shared) async -> PurchaseActivityOutcome? {
        guard let session = purchaseSessions.first(where: { $0.id == sessionID }) else { return nil }
        return await publish(session: session, requestActivity: requestActivity ?? (session.status == .active), activityStarter: activityStarter)
    }

    func cancelPurchaseSession(_ session: PurchaseSession) {
        var cancelled = session
        cancelled.status = .cancelled
        cancelled.updatedAt = .now
        savePurchaseSession(cancelled)
        let cancelledID = cancelled.id
        Task { [weak self] in
            guard let self else { return }
            await PurchaseLiveActivityController.shared.end(sessionID: cancelledID)
            self.dismissPurchaseSyncWarning()
        }
    }

    /// Local-first item completion.
    ///
    /// The stored `PurchaseSession` is the source of truth: it is validated, mutated and
    /// persisted here, and the App Group / Live Activity bridge is updated afterwards by
    /// `publish(session:requestActivity:)`. A failing bridge can therefore never roll back
    /// the completion, return nil, change the session status or dismiss the screen.
    @discardableResult
    func setPurchaseItem(_ itemID: UUID, in sessionID: UUID, completed: Bool) -> PurchaseSession? {
        guard var session = purchaseSessions.first(where: { $0.id == sessionID }),
              session.status == .active || session.status == .awaitingSummary,
              let index = session.items.firstIndex(where: { $0.id == itemID }) else { return nil }
        session.items[index].isCompleted = completed
        session.items[index].completedAt = completed ? .now : nil
        // Only a fully completed list leaves the active state; non-final taps stay active.
        if session.items.allSatisfy(\.isCompleted) {
            session.status = .awaitingSummary
            session.completedAt = .now
        } else {
            session.status = .active
            session.completedAt = nil
        }
        session.updatedAt = .now
        savePurchaseSession(session)
        return purchaseSessions.first(where: { $0.id == sessionID }) ?? session
    }

    func finalizePurchaseSession(_ sessionID: UUID, receiptAttachmentID: String?) async throws {
        guard var sessions = state.purchaseSessions, let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        let session = sessions[sessionIndex]
        if session.status == .completed { return }
        guard session.status == .awaitingSummary, session.items.allSatisfy(\.isCompleted) else { throw PurchaseFinalizationError.notReady }
        try PurchaseRules.validatePayment(session, in: state)
        try PurchaseRules.validateItems(session, in: state)
        guard let accountID = session.accountID else { throw PurchaseFinalizationError.paymentAccountUnavailable }
        guard let paymentAccount = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }) else { throw PurchaseFinalizationError.paymentAccountUnavailable }
        // Post each child to the pocket that already holds the purchase currency, else the primary pocket.
        let purchasePocket = paymentAccount.defaultPocket(for: session.currency)

        // Pre-scan active transactions in the current book.
        let activeTransactions = state.transactions.filter { $0.deletedAt == nil && !$0.isReversal }
        let activeByID = Dictionary(activeTransactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existingSessionTransactions = activeTransactions.filter {
            $0.purchaseSessionID == sessionID && $0.purchaseItemID != nil
        }
        let existingByItemID = Dictionary(grouping: existingSessionTransactions, by: { $0.purchaseItemID! })

        let currentItemIDs = Set(session.items.map(\.id))

        guard existingSessionTransactions.allSatisfy({
            guard let itemID = $0.purchaseItemID else { return false }
            return currentItemIDs.contains(itemID)
        }) else {
            throw PurchaseFinalizationError.inconsistentPurchaseData
        }

        var newTransactions: [LedgerTransaction] = []
        var itemTransactionMappings: [(itemIndex: Int, transactionID: UUID)] = []

        for (itemIndex, item) in session.items.enumerated() {
            let matches = existingByItemID[item.id] ?? []

            if let linkedID = item.linkedTransactionID {
                guard matches.count == 1,
                      matches[0].id == linkedID,
                      let linked = activeByID[linkedID],
                      linked.purchaseSessionID == sessionID,
                      linked.purchaseItemID == item.id
                else {
                    throw PurchaseFinalizationError.inconsistentPurchaseData
                }

                itemTransactionMappings.append((itemIndex, linkedID))
            } else {
                switch matches.count {
                case 0:
                    let taxSnapshot = state.categories.first(where: { $0.id == item.categoryID }).flatMap {
                        TaxCalculations.resolve(entered: item.amount, type: .expense, rate: state.settings.taxRate(for: $0), mode: .finalAmount, exempt: false)
                    }
                    let transaction = try buildTransaction(
                        type: .expense,
                        accountID: accountID,
                        destinationAccountID: nil,
                        amount: item.amount,
                        currency: session.currency,
                        categoryID: item.categoryID,
                        occurredAt: item.completedAt ?? .now,
                        note: item.note,
                        purchaseSessionID: sessionID,
                        purchaseItemID: item.id,
                        accountCurrency: purchasePocket,
                        taxSnapshot: taxSnapshot,
                        in: state
                    )
                    newTransactions.append(transaction)
                    itemTransactionMappings.append((itemIndex, transaction.id))
                case 1:
                    let matchID = matches[0].id
                    itemTransactionMappings.append((itemIndex, matchID))
                default:
                    throw PurchaseFinalizationError.inconsistentPurchaseData
                }
            }
        }

        // Verify 1-to-1 uniqueness: every item must map to a distinct transaction ID
        let resolvedIDs = itemTransactionMappings.map(\.transactionID)
        guard Set(resolvedIDs).count == session.items.count else {
            throw PurchaseFinalizationError.inconsistentPurchaseData
        }

        let previousSession = session
        let createdTransactionIDs = Set(newTransactions.map(\.id))
        var finishedSession: PurchaseSession?
        mutateState(.financial) { state in
            if !newTransactions.isEmpty {
                state.transactions.append(contentsOf: newTransactions)
            }
            if var currentSessions = state.purchaseSessions, let idx = currentSessions.firstIndex(where: { $0.id == sessionID }) {
                for mapping in itemTransactionMappings {
                    currentSessions[idx].items[mapping.itemIndex].linkedTransactionID = mapping.transactionID
                }
                currentSessions[idx].receiptAttachmentID = receiptAttachmentID ?? currentSessions[idx].receiptAttachmentID
                currentSessions[idx].status = .completed
                currentSessions[idx].completedAt = currentSessions[idx].completedAt ?? .now
                currentSessions[idx].updatedAt = .now
                finishedSession = currentSessions[idx]
                state.purchaseSessions = currentSessions
            }
        }

        guard let finished = finishedSession else { return }
        let expectedFingerprint = persistenceFingerprint(for: finished)

        do {
            try await persistDurableAsync()
        } catch {
            mutateState(.financial) { state in
                state.transactions.removeAll { createdTransactionIDs.contains($0.id) }
                if var currentSessions = state.purchaseSessions, let idx = currentSessions.firstIndex(where: { $0.id == sessionID }) {
                    if persistenceFingerprint(for: currentSessions[idx]) == expectedFingerprint {
                        currentSessions[idx] = previousSession
                        state.purchaseSessions = currentSessions
                    }
                }
            }
            commitActiveBook()
            scheduleSave()
            throw error
        }

        if let finished = finishedSession {
            Task { [weak self] in
                guard let self else { return }
                await self.publish(session: finished, requestActivity: false)
            }
        }
    }

    /// Merges newer App Group snapshots (checked from the Lock Screen / Dynamic Island) into
    /// the local store. Only strictly newer snapshots win, and local state is persisted after
    /// a successful merge. Never touches `presentedError`: the bridge is a nonfatal channel.
    @discardableResult
    func reconcileSharedActivePurchases() -> Bool {
        // Explicit availability check: do not discover a missing container through item taps.
        guard PurchaseSharedStateStore.availability().isAvailable else { return false }
        guard var sessions = state.purchaseSessions else { return false }
        var changed = false
        for index in sessions.indices where sessions[index].status == .active || sessions[index].status == .awaitingSummary {
            let local = sessions[index]
            guard let snapshot = PurchaseSharedStateStore.newerSnapshot(for: local),
                  PurchaseRules.shouldAdoptSharedSnapshot(snapshot, over: local),
                  (try? PurchaseRules.validatePayment(snapshot.session, in: state)) != nil else { continue }
            sessions[index] = snapshot.session
            changed = true
        }
        guard changed else { return false }
        mutateState(.purchaseOnly) { state in
            state.purchaseSessions = sessions
        }
        scheduleSave()
        return true
    }


}
