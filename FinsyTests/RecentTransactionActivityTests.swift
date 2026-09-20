import XCTest
@testable import Finsy

@MainActor
final class RecentTransactionActivityTests: XCTestCase {
    func testSnapshotCreationAndExpiryWindow() async {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else {
            XCTFail("Missing account")
            return
        }

        let now = Date.now
        guard let tx = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 12.50,
            currency: account.currency,
            categoryID: .food,
            occurredAt: now,
            note: "Coffee"
        ) else {
            XCTFail("Failed to add transaction")
            return
        }

        // Wait brief tick for Task in addTransaction to write snapshot
        await Task.yield()

        let snapshot = RecentTransactionSharedStore.loadSnapshot(id: tx.id)
        XCTAssertNotNil(snapshot, "Snapshot should be saved to shared store")
        if let s = snapshot {
            XCTAssertEqual(s.id, tx.id)
            XCTAssertEqual(s.title, "Coffee")
            XCTAssertTrue(s.amountText.contains("12.50"))
            XCTAssertTrue(s.isRefundable)
            XCTAssertFalse(s.isUndone)
            XCTAssertFalse(s.isRefunded)
            let diff = s.expiresAt.timeIntervalSince(now)
            XCTAssertGreaterThanOrEqual(diff, 9.0, "Expiry window should be approx 10 seconds")
            XCTAssertLessThanOrEqual(diff, 11.0)
        }
    }

    func testIntentMarkUndoneReconciliationDeletesTransaction() async {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else { return }

        guard let tx = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 15.0,
            currency: account.currency,
            categoryID: .shopping,
            occurredAt: .now,
            note: "Mistaken purchase"
        ) else { return }

        // Simulate widget / intent marking the snapshot undone
        RecentTransactionSharedStore.markUndone(id: tx.id)
        let marked = RecentTransactionSharedStore.loadSnapshot(id: tx.id)
        XCTAssertEqual(marked?.isUndone, true)

        // Run coordinator reconciliation
        RecentTransactionActivityCoordinator.shared.reconcilePendingActions(store: store)

        // Transaction should now be deleted in the store
        let current = store.state.transactions.first(where: { $0.id == tx.id })
        XCTAssertNotNil(current?.deletedAt, "Reconciled transaction must be soft-deleted")
    }

    func testIntentMarkRefundedReconciliationCreatesReversal() async {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else { return }

        guard let tx = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 88.0,
            currency: account.currency,
            categoryID: .shopping,
            occurredAt: .now,
            note: "Store return"
        ) else { return }

        // Simulate widget / intent marking the snapshot refunded
        RecentTransactionSharedStore.markRefunded(id: tx.id)

        RecentTransactionActivityCoordinator.shared.reconcilePendingActions(store: store)

        // Original transaction has reversalTransactionID set
        let original = store.state.transactions.first(where: { $0.id == tx.id })
        XCTAssertNotNil(original?.reversalTransactionID, "Refunded transaction must link to reversal")

        // Reversal transaction exists
        let reversal = store.state.transactions.first(where: { $0.reversalOfTransactionID == tx.id })
        XCTAssertNotNil(reversal, "Reversal transaction must be created")
    }
}
