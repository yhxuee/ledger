import XCTest
@testable import Finsy

@MainActor
final class ScopedUndoTests: XCTestCase {
    func testDeleteTransactionUndoPreservesInterveningCreatedTransaction() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else {
            XCTFail("Missing account")
            return
        }

        // Add Transaction A
        guard let txA = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 50.0,
            currency: account.currency,
            categoryID: .food,
            occurredAt: .now,
            note: "Transaction A"
        ) else {
            XCTFail("Failed to add transaction A")
            return
        }

        // Delete Transaction A (scoped undo captures snapshot)
        store.deleteTransaction(txA)
        XCTAssertTrue(store.state.transactions.first(where: { $0.id == txA.id })?.deletedAt != nil)
        XCTAssertNotNil(store.activeUndoOperation)

        // Add intervening Transaction B
        guard let txB = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 75.0,
            currency: account.currency,
            categoryID: .shopping,
            occurredAt: .now,
            note: "Transaction B"
        ) else {
            XCTFail("Failed to add transaction B")
            return
        }

        // Perform Undo
        store.undoDelete()

        // Verify Transaction A is restored
        let restoredA = store.state.transactions.first(where: { $0.id == txA.id })
        XCTAssertNotNil(restoredA)
        XCTAssertNil(restoredA?.deletedAt, "Transaction A must be restored")

        // CRITICAL CHECK: Transaction B MUST still exist! (Old unsafe whole-state undo would have erased B!)
        let retainedB = store.state.transactions.first(where: { $0.id == txB.id })
        XCTAssertNotNil(retainedB, "Intervening transaction B must be preserved by scoped undo")
        XCTAssertNil(retainedB?.deletedAt)
    }

    func testDeleteAccountUndoPreservesInterveningMutations() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        let accountToDelete = store.state.accounts[0]
        let otherAccount = store.state.accounts[1]

        store.deleteAccount(accountToDelete)
        XCTAssertTrue(store.state.accounts.first(where: { $0.id == accountToDelete.id })?.deletedAt != nil)
        XCTAssertNotNil(store.activeUndoOperation)

        // Intervening transaction created in other account
        guard let interveningTx = store.addTransaction(
            type: .expense,
            accountID: otherAccount.id,
            destinationAccountID: nil,
            amount: 30.0,
            currency: otherAccount.currency,
            categoryID: .food,
            occurredAt: .now,
            note: "Intervening Lunch"
        ) else {
            XCTFail("Failed to add intervening tx")
            return
        }

        // Undo account deletion
        store.undoDelete()

        // Account is restored
        let restoredAccount = store.state.accounts.first(where: { $0.id == accountToDelete.id })
        XCTAssertNotNil(restoredAccount)
        XCTAssertNil(restoredAccount?.deletedAt)

        // Intervening transaction is NOT wiped out
        XCTAssertTrue(store.state.transactions.contains(where: { $0.id == interveningTx.id }))
    }

    func testUndoFailsSafelyIfVersionChangedConcurrently() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else { return }

        guard let tx = store.addTransaction(
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 40.0,
            currency: account.currency,
            categoryID: .food,
            occurredAt: .now,
            note: "Version Test"
        ) else { return }

        store.deleteTransaction(tx)
        guard var op = store.activeUndoOperation else {
            XCTFail("Missing active undo op")
            return
        }

        // Simulate an external version change or mismatch
        op.expectedTransactionVersions[tx.id] = 999
        let success = store.applyUndo(op)

        XCTAssertFalse(success, "Undo must reject when version guard fails")
    }

    func testCombinedPaymentRefundUndoRemovesSupportReversals() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard store.state.accounts.count >= 2 else { return }
        let acc1 = store.state.accounts[0]
        let acc2 = store.state.accounts[1]

        // Create two transactions and combine them
        guard let t1 = store.addTransaction(type: .expense, accountID: acc1.id, destinationAccountID: nil, amount: 20, currency: acc1.currency, categoryID: .food, occurredAt: .now, note: "Item 1"),
              let t2 = store.addTransaction(type: .expense, accountID: acc2.id, destinationAccountID: nil, amount: 30, currency: acc2.currency, categoryID: .food, occurredAt: .now, note: "Item 2") else {
            XCTFail("Setup failed")
            return
        }

        guard let combinedParent = store.combineTransactions(first: t1, second: t2) else {
            XCTFail("Combine failed")
            return
        }

        // Refund the combined payment
        let refunded = store.refundCombinedPayment(parentID: combinedParent.id)
        XCTAssertTrue(refunded)

        let initialTxCount = store.state.transactions.count
        _ = initialTxCount
        XCTAssertNotNil(store.activeUndoOperation)

        // Undo refund
        store.undoDelete()

        // Created refund transactions should have been marked deleted
        let parentID = combinedParent.id
        let activeVisibleRefund = store.state.transactions.first { (tx: LedgerTransaction) -> Bool in
            guard tx.parentTransactionID == parentID else { return false }
            guard tx.linkedTransactionKind == .combinedPaymentRefund else { return false }
            return tx.deletedAt == nil
        }
        XCTAssertNil(activeVisibleRefund, "Visible refund transaction must be marked deleted on undo")
    }
}
