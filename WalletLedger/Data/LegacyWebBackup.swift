import Foundation

private struct WebBackup: Decodable {
    struct Metadata: Decodable { var app: String; var schemaVersion: Int; var exportedAt: String?; var userId: String? }
    struct DataBlock: Decodable {
        struct Account: Decodable {
            struct Style: Decodable { var start: String; var end: String }
            var id: String; var name: String; var type: String; var currency: String; var openingBalance: Double; var budget: Double; var includeInBudget: Bool; var logo: String; var cardStyle: Style; var createdAt: String?; var updatedAt: String?; var deletedAt: String?; var version: Int?
        }
        struct Transaction: Decodable {
            var id: String; var type: String; var accountId: String; var destinationAccountId: String?; var amount: Double; var currency: String; var accountAmount: Double?; var destinationAmount: Double?; var categoryId: String; var date: String; var time: String; var note: String?; var exchangeRateAtTransaction: Double; var createdAt: String?; var updatedAt: String?; var deletedAt: String?; var version: Int?
        }
        struct Category: Decodable { var id: String; var name: String; var description: String; var color: String; var icon: String }
        struct Settings: Decodable { var userId: String; var baseCurrency: String; var rates: [String: Double]; var automaticRates: Bool; var backupEnabled: Bool; var lastBackup: String?; var updatedAt: String? }
        var accounts: [Account]; var transactions: [Transaction]; var categories: [Category]?; var settings: Settings
    }
    var metadata: Metadata
    var data: DataBlock
}

enum LegacyWebBackup {
    static func decode(_ data: Data) throws -> LedgerBackupEnvelope {
        let web = try JSONDecoder().decode(WebBackup.self, from: data)
        let userID = web.data.settings.userId
        let accountIDMap = Dictionary(uniqueKeysWithValues: web.data.accounts.map { ($0.id, stableUUID($0.id)) })
        let accounts = web.data.accounts.compactMap { item -> LedgerAccount? in
            guard let id = accountIDMap[item.id] else { return nil }
            return LedgerAccount(id: id, userID: userID, name: item.name, type: AccountType(rawValue: item.type) ?? .checking, currency: CurrencyCode(rawValue: item.currency) ?? .HKD, openingBalance: item.openingBalance, budget: item.budget, includeInBudget: item.includeInBudget, logo: item.logo, cardStyle: .init(startHex: cleanHex(item.cardStyle.start), endHex: cleanHex(item.cardStyle.end)), createdAt: parseISO(item.createdAt) ?? .now, updatedAt: parseISO(item.updatedAt) ?? .now, deletedAt: parseISO(item.deletedAt), version: item.version ?? 1, syncStatus: .pending)
        }
        let transactions = web.data.transactions.compactMap { item -> LedgerTransaction? in
            guard let source = accountIDMap[item.accountId] else { return nil }
            let occurred = parseDateTime(item.date, item.time) ?? .now
            return LedgerTransaction(id: stableUUID(item.id), userID: userID, type: LedgerTransactionType(rawValue: item.type) ?? .expense, accountID: source, destinationAccountID: item.destinationAccountId.flatMap { accountIDMap[$0] }, amount: item.amount, currency: CurrencyCode(rawValue: item.currency) ?? .HKD, accountAmount: item.accountAmount, destinationAmount: item.destinationAmount, categoryID: LedgerCategoryID(rawValue: item.categoryId) ?? .other, occurredAt: occurred, note: item.note, exchangeRateAtTransaction: item.exchangeRateAtTransaction, createdAt: parseISO(item.createdAt) ?? occurred, updatedAt: parseISO(item.updatedAt) ?? occurred, deletedAt: parseISO(item.deletedAt), version: item.version ?? 1, syncStatus: .pending)
        }
        let categories = (web.data.categories ?? []).compactMap { item -> LedgerCategory? in
            guard let id = LedgerCategoryID(rawValue: item.id) else { return nil }
            let seed = SeedData.categories.first { $0.id == id }
            return .init(id: id, name: item.name, detail: item.description, symbol: seed?.symbol ?? "circle.fill", colorHex: cleanHex(item.color))
        }
        let rates = Dictionary(uniqueKeysWithValues: CurrencyCode.allCases.map { ($0, web.data.settings.rates[$0.rawValue] ?? SeedData.rates[$0] ?? 1) })
        let state = LedgerState(schemaVersion: BackupCodec.currentSchemaVersion, accounts: accounts, transactions: transactions, categories: categories.isEmpty ? SeedData.categories : categories, settings: .init(userID: userID, baseCurrency: CurrencyCode(rawValue: web.data.settings.baseCurrency) ?? .HKD, rates: rates, automaticRates: web.data.settings.automaticRates, backupReminders: web.data.settings.backupEnabled, lastBackupAt: parseISO(web.data.settings.lastBackup), updatedAt: parseISO(web.data.settings.updatedAt) ?? .now))
        return .init(metadata: .init(app: web.metadata.app, schemaVersion: BackupCodec.currentSchemaVersion, exportedAt: parseISO(web.metadata.exportedAt) ?? .now, userID: userID, accountCount: accounts.count, transactionCount: transactions.count, categoryCount: state.categories.count, baseCurrency: state.settings.baseCurrency), data: state)
    }

    private static func stableUUID(_ value: String) -> UUID {
        if let uuid = UUID(uuidString: value) { return uuid }
        var bytes = Array(repeating: UInt8(0), count: 16)
        for (index, byte) in value.utf8.enumerated() { bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(index & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func parseDateTime(_ date: String, _ time: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(time)")
    }

    private static func cleanHex(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased() }
}
