import XCTest
@testable import Finsy

@MainActor
final class PurchasePersistenceRaceTests: XCTestCase {
    struct SimulatedPersistenceError: Error, Equatable {}

    func testRollbackPreservesUnrelatedMutationsDuringPersistence() async throws {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else {
            XCTFail("Missing test account")
            return
        }

        // Create and start a purchase session
        let sessionID = UUID()
        let itemID = UUID()
        let item = PurchaseItem(id: itemID, categoryID: .shopping, note: "Headphones", amount: 150.0, displayOrder: 0, isCompleted: true)
        let session = PurchaseSession(
            id: sessionID,
            ledgerBookID: store.activeBookID,
            name: "Audio Store",
            status: .awaitingSummary,
            sections: [],
            items: [item],
            createdAt: .now,
            startedAt: .now,
            completedAt: .now,
            currency: account.currency,
            accountID: account.id
        )
        store.mutateState { $0.purchaseSessions = [session] }

        // Gate continuation for deterministic async race testing (no Task.sleep)
        final class SuspensionGate: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Error>?
        }
        let gate = SuspensionGate()
        let (stream1, streamContinuation1) = AsyncStream<Void>.makeStream()

        store.persistenceTestHook = {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                gate.continuation = cont
                streamContinuation1.yield()
            }
        }
        defer { store.persistenceTestHook = nil }

        // Unrelated transaction to be added while finalization is suspended
        let unrelatedTx = LedgerTransaction(
            id: UUID(),
            userID: store.state.settings.userID,
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 25.0,
            currency: account.currency,
            accountAmount: 25.0,
            destinationAmount: nil,
            categoryID: .food,
            occurredAt: .now,
            note: "Mid-flight coffee",
            exchangeRateAtTransaction: 1.0,
            createdAt: .now,
            updatedAt: .now,
            version: 1,
            syncStatus: .pending
        )

        let finalizeTask = Task { @MainActor in
            defer { streamContinuation1.finish() }
            try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        }

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            streamContinuation1.finish()
        }
        defer { watchdog.cancel() }

        var it = stream1.makeAsyncIterator()
        let hookReached = await it.next() != nil
        XCTAssertTrue(hookReached, "Persistence hook must be reached")
        guard hookReached, let cont = gate.continuation else {
            _ = try? await finalizeTask.value
            return
        }

        // While suspended, perform an unrelated mutation on the ledger
        store.mutateState { $0.transactions.append(unrelatedTx) }
        XCTAssertTrue(store.state.transactions.contains(where: { $0.id == unrelatedTx.id }))

        // Now resume the hook with error to trigger rollback
        cont.resume(throwing: SimulatedPersistenceError())

        do {
            try await finalizeTask.value
            XCTFail("Finalize should fail due to persistence error")
        } catch is SimulatedPersistenceError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Rollback must have removed purchase transaction, but kept unrelated transaction!
        XCTAssertTrue(store.state.transactions.contains(where: { $0.id == unrelatedTx.id }), "Unrelated transaction must survive rollback")
        XCTAssertFalse(store.state.transactions.contains(where: { $0.purchaseSessionID == sessionID }), "Purchase transaction must be rolled back")
    }

    func testRollbackAbortsIfSessionMutatedConcurrentlyWithNewerFingerprint() async throws {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else {
            XCTFail("Missing test account")
            return
        }

        let sessionID = UUID()
        let item1 = PurchaseItem(id: UUID(), categoryID: .shopping, note: "Book", amount: 20.0, displayOrder: 0, isCompleted: true)
        let session = PurchaseSession(
            id: sessionID,
            ledgerBookID: store.activeBookID,
            name: "Bookstore",
            status: .awaitingSummary,
            sections: [],
            items: [item1],
            createdAt: .now,
            startedAt: .now,
            completedAt: .now,
            currency: account.currency,
            accountID: account.id
        )
        store.mutateState { $0.purchaseSessions = [session] }

        final class SuspensionGate: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Error>?
        }
        let gate = SuspensionGate()
        let (stream2, streamContinuation2) = AsyncStream<Void>.makeStream()

        store.persistenceTestHook = {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                gate.continuation = cont
                streamContinuation2.yield()
            }
        }
        defer { store.persistenceTestHook = nil }

        let finalizeTask = Task { @MainActor in
            defer { streamContinuation2.finish() }
            try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        }

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            streamContinuation2.finish()
        }
        defer { watchdog.cancel() }

        var it = stream2.makeAsyncIterator()
        let hookReached = await it.next() != nil
        XCTAssertTrue(hookReached, "Persistence hook must be reached")
        guard hookReached, let cont = gate.continuation else {
            _ = try? await finalizeTask.value
            return
        }

        // While finalize is suspended, a concurrent mutation adds a second item to the session
        let item2 = PurchaseItem(id: UUID(), categoryID: .shopping, note: "Bookmark", amount: 5.0, displayOrder: 1, isCompleted: false)
        store.mutateState { state in
            if var sessions = state.purchaseSessions, let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[idx].items.append(item2)
                sessions[idx].updatedAt = Date.now.addingTimeInterval(5)
                state.purchaseSessions = sessions
            }
        }

        // Resume with persistence failure
        cont.resume(throwing: SimulatedPersistenceError())

        do {
            try await finalizeTask.value
            XCTFail("Finalize should throw")
        } catch is SimulatedPersistenceError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Because fingerprint changed during suspension (items count changed),
        // the rollback must NOT overwrite the newer session state!
        let currentSession = store.purchaseSessions.first(where: { $0.id == sessionID })
        XCTAssertNotNil(currentSession)
        XCTAssertEqual(currentSession?.items.count, 2, "Newer session mutation must not be overwritten by stale rollback")
    }
}
