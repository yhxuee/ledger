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
        mutateState { state in
            var sessions = state.purchaseSessions ?? []
            if let index = sessions.firstIndex(where: { $0.id == updated.id }) { sessions[index] = updated } else { sessions.append(updated) }
            state.purchaseSessions = sessions
        }
        scheduleSave()
    }

    private func persistPurchaseChanges() throws {
        guard persistenceEnabled else { return }
        saveTask?.cancel()
        try Self.writeLibrary(librarySnapshot())
        scheduleSave()
    }

    @discardableResult
    func startPurchaseSession(_ sessionID: UUID, activityStarter: any PurchaseActivityStarting = PurchaseLiveActivityController.shared) async throws -> PurchaseActivityOutcome {
        guard var session = purchaseSessions.first(where: { $0.id == sessionID }) else { throw PurchaseFinalizationError.missingSession }
        guard session.status == .draft else { throw PurchaseFinalizationError.notReady }
        try PurchaseRules.validatePayment(session, in: state)
        try PurchaseRules.validateItems(session, in: state)
        // Local-first: the purchase becomes active and is durably persisted before any
        // App Group / ActivityKit work runs. Those steps can never fail the start.
        session.status = .active
        session.startedAt = .now
        session.completedAt = nil
        for index in session.items.indices { session.items[index].isCompleted = false; session.items[index].completedAt = nil }
        session.updatedAt = .now
        savePurchaseSession(session)
        try persistPurchaseChanges()
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

    func finalizePurchaseSession(_ sessionID: UUID, receiptAttachmentID: String?) throws {
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
        // Validate the entire purchase before adding any financial children.
        for itemIndex in sessions[sessionIndex].items.indices where sessions[sessionIndex].items[itemIndex].linkedTransactionID == nil {
            let item = sessions[sessionIndex].items[itemIndex]
            guard let transaction = addTransaction(type: .expense, accountID: accountID, destinationAccountID: nil, amount: item.amount, currency: session.currency, categoryID: item.categoryID, occurredAt: item.completedAt ?? .now, note: item.note, purchaseSessionID: sessionID, purchaseItemID: item.id, accountCurrency: purchasePocket, taxSnapshot: state.categories.first(where: { $0.id == item.categoryID }).flatMap { TaxCalculations.resolve(entered: item.amount, type: .expense, rate: state.settings.taxRate(for: $0), mode: .finalAmount, exempt: false) }) else { throw PurchaseFinalizationError.invalidItem }
            sessions[sessionIndex].items[itemIndex].linkedTransactionID = transaction.id
        }
        sessions[sessionIndex].receiptAttachmentID = receiptAttachmentID ?? session.receiptAttachmentID
        sessions[sessionIndex].status = .completed
        sessions[sessionIndex].completedAt = .now
        sessions[sessionIndex].updatedAt = .now
        let finished = sessions[sessionIndex]
        mutateState { state in
            state.purchaseSessions = sessions
        }
        try persistPurchaseChanges()
        Task { [weak self] in
            guard let self else { return }
            await self.publish(session: finished, requestActivity: false)
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
        mutateState { state in
            state.purchaseSessions = sessions
        }
        do { try persistPurchaseChanges() }
        catch { presentedError = "Purchase sync failed: \(error.localizedDescription)" }
        return true
    }


}
