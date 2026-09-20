import XCTest
import CloudKit
@testable import Finsy

private struct FixedActivityStarter: PurchaseActivityStarting {
    var activity: PurchaseActivityOutcome.Activity = .started(activityID: "stub-activity")
    var interactive = true
    var warning: String?

    func publish(session: PurchaseSession, categoryColors: [String: String], requestActivityIfNeeded: Bool) async -> PurchaseActivityOutcome {
        .init(activity: activity, interactive: interactive, warning: warning)
    }
}

/// Simulates a device/build where the App Group container cannot be opened.
private let bridgeUnavailableStarter = FixedActivityStarter(
    activity: .notRunning,
    interactive: false,
    warning: "Lock Screen item controls require a signed build with App Group access.")

/// Captures the published Live Activity state from an injected request closure.
private final class ContentStateBox: @unchecked Sendable {
    var state: PurchaseActivityAttributes.ContentState?
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
        let store = LedgerStore(stateForTesting: DemoDataFactory.makeWithSingleAccount())
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
        var state = DemoDataFactory.makeWithSingleAccount()
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
        var state = DemoDataFactory.makeWithSingleAccount()
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

    func testFinalizationUsesSessionCurrencyAndOneAccountNotItemDefaults() async throws {
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
        try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
        try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
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
        let content = PurchaseActivityAttributes.ContentState.make(session: session, interactiveCompletionAvailable: true, categoryColors: ["food": "F05E4F"])
        XCTAssertEqual(content.completedItemCount, 1)
        XCTAssertEqual(content.totalItemCount, 3)
        XCTAssertEqual(content.completionFraction, 1.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(content.completedAmount, 10)
        XCTAssertEqual(content.totalPlannedAmount, 100)
        XCTAssertEqual(content.nextItems.map(\.name), ["Bread", "Train"])
        XCTAssertEqual(content.nextItems.first?.categoryColorHex, "F05E4F")
        XCTAssertTrue(content.interactiveCompletionAvailable)
        XCTAssertFalse(content.isCompleted)
        session.items.append(.init(id: UUID(), categoryID: .transport, note: "Bus", amount: 5, displayOrder: 3, isCompleted: false, completedAt: nil, linkedTransactionID: nil))
        session.items.append(.init(id: UUID(), categoryID: .transport, note: "Taxi", amount: 5, displayOrder: 4, isCompleted: false, completedAt: nil, linkedTransactionID: nil))
        XCTAssertEqual(PurchaseActivityAttributes.ContentState.make(session: session, interactiveCompletionAvailable: false).nextItems.map(\.name), ["Bread", "Train", "Bus"])
    }

    func testActivityContentIsReadOnlyByDefaultAndDecodesLegacyPayloads() throws {
        var session = makeSession(accountID: UUID())
        session.status = .awaitingSummary
        for index in session.items.indices { session.items[index].isCompleted = true }
        let completed = PurchaseActivityAttributes.ContentState.make(session: session, interactiveCompletionAvailable: false)
        XCTAssertTrue(completed.isCompleted)
        XCTAssertFalse(completed.interactiveCompletionAvailable)

        // Payload persisted by an earlier build: missing keys must decode as read-only.
        let legacy = #"{"totalPlannedAmount":100,"completedAmount":40,"completionFraction":0.4,"nextItems":[],"isCompleted":false}"#
        let decoded = try JSONDecoder().decode(PurchaseActivityAttributes.ContentState.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.completedAmount, 40, accuracy: 0.000001)
        XCTAssertEqual(decoded.completedItemCount, 0)
        XCTAssertEqual(decoded.totalItemCount, 0)
        XCTAssertFalse(decoded.interactiveCompletionAvailable)
    }

    func testDeletedPaymentAccountBlocksStartAndFinalizationWithoutFallback() async throws {
        var state = SeedData.make()
        state.transactions = []
        var session = makeSession(accountID: state.accounts[0].id)
        state.accounts[0].deletedAt = .now
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        do {
            _ = try await store.startPurchaseSession(session.id, activityStarter: FixedActivityStarter())
            XCTFail("Starting must reject a deleted payment account.")
        } catch { XCTAssertTrue(store.state.transactions.isEmpty) }
        session.status = .awaitingSummary
        for i in session.items.indices { session.items[i].isCompleted = true }
        store.savePurchaseSession(session)
        do {
            try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
            XCTFail("Finalization must reject a deleted payment account.")
        } catch {
            XCTAssertTrue(store.state.transactions.isEmpty)
        }
        XCTAssertEqual(store.purchaseSessions.first?.accountID, state.accounts[0].id)
    }

    func testStartPurchaseSucceedsAndWarnsWhenSharedStorageIsUnavailable() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let session = makeSession(accountID: state.accounts[0].id)
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        let outcome = try await store.startPurchaseSession(session.id, activityStarter: bridgeUnavailableStarter)
        XCTAssertFalse(outcome.interactive)
        XCTAssertNotNil(outcome.warning)
        // The purchase itself succeeded: active, persisted and never a fatal error.
        XCTAssertEqual(store.purchaseSessions.first?.status, .active)
        XCTAssertNotNil(store.purchaseSessions.first?.startedAt)
        XCTAssertNil(store.presentedError)
        XCTAssertEqual(store.purchaseSyncWarning, outcome.warning)
        XCTAssertTrue(store.state.transactions.isEmpty)
    }

    func testItemCompletionIsLocalFirstAndSurvivesBridgeFailure() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        var session = makeSession(accountID: state.accounts[0].id)
        session.status = .active
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        let item = try XCTUnwrap(session.items.first)

        let updated = try XCTUnwrap(store.setPurchaseItem(item.id, in: session.id, completed: true))
        XCTAssertEqual(updated.items.first(where: { $0.id == item.id })?.isCompleted, true)
        // A non-final item must never leave the active state.
        XCTAssertEqual(updated.status, .active)
        XCTAssertEqual(store.purchaseSessions.first?.status, .active)
        XCTAssertNil(store.presentedError)
        XCTAssertNil(store.purchaseSyncWarning)

        let outcome = await store.publishPurchase(sessionID: session.id, activityStarter: bridgeUnavailableStarter)
        XCTAssertEqual(outcome?.interactive, false)
        // No rollback, no status change, no fatal error.
        XCTAssertEqual(store.purchaseSessions.first?.items.first(where: { $0.id == item.id })?.isCompleted, true)
        XCTAssertEqual(store.purchaseSessions.first?.status, .active)
        XCTAssertNil(store.presentedError)
        XCTAssertEqual(store.purchaseSyncWarning, outcome?.warning)
    }

    func testBridgeNoticeIsShownOnceAndStaysDismissedUntilTheBridgeChanges() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        var session = makeSession(accountID: state.accounts[0].id)
        session.status = .active
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)

        _ = await store.publishPurchase(sessionID: session.id, activityStarter: bridgeUnavailableStarter)
        XCTAssertEqual(store.purchaseSyncWarning, bridgeUnavailableStarter.warning)

        // Repeating the same bridge failure must not re-announce itself.
        _ = await store.publishPurchase(sessionID: session.id, activityStarter: bridgeUnavailableStarter)
        XCTAssertEqual(store.purchaseSyncWarning, bridgeUnavailableStarter.warning)

        // Dismissing the notice keeps it dismissed for the current purchase.
        store.dismissPurchaseSyncWarning()
        XCTAssertNil(store.purchaseSyncWarning)
        _ = await store.publishPurchase(sessionID: session.id, activityStarter: bridgeUnavailableStarter)
        XCTAssertNil(store.purchaseSyncWarning, "A dismissed bridge notice must not reappear on the next item tap.")

        // A working bridge clears the notice and the dismissal, so a later failure is reported again.
        let active = try XCTUnwrap(store.purchaseSessions.first)
        _ = await store.publish(session: active, requestActivity: false,
                                activityStarter: FixedActivityStarter(activity: .updated, interactive: true, warning: nil))
        XCTAssertNil(store.purchaseSyncWarning)
        _ = await store.publishPurchase(sessionID: session.id, activityStarter: bridgeUnavailableStarter)
        XCTAssertEqual(store.purchaseSyncWarning, bridgeUnavailableStarter.warning)
    }

    func testOnlyTheFinalItemLeavesTheActiveState() throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        var session = makeSession(accountID: state.accounts[0].id)
        session.status = .active
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        let ids = session.items.map(\.id)

        let first = try XCTUnwrap(store.setPurchaseItem(ids[0], in: session.id, completed: true))
        XCTAssertEqual(first.completedItemCount, 1)
        XCTAssertEqual(first.status, .active)

        let second = try XCTUnwrap(store.setPurchaseItem(ids[1], in: session.id, completed: true))
        XCTAssertEqual(second.completedItemCount, 2)
        XCTAssertEqual(second.status, .active)

        let third = try XCTUnwrap(store.setPurchaseItem(ids[2], in: session.id, completed: true))
        XCTAssertEqual(third.completedItemCount, 3)
        XCTAssertEqual(third.status, .awaitingSummary)

        // Unchecking the final item returns the list to active.
        let reverted = try XCTUnwrap(store.setPurchaseItem(ids[2], in: session.id, completed: false))
        XCTAssertEqual(reverted.completedItemCount, 2)
        XCTAssertEqual(reverted.status, .active)
    }

    func testBridgeFailureNeverAltersFinalItemTransitions() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        var session = makeSession(accountID: state.accounts[0].id)
        session.status = .active
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        let ids = session.items.map(\.id)
        for (index, id) in ids.enumerated() {
            _ = store.setPurchaseItem(id, in: session.id, completed: true)
            _ = await store.publishPurchase(sessionID: session.id, activityStarter: bridgeUnavailableStarter)
            let expected: PurchaseSessionStatus = index == ids.count - 1 ? .awaitingSummary : .active
            XCTAssertEqual(store.purchaseSessions.first?.status, expected)
            XCTAssertEqual(store.purchaseSessions.first?.completedItemCount, index + 1)
        }
        XCTAssertNil(store.presentedError)
    }

    func testControllerSurfacesThrownRequestError() async {
        var session = makeSession(accountID: UUID())
        session.status = .active
        let controller = PurchaseLiveActivityController(
            snapshotWriter: { _, _ in }, // The App Group bridge succeeds.
            activitiesEnabled: { true },
            requestActivity: { _, _ in throw NSError(domain: "ActivityKit.Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test rejection"]) })
        let outcome = await controller.start(session: session)

        // The ActivityKit request failure is the primary result.
        guard case .requestFailed(let detail) = outcome.activity else {
            return XCTFail("A thrown request must surface as requestFailed, got \(outcome.activity)")
        }
        XCTAssertTrue(detail.contains("ActivityKit.Test"))
        XCTAssertTrue(detail.contains("42"))
        XCTAssertTrue(detail.contains("Test rejection"))

        // A failed Activity.request says nothing about the bridge, which succeeded here.
        XCTAssertTrue(outcome.interactive)

        // The ActivityKit failure is intentionally surfaced a second time as a nonfatal warning.
        let warning = outcome.warning ?? ""
        XCTAssertNotNil(outcome.warning)
        XCTAssertTrue(warning.contains("Live Activity could not start"))
        XCTAssertTrue(warning.contains("ActivityKit.Test"))
        XCTAssertTrue(warning.contains("42"))
        XCTAssertTrue(warning.contains("Test rejection"))
    }

    func testControllerStillRequestsActivityWhenSharedStateIsUnavailable() async {
        var session = makeSession(accountID: UUID())
        session.status = .active
        let controller = PurchaseLiveActivityController(
            snapshotWriter: { _, _ in throw PurchaseSharedStateError.appGroupUnavailable },
            activitiesEnabled: { true },
            requestActivity: { _, _ in "probe-activity" })
        let outcome = await controller.start(session: session)
        guard case .started(let activityID) = outcome.activity else {
            return XCTFail("A successful Activity.request must not be hidden by an App Group failure: \(outcome)")
        }
        XCTAssertEqual(activityID, "probe-activity")
        XCTAssertFalse(outcome.interactive)
        XCTAssertEqual(outcome.warning, "Lock Screen item controls require a signed build with App Group access.")
    }

    func testControllerKeepsRequestFailureVisibleAlongsideBridgeFailure() async {
        var session = makeSession(accountID: UUID())
        session.status = .active
        let controller = PurchaseLiveActivityController(
            snapshotWriter: { _, _ in throw PurchaseSharedStateError.appGroupUnavailable },
            activitiesEnabled: { true },
            requestActivity: { _, _ in throw NSError(domain: "ActivityKit.Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "denied"]) })
        let outcome = await controller.start(session: session)
        guard case .requestFailed(let detail) = outcome.activity else { return XCTFail("Expected requestFailed, got \(outcome)") }
        XCTAssertTrue(detail.contains("ActivityKit.Test"))
        XCTAssertTrue(detail.contains("denied"))
        XCTAssertFalse(outcome.interactive)
        XCTAssertTrue((outcome.warning ?? "").contains("App Group access"))
        XCTAssertTrue((outcome.warning ?? "").contains("Live Activity could not start"))
    }

    func testControllerReportsDisabledLiveActivitiesAsNonfatalWarning() async {
        var session = makeSession(accountID: UUID())
        session.status = .active
        let controller = PurchaseLiveActivityController(snapshotWriter: { _, _ in }, activitiesEnabled: { false }, requestActivity: { _, _ in "unused" })
        let outcome = await controller.start(session: session)
        XCTAssertEqual(outcome.activity, .liveActivitiesDisabled)
        XCTAssertTrue((outcome.warning ?? "").contains("Live Activities are disabled"))
        XCTAssertTrue(outcome.interactive)
    }

    func testControllerPublishesInteractivityAndCategoryColors() async {
        var session = makeSession(accountID: UUID(), currency: .USDT)
        session.status = .active
        session.items[0].isCompleted = true
        session.normalizeSections()
        let box = ContentStateBox()
        let controller = PurchaseLiveActivityController(
            snapshotWriter: { _, _ in },
            activitiesEnabled: { true },
            requestActivity: { _, state in box.state = state; return "activity" })
        _ = await controller.start(session: session, categoryColors: ["food": "F05E4F"])
        let published = box.state
        XCTAssertEqual(published?.interactiveCompletionAvailable, true)
        XCTAssertEqual(published?.completedItemCount, 1)
        XCTAssertEqual(published?.totalItemCount, 3)
        XCTAssertEqual(published?.nextItems.map(\.name), ["Bread", "Train"])
        XCTAssertEqual(published?.nextItems.first?.categoryColorHex, "F05E4F")
    }

    func testOldDevelopmentPurchaseDecodesAndMigratesWithinSchemaTwo() throws {
        var state = DemoDataFactory.makeWithSingleAccount()
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

    func testSharedSnapshotAdoptionRequiresStrictlyNewerTimestamp() {
        var local = makeSession(accountID: UUID())
        local.updatedAt = Date(timeIntervalSince1970: 1000.5)
        let newer = PurchaseSharedSnapshot(session: local, currencyCode: local.currency, updatedAt: Date(timeIntervalSince1970: 1000.75))
        XCTAssertTrue(PurchaseRules.shouldAdoptSharedSnapshot(newer, over: local), "Subsecond-newer snapshots must win.")
        let equal = PurchaseSharedSnapshot(session: local, currencyCode: local.currency, updatedAt: Date(timeIntervalSince1970: 1000.5))
        XCTAssertFalse(PurchaseRules.shouldAdoptSharedSnapshot(equal, over: local))
        let older = PurchaseSharedSnapshot(session: local, currencyCode: local.currency, updatedAt: Date(timeIntervalSince1970: 1000.25))
        XCTAssertFalse(PurchaseRules.shouldAdoptSharedSnapshot(older, over: local), "An older snapshot must never overwrite newer local state.")
    }

    func testSharedSnapshotAdoptionRequiresMatchingPaymentIdentity() {
        var local = makeSession(accountID: UUID())
        local.updatedAt = Date(timeIntervalSince1970: 1000)
        var otherAccount = local
        otherAccount.accountID = UUID()
        XCTAssertFalse(PurchaseRules.shouldAdoptSharedSnapshot(.init(session: otherAccount, currencyCode: otherAccount.currency, updatedAt: Date(timeIntervalSince1970: 2000)), over: local))
        var otherCurrency = local
        otherCurrency.currency = .EUR
        XCTAssertFalse(PurchaseRules.shouldAdoptSharedSnapshot(.init(session: otherCurrency, currencyCode: .EUR, updatedAt: Date(timeIntervalSince1970: 2000)), over: local))
    }

    func testReconcileMergesLockScreenCompletionsWithoutLosingOrder() throws {
        try XCTSkipUnless(PurchaseSharedStateStore.availability().isAvailable, "App Group container is unavailable in this environment")
        defer { try? PurchaseSharedStateStore.resetLocalSnapshots() }
        var state = DemoDataFactory.makeWithSingleAccount()
        var session = makeSession(accountID: state.accounts[0].id)
        session.status = .active
        session.updatedAt = Date(timeIntervalSince1970: 1000)
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        let firstID = session.items[0].id, secondID = session.items[1].id

        // Two Lock Screen / Dynamic Island completions arrive through the bridge.
        try PurchaseSharedStateStore.write(session: session)
        _ = try PurchaseSharedStateStore.updateItem(sessionID: session.id, itemID: firstID, completed: true)
        _ = try PurchaseSharedStateStore.updateItem(sessionID: session.id, itemID: secondID, completed: true)

        XCTAssertTrue(store.reconcileSharedActivePurchases())
        let merged = try XCTUnwrap(store.purchaseSessions.first)
        XCTAssertTrue(merged.items.first { $0.id == firstID }?.isCompleted == true)
        XCTAssertTrue(merged.items.first { $0.id == secondID }?.isCompleted == true)
        XCTAssertEqual(merged.status, .active, "One item is still open, so the list stays active.")
        XCTAssertEqual(merged.orderedItems.map(\.note), ["Milk", "Bread", "Train"], "Ordering and grouping must survive reconciliation.")

        // Nothing new in the bridge: reconciliation must be a no-op.
        XCTAssertFalse(store.reconcileSharedActivePurchases())
        XCTAssertEqual(store.purchaseSessions.first?.completedItemCount, 2)
    }

    func testOlderSharedSnapshotCannotOverwriteNewerLocalSession() throws {
        try XCTSkipUnless(PurchaseSharedStateStore.availability().isAvailable, "App Group container is unavailable in this environment")
        defer { try? PurchaseSharedStateStore.resetLocalSnapshots() }
        var state = DemoDataFactory.makeWithSingleAccount()
        var session = makeSession(accountID: state.accounts[0].id)
        session.status = .active
        session.updatedAt = Date(timeIntervalSince1970: 1000)
        state.purchaseSessions = [session]
        let store = LedgerStore(stateForTesting: state)
        // The bridge still holds the older, fully incomplete session.
        try PurchaseSharedStateStore.write(session: session)
        // The app then completes an item locally with a newer timestamp.
        XCTAssertNotNil(store.setPurchaseItem(session.items[0].id, in: session.id, completed: true))
        XCTAssertFalse(store.reconcileSharedActivePurchases(), "A stale bridge snapshot must not be adopted.")
        XCTAssertEqual(store.purchaseSessions.first?.completedItemCount, 1)
    }

    func testAppGroupDiagnosticsReportRuntimeStateAndLeaveNoProbeFiles() {
        let diagnostics = PurchaseSharedStateStore.diagnostics()
        XCTAssertEqual(diagnostics.appGroupIdentifier, "group.com.finsy.app")
        XCTAssertFalse(diagnostics.report.isEmpty)
        if diagnostics.containerReachable {
            XCTAssertTrue(diagnostics.wroteProbeFile)
            XCTAssertTrue(diagnostics.readProbeFile)
            XCTAssertTrue(diagnostics.removedProbeFile, "Diagnostic probe files must never be kept.")
            XCTAssertEqual(diagnostics.state, .available)
        } else {
            XCTAssertEqual(diagnostics.state, .containerUnavailable)
            XCTAssertFalse(diagnostics.wroteProbeFile)
        }
        XCTAssertEqual(PurchaseSharedStateStore.supportsInteractiveCompletion, PurchaseSharedStateStore.availability().isAvailable)
        XCTAssertNil(PurchaseSharedContainerState.available.warning)
        XCTAssertNotNil(PurchaseSharedContainerState.containerUnavailable.warning)
    }

    func testFinalizePurchaseWithValidLinkedItemSucceeds() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        var session = makeSession(accountID: accountID, currency: .HKD)
        session.status = .awaitingSummary
        for i in session.items.indices {
            session.items[i].isCompleted = true
            session.items[i].completedAt = .now
        }

        let item0 = session.items[0]
        let txA = LedgerTransaction(
            id: UUID(), userID: SeedData.localUserID, type: .expense, accountID: accountID,
            destinationAccountID: nil, amount: item0.amount, currency: .HKD, accountAmount: item0.amount,
            destinationAmount: nil, categoryID: item0.categoryID, occurredAt: .now, note: item0.note,
            exchangeRateAtTransaction: 1.0, purchaseSessionID: session.id, purchaseItemID: item0.id,
            createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        state.transactions = [txA]
        session.items[0].linkedTransactionID = txA.id
        state.purchaseSessions = [session]

        let store = LedgerStore(stateForTesting: state)
        try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)

        let completedSession = try XCTUnwrap(store.purchaseSessions.first)
        XCTAssertEqual(completedSession.status, .completed)
        XCTAssertEqual(completedSession.items[0].linkedTransactionID, txA.id)
        XCTAssertEqual(store.state.transactions.count, 3)
        XCTAssertEqual(store.state.transactions.filter { $0.id == txA.id }.count, 1)
    }

    func testFinalizePurchaseWithDuplicateTransactionForLinkedItemThrows() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        var session = makeSession(accountID: accountID, currency: .HKD)
        session.status = .awaitingSummary
        for i in session.items.indices {
            session.items[i].isCompleted = true
            session.items[i].completedAt = .now
        }

        let item0 = session.items[0]
        let txA = LedgerTransaction(
            id: UUID(), userID: SeedData.localUserID, type: .expense, accountID: accountID,
            destinationAccountID: nil, amount: item0.amount, currency: .HKD, accountAmount: item0.amount,
            destinationAmount: nil, categoryID: item0.categoryID, occurredAt: .now, note: item0.note,
            exchangeRateAtTransaction: 1.0, purchaseSessionID: session.id, purchaseItemID: item0.id,
            createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        let txB = LedgerTransaction(
            id: UUID(), userID: SeedData.localUserID, type: .expense, accountID: accountID,
            destinationAccountID: nil, amount: item0.amount, currency: .HKD, accountAmount: item0.amount,
            destinationAmount: nil, categoryID: item0.categoryID, occurredAt: .now, note: "Duplicate",
            exchangeRateAtTransaction: 1.0, purchaseSessionID: session.id, purchaseItemID: item0.id,
            createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        state.transactions = [txA, txB]
        session.items[0].linkedTransactionID = txA.id
        state.purchaseSessions = [session]

        let store = LedgerStore(stateForTesting: state)
        let initialTxCount = store.state.transactions.count

        do {
            try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
            XCTFail("Must throw inconsistentPurchaseData when duplicate matching transaction exists for linked item")
        } catch let error as PurchaseFinalizationError {
            XCTAssertEqual(error, .inconsistentPurchaseData)
        }
        XCTAssertEqual(store.state.transactions.count, initialTxCount)
        XCTAssertEqual(store.purchaseSessions.first?.status, .awaitingSummary)
    }

    func testFinalizePurchaseAdoptsSingleUnlinkedTransaction() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        var session = makeSession(accountID: accountID, currency: .HKD)
        session.status = .awaitingSummary
        for i in session.items.indices {
            session.items[i].isCompleted = true
            session.items[i].completedAt = .now
        }

        let item0 = session.items[0]
        let txA = LedgerTransaction(
            id: UUID(), userID: SeedData.localUserID, type: .expense, accountID: accountID,
            destinationAccountID: nil, amount: item0.amount, currency: .HKD, accountAmount: item0.amount,
            destinationAmount: nil, categoryID: item0.categoryID, occurredAt: .now, note: item0.note,
            exchangeRateAtTransaction: 1.0, purchaseSessionID: session.id, purchaseItemID: item0.id,
            createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        state.transactions = [txA]
        session.items[0].linkedTransactionID = nil
        state.purchaseSessions = [session]

        let store = LedgerStore(stateForTesting: state)
        try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)

        let completedSession = try XCTUnwrap(store.purchaseSessions.first)
        XCTAssertEqual(completedSession.status, .completed)
        XCTAssertEqual(completedSession.items[0].linkedTransactionID, txA.id)
        XCTAssertEqual(store.state.transactions.count, 3)
    }

    func testFinalizePurchaseWithMultipleTransactionsForUnlinkedItemThrows() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        var session = makeSession(accountID: accountID, currency: .HKD)
        session.status = .awaitingSummary
        for i in session.items.indices {
            session.items[i].isCompleted = true
            session.items[i].completedAt = .now
        }

        let item0 = session.items[0]
        let txA = LedgerTransaction(
            id: UUID(), userID: SeedData.localUserID, type: .expense, accountID: accountID,
            destinationAccountID: nil, amount: item0.amount, currency: .HKD, accountAmount: item0.amount,
            destinationAmount: nil, categoryID: item0.categoryID, occurredAt: .now, note: item0.note,
            exchangeRateAtTransaction: 1.0, purchaseSessionID: session.id, purchaseItemID: item0.id,
            createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        let txB = LedgerTransaction(
            id: UUID(), userID: SeedData.localUserID, type: .expense, accountID: accountID,
            destinationAccountID: nil, amount: item0.amount, currency: .HKD, accountAmount: item0.amount,
            destinationAmount: nil, categoryID: item0.categoryID, occurredAt: .now, note: "Duplicate Unlinked",
            exchangeRateAtTransaction: 1.0, purchaseSessionID: session.id, purchaseItemID: item0.id,
            createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        state.transactions = [txA, txB]
        session.items[0].linkedTransactionID = nil
        state.purchaseSessions = [session]

        let store = LedgerStore(stateForTesting: state)
        let initialTxCount = store.state.transactions.count

        do {
            try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
            XCTFail("Must throw inconsistentPurchaseData when multiple matching transactions exist for unlinked item")
        } catch let error as PurchaseFinalizationError {
            XCTAssertEqual(error, .inconsistentPurchaseData)
        }
        XCTAssertEqual(store.state.transactions.count, initialTxCount)
        XCTAssertEqual(store.purchaseSessions.first?.status, .awaitingSummary)
    }

    func testFinalizePurchaseWithOrphanedSessionTransactionThrows() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        var session = makeSession(accountID: accountID, currency: .HKD)
        session.status = .awaitingSummary
        for i in session.items.indices {
            session.items[i].isCompleted = true
            session.items[i].completedAt = .now
        }

        let orphanTx = LedgerTransaction(
            id: UUID(), userID: SeedData.localUserID, type: .expense, accountID: accountID,
            destinationAccountID: nil, amount: 50, currency: .HKD, accountAmount: 50,
            destinationAmount: nil, categoryID: .other, occurredAt: .now, note: "Removed item",
            exchangeRateAtTransaction: 1.0, purchaseSessionID: session.id, purchaseItemID: UUID(),
            createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending
        )
        state.transactions = [orphanTx]
        state.purchaseSessions = [session]

        let store = LedgerStore(stateForTesting: state)
        let initialTxCount = store.state.transactions.count

        do {
            try await store.finalizePurchaseSession(session.id, receiptAttachmentID: nil)
            XCTFail("Must throw inconsistentPurchaseData when transaction references an item no longer in session")
        } catch let error as PurchaseFinalizationError {
            XCTAssertEqual(error, .inconsistentPurchaseData)
        }
        XCTAssertEqual(store.state.transactions.count, initialTxCount)
        XCTAssertEqual(store.purchaseSessions.first?.status, .awaitingSummary)
    }

    private func makeSession(accountID: UUID, currency: CurrencyCode = .USD) -> PurchaseSession {
        .init(id: UUID(), ledgerBookID: UUID(), name: "Shopping", status: .draft, sections: [], items: [
            .init(id: UUID(), categoryID: .food, note: "Milk", amount: 10, displayOrder: 0, isCompleted: false, completedAt: nil, linkedTransactionID: nil),
            .init(id: UUID(), categoryID: .food, note: "Bread", amount: 20, displayOrder: 1, isCompleted: false, completedAt: nil, linkedTransactionID: nil),
            .init(id: UUID(), categoryID: .transport, note: "Train", amount: 70, displayOrder: 2, isCompleted: false, completedAt: nil, linkedTransactionID: nil)
        ], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil, currency: currency, accountID: accountID)
    }
}
