import Foundation

enum BackupCodec {
    static let currentSchemaVersion = 1

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
        .init(metadata: .init(app: "wallet-ledger-ios", schemaVersion: currentSchemaVersion, exportedAt: .now, userID: state.settings.userID, accountCount: state.accounts.filter { $0.deletedAt == nil }.count, transactionCount: state.transactions.filter { $0.deletedAt == nil }.count, categoryCount: state.categories.count, baseCurrency: state.settings.baseCurrency), data: state)
    }

    static func encode(_ envelope: LedgerBackupEnvelope) throws -> Data { try encoder().encode(envelope) }

    static func decode(_ data: Data, sourceName: String) throws -> ImportPreview {
        var envelope: LedgerBackupEnvelope
        do {
            envelope = try decoder().decode(LedgerBackupEnvelope.self, from: data)
        } catch {
            envelope = try LegacyWebBackup.decode(data)
        }
        guard ["wallet-ledger-ios", "wallet-ledger-overview"].contains(envelope.metadata.app) else { throw BackupError.wrongApplication }
        guard envelope.metadata.schemaVersion <= currentSchemaVersion else { throw BackupError.futureSchema(envelope.metadata.schemaVersion) }
        try validate(envelope.data)
        envelope.metadata.accountCount = envelope.data.accounts.filter { $0.deletedAt == nil }.count
        envelope.metadata.transactionCount = envelope.data.transactions.filter { $0.deletedAt == nil }.count
        envelope.metadata.categoryCount = envelope.data.categories.count
        envelope.metadata.baseCurrency = envelope.data.settings.baseCurrency
        var warnings: [String] = []
        if envelope.metadata.app == "wallet-ledger-overview" { warnings.append("Web backup converted to the native iOS schema.") }
        return .init(sourceName: sourceName, envelope: envelope, warnings: warnings)
    }

    static func validate(_ state: LedgerState) throws {
        guard state.schemaVersion <= currentSchemaVersion else { throw BackupError.futureSchema(state.schemaVersion) }
        let accountIDs = state.accounts.map(\.id)
        guard Set(accountIDs).count == accountIDs.count else { throw BackupError.duplicateID("account") }
        let transactionIDs = state.transactions.map(\.id)
        guard Set(transactionIDs).count == transactionIDs.count else { throw BackupError.duplicateID("transaction") }
        let knownAccounts = Set(accountIDs)
        let categoryIDs = state.categories.map(\.id)
        guard Set(categoryIDs).count == categoryIDs.count, LedgerCategoryID.builtIns.allSatisfy(categoryIDs.contains) else { throw BackupError.invalidValue("categories") }
        for account in state.accounts {
            guard account.openingBalance.isFinite, account.budget.isFinite, account.budget >= 0 else { throw BackupError.invalidValue("account \(account.name)") }
        }
        for transaction in state.transactions {
            guard knownAccounts.contains(transaction.accountID) else { throw BackupError.missingAccount }
            guard transaction.amount.isFinite, transaction.amount > 0, transaction.exchangeRateAtTransaction.isFinite, transaction.exchangeRateAtTransaction > 0 else { throw BackupError.invalidValue("transaction") }
            guard categoryIDs.contains(transaction.categoryID) else { throw BackupError.invalidValue("transaction category") }
            if transaction.type == .transfer {
                guard let destination = transaction.destinationAccountID, destination != transaction.accountID, knownAccounts.contains(destination) else { throw BackupError.invalidTransfer }
            }
        }
        for currency in CurrencyCode.allCases {
            guard let rate = state.settings.rates[currency], rate.isFinite, rate > 0 else { throw BackupError.invalidValue("exchange rate \(currency.rawValue)") }
        }
    }
}

enum BackupError: LocalizedError {
    case wrongApplication, futureSchema(Int), duplicateID(String), missingAccount, invalidTransfer, invalidValue(String), iCloudUnavailable, noICloudBackup
    var errorDescription: String? {
        switch self {
        case .wrongApplication: "This file is not a Wallet Ledger backup."
        case .futureSchema(let version): "Backup schema \(version) is newer than this app supports."
        case .duplicateID(let type): "Backup contains a duplicate \(type) ID."
        case .missingAccount: "A transaction references a missing account."
        case .invalidTransfer: "A transfer has an invalid destination account."
        case .invalidValue(let field): "Backup contains an invalid \(field) value."
        case .iCloudUnavailable: "iCloud Drive is not available. Check the app capability and Apple ID."
        case .noICloudBackup: "No iCloud backup was found."
        }
    }
}
