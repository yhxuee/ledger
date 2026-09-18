import XCTest
@testable import WalletLedger

final class LedgerCalculationsTests: XCTestCase {
    func testExpenseIncomeAndTransferAffectBalancesOnce() throws {
        var state = SeedData.make()
        let source = try XCTUnwrap(state.accounts.first)
        let destination = try XCTUnwrap(state.accounts.dropFirst().first)
        state.transactions = [
            makeTransaction(type: .expense, source: source, amount: 100),
            makeTransaction(type: .income, source: source, amount: 40),
            makeTransaction(type: .transfer, source: source, destination: destination, amount: 200)
        ]
        XCTAssertEqual(LedgerCalculations.balance(for: source, in: state), source.openingBalance - 260, accuracy: 0.001)
        XCTAssertEqual(LedgerCalculations.balance(for: destination, in: state), destination.openingBalance + 200, accuracy: 0.001)
        XCTAssertEqual(LedgerCalculations.analytics(state, range: .week).total, 100, accuracy: 0.001)
    }

    func testDeletedTransactionsDoNotAffectTotals() throws {
        var state = SeedData.make()
        let source = try XCTUnwrap(state.accounts.first)
        var deleted = makeTransaction(type: .expense, source: source, amount: 100)
        deleted.deletedAt = .now
        state.transactions = [deleted]
        XCTAssertEqual(LedgerCalculations.balance(for: source, in: state), source.openingBalance, accuracy: 0.001)
        XCTAssertEqual(LedgerCalculations.analytics(state, range: .week).total, 0)
    }

    func testBudgetExcludesSavingsAndTransfers() throws {
        var state = SeedData.make()
        let checking = try XCTUnwrap(state.accounts.first(where: { $0.includeInBudget }))
        let savings = try XCTUnwrap(state.accounts.first(where: { !$0.includeInBudget }))
        state.transactions = [makeTransaction(type: .expense, source: checking, amount: 100), makeTransaction(type: .expense, source: savings, amount: 500), makeTransaction(type: .transfer, source: checking, destination: savings, amount: 200)]
        XCTAssertEqual(LedgerCalculations.budgetUsage(state).spent, 100, accuracy: 0.001)
    }

    func testBackupRoundTrip() throws {
        var state = SeedData.make()
        let source = try XCTUnwrap(state.accounts.first)
        state.recurringRules = [
            .init(id: UUID(), userID: state.settings.userID, type: .expense, accountID: source.id, destinationAccountID: nil, amount: 88, currency: source.currency, categoryID: .food, note: "Weekly lunch", interval: .weekly, customIntervalDays: 7, nextRunAt: .now, isEnabled: true, createdAt: .now, updatedAt: .now)
        ]
        let data = try BackupCodec.encode(BackupCodec.envelope(for: state))
        let decoded = try BackupCodec.decode(data, sourceName: "test.walletledger")
        XCTAssertEqual(decoded.envelope.data.accounts.count, state.accounts.count)
        XCTAssertEqual(decoded.envelope.data.transactions.count, state.transactions.count)
        XCTAssertEqual(decoded.envelope.data.recurringRules, state.recurringRules)
    }

    private func makeTransaction(type: LedgerTransactionType, source: LedgerAccount, destination: LedgerAccount? = nil, amount: Double) -> LedgerTransaction {
        .init(id: UUID(), userID: SeedData.localUserID, type: type, accountID: source.id, destinationAccountID: destination?.id, amount: amount, currency: source.currency, accountAmount: amount, destinationAmount: destination == nil ? nil : amount, categoryID: .food, occurredAt: .now, note: nil, exchangeRateAtTransaction: SeedData.rates[source.currency] ?? 1, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
    }
}
