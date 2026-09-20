import XCTest
@testable import Finsy

@MainActor
final class WalletPassSnapshotTests: XCTestCase {
    func testAccountPassSnapshotNetWorthParity() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        let expectedNetWorth = LedgerCalculations.portfolioBalance(store.state, target: store.state.settings.baseCurrency)

        let snapshot = WalletPassManager.shared.buildAccountPassSnapshot(
            store: store,
            source: .allAccounts,
            locations: []
        )

        XCTAssertEqual(snapshot.title, "Net Worth")
        XCTAssertEqual(snapshot.balanceAmount, expectedNetWorth, accuracy: 0.0001)
        XCTAssertEqual(snapshot.currency, store.state.settings.baseCurrency)
    }

    func testAccountPassSnapshotSpecificAccountParity() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else { return }

        let expectedBalance = LedgerCalculations.balance(for: account, in: store.state)

        let snapshot = WalletPassManager.shared.buildAccountPassSnapshot(
            store: store,
            source: .specificAccount(account.id),
            locations: []
        )

        XCTAssertEqual(snapshot.title, account.name)
        XCTAssertEqual(snapshot.balanceAmount, expectedBalance, accuracy: 0.0001)
        XCTAssertEqual(snapshot.currency, account.currency)
    }

    func testLocationsAreCappedAtTen() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        let fifteenLocations = (1...15).map { i in
            WalletRelevantLocation(latitude: 37.0 + Double(i) * 0.01, longitude: -122.0, relevantText: "Store \(i)")
        }

        let snapshot = WalletPassManager.shared.buildAccountPassSnapshot(
            store: store,
            source: .allAccounts,
            locations: fifteenLocations
        )

        XCTAssertEqual(snapshot.locations.count, 10, "Snapshot must enforce the 10 location cap")
    }

    func testTaxReceiptPassExcludesIncomeTax() {
        let store = LedgerStore(stateForTesting: DemoDataFactory.make())
        guard let account = store.state.accounts.first(where: { $0.deletedAt == nil }) else { return }

        let calendar = Calendar.current
        let year = 2026
        let month = 4
        let comps = DateComponents(year: year, month: month, day: 10, hour: 12)
        let date = calendar.date(from: comps)!

        // Add expense with tax: $100 amount, $10 tax
        var expenseTx = LedgerTransaction(
            id: UUID(),
            userID: store.state.settings.userID,
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 100.0,
            currency: store.state.settings.baseCurrency,
            accountAmount: 100.0,
            destinationAmount: nil,
            categoryID: .shopping,
            occurredAt: date,
            note: "Taxable expense",
            exchangeRateAtTransaction: 1.0,
            createdAt: date,
            updatedAt: date,
            version: 1,
            syncStatus: .pending
        )
        expenseTx.taxAmount = 10.0
        expenseTx.taxRate = 0.10

        // Add income with tax: $500 amount, $50 tax
        var incomeTx = LedgerTransaction(
            id: UUID(),
            userID: store.state.settings.userID,
            type: .income,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 500.0,
            currency: store.state.settings.baseCurrency,
            accountAmount: 500.0,
            destinationAmount: nil,
            categoryID: .salary,
            occurredAt: date,
            note: "Taxable income",
            exchangeRateAtTransaction: 1.0,
            createdAt: date,
            updatedAt: date,
            version: 1,
            syncStatus: .pending
        )
        incomeTx.taxAmount = 50.0
        incomeTx.taxRate = 0.10

        store.mutateState { state in
            state.transactions.append(expenseTx)
            state.transactions.append(incomeTx)
        }

        let snapshot = WalletPassManager.shared.buildTaxReceiptSnapshot(
            year: year,
            month: month,
            store: store
        )

        // Expense tax should be exactly 10.0, income tax of 50.0 MUST NOT be added!
        XCTAssertEqual(snapshot.totalExpenseTax, 10.0, accuracy: 0.0001, "Tax pass must include only expense tax, strictly ignoring income tax")
        XCTAssertEqual(snapshot.totalTaxableExpense, 100.0, accuracy: 0.0001)
    }

    func testWalletPassConfigurationAndIssuerState() {
        XCTAssertEqual(WalletPassConfiguration.issuerURLKey, "FINSY_WALLET_PASS_ISSUER_URL")

        let networkIssuer = NetworkWalletPassIssuer(signingEndpoint: nil)
        XCTAssertFalse(networkIssuer.isConfigured)

        let mockIssuer = MockWalletPassIssuer()
        XCTAssertTrue(mockIssuer.isConfigured)

        let configuredNetworkIssuer = NetworkWalletPassIssuer(signingEndpoint: URL(string: "https://example.com/pass"))
        XCTAssertTrue(configuredNetworkIssuer.isConfigured)
    }
}
