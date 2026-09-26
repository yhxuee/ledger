import Foundation
import CryptoKit

enum BackupCodec {
    static let currentSchemaVersion = 3

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func envelope(for state: LedgerState) -> LedgerBackupEnvelope {
        .init(metadata: .init(app: "finsy", schemaVersion: currentSchemaVersion, exportedAt: .now, userID: state.settings.userID, accountCount: state.accounts.filter { $0.deletedAt == nil }.count, transactionCount: state.transactions.filter { $0.deletedAt == nil }.count, categoryCount: state.categories.count, baseCurrency: state.settings.baseCurrency), data: state)
    }

    static func encode(_ envelope: LedgerBackupEnvelope) throws -> Data { try encoder().encode(envelope) }

    static func encodeFsy(
        envelope: LedgerBackupEnvelope,
        ledgerID: UUID,
        key: SymmetricKey?
    ) throws -> Data {
        let manifest = FsyInnerManifest(
            ledgerID: ledgerID,
            snapshotCreatedAt: .now,
            stateLastModifiedAt: envelope.data.lastModifiedAt,
            schemaVersion: envelope.data.schemaVersion,
            accountCount: envelope.metadata.accountCount,
            transactionCount: envelope.metadata.transactionCount
        )
        let innerPayload = FsyInnerBackupPayload(manifest: manifest, envelope: envelope)
        let innerData = try encoder().encode(innerPayload)

        let container: FsyBackupContainer
        if let key {
            let (ciphertext, fp) = try LedgerCryptoService.encryptBackup(innerData, ledgerID: ledgerID, key: key)
            container = FsyBackupContainer(
                format: FsyBackupContainer.currentFormat,
                formatVersion: FsyBackupContainer.currentFormatVersion,
                ledgerID: ledgerID,
                encrypted: true,
                encryptionVersion: LedgerCryptoService.currentEncryptionVersion,
                keyFingerprint: fp,
                createdAt: .now,
                payload: ciphertext
            )
        } else {
            container = FsyBackupContainer(
                format: FsyBackupContainer.currentFormat,
                formatVersion: FsyBackupContainer.currentFormatVersion,
                ledgerID: ledgerID,
                encrypted: false,
                encryptionVersion: nil,
                keyFingerprint: nil,
                createdAt: .now,
                payload: innerData
            )
        }
        return try encoder().encode(container)
    }

    static func decode(_ data: Data, sourceName: String, existingState: LedgerState? = nil) throws -> ImportPreview {
        // 1. Check for CSV format
        if sourceName.lowercased().hasSuffix(".csv") || (String(data: data, encoding: .utf8)?.contains("account_amount") == true) {
            if let text = String(data: data, encoding: .utf8), let baseState = existingState {
                return try CSVTransactionImporter.convertToImportPreview(csvText: text, sourceName: sourceName, existingState: baseState)
            }
        }

        // 2. Check for .fsy container
        if let fsy = try? decoder().decode(FsyBackupContainer.self, from: data), fsy.format == FsyBackupContainer.currentFormat {
            let innerData: Data
            if fsy.encrypted {
                guard let key = try LedgerKeyStore.loadKey(for: fsy.ledgerID, expectedFingerprint: fsy.keyFingerprint) else {
                    throw LedgerCryptoError.authorizationRequired(ledgerID: fsy.ledgerID, fingerprint: fsy.keyFingerprint)
                }
                let fp = LedgerKeyStore.fingerprint(for: key, ledgerID: fsy.ledgerID)
                if let expected = fsy.keyFingerprint, !expected.isEmpty, expected.lowercased() != fp.lowercased() {
                    throw LedgerCryptoError.authorizationRequired(ledgerID: fsy.ledgerID, fingerprint: expected)
                }
                innerData = try LedgerCryptoService.decryptBackup(
                    fsy.payload,
                    ledgerID: fsy.ledgerID,
                    key: key,
                    formatVersion: fsy.formatVersion,
                    expectedFingerprint: fsy.keyFingerprint
                )
            } else {
                innerData = fsy.payload
            }

            var envelope: LedgerBackupEnvelope
            if let inner = try? decoder().decode(FsyInnerBackupPayload.self, from: innerData) {
                guard inner.manifest.ledgerID == fsy.ledgerID else {
                    throw LedgerCryptoError.corruptedContainer("Inner manifest ledger ID does not match container.")
                }
                envelope = inner.envelope
            } else if let direct = try? decoder().decode(LedgerBackupEnvelope.self, from: innerData) {
                envelope = direct
            } else {
                throw BackupError.invalidFormat
            }

            PurchaseRules.migrateDevelopmentSessions(in: &envelope.data)
            SchemaMigration.normalize(&envelope.data)
            try validate(envelope.data)
            envelope.metadata.accountCount = envelope.data.accounts.filter { $0.deletedAt == nil }.count
            envelope.metadata.transactionCount = envelope.data.transactions.filter { $0.deletedAt == nil }.count
            envelope.metadata.categoryCount = envelope.data.categories.count
            envelope.metadata.baseCurrency = envelope.data.settings.baseCurrency
            return .init(sourceName: sourceName, envelope: envelope, warnings: [])
        }

        // 3. Fallback to legacy formats (.walletledger, .json)
        var envelope: LedgerBackupEnvelope
        if let current = try? decoder().decode(LedgerBackupEnvelope.self, from: data) {
            envelope = current
        } else if let nativeV1 = try? decoder().decode(LedgerBackupEnvelopeV1.self, from: data), nativeV1.data.schemaVersion <= 1 {
            envelope = SchemaMigration.migrate(nativeV1)
        } else {
            envelope = try LegacyWebBackup.decode(data)
        }
        guard FinsyCompatibility.backupApps.contains(envelope.metadata.app) else { throw BackupError.wrongApplication }
        guard envelope.metadata.schemaVersion <= currentSchemaVersion else { throw BackupError.futureSchema(envelope.metadata.schemaVersion) }
        PurchaseRules.migrateDevelopmentSessions(in: &envelope.data)
        SchemaMigration.normalize(&envelope.data)
        try validate(envelope.data)
        envelope.metadata.accountCount = envelope.data.accounts.filter { $0.deletedAt == nil }.count
        envelope.metadata.transactionCount = envelope.data.transactions.filter { $0.deletedAt == nil }.count
        envelope.metadata.categoryCount = envelope.data.categories.count
        envelope.metadata.baseCurrency = envelope.data.settings.baseCurrency
        var warnings: [String] = []
        if envelope.metadata.app == FinsyCompatibility.webBackupApp { warnings.append(String(localized: "Web backup converted to the native iOS schema.")) }
        return .init(sourceName: sourceName, envelope: envelope, warnings: warnings)
    }

    /// Invariant: BackupCodec.validate() requires fully materialized LedgerState.
    /// It enforces complete referential integrity across all transactions, refunds, and linked purchases.
    static func validate(_ state: LedgerState) throws {
        guard state.schemaVersion <= currentSchemaVersion else { throw BackupError.futureSchema(state.schemaVersion) }
        let accountIDs = state.accounts.map(\.id)
        guard Set(accountIDs).count == accountIDs.count else { throw BackupError.duplicateID("account") }
        let transactionIDs = state.transactions.map(\.id)
        guard Set(transactionIDs).count == transactionIDs.count else { throw BackupError.duplicateID("transaction") }
        let transactionsByID = Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) })
        let knownAccounts = Set(accountIDs)
        let categoryIDs = state.categories.map(\.id)
        guard Set(categoryIDs).count == categoryIDs.count, LedgerCategoryID.builtIns.allSatisfy(categoryIDs.contains) else { throw BackupError.invalidValue("categories") }
        let accountsByID = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0) })
        try LinkedTransactionValidation.validate(state)
        for account in state.accounts {
            if let stock = account.stockMetadata {
                guard stock.averageCost.isFinite, stock.averageCost >= 0,
                      stock.quantity.isFinite, stock.quantity >= 0, stock.costBasis.isFinite,
                      stock.latestPrice.map({ $0.isFinite && $0 > 0 }) ?? true,
                      stock.marketValue?.isFinite ?? true else { throw BackupError.invalidValue("stock metadata") }
            }
            guard account.openingBalance.isFinite, account.budget.isFinite, account.budget >= 0 else { throw BackupError.invalidValue("account \(account.name)") }
            if let loan = account.loanMetadata { guard loan.annualPercentageRate.isFinite, loan.annualPercentageRate >= 0, loan.customIntervalDays > 0 else { throw BackupError.invalidValue("loan metadata") } }
            let pockets = account.normalizedPockets
            guard !pockets.isEmpty, pockets.allSatisfy({ $0.openingBalance.isFinite }) else { throw BackupError.invalidValue("account pockets") }
            guard pockets.contains(where: { $0.currency == account.currency }) else { throw BackupError.invalidValue("account primary currency") }
            if account.usesCurrencyPockets {
                guard Set(pockets.map(\.currency)).count == pockets.count else { throw BackupError.invalidValue("duplicate account pocket") }
                guard account.stockMetadata == nil else { throw BackupError.invalidValue("multi-currency stocks account") }
            }
            if let coupons = account.coupons, !coupons.isEmpty {
                guard account.type == .eWallet else { throw BackupError.invalidValue("coupons on non-eWallet account") }
                let couponIDs = coupons.map(\.id)
                guard Set(couponIDs).count == couponIDs.count else { throw BackupError.duplicateID("coupon") }
                for coupon in coupons {
                    guard coupon.faceValue.isFinite, coupon.faceValue > 0 else { throw BackupError.invalidValue("coupon face value") }
                    guard account.pocketCurrencies.contains(coupon.currency) || coupon.currency == account.currency else { throw BackupError.invalidValue("coupon currency") }
                }
            }
        }
        for transaction in state.transactions {
            if let identifier = transaction.noteAttachmentID { try AttachmentPath.validate(identifier) }
            guard knownAccounts.contains(transaction.accountID) else { throw BackupError.missingAccount }
            guard transaction.amount.isFinite, transaction.amount > 0, transaction.exchangeRateAtTransaction.isFinite, transaction.exchangeRateAtTransaction > 0 else { throw BackupError.invalidValue("transaction") }
            guard categoryIDs.contains(transaction.categoryID) else { throw BackupError.invalidValue("transaction category") }
            if let currency = transaction.accountCurrency, let account = accountsByID[transaction.accountID], account.usesCurrencyPockets {
                guard account.pocketCurrencies.contains(currency) else { throw BackupError.invalidValue("transaction account pocket") }
            }
            if let currency = transaction.destinationAccountCurrency, let destinationID = transaction.destinationAccountID, let account = accountsByID[destinationID], account.usesCurrencyPockets {
                guard account.pocketCurrencies.contains(currency) else { throw BackupError.invalidValue("transaction destination pocket") }
            }
            if transaction.type == .transfer {
                guard let destination = transaction.destinationAccountID, knownAccounts.contains(destination), let source = accountsByID[transaction.accountID], TransactionSemantics.validTransfer(source: source, destinationID: destination, sourceCurrency: transaction.accountCurrency, destinationCurrency: transaction.destinationAccountCurrency) else { throw BackupError.invalidTransfer }
            }
            if let originalID = transaction.reversalOfTransactionID {
                guard originalID != transaction.id, let original = transactionsByID[originalID], original.reversalTransactionID == transaction.id else { throw BackupError.invalidValue("refund relationship") }
            }
            if let reversalID = transaction.reversalTransactionID {
                guard reversalID != transaction.id, let reversal = transactionsByID[reversalID], reversal.reversalOfTransactionID == transaction.id else { throw BackupError.invalidValue("refund relationship") }
            }
        }
        for rule in state.recurringRules ?? [] {
            guard rule.userID == state.settings.userID, knownAccounts.contains(rule.accountID), rule.amount.isFinite, (rule.effectiveAmountKind == .loanInterest || rule.amount > 0), rule.customIntervalDays > 0 else { throw BackupError.invalidValue("recurring transaction") }
            guard categoryIDs.contains(rule.categoryID) else { throw BackupError.invalidValue("recurring category") }
            if let currency = rule.accountCurrency, let account = accountsByID[rule.accountID], account.usesCurrencyPockets {
                guard account.pocketCurrencies.contains(currency) else { throw BackupError.invalidValue("recurring account pocket") }
            }
            if let currency = rule.destinationAccountCurrency, let destinationID = rule.destinationAccountID, let account = accountsByID[destinationID], account.usesCurrencyPockets {
                guard account.pocketCurrencies.contains(currency) else { throw BackupError.invalidValue("recurring destination pocket") }
            }
            if rule.effectiveAmountKind == .loanInterest { guard let loanID = rule.linkedLoanAccountID, loanID == rule.accountID, knownAccounts.contains(loanID) else { throw BackupError.invalidValue("loan interest rule") } }
            if rule.type == .transfer {
                guard let destination = rule.destinationAccountID, destination != rule.accountID, knownAccounts.contains(destination) else { throw BackupError.invalidTransfer }
            }
        }
        for (categoryID, accountID) in state.settings.defaultExpenseAccountByCategory {
            guard categoryIDs.contains(categoryID), knownAccounts.contains(accountID) else { throw BackupError.invalidValue("default expense account") }
        }
        for (categoryID, amount) in state.settings.budgetPlan.categoryAllocations {
            guard categoryIDs.contains(categoryID), amount.isFinite, amount >= 0 else { throw BackupError.invalidValue("category budget") }
        }
        for (accountID, amount) in state.settings.budgetPlan.accountAllocations {
            guard knownAccounts.contains(accountID), amount.isFinite, amount >= 0 else { throw BackupError.invalidValue("account budget") }
        }
        let purchaseSessionIDs = (state.purchaseSessions ?? []).map(\.id)
        guard Set(purchaseSessionIDs).count == purchaseSessionIDs.count else { throw BackupError.duplicateID("purchase session") }
        for session in state.purchaseSessions ?? [] {
            if let identifier = session.receiptAttachmentID { try AttachmentPath.validate(identifier) }
            if let accountID = session.accountID { guard knownAccounts.contains(accountID) else { throw BackupError.missingAccount } }
            if session.status == .active || session.status == .awaitingSummary {
                guard session.accountID != nil else { throw BackupError.invalidValue("purchase payment account") }
            }
            let sectionIDs = session.sections.map(\.id), itemIDs = session.items.map(\.id)
            guard Set(sectionIDs).count == sectionIDs.count, Set(itemIDs).count == itemIDs.count else { throw BackupError.duplicateID("purchase item") }
            guard session.sections.allSatisfy({ categoryIDs.contains($0.categoryID) }) else { throw BackupError.invalidValue("purchase section") }
            for item in session.items {
                guard categoryIDs.contains(item.categoryID), item.amount.isFinite, item.amount >= 0 else { throw BackupError.invalidValue("purchase item") }
                if let accountID = item.resolvedAccountID { guard knownAccounts.contains(accountID) else { throw BackupError.missingAccount } }
                if let transactionID = item.linkedTransactionID { guard transactionsByID[transactionID] != nil else { throw BackupError.invalidValue("purchase transaction link") } }
            }
        }
        let usedCurrencies = Set(state.accounts.map(\.currency) + state.accounts.flatMap { ($0.coupons ?? []).map(\.currency) } + state.transactions.map(\.currency) + (state.recurringRules ?? []).map(\.currency) + (state.purchaseSessions ?? []).map(\.currency) + [state.settings.baseCurrency, .HKD])
        for currency in usedCurrencies {
            guard CurrencyRates.reference(currency, in: state.settings.rates) != nil else { throw BackupError.invalidValue("exchange rate \(currency.rawValue)") }
        }
    }
}

enum BackupError: LocalizedError {
    case wrongApplication, invalidFormat, futureSchema(Int), duplicateID(String), missingAccount, invalidTransfer, invalidValue(String), iCloudUnavailable, noICloudBackup
    case iCloudSyncPending
    var errorDescription: String? {
        switch self {
        case .wrongApplication: "This file is not a Finsy backup."
        case .invalidFormat: "The saved ledger format is invalid or unsupported."
        case .futureSchema(let version): "Backup schema \(version) is newer than this app supports."
        case .duplicateID(let type): "Backup contains a duplicate \(type) ID."
        case .missingAccount: "A transaction references a missing account."
        case .invalidTransfer: "A transfer has an invalid destination account."
        case .invalidValue(let field): "Backup contains an invalid \(field) value."
        case .iCloudUnavailable: "iCloud Drive is not available. Check the app capability and Apple ID."
        case .noICloudBackup: "No iCloud backup was found."
        case .iCloudSyncPending: "iCloud has not finished transferring the backup. Keep both devices online and try again."
        }
    }
}
