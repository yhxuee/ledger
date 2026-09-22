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
        for _ in 0..<20 {
            if RecentTransactionSharedStore.loadSnapshot(id: tx.id) != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let snapshot = RecentTransactionSharedStore.loadSnapshot(id: tx.id)
        XCTAssertNotNil(snapshot, "Snapshot should be saved to shared store")
        if let s = snapshot {
            XCTAssertEqual(s.id, tx.id)
            XCTAssertEqual(s.transactionID, tx.id)
            XCTAssertEqual(s.ledgerBookID, store.activeBookID)
            XCTAssertEqual(s.title, "Coffee")
            XCTAssertTrue(s.amountText.contains("12.50"))
            XCTAssertTrue(s.isRefundable)
            XCTAssertFalse(s.isUndone)
            XCTAssertFalse(s.isRefunded)
            let diff = s.expiresAt.timeIntervalSince(now)
            XCTAssertGreaterThanOrEqual(diff, 7.0, "Expiry window should be approx 8 seconds")
            XCTAssertLessThanOrEqual(diff, 9.5)
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

        for _ in 0..<20 {
            if RecentTransactionSharedStore.loadSnapshot(id: tx.id) != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

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

        for _ in 0..<20 {
            if RecentTransactionSharedStore.loadSnapshot(id: tx.id) != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

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

    func testRecurringTransactionOriginDoesNotTriggerActivity() async {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else { return }

        guard let tx = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 50.0,
            currency: account.currency,
            categoryID: .utilities,
            occurredAt: .now,
            note: "Monthly subscription",
            origin: .recurring
        ) else {
            XCTFail("Failed to add recurring transaction")
            return
        }

        // Wait ticks
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Snapshot must NOT be created for recurring origin
        let snapshot = RecentTransactionSharedStore.loadSnapshot(id: tx.id)
        XCTAssertNil(snapshot, "Non-user transaction origin must not launch Live Activity snapshot")
    }

    func testCrossLedgerReconciliationIsIgnored() async {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else { return }

        guard let tx = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 25.0,
            currency: account.currency,
            categoryID: .food,
            occurredAt: .now,
            note: "Other book tx"
        ) else { return }

        // Manually overwrite snapshot with a foreign book ID
        let foreignSnapshot = RecentTransactionActionSnapshot(
            operationID: UUID(),
            ledgerBookID: UUID(), // different from store.activeBookID
            transactionID: tx.id,
            title: "Other book tx",
            amountText: "-$25.00",
            occurredAt: .now,
            expiresAt: Date.now.addingTimeInterval(10),
            isRefundable: true,
            accountName: account.name,
            isUndone: true
        )
        RecentTransactionSharedStore.saveSnapshot(foreignSnapshot)

        // Reconciliation should ignore foreign book ID
        RecentTransactionActivityCoordinator.shared.reconcilePendingActions(store: store)

        let current = store.state.transactions.first(where: { $0.id == tx.id })
        XCTAssertNil(current?.deletedAt, "Cross-ledger snapshot must not mutate active book transactions")
    }

    func testTurboTransientPresentationSnapshot() async {
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
            amount: 8.0,
            currency: account.currency,
            categoryID: .food,
            occurredAt: now,
            note: "Turbo Snack",
            presentation: .transient
        ) else {
            XCTFail("Failed to add turbo transaction")
            return
        }

        for _ in 0..<20 {
            if RecentTransactionSharedStore.loadSnapshot(id: tx.id) != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let snapshot = RecentTransactionSharedStore.loadSnapshot(id: tx.id)
        XCTAssertNotNil(snapshot, "Snapshot should be saved for Turbo transaction")
        if let s = snapshot {
            XCTAssertEqual(s.id, tx.id)
            let diff = s.expiresAt.timeIntervalSince(now)
            XCTAssertGreaterThanOrEqual(diff, 2.5, "Turbo expiry window should be approx 3 seconds")
            XCTAssertLessThanOrEqual(diff, 4.5)
        }
    }

    func testExplicitNonePresentationDoesNotCreateSnapshot() async {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else {
            XCTFail("Missing account")
            return
        }

        guard let tx = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 19.99,
            currency: account.currency,
            categoryID: .entertainment,
            occurredAt: .now,
            note: "Silent Transaction",
            presentation: .none
        ) else {
            XCTFail("Failed to add transaction")
            return
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let snapshot = RecentTransactionSharedStore.loadSnapshot(id: tx.id)
        XCTAssertNil(snapshot, "Explicit .none presentation must not create a Live Activity snapshot")
    }
}
