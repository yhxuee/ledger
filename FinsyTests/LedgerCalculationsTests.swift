import XCTest
import CloudKit
@testable import Finsy

@MainActor
final class LedgerCalculationsTests: XCTestCase {
    func testExpenseIncomeAndTransferAffectBalancesOnce() throws {
        var state = SeedData.make()
        state.accounts[0].isMultiCurrency = false
        state.accounts[0].currencyPockets = []
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
        state.accounts[0].isMultiCurrency = false
        state.accounts[0].currencyPockets = []
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
        state.accounts[0].isMultiCurrency = false
        state.accounts[0].currencyPockets = []
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
        // Native backup dates are ISO-8601 seconds; compare the complete serialized finance models.
        XCTAssertEqual(try BackupCodec.encoder().encode(decoded.envelope.data.recurringRules), try BackupCodec.encoder().encode(state.recurringRules))
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

        XCTAssertEqual(migrated.schemaVersion, BackupCodec.currentSchemaVersion)
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
        state.accounts[0].isMultiCurrency = false
        state.accounts[0].currencyPockets = []
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
        state.accounts[0].isMultiCurrency = false
        state.accounts[0].currencyPockets = []
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
        state.accounts[0].isMultiCurrency = false
        state.accounts[0].currencyPockets = []
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
        var state = DemoDataFactory.makeWithSingleAccount()
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
        XCTAssertEqual(preview.envelope.data.schemaVersion, BackupCodec.currentSchemaVersion)
        XCTAssertEqual(transaction.amount, 12.5)
        XCTAssertEqual(transaction.accountAmount, 13.75)
        XCTAssertEqual(transaction.exchangeRateAtTransaction, 8.25)
    }

    func testCategoryBudgetCountsRefundAndIgnoresDeletedTransactions() throws {
        var state = DemoDataFactory.makeWithSingleAccount()
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
        var state = DemoDataFactory.makeWithSingleAccount()
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
        var state = DemoDataFactory.makeWithSingleAccount()
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

    func testPurchaseFinalizationCreatesOnlyChildTransactionsAndIsIdempotent() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        let sessionID = UUID()
        let items = [
            PurchaseItem(id: UUID(), categoryID: .food, note: "Fruit", amount: 30, displayOrder: 0, isCompleted: true, completedAt: .now, resolvedAccountID: accountID, linkedTransactionID: nil),
            PurchaseItem(id: UUID(), categoryID: .shopping, note: "Soap", amount: 20, displayOrder: 1, isCompleted: true, completedAt: .now, resolvedAccountID: accountID, linkedTransactionID: nil)
        ]
        state.purchaseSessions = [.init(id: sessionID, ledgerBookID: UUID(), name: "Groceries", status: .awaitingSummary, sections: [], items: items, createdAt: .now, startedAt: .now, completedAt: .now, receiptAttachmentID: nil, currency: .HKD, accountID: accountID)]
        let store = LedgerStore(stateForTesting: state)
        try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        XCTAssertEqual(store.state.transactions.count, 2)
        XCTAssertTrue(store.state.transactions.allSatisfy { $0.purchaseSessionID == sessionID })
        XCTAssertEqual(LedgerCalculations.analytics(store.state, range: .week).total, 50, accuracy: 0.001)
    }

    func testPurchasePresentationExpandsChildrenWhenFiltering() throws {
        let state = DemoDataFactory.makeWithSingleAccount()
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
        var state = SeedData.make()
        SchemaMigration.normalize(&state)
        let book = LedgerBook(id: UUID(), name: "Shared Ledger", state: state, createdAt: .now, updatedAt: .now)
        let records = try CloudRecordMapper.records(for: book)
        XCTAssertEqual(records.filter { $0.recordType == CloudRecordType.transaction }.count, state.transactions.count)
        XCTAssertNotNil(records.first(where: { $0.recordType == CloudRecordType.budget }))
        let decoded = try CloudRecordMapper.decodeBook(from: records, participant: false)
        XCTAssertEqual(decoded.id, book.id)
        XCTAssertEqual(try BackupCodec.encoder().encode(decoded.state.accounts), try BackupCodec.encoder().encode(state.accounts))
        XCTAssertEqual(decoded.state.transactions, state.transactions)
        XCTAssertEqual(decoded.effectiveStorageKind, .cloudOwner)
    }

    func testAnalyticsRemainsFiniteWithInvalidPersistedRates() {
        var state = SeedData.make()
        state.settings.rates[state.settings.baseCurrency] = 0
        state.transactions[0].exchangeRateAtTransaction = .infinity
        let summary = LedgerCalculations.analytics(state, range: .week)
        XCTAssertTrue(summary.total.isFinite)
        XCTAssertTrue(summary.average.isFinite)
        XCTAssertTrue(summary.minimum.isFinite)
        XCTAssertTrue(summary.maximum.isFinite)
        XCTAssertTrue(summary.buckets.allSatisfy { $0.value.isFinite })
        XCTAssertTrue(summary.categoryTotals.values.allSatisfy(\.isFinite))
    }

    func testLedgerIndexAndCalculationsEquivalence() throws {
        let state = SeedData.make()
        let index = LedgerIndex(state: state)

        let accountViewsDirect = LedgerCalculations.accountViews(state)
        let accountViewsIndexed = LedgerCalculations.accountViews(state, index: index)
        XCTAssertEqual(accountViewsDirect.count, accountViewsIndexed.count)
        for (direct, indexed) in zip(accountViewsDirect, accountViewsIndexed) {
            XCTAssertEqual(direct.id, indexed.id)
            XCTAssertEqual(direct.balance, indexed.balance, accuracy: 0.001)
        }

        let portfolioDirect = LedgerCalculations.portfolioBalance(state)
        let portfolioIndexed = LedgerCalculations.portfolioBalance(state, index: index)
        XCTAssertEqual(portfolioDirect, portfolioIndexed, accuracy: 0.001)

        let activeDirect = LedgerCalculations.activeTransactions(state).sorted { $0.occurredAt > $1.occurredAt }
        let activeIndexed = index.activeTransactionsSorted
        XCTAssertEqual(activeDirect.map(\.id), activeIndexed.map(\.id))
    }

    func testThreeMonthFinancialEngineSinglePassEquivalence() throws {
        let state = SeedData.make()
        let index = LedgerIndex(state: state)
        let now = Date.now

        let (summary, windows) = ThreeMonthFinancialEngine.calculate(for: now, in: state, baseCurrency: state.settings.baseCurrency, now: now, index: index)

        let m1NW = ThreeMonthFinancialEngine.closingNetWorth(at: windows.m1.monthEnd, baseCurrency: state.settings.baseCurrency, in: state)
        let m2NW = ThreeMonthFinancialEngine.closingNetWorth(at: windows.m2.monthEnd, baseCurrency: state.settings.baseCurrency, in: state)
        let m3NW = ThreeMonthFinancialEngine.closingNetWorth(at: windows.m3.monthEnd, baseCurrency: state.settings.baseCurrency, in: state)
        let expectedNW = (m1NW + m2NW + m3NW) / 3.0
        XCTAssertEqual(summary.averageNetWorth, expectedNW, accuracy: 0.001)

        let m1Inc = ThreeMonthFinancialEngine.monthlyRecognizedIncome(from: windows.m1.monthStart, to: windows.m1.monthEnd, baseCurrency: state.settings.baseCurrency, in: state, now: now)
        let m2Inc = ThreeMonthFinancialEngine.monthlyRecognizedIncome(from: windows.m2.monthStart, to: windows.m2.monthEnd, baseCurrency: state.settings.baseCurrency, in: state, now: now)
        let m3Inc = ThreeMonthFinancialEngine.monthlyRecognizedIncome(from: windows.m3.monthStart, to: windows.m3.monthEnd, baseCurrency: state.settings.baseCurrency, in: state, now: now)
        let expectedInc = (m1Inc + m2Inc + m3Inc) / 3.0
        XCTAssertEqual(summary.averageIncome, expectedInc, accuracy: 0.001)

        let m1Exp = ThreeMonthFinancialEngine.monthlyRecognizedExpense(from: windows.m1.monthStart, to: windows.m1.monthEnd, baseCurrency: state.settings.baseCurrency, in: state, now: now)
        let m2Exp = ThreeMonthFinancialEngine.monthlyRecognizedExpense(from: windows.m2.monthStart, to: windows.m2.monthEnd, baseCurrency: state.settings.baseCurrency, in: state, now: now)
        let m3Exp = ThreeMonthFinancialEngine.monthlyRecognizedExpense(from: windows.m3.monthStart, to: windows.m3.monthEnd, baseCurrency: state.settings.baseCurrency, in: state, now: now)
        let expectedExp = (m1Exp + m2Exp + m3Exp) / 3.0
        XCTAssertEqual(summary.averageSpending, expectedExp, accuracy: 0.001)

        let m1Turn = ThreeMonthFinancialEngine.monthlyExternalTurnover(from: windows.m1.monthStart, to: windows.m1.monthEnd, baseCurrency: state.settings.baseCurrency, in: state)
        let m2Turn = ThreeMonthFinancialEngine.monthlyExternalTurnover(from: windows.m2.monthStart, to: windows.m2.monthEnd, baseCurrency: state.settings.baseCurrency, in: state)
        let m3Turn = ThreeMonthFinancialEngine.monthlyExternalTurnover(from: windows.m3.monthStart, to: windows.m3.monthEnd, baseCurrency: state.settings.baseCurrency, in: state)
        let expectedTurn = (m1Turn + m2Turn + m3Turn) / 3.0
        XCTAssertEqual(summary.averageTurnover, expectedTurn, accuracy: 0.001)
    }

    func testFinancialRevisionIncrementsOnMutations() throws {
        let state = SeedData.make()
        let store = LedgerStore(stateForTesting: state)
        let initialRevision = store.financialRevision

        store.mutateState { state in
            state.transactions.append(makeTransaction(type: .expense, source: state.accounts[0], amount: 50))
        }
        XCTAssertEqual(store.financialRevision, initialRevision &+ 1)
    }

    func testMutateStatePerformsSingleRevisionBumpForMultipleMutations() throws {
        let state = SeedData.make()
        let store = LedgerStore(stateForTesting: state)
        let initialRevision = store.financialRevision

        store.mutateState { state in
            state.transactions.append(makeTransaction(type: .expense, source: state.accounts[0], amount: 10))
            state.transactions.append(makeTransaction(type: .expense, source: state.accounts[0], amount: 20))
            state.accounts[0].name = "Renamed Account"
        }
        XCTAssertEqual(store.financialRevision, initialRevision &+ 1)
        XCTAssertEqual(store.state.accounts[0].name, "Renamed Account")
    }

    func testPurchaseModeForeignCurrencyConversion() throws {
        let state = SeedData.make()
        let baseCurrency = state.settings.baseCurrency // HKD
        let foreignCurrency: CurrencyCode = .USD
        let amount = 100.0
        let expectedConverted = LedgerCalculations.convert(amount, from: foreignCurrency, to: baseCurrency, rates: state.settings.rates)
        XCTAssertEqual(expectedConverted, 780.0, accuracy: 0.001)
    }

    func testPurchaseSessionDraftSaveAndNormalization() throws {
        let state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        let sessionID = UUID()
        var session = PurchaseSession(id: sessionID, ledgerBookID: UUID(), name: "Weekly Shopping", status: .draft, sections: [], items: [], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil, currency: .HKD, accountID: accountID)
        let item1 = PurchaseItem(id: UUID(), categoryID: .food, note: "Apples", amount: 15, displayOrder: 1, isCompleted: false, completedAt: nil, resolvedAccountID: accountID, linkedTransactionID: nil)
        let item2 = PurchaseItem(id: UUID(), categoryID: .shopping, note: "Paper Towels", amount: 25, displayOrder: 0, isCompleted: false, completedAt: nil, resolvedAccountID: accountID, linkedTransactionID: nil)
        session.items = [item1, item2]

        let store = LedgerStore(stateForTesting: state)
        store.savePurchaseSession(session)

        let saved = try XCTUnwrap(store.purchaseSessions.first(where: { $0.id == sessionID }))
        XCTAssertEqual(saved.items.count, 2)
        XCTAssertEqual(saved.sections.count, 2)
        XCTAssertEqual(saved.plannedAmount, 40.0, accuracy: 0.001)
    }

    func testPurchaseOnlyMutationDoesNotIncrementFinancialRevision() throws {
        let state = DemoDataFactory.makeWithSingleAccount()
        let store = LedgerStore(stateForTesting: state)
        let initialFinancialRev = store.financialRevision

        // Saving a purchase session uses .purchaseOnly
        let session = PurchaseSession(id: UUID(), ledgerBookID: UUID(), name: "Draft List", status: .draft, sections: [], items: [], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil)
        store.savePurchaseSession(session)
        XCTAssertEqual(store.financialRevision, initialFinancialRev, "Purchase-only mutations must not bump financialRevision")

        // Direct financial mutation does increment
        store.mutateState(.financial) { state in
            state.accounts[0].name = "Updated Account"
        }
        XCTAssertEqual(store.financialRevision, initialFinancialRev &+ 1, "Financial mutation must bump financialRevision")
    }

    func testStrictReferenceRateValidationForCurrencyConversion() throws {
        var rates: [CurrencyCode: Double] = [.HKD: 1.0, .USD: 7.8]
        XCTAssertNotNil(CurrencyRates.reference(.USD, in: rates))
        XCTAssertNotNil(CurrencyRates.reference(.HKD, in: rates))

        // When a rate is absent:
        rates.removeValue(forKey: .USD)
        XCTAssertNil(CurrencyRates.reference(.USD, in: rates), "Missing USD rate must return nil")

        // Verify conversion guard logic:
        let baseCurrency: CurrencyCode = .HKD
        let foreignCurrency: CurrencyCode = .USD
        let hasRates = CurrencyRates.reference(foreignCurrency, in: rates) != nil && CurrencyRates.reference(baseCurrency, in: rates) != nil
        XCTAssertFalse(hasRates, "Guard condition must be false when reference rate is missing, avoiding 1:1 fallback")
    }

    func testPurchaseSessionOrderedSectionsEmptyState() throws {
        var session = PurchaseSession(id: UUID(), ledgerBookID: UUID(), name: "List", status: .draft, sections: [], items: [], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil)
        session.normalizeSections()
        XCTAssertTrue(session.orderedSections.isEmpty, "Empty session should have no orderedSections (shows global Add Item)")

        let item = PurchaseItem(id: UUID(), categoryID: .food, note: "Coffee", amount: 4.5, displayOrder: 0, isCompleted: false, completedAt: nil, linkedTransactionID: nil)
        session.items.append(item)
        session.normalizeSections()
        XCTAssertFalse(session.orderedSections.isEmpty, "Session with items has orderedSections (hides global Add Item)")

        session.items.removeAll()
        session.normalizeSections()
        XCTAssertTrue(session.orderedSections.isEmpty, "Session after deleting all items has empty orderedSections (restores global Add Item)")
    }

    func testPurchaseRulesRejectInvalidCategories() {
        let state = DemoDataFactory.make()
        // Normal expense category is valid
        XCTAssertTrue(PurchaseRules.validItemCategory(.food, in: state))
        XCTAssertTrue(PurchaseRules.validItemCategory(.shopping, in: state))

        // System linked category is invalid
        XCTAssertTrue(LedgerCategoryID.settlement.isSystemLinked)
        XCTAssertFalse(PurchaseRules.validItemCategory(.settlement, in: state))
        XCTAssertFalse(PurchaseRules.validItemCategory(.reimbursement, in: state))

        // Income category is invalid for purchase items
        let incomeCat = state.categories.first { $0.kind == .income }
        if let incomeCat {
            XCTAssertFalse(PurchaseRules.validItemCategory(incomeCat.id, in: state))
        }

        // Test that validateItems throws when an item uses an invalid category
        var session = PurchaseSession(id: UUID(), ledgerBookID: UUID(), name: "Invalid Cat Test", status: .draft, sections: [], items: [
            PurchaseItem(id: UUID(), categoryID: .settlement, note: "Invalid", amount: 10, displayOrder: 0, isCompleted: false, completedAt: nil, linkedTransactionID: nil)
        ], createdAt: .now, startedAt: nil, completedAt: nil, receiptAttachmentID: nil)
        XCTAssertThrowsError(try PurchaseRules.validateItems(session, in: state)) { error in
            guard case PurchaseFinalizationError.invalidItem = error else {
                XCTFail("Expected invalidItem error, got \(error)")
                return
            }
        }
    }

    func testAtomicFinalizationRollbackOnInvalidItem() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let accountID = state.accounts[0].id
        let sessionID = UUID()
        // First item is valid, second item has invalid (system linked) category
        let items = [
            PurchaseItem(id: UUID(), categoryID: .food, note: "Valid Item", amount: 30, displayOrder: 0, isCompleted: true, completedAt: .now, resolvedAccountID: accountID, linkedTransactionID: nil),
            PurchaseItem(id: UUID(), categoryID: .settlement, note: "Invalid Item", amount: 20, displayOrder: 1, isCompleted: true, completedAt: .now, resolvedAccountID: accountID, linkedTransactionID: nil)
        ]
        state.purchaseSessions = [.init(id: sessionID, ledgerBookID: UUID(), name: "Rollback Test", status: .awaitingSummary, sections: [], items: items, createdAt: .now, startedAt: .now, completedAt: .now, receiptAttachmentID: nil, currency: .HKD, accountID: accountID)]
        let initialTxCount = state.transactions.count
        let store = LedgerStore(stateForTesting: state)

        do {
            try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
            XCTFail("Finalization must throw on invalid item category")
        } catch {
            // Must have zero partial transactions committed
            XCTAssertEqual(store.state.transactions.count, initialTxCount, "No transactions should be created if any item fails")
            XCTAssertEqual(store.purchaseSessions.first?.status, .awaitingSummary, "Session status must remain awaitingSummary on failure")
        }
    }

    func testStatementPostingResolverIndexParity() {
        let state = DemoDataFactory.make()
        let accountIDs = Set(state.accounts.map(\.id))
        let baseCurrency = state.settings.baseCurrency
        let transactions = state.transactions

        let withoutIndex = StatementPostingResolver.resolvePostings(
            transactions: transactions,
            selectedAccountIDs: accountIDs,
            baseCurrency: baseCurrency,
            in: state
        )

        let index = LedgerIndex(state: state)
        let allTxByID = Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) })
        let withIndex = StatementPostingResolver.resolvePostings(
            transactions: transactions,
            selectedAccountIDs: accountIDs,
            baseCurrency: baseCurrency,
            in: state,
            index: index,
            allTransactionsByID: allTxByID
        )

        XCTAssertEqual(withoutIndex.count, withIndex.count)
        for (p1, p2) in zip(withoutIndex, withIndex) {
            XCTAssertEqual(p1.transactionID, p2.transactionID)
            XCTAssertEqual(p1.accountID, p2.accountID)
            XCTAssertEqual(p1.baseAmount, p2.baseAmount, accuracy: 0.0001)
            XCTAssertEqual(p1.userDescription, p2.userDescription)
            XCTAssertEqual(p1.direction, p2.direction)
            XCTAssertEqual(p1.nativeAmount, p2.nativeAmount, accuracy: 0.0001)
        }
    }

    func testBudgetBreakdownSinglePassParity() {
        let state = DemoDataFactory.make()
        let index = LedgerIndex(state: state)

        let breakdownWithoutIndex = LedgerCalculations.budgetBreakdown(state)
        let breakdownWithIndex = LedgerCalculations.budgetBreakdown(state, index: index)

        XCTAssertEqual(breakdownWithoutIndex.budget, breakdownWithIndex.budget, accuracy: 0.001)
        XCTAssertEqual(breakdownWithoutIndex.spent, breakdownWithIndex.spent, accuracy: 0.001)
        XCTAssertEqual(breakdownWithoutIndex.lines.count, breakdownWithIndex.lines.count)
        for (l1, l2) in zip(breakdownWithoutIndex.lines, breakdownWithIndex.lines) {
            XCTAssertEqual(l1.id, l2.id)
            XCTAssertEqual(l1.budget, l2.budget, accuracy: 0.001)
            XCTAssertEqual(l1.spent, l2.spent, accuracy: 0.001)
        }
    }

    func testPurchaseFinalizationTargetedRollbackPreservesUnrelatedMutations() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let account = state.accounts[0]
        let sessionID = UUID()
        let itemID = UUID()
        let item = PurchaseItem(
            id: itemID,
            categoryID: .food,
            note: "Groceries",
            amount: 50,
            displayOrder: 0,
            isCompleted: true,
            completedAt: .now,
            resolvedAccountID: account.id,
            linkedTransactionID: nil
        )
        state.purchaseSessions = [
            .init(
                id: sessionID,
                ledgerBookID: UUID(),
                name: "Dinner Run",
                status: .awaitingSummary,
                sections: [],
                items: [item],
                createdAt: .now,
                startedAt: .now,
                completedAt: .now,
                receiptAttachmentID: nil,
                currency: .HKD,
                accountID: account.id
            )
        ]

        let store = LedgerStore(stateForTesting: state)
        store.persistenceEnabled = true

        // Simulate an unrelated mutation that occurred before/concurrently
        let unrelatedTx = makeTransaction(type: .expense, source: account, amount: 99)
        store.mutateState { $0.transactions.append(unrelatedTx) }
        store.commitActiveBook()
        let txCountBeforeFinalize = store.state.transactions.count
        XCTAssertTrue(store.state.transactions.contains(where: { $0.id == unrelatedTx.id }))

        // Trigger failure in persistDurableAsync
        struct DummyPersistenceError: Error {}
        store.persistenceTestHook = {
            throw DummyPersistenceError()
        }

        do {
            try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
            XCTFail("Expected persistence error to be thrown")
        } catch is DummyPersistenceError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Newly created purchase transactions should be rolled back
        XCTAssertEqual(store.state.transactions.count, txCountBeforeFinalize)
        XCTAssertFalse(store.state.transactions.contains(where: { $0.purchaseSessionID == sessionID }))

        // Unrelated transaction is preserved
        XCTAssertTrue(store.state.transactions.contains(where: { $0.id == unrelatedTx.id }))

        // Session status is restored to .awaitingSummary
        let restoredSession = store.state.purchaseSessions?.first(where: { $0.id == sessionID })
        XCTAssertEqual(restoredSession?.status, .awaitingSummary)
        XCTAssertNil(restoredSession?.items.first?.linkedTransactionID)

        // Active book mirror is synchronized
        XCTAssertEqual(store.books[0].state.transactions.count, store.state.transactions.count)
        XCTAssertTrue(store.books[0].state.transactions.contains(where: { $0.id == unrelatedTx.id }))
        XCTAssertEqual(store.books[0].state.purchaseSessions?.first(where: { $0.id == sessionID })?.status, .awaitingSummary)
    }

    func testPurchaseFinalizationLegacyPartialRecoveryAdoptsSingleMatch() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let account = state.accounts[0]
        let sessionID = UUID()
        let item1ID = UUID()
        let item2ID = UUID()

        // Item 1 has an existing transaction in state, but item1.linkedTransactionID is nil
        let existingTx = LedgerTransaction(
            id: UUID(),
            userID: SeedData.localUserID,
            type: .expense,
            accountID: account.id,
            destinationAccountID: nil,
            amount: 25,
            currency: .HKD,
            accountAmount: 25,
            destinationAmount: nil,
            categoryID: .food,
            occurredAt: .now,
            note: "Existing Item 1",
            exchangeRateAtTransaction: 1.0,
            purchaseSessionID: sessionID,
            purchaseItemID: item1ID,
            createdAt: .now,
            updatedAt: .now,
            deletedAt: nil,
            version: 1,
            syncStatus: .pending
        )
        state.transactions.append(existingTx)

        let item1 = PurchaseItem(
            id: item1ID,
            categoryID: .food,
            note: "Existing Item 1",
            amount: 25,
            displayOrder: 0,
            isCompleted: true,
            completedAt: .now,
            resolvedAccountID: account.id,
            linkedTransactionID: nil
        )
        let item2 = PurchaseItem(
            id: item2ID,
            categoryID: .food,
            note: "New Item 2",
            amount: 40,
            displayOrder: 1,
            isCompleted: true,
            completedAt: .now,
            resolvedAccountID: account.id,
            linkedTransactionID: nil
        )

        state.purchaseSessions = [
            .init(
                id: sessionID,
                ledgerBookID: UUID(),
                name: "Partial Recovery Test",
                status: .awaitingSummary,
                sections: [],
                items: [item1, item2],
                createdAt: .now,
                startedAt: .now,
                completedAt: .now,
                receiptAttachmentID: nil,
                currency: .HKD,
                accountID: account.id
            )
        ]

        let store = LedgerStore(stateForTesting: state)
        try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)

        let sessionTxs = store.state.transactions.filter { $0.purchaseSessionID == sessionID }
        XCTAssertEqual(sessionTxs.count, 2)

        let completedSession = try XCTUnwrap(store.state.purchaseSessions?.first(where: { $0.id == sessionID }))
        XCTAssertEqual(completedSession.status, .completed)
        XCTAssertEqual(completedSession.items[0].linkedTransactionID, existingTx.id)
        XCTAssertNotNil(completedSession.items[1].linkedTransactionID)
        XCTAssertNotEqual(completedSession.items[1].linkedTransactionID, existingTx.id)
    }

    func testPurchaseFinalizationInconsistentDataOnMultipleMatches() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let account = state.accounts[0]
        let sessionID = UUID()
        let itemID = UUID()

        func makeTx() -> LedgerTransaction {
            LedgerTransaction(
                id: UUID(),
                userID: SeedData.localUserID,
                type: .expense,
                accountID: account.id,
                destinationAccountID: nil,
                amount: 15,
                currency: .HKD,
                accountAmount: 15,
                destinationAmount: nil,
                categoryID: .food,
                occurredAt: .now,
                note: "Duplicate",
                exchangeRateAtTransaction: 1.0,
                purchaseSessionID: sessionID,
                purchaseItemID: itemID,
                createdAt: .now,
                updatedAt: .now,
                deletedAt: nil,
                version: 1,
                syncStatus: .pending
            )
        }
        state.transactions.append(contentsOf: [makeTx(), makeTx()])

        let item = PurchaseItem(
            id: itemID,
            categoryID: .food,
            note: "Duplicate item",
            amount: 15,
            displayOrder: 0,
            isCompleted: true,
            completedAt: .now,
            resolvedAccountID: account.id,
            linkedTransactionID: nil
        )
        state.purchaseSessions = [
            .init(
                id: sessionID,
                ledgerBookID: UUID(),
                name: "Duplicate Test",
                status: .awaitingSummary,
                sections: [],
                items: [item],
                createdAt: .now,
                startedAt: .now,
                completedAt: .now,
                receiptAttachmentID: nil,
                currency: .HKD,
                accountID: account.id
            )
        ]

        let store = LedgerStore(stateForTesting: state)
        do {
            try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
            XCTFail("Should throw inconsistentPurchaseData on multiple matches")
        } catch PurchaseFinalizationError.inconsistentPurchaseData {
            // Success
        } catch {
            XCTFail("Expected inconsistentPurchaseData, got \(error)")
        }
    }

    func testPurchaseFinalizationInconsistentDataOnCorruptedLink() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let account = state.accounts[0]
        let sessionID = UUID()
        let itemID = UUID()

        let item = PurchaseItem(
            id: itemID,
            categoryID: .food,
            note: "Corrupted link item",
            amount: 15,
            displayOrder: 0,
            isCompleted: true,
            completedAt: .now,
            resolvedAccountID: account.id,
            linkedTransactionID: UUID()
        )
        state.purchaseSessions = [
            .init(
                id: sessionID,
                ledgerBookID: UUID(),
                name: "Corrupted Link Test",
                status: .awaitingSummary,
                sections: [],
                items: [item],
                createdAt: .now,
                startedAt: .now,
                completedAt: .now,
                receiptAttachmentID: nil,
                currency: .HKD,
                accountID: account.id
            )
        ]

        let store = LedgerStore(stateForTesting: state)
        do {
            try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
            XCTFail("Should throw inconsistentPurchaseData on non-existent link")
        } catch PurchaseFinalizationError.inconsistentPurchaseData {
            // Success
        } catch {
            XCTFail("Expected inconsistentPurchaseData, got \(error)")
        }
    }

    func testPurchaseFinalizationIdempotency() async throws {
        var state = DemoDataFactory.makeWithSingleAccount()
        let account = state.accounts[0]
        let sessionID = UUID()
        let item = PurchaseItem(
            id: UUID(),
            categoryID: .food,
            note: "Lunch",
            amount: 35,
            displayOrder: 0,
            isCompleted: true,
            completedAt: .now,
            resolvedAccountID: account.id,
            linkedTransactionID: nil
        )
        state.purchaseSessions = [
            .init(
                id: sessionID,
                ledgerBookID: UUID(),
                name: "Idempotency Test",
                status: .awaitingSummary,
                sections: [],
                items: [item],
                createdAt: .now,
                startedAt: .now,
                completedAt: .now,
                receiptAttachmentID: nil,
                currency: .HKD,
                accountID: account.id
            )
        ]

        let store = LedgerStore(stateForTesting: state)

        // First finalization
        try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        let txCountAfterFirst = store.state.transactions.count
        XCTAssertEqual(store.state.purchaseSessions?.first?.status, .completed)

        // Second finalization on the same completed session should be a no-op
        try await store.finalizePurchaseSession(sessionID, receiptAttachmentID: nil)
        XCTAssertEqual(store.state.transactions.count, txCountAfterFirst)
        XCTAssertEqual(store.state.purchaseSessions?.first?.status, .completed)
    }

    private func makeTransaction(type: LedgerTransactionType, source: LedgerAccount, destination: LedgerAccount? = nil, amount: Double) -> LedgerTransaction {
        .init(id: UUID(), userID: SeedData.localUserID, type: type, accountID: source.id, destinationAccountID: destination?.id, amount: amount, currency: source.currency, accountAmount: amount, destinationAmount: destination == nil ? nil : amount, categoryID: .food, occurredAt: .now, note: nil, exchangeRateAtTransaction: SeedData.rates[source.currency] ?? 1, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
    }
}
