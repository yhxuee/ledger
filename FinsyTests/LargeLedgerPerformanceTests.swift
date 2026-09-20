import XCTest
@testable import Finsy

@MainActor
final class LargeLedgerPerformanceTests: XCTestCase {
    private func makeLargeLedger(count: Int) -> LedgerState {
        var state = SeedData.makeEmpty()
        let accountID = UUID()
        let account = LedgerAccount(
            id: accountID,
            userID: state.settings.userID,
            name: "Performance Account",
            type: .checking,
            currency: .USD,
            openingBalance: 10_000,
            budget: 0,
            includeInBudget: false,
            logo: "PERF",
            cardStyle: .init(startHex: "3A78C2", endHex: "6C9EBB"),
            createdAt: .now,
            updatedAt: .now,
            version: 1,
            syncStatus: .synced
        )
        state.accounts = [account]

        var txs: [LedgerTransaction] = []
        txs.reserveCapacity(count)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<count {
            let tx = LedgerTransaction(
                id: UUID(),
                userID: state.settings.userID,
                type: i % 5 == 0 ? .income : .expense,
                accountID: accountID,
                destinationAccountID: nil,
                amount: Double((i % 100) + 1),
                currency: .USD,
                accountAmount: Double((i % 100) + 1),
                destinationAmount: nil,
                categoryID: .food,
                occurredAt: baseDate.addingTimeInterval(Double(i * 60)),
                note: "Tx \(i)",
                exchangeRateAtTransaction: 1.0,
                createdAt: baseDate,
                updatedAt: baseDate,
                version: 1,
                syncStatus: .synced
            )
            txs.append(tx)
        }
        state.transactions = txs
        return state
    }

    func test10kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 10_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.portfolioBalance(state, target: state.settings.baseCurrency)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 2.0, "10k calculation took \(duration)s, expected < 2.0s")
    }

    func test50kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 50_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.portfolioBalance(state, target: state.settings.baseCurrency)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 5.0, "50k calculation took \(duration)s, expected < 5.0s")
    }

    func test100kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 100_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.portfolioBalance(state, target: state.settings.baseCurrency)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 10.0, "100k calculation took \(duration)s, expected < 10.0s")
    }
}
