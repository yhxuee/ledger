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
