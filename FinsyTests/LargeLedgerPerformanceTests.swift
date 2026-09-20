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
        let total = LedgerCalculations.totalBalance(in: state, rates: state.settings.rates)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 0.5, "10k calculation took \(duration)s, expected < 0.5s")
    }

    func test50kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 50_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.totalBalance(in: state, rates: state.settings.rates)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 1.5, "50k calculation took \(duration)s, expected < 1.5s")
    }

    func test100kTransactionsCalculationPerformance() {
        let state = makeLargeLedger(count: 100_000)
        let start = CFAbsoluteTimeGetCurrent()
        let total = LedgerCalculations.totalBalance(in: state, rates: state.settings.rates)
        let duration = CFAbsoluteTimeGetCurrent() - start

        XCTAssertTrue(total.isFinite)
        XCTAssertLessThan(duration, 3.0, "100k calculation took \(duration)s, expected < 3.0s")
    }
}
