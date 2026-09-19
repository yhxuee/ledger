import XCTest
import CloudKit
@testable import WalletLedger

@MainActor
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

    func testPortfolioSummarySeparatesAssetsAndLiabilities() {
        var state = SeedData.make()
        state.transactions = []
        let expected = state.accounts.reduce(into: (assets: 0.0, liabilities: 0.0)) { result, account in
            let value = LedgerCalculations.convert(account.openingBalance, from: account.currency, to: state.settings.baseCurrency, rates: state.settings.rates)
            if value >= 0 { result.assets += value } else { result.liabilities += abs(value) }
        }
        let summary = LedgerCalculations.portfolioSummary(state)
        XCTAssertEqual(summary.assets, expected.assets, accuracy: 0.001)
        XCTAssertEqual(summary.liabilities, expected.liabilities, accuracy: 0.001)
        XCTAssertEqual(summary.netWorth, expected.assets - expected.liabilities, accuracy: 0.001)
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
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"HKD\""), "Currency-keyed rate dictionaries must remain compatible with v1 JSON objects.")
    }

    func testCurrencyCatalogueIsFlexibleAndComplete() {
        XCTAssertGreaterThan(CurrencyCode.allCases.count, 150)
        XCTAssertEqual(CurrencyCode(rawValue: "aed")?.rawValue, "AED")
        XCTAssertNotNil(CurrencyCode(rawValue: "ZWG"))
        XCTAssertEqual(CurrencyCode(rawValue: "XYZ")?.rawValue, "XYZ", "Valid ISO-style identifiers must survive even when absent from the bundled catalogue.")
        XCTAssertNil(CurrencyCode(rawValue: "NOT_A_CURRENCY"))
    }

    func testNativeV1BackupMigratesToV2WithoutChangingHistoricalFX() throws {
        let current = SeedData.make()
        let oldSettings = LedgerSettingsV1(
            userID: current.settings.userID,
            baseCurrency: current.settings.baseCurrency,
            rates: current.settings.rates,
            automaticRates: true,
            backupReminders: current.settings.backupReminders,
            lastBackupAt: current.settings.lastBackupAt,
            updatedAt: current.settings.updatedAt,
            exchangeRatesUpdatedAt: .now
        )
        let oldState = LedgerStateV1(schemaVersion: 1, accounts: current.accounts, transactions: current.transactions, categories: current.categories, settings: oldSettings, recurringRules: current.recurringRules)
        let oldEnvelope = LedgerBackupEnvelopeV1(
            metadata: .init(app: "wallet-ledger-ios", schemaVersion: 1, exportedAt: .now, userID: oldSettings.userID, accountCount: oldState.accounts.count, transactionCount: oldState.transactions.count, categoryCount: oldState.categories.count, baseCurrency: oldSettings.baseCurrency),
            data: oldState
        )
        let data = try BackupCodec.encoder().encode(oldEnvelope)
        let migrated = try BackupCodec.decode(data, sourceName: "v1.walletledger").envelope.data

        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.transactions.map(\.exchangeRateAtTransaction), oldState.transactions.map(\.exchangeRateAtTransaction))
        XCTAssertEqual(migrated.settings.rates, oldState.settings.rates)
        XCTAssertEqual(migrated.settings.budgetPlan.mode, .account)
        let expectedBudgetAccounts = Set(oldState.accounts.filter { $0.includeInBudget && $0.budget > 0 }.map(\.id))
        XCTAssertEqual(Set(migrated.settings.budgetPlan.accountAllocations.keys), expectedBudgetAccounts)
    }

    func testDevicePreferencesAreNotIncludedInLedgerBackup() throws {
        let data = try BackupCodec.encode(BackupCodec.envelope(for: SeedData.make()))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("biometricLockEnabled"))
        XCTAssertFalse(json.contains("hapticFeedbackEnabled"))
        XCTAssertFalse(json.contains("swipeActionOrientation"))
        XCTAssertFalse(json.contains("languageCode"))
    }

    func testExpenseRefundIsExactIdempotentAndReducesSpending() throws {
        var state = SeedData.make()
        let source = try XCTUnwrap(state.accounts.first)
        let expense = makeTransaction(type: .expense, source: source, amount: 100)
        state.transactions = [expense]
        let store = LedgerStore(stateForTesting: state)

        let refund = try XCTUnwrap(store.refundTransaction(expense))
        XCTAssertNil(store.refundTransaction(expense), "A second active refund must not be created.")
        XCTAssertEqual(refund.accountAmount, expense.accountAmount)
        XCTAssertEqual(LedgerCalculations.balance(for: source, in: store.state), source.openingBalance, accuracy: 0.001)
        XCTAssertEqual(LedgerCalculations.analytics(store.state, range: .week).total, 0, accuracy: 0.001)
        XCTAssertEqual(store.state.transactions.first(where: { $0.id == expense.id })?.reversalTransactionID, refund.id)
    }

    func testIncomeAndTransferReversalsRestoreExactAccountAmounts() throws {
        var state = SeedData.make()
        let source = try XCTUnwrap(state.accounts.first)
        let destination = try XCTUnwrap(state.accounts.first(where: { $0.currency == .USD }))

        let income = makeTransaction(type: .income, source: source, amount: 80)
        state.transactions = [income]
        var store = LedgerStore(stateForTesting: state)
        _ = try XCTUnwrap(store.refundTransaction(income))
        XCTAssertEqual(LedgerCalculations.balance(for: source, in: store.state), source.openingBalance, accuracy: 0.001)

        let transfer = LedgerTransaction(id: UUID(), userID: SeedData.localUserID, type: .transfer, accountID: source.id, destinationAccountID: destination.id, amount: 780, currency: .HKD, accountAmount: 780, destinationAmount: 100, categoryID: .other, occurredAt: .now, note: "FX transfer", exchangeRateAtTransaction: 1, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
        state.transactions = [transfer]
        store = LedgerStore(stateForTesting: state)
        let reversal = try XCTUnwrap(store.refundTransaction(transfer))
        XCTAssertEqual(reversal.accountID, destination.id)
        XCTAssertEqual(reversal.accountAmount, 100)
        XCTAssertEqual(reversal.destinationAmount, 780)
        XCTAssertEqual(LedgerCalculations.balance(for: source, in: store.state), source.openingBalance, accuracy: 0.001)
        XCTAssertEqual(LedgerCalculations.balance(for: destination, in: store.state), destination.openingBalance, accuracy: 0.001)
    }

    func testDeletingRefundRestoresOriginalRefundableStateAndUndoRestoresLink() throws {
        var state = SeedData.make()
        let source = try XCTUnwrap(state.accounts.first)
        let expense = makeTransaction(type: .expense, source: source, amount: 45)
        state.transactions = [expense]
        let store = LedgerStore(stateForTesting: state)
        let refund = try XCTUnwrap(store.refundTransaction(expense))

        store.deleteTransaction(refund)
        XCTAssertNil(store.state.transactions.first(where: { $0.id == expense.id })?.reversalTransactionID)
        XCTAssertNotNil(store.state.transactions.first(where: { $0.id == refund.id })?.deletedAt)
        XCTAssertEqual(LedgerCalculations.balance(for: source, in: store.state), source.openingBalance - 45, accuracy: 0.001)

        store.undoDelete()
        XCTAssertEqual(store.state.transactions.first(where: { $0.id == expense.id })?.reversalTransactionID, refund.id)
        XCTAssertNil(store.state.transactions.first(where: { $0.id == refund.id })?.deletedAt)
        XCTAssertEqual(LedgerCalculations.balance(for: source, in: store.state), source.openingBalance, accuracy: 0.001)
    }

    func testRecurringLoanInterestUsesCurrentOutstandingPrincipal() throws {
        var state = SeedData.makeEmpty()
        let accountID = state.accounts[0].id
        let ruleID = UUID()
        state.accounts[0].type = .loan
        state.accounts[0].openingBalance = -12_000
        state.accounts[0].loanMetadata = .init(annualPercentageRate: 12, interestInterval: .monthly, customIntervalDays: 30, linkedRecurringRuleID: ruleID)
        state.recurringRules = [
            .init(id: ruleID, userID: state.settings.userID, type: .expense, accountID: accountID, destinationAccountID: nil, amount: 0, amountKind: .loanInterest, linkedLoanAccountID: accountID, currency: .HKD, categoryID: .other, note: "Loan Interest", interval: .monthly, customIntervalDays: 30, nextRunAt: .now, isEnabled: true, createdAt: .now, updatedAt: .now)
        ]
        let store = LedgerStore(stateForTesting: state)
        store.processDueRecurring(now: .now.addingTimeInterval(1))
        let interest = try XCTUnwrap(store.state.transactions.first)
        XCTAssertEqual(interest.amount, 120, accuracy: 0.001)
        XCTAssertEqual(LedgerCalculations.balance(for: store.state.accounts[0], in: store.state), -12_120, accuracy: 0.001)
    }

    func testLegacyWebBackupConversionPreservesHistoricalAmountAndRate() throws {
        let json = """
        {"metadata":{"app":"wallet-ledger-overview","schemaVersion":1,"exportedAt":"2025-01-01T00:00:00Z","userId":"legacy-user"},"data":{"accounts":[{"id":"account-a","name":"Cash","type":"checking","currency":"USD","openingBalance":500,"budget":200,"includeInBudget":true,"logo":"CA","cardStyle":{"start":"#111111","end":"#222222"}}],"transactions":[{"id":"transaction-a","type":"expense","accountId":"account-a","amount":12.5,"currency":"EUR","accountAmount":13.75,"categoryId":"food","date":"2025-01-02","time":"12:30","note":"Lunch","exchangeRateAtTransaction":8.25}],"categories":[],"settings":{"userId":"legacy-user","baseCurrency":"USD","rates":{"USD":7.8,"EUR":8.25},"automaticRates":false,"backupEnabled":true}}}
        """
        let preview = try BackupCodec.decode(Data(json.utf8), sourceName: "legacy.json")
        let transaction = try XCTUnwrap(preview.envelope.data.transactions.first)
        XCTAssertEqual(preview.envelope.data.schemaVersion, 2)
        XCTAssertEqual(transaction.amount, 12.5)
        XCTAssertEqual(transaction.accountAmount, 13.75)
        XCTAssertEqual(transaction.exchangeRateAtTransaction, 8.25)
    }

    func testCategoryBudgetCountsRefundAndIgnoresDeletedTransactions() throws {
        var state = SeedData.makeEmpty()
        let account = state.accounts[0]
        state.settings.budgetPlan = .init(mode: .category, categoryAllocations: [.food: 500, .transport: 300], accountAllocations: [:], updatedAt: .now)
        let food = makeTransaction(type: .expense, source: account, amount: 120)
        var deleted = makeTransaction(type: .expense, source: account, amount: 80)
        deleted.deletedAt = .now
        state.transactions = [food, deleted]
        let store = LedgerStore(stateForTesting: state)
        _ = try XCTUnwrap(store.refundTransaction(food))
        let detail = LedgerCalculations.budgetBreakdown(store.state)
        XCTAssertEqual(detail.budget, 800, accuracy: 0.001)
        XCTAssertEqual(detail.spent, 0, accuracy: 0.001)
        XCTAssertEqual(detail.lines.count, 2)
    }

    func testAccountBudgetConvertsEachAccountsCurrency() throws {
        var state = SeedData.make()
        state.transactions = []
        let hkd = try XCTUnwrap(state.accounts.first(where: { $0.currency == .HKD }))
        let usd = try XCTUnwrap(state.accounts.first(where: { $0.currency == .USD }))
        state.settings.budgetPlan = .init(mode: .account, categoryAllocations: [:], accountAllocations: [hkd.id: 100, usd.id: 100], updatedAt: .now)
        state.transactions = [makeTransaction(type: .expense, source: hkd, amount: 20), makeTransaction(type: .expense, source: usd, amount: 10)]
        let detail = LedgerCalculations.budgetBreakdown(state)
        XCTAssertEqual(detail.budget, 880, accuracy: 0.001)
        XCTAssertEqual(detail.spent, 98, accuracy: 0.001)
    }

    func testDeletingAccountInvalidatesDefaultExpenseMapping() throws {
        var state = SeedData.makeEmpty()
        let account = state.accounts[0]
        state.settings.defaultExpenseAccountByCategory[.food] = account.id
        let store = LedgerStore(stateForTesting: state)
        store.deleteAccount(account)
        XCTAssertNil(store.state.settings.defaultExpenseAccountByCategory[.food])
        store.undoDelete()
        XCTAssertEqual(store.state.settings.defaultExpenseAccountByCategory[.food], account.id)
        XCTAssertNil(store.state.accounts.first(where: { $0.id == account.id })?.deletedAt)
    }

    func testDeletingRecurringRuleUsesTombstoneAndUndo() throws {
        var state = SeedData.makeEmpty()
        let account = state.accounts[0]
        let rule = RecurringRule(id: UUID(), userID: state.settings.userID, type: .expense, accountID: account.id, destinationAccountID: nil, amount: 12, currency: account.currency, categoryID: .food, note: "Subscription", interval: .monthly, customIntervalDays: 30, nextRunAt: .now, isEnabled: true, createdAt: .now, updatedAt: .now)
        state.recurringRules = [rule]
        let store = LedgerStore(stateForTesting: state)
        store.deleteRecurringRule(rule)
        XCTAssertTrue(store.recurringRules.isEmpty)
        XCTAssertNotNil(store.state.recurringRules?.first?.deletedAt)
        store.undoDelete()
        XCTAssertEqual(store.recurringRules.map(\.id), [rule.id])
    }

    func testPurchaseFinalizationCreatesOnlyChildTransactionsAndIsIdempotent() throws {
        var state = SeedData.makeEmpty()
        let accountID = state.accounts[0].id
        let sessionID = UUID()
        let items = [
            PurchaseItem(id: UUID(), categoryID: .food, note: "Fruit", amount: 30, displayOrder: 0, isCompleted: true, completedAt: .now, resolvedAccountID: accountID, linkedTransactionID: nil),
            PurchaseItem(id: UUID(), categoryID: .shopping, note: "Soap", amount: 20, displayOrder: 1, isCompleted: true, completedAt: .now, resolvedAccountID: accountID, linkedTransactionID: nil)
        ]
        state.purchaseSessions = [.init(id: sessionID, ledgerBookID: UUID(), name: "Groceries", status: .awaitingSummary, sections: [], items: items, createdAt: .now, startedAt: .now, completedAt: .now, receiptAttachmentID: nil)]
        let store = LedgerStore(stateForTesting: state)
        try store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        try store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        XCTAssertEqual(store.state.transactions.count, 2)
        XCTAssertTrue(store.state.transactions.allSatisfy { $0.purchaseSessionID == sessionID })
        XCTAssertEqual(LedgerCalculations.analytics(store.state, range: .week).total, 50, accuracy: 0.001)
    }

    func testPurchasePresentationExpandsChildrenWhenFiltering() throws {
        var state = SeedData.makeEmpty()
        let account = state.accounts[0]
        let sessionID = UUID()
        var first = makeTransaction(type: .expense, source: account, amount: 10)
        var second = makeTransaction(type: .expense, source: account, amount: 20)
        first.purchaseSessionID = sessionID; second.purchaseSessionID = sessionID
        let session = PurchaseSession(id: sessionID, ledgerBookID: UUID(), name: "Shop", status: .completed, sections: [], items: [], createdAt: .now, startedAt: .now, completedAt: .now, receiptAttachmentID: nil)
        let collapsed = PurchaseLedgerPresentation.entries(transactions: [first, second], sessions: [session], collapsePurchases: true)
        let filtered = PurchaseLedgerPresentation.entries(transactions: [first], sessions: [session], collapsePurchases: false)
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(filtered, [.transaction(first)])
    }

    func testCloudKitRecordMappingRoundTripWithoutNetwork() throws {
        let state = SeedData.make()
        let book = LedgerBook(id: UUID(), name: "Shared Ledger", state: state, createdAt: .now, updatedAt: .now)
        let records = try CloudRecordMapper.records(for: book)
        XCTAssertEqual(records.filter { $0.recordType == CloudRecordType.transaction }.count, state.transactions.count)
        XCTAssertNotNil(records.first(where: { $0.recordType == CloudRecordType.budget }))
        let decoded = try CloudRecordMapper.decodeBook(from: records, participant: false)
        XCTAssertEqual(decoded.id, book.id)
        XCTAssertEqual(decoded.state.accounts, state.accounts)
        XCTAssertEqual(decoded.state.transactions, state.transactions)
        XCTAssertEqual(decoded.effectiveStorageKind, .cloudOwner)
    }

    private func makeTransaction(type: LedgerTransactionType, source: LedgerAccount, destination: LedgerAccount? = nil, amount: Double) -> LedgerTransaction {
        .init(id: UUID(), userID: SeedData.localUserID, type: type, accountID: source.id, destinationAccountID: destination?.id, amount: amount, currency: source.currency, accountAmount: amount, destinationAmount: destination == nil ? nil : amount, categoryID: .food, occurredAt: .now, note: nil, exchangeRateAtTransaction: SeedData.rates[source.currency] ?? 1, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
    }
}
