import XCTest
import CloudKit
@testable import WalletLedger

private struct FixedActivityStarter: PurchaseActivityStarting {
    let result: PurchaseActivityResult
    func start(session: PurchaseSession) async -> PurchaseActivityResult { result }
}

@MainActor
final class CurrencyPurchaseTests: XCTestCase {
    func testStablecoinIdentifiersRoundTripAndRejectUnknownLongCodes() throws {
        XCTAssertEqual(CurrencyCode.usdStablecoins.map(\.rawValue), ["USDT", "USDC", "PYUSD", "BUSD", "GUSD"])
        for code in CurrencyCode.usdStablecoins {
            XCTAssertTrue(code.isUSDStablecoin)
            XCTAssertEqual(code.referenceCurrency, .USD)
            let data = try JSONEncoder().encode(code)
            XCTAssertEqual(try JSONDecoder().decode(CurrencyCode.self, from: data), code)
            XCTAssertEqual(CurrencyCode(rawValue: code.rawValue.lowercased()), code)
        }
        for code in ["USDX", "BITCOIN", "ABCDE", "中美元", "US1", " USD"] {
            XCTAssertNil(CurrencyCode(rawValue: code))
            XCTAssertThrowsError(try JSONDecoder().decode(CurrencyCode.self, from: Data("\"\(code)\"".utf8)))
        }
        XCTAssertFalse(CurrencyCode.allCases.contains { $0.rawValue == "BTC" })
    }

    func testEveryStablecoinUsesUSDAliasEvenWithConflictingDictionaryEntries() {
        var rates: [CurrencyCode: Double] = [.HKD: 1, .USD: 7.8, .EUR: 8.5]
        for coin in CurrencyCode.usdStablecoins { rates[coin] = 999 }
        for coin in CurrencyCode.usdStablecoins {
            XCTAssertEqual(CurrencyRates.reference(coin, in: rates), 7.8)
            XCTAssertEqual(LedgerCalculations.convert(20, from: coin, to: .EUR, rates: rates),
                           LedgerCalculations.convert(20, from: .USD, to: .EUR, rates: rates), accuracy: 0.000001)
            XCTAssertEqual(LedgerCalculations.convert(20, from: .EUR, to: coin, rates: rates),
                           LedgerCalculations.convert(20, from: .EUR, to: .USD, rates: rates), accuracy: 0.000001)
            XCTAssertEqual(CurrencyRates.mirroringUSDAliases(rates)[coin], 7.8)
        }
        rates[.USD] = nil
        XCTAssertNil(CurrencyRates.reference(.USDT, in: rates), "A stale alias must never substitute for missing USD.")
    }

    func testSnapshotsAndNonfinancialEditsKeepHistoricalStablecoinRates() throws {
        let store = LedgerStore(stateForTesting: SeedData.makeEmpty())
        let account = try XCTUnwrap(store.accounts.first).id
        var originals: [LedgerTransaction] = []
        for coin in CurrencyCode.usdStablecoins + [.USD] {
            originals.append(try XCTUnwrap(store.addTransaction(type: .expense, accountID: account, destinationAccountID: nil,
                amount: 10, currency: coin, categoryID: .food, occurredAt: .now, note: "Original")))
        }
        XCTAssertTrue(originals.allSatisfy { $0.exchangeRateAtTransaction == originals.last?.exchangeRateAtTransaction })
        XCTAssertTrue(originals.allSatisfy { $0.accountAmount == originals.last?.accountAmount })
        store.updateSettings { $0.rates[.USD] = 9 }
        for original in originals {
            var edited = original
            edited.note = "Edited note"
            store.updateTransaction(edited)
            let saved = try XCTUnwrap(store.state.transactions.first { $0.id == original.id })
            XCTAssertEqual(saved.exchangeRateAtTransaction, original.exchangeRateAtTransaction)
            XCTAssertEqual(saved.accountAmount, original.accountAmount)
            XCTAssertEqual(LedgerCalculations.historical(saved, to: .HKD, rates: store.state.settings.rates), 78, accuracy: 0.001)
        }
        let new = try XCTUnwrap(store.addTransaction(type: .expense, accountID: account, destinationAccountID: nil,
            amount: 10, currency: .USDT, categoryID: .food, occurredAt: .now, note: nil))
        XCTAssertEqual(new.exchangeRateAtTransaction, 9)
    }

    func testCatalogRefreshRetainsStablecoinsAndSanitizesLocalizedNames() {
        let catalog = CurrencyDescriptor.appCatalog([.init(code: .CNY, name: "人民币", symbol: "元")])
        for code in CurrencyCode.usdStablecoins { XCTAssertTrue(catalog.contains { $0.code == code }) }
        XCTAssertEqual(catalog.first { $0.code == .CNY }?.name, "CNY")
        XCTAssertTrue(catalog.allSatisfy { $0.name.unicodeScalars.allSatisfy(\.isASCII) })
        XCTAssertTrue(LedgerFormat.money(12, currency: .CNY).hasPrefix("¥"))
        XCTAssertTrue(LedgerFormat.money(12, currency: .PYUSD).hasPrefix("$"))
        XCTAssertEqual(CurrencyCode.preferredFiat.map(\.rawValue), ["HKD", "USD", "GBP", "JPY", "CNY", "EUR", "SGD", "CHF"])
    }

    func testPurchaseBackupAndCloudRoundTripWithUnifiedPayment() throws {
        var state = SeedData.makeEmpty()
        var session = makeSession(accountID: state.accounts[0].id, currency: .USDC)
        session.normalizeSections()
        state.purchaseSessions = [session]
        // No explicit stablecoin entry is necessary in backups.
        XCTAssertNil(state.settings.rates[.USDC])
        let decoded = try BackupCodec.decode(BackupCodec.encode(BackupCodec.envelope(for: state)), sourceName: "purchase.walletledger").envelope.data
        XCTAssertEqual(decoded.purchaseSessions?.first?.currency, .USDC)
        XCTAssertEqual(decoded.purchaseSessions?.first?.accountID, session.accountID)
        XCTAssertEqual(decoded.purchaseSessions?.first?.plannedAmount, 100)
        let book = LedgerBook(id: session.ledgerBookID, name: "Test", state: state, createdAt: .now, updatedAt: .now)
        let records = try CloudRecordMapper.records(for: book)
        let cloud = try CloudRecordMapper.decodeBook(from: records, participant: false)
        XCTAssertEqual(cloud.state.purchaseSessions?.first?.currency, .USDC)
        XCTAssertEqual(cloud.state.purchaseSessions?.first?.accountID, session.accountID)
        XCTAssertEqual(cloud.state.purchaseSessions?.first?.orderedItems.map(\.id), session.orderedItems.map(\.id))
    }

    func testCloudHeaderExcludesDeletedDraftItemsFromOldCachedRecords() throws {
        var state = SeedData.makeEmpty()
        var session = makeSession(accountID: state.accounts[0].id)
        session.normalizeSections()
        state.purchaseSessions = [session]
        var book = LedgerBook(id: session.ledgerBookID, name: "Shared", state: state, createdAt: .now, updatedAt: .now)
        let originalRecords = try CloudRecordMapper.records(for: book)
        let removed = session.items.removeLast()
        session.normalizeSections()
        book.state.purchaseSessions = [session]
        var refreshed = try CloudRecordMapper.records(for: book)
        refreshed += originalRecords.filter { $0.recordID.recordName == "purchase-item-\(removed.id.uuidString)" }
        let decoded = try CloudRecordMapper.decodeBook(from: refreshed, participant: false)
        XCTAssertEqual(decoded.state.purchaseSessions?.first?.items.count, 2)
        XCTAssertFalse(decoded.state.purchaseSessions?.first?.items.contains { $0.id == removed.id } ?? true)
    }

    func testFinalizationUsesSessionCurrencyAndOneAccountNotItemDefaults() throws {
        var state = SeedData.make()
        state.transactions = []
        let payment = try XCTUnwrap(state.accounts.first { $0.currency == .USD })
        var session = makeSession(accountID: payment.id, currency: .USDT)
        session.status = .awaitingSummary
        for index in session.items.indices {
            session.items[index].isCompleted = true
            session.items[index].completedAt = .now
            session.items[index].resolvedAccountID = state.accounts[0].id
        }
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        try store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
        try store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
        XCTAssertEqual(store.state.transactions.count, 3)
        XCTAssertTrue(store.state.transactions.allSatisfy { $0.currency == .USDT && $0.accountID == payment.id })
        XCTAssertEqual(store.state.transactions.reduce(0) { $0 + $1.amount }, 100)
        XCTAssertEqual(store.state.transactions.reduce(0) { $0 + ($1.accountAmount ?? 0) }, 100, accuracy: 0.001)
        XCTAssertEqual(LedgerCalculations.analytics(store.state, range: .week).total, 780, accuracy: 0.001)
        XCTAssertEqual(store.purchaseSessions.first?.currency, .USDT)
        store.updateSettings { $0.baseCurrency = .EUR; $0.rates[.USD] = 9 }
        XCTAssertEqual(PurchaseLedgerPresentation.displayedTotal(store.state.transactions, session: session, rates: store.state.settings.rates), 100)
    }

    func testCategoryGroupingMovesItemsAndDropsEmptyGroupsDeterministically() {
        var session = makeSession(accountID: UUID())
        session.normalizeSections()
        XCTAssertEqual(session.orderedItems.map(\.note), ["Milk", "Bread", "Train"])
        session.items[2].categoryID = .food
        session.normalizeSections()
        XCTAssertEqual(session.orderedSections.map(\.categoryID), [.food])
        let previous = session.sections
        session.normalizeSections()
        XCTAssertEqual(session.sections, previous)
        XCTAssertEqual(session.orderedItems.map(\.note), ["Milk", "Bread", "Train"])
    }

    func testContentProgressCountsItemsIndependentlyOfAmountsAndOrdersNextThree() {
        var session = makeSession(accountID: UUID(), currency: .PYUSD)
        session.items[0].isCompleted = true // 10 of 100, but 1 of 3 items.
        session.normalizeSections()
        let content = PurchaseActivityAttributes.ContentState.make(session: session)
        XCTAssertEqual(content.completedItemCount, 1)
        XCTAssertEqual(content.totalItemCount, 3)
        XCTAssertEqual(content.completionFraction, 1.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(content.completedAmount, 10)
        XCTAssertEqual(content.totalPlannedAmount, 100)
        XCTAssertEqual(content.nextItems.map(\.name), ["Bread", "Train"])
        session.items.append(.init(id: UUID(), categoryID: .transport, note: "Bus", amount: 5, displayOrder: 3, isCompleted: false, completedAt: nil, linkedTransactionID: nil))
        session.items.append(.init(id: UUID(), categoryID: .transport, note: "Taxi", amount: 5, displayOrder: 4, isCompleted: false, completedAt: nil, linkedTransactionID: nil))
        XCTAssertEqual(PurchaseActivityAttributes.ContentState.make(session: session).nextItems.map(\.name), ["Bread", "Train", "Bus"])
    }

    func testDeletedPaymentAccountBlocksStartAndFinalizationWithoutFallback() async throws {
        var state = SeedData.make()
        state.transactions = []
        var session = makeSession(accountID: state.accounts[0].id)
        state.accounts[0].deletedAt = .now
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        do {
            _ = try await store.startPurchaseSession(session.id, activityStarter: FixedActivityStarter(result: .started(activityID: "unexpected")))
            XCTFail("Starting must reject a deleted payment account.")
        } catch { XCTAssertTrue(store.state.transactions.isEmpty) }
        session.status = .awaitingSummary
        for i in session.items.indices { session.items[i].isCompleted = true }
        store.savePurchaseSession(session)
        XCTAssertThrowsError(try store.finalizePurchaseSession(session.id, receiptAttachmentID: nil))
        XCTAssertTrue(store.state.transactions.isEmpty)
        XCTAssertEqual(store.purchaseSessions.first?.accountID, state.accounts[0].id)
    }

    func testLiveActivityFailureIsPresentedAndPurchaseRemainsActive() async throws {
        for result in [PurchaseActivityResult.liveActivitiesDisabled, .requestFailed("ActivityKit.Test (42): denied"), .sharedStateFailed("Missing App Group")] {
            var state = SeedData.makeEmpty()
            let session = makeSession(accountID: state.accounts[0].id)
            state.purchaseSessions = [session]
            let store = LedgerStore(stateForTesting: state)
            let actual = try await store.startPurchaseSession(session.id, activityStarter: FixedActivityStarter(result: result))
            XCTAssertEqual(actual, result)
            XCTAssertEqual(store.purchaseSessions.first?.status, .active)
            XCTAssertEqual(store.presentedError, result.userMessage)
            XCTAssertNotNil(store.presentedError)
            XCTAssertTrue(store.state.transactions.isEmpty)
        }
    }

    func testControllerSurfacesThrownRequestError() async {
        var session = makeSession(accountID: UUID())
        session.status = .active
        let controller = PurchaseLiveActivityController(snapshotWriter: { _ in }, activitiesEnabled: { true },
            requestActivity: { _, _ in throw NSError(domain: "ActivityKit.Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test rejection"]) })
        let result = await controller.start(session: session)
        guard case .requestFailed(let detail) = result else { return XCTFail("A thrown request must surface as requestFailed.") }
        XCTAssertTrue(detail.contains("ActivityKit.Test"))
        XCTAssertTrue(detail.contains("42"))
        XCTAssertTrue(detail.contains("Test rejection"))
    }

    func testLiveActivityIsStillRequestedWhenSharedStateIsUnavailable() async {
        var session = makeSession(accountID: UUID())
        session.status = .active
        let controller = PurchaseLiveActivityController(
            snapshotWriter: { _ in throw PurchaseSharedStateError.appGroupUnavailable },
            activitiesEnabled: { true },
            requestActivity: { _, _ in "probe-activity" })
        let result = await controller.start(session: session)
        guard case .startedWithoutSharedState(let activityID, let detail) = result else {
            return XCTFail("A successful Activity.request must not be hidden by an App Group failure: \(result)")
        }
        XCTAssertEqual(activityID, "probe-activity")
        XCTAssertFalse(detail.isEmpty)
        XCTAssertNotNil(result.userMessage)
    }

    func testSharedStateFailureDoesNotHideAThrownRequestError() async {
        var session = makeSession(accountID: UUID())
        session.status = .active
        let controller = PurchaseLiveActivityController(
            snapshotWriter: { _ in throw PurchaseSharedStateError.appGroupUnavailable },
            activitiesEnabled: { true },
            requestActivity: { _, _ in throw NSError(domain: "ActivityKit.Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "denied"]) })
        let result = await controller.start(session: session)
        guard case .requestFailed(let detail) = result else { return XCTFail("Expected requestFailed, got \(result)") }
        XCTAssertTrue(detail.contains("ActivityKit.Test"))
        XCTAssertTrue(detail.contains("denied"))
        XCTAssertTrue(detail.contains("Shared storage also failed"))
    }

    func testOldDevelopmentPurchaseDecodesAndMigratesWithinSchemaTwo() throws {
        var state = SeedData.makeEmpty()
        var session = makeSession(accountID: state.accounts[0].id)
        for i in session.items.indices { session.items[i].resolvedAccountID = state.accounts[0].id }
        let encoded = try JSONEncoder().encode(session)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "currency"); json.removeValue(forKey: "accountID")
        let legacy = try JSONDecoder().decode(PurchaseSession.self, from: JSONSerialization.data(withJSONObject: json))
        state.settings.baseCurrency = .USD
        state.purchaseSessions = [legacy]
        PurchaseRules.migrateDevelopmentSessions(in: &state)
        XCTAssertEqual(state.schemaVersion, 2)
        XCTAssertEqual(state.purchaseSessions?.first?.currency, .USD)
        XCTAssertEqual(state.purchaseSessions?.first?.accountID, state.accounts[0].id)
    }

    private func makeSession(accountID: UUID, currency: CurrencyCode = .USD) -> PurchaseSession {
        .init(id: UUID(), ledgerBookID: UUID(), name: "Shopping", status: .draft, sections: [], items: [
            .init(id: UUID(), categoryID: .food, note: "Milk", amount: 10, displayOrder: 0, isCompleted: false, completedAt: nil, linkedTransactionID: nil),
            .init(id: UUID(), categoryID: .food, note: "Bread", amount: 20, displayOrder: 1, isCompleted: false, completedAt: nil, linkedTransactionID: nil),
            .init(id: UUID(), categoryID: .transport, note: "Train", amount: 70, displayOrder: 2, isCompleted: false, completedAt: nil, linkedTransactionID: nil)
        ], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil, currency: currency, accountID: accountID)
    }
}
