import Foundation
import SwiftUI

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var state: LedgerState
    @Published private(set) var books: [LedgerBook]
    @Published private(set) var activeBookID: UUID
    @Published var presentedError: String?
    @Published var undoMessage: String?
    private var saveTask: Task<Void, Never>?
    private var undoTransaction: LedgerTransaction?

    init() {
        if let library = Self.loadLibrary(), let active = library.books.first(where: { $0.id == library.activeBookID }) ?? library.books.first {
            books = library.books
            activeBookID = active.id
            state = active.state
        } else {
            let initial = Self.loadLegacyState() ?? SeedData.make()
            let book = LedgerBook(id: UUID(), name: "Ledger 1", state: initial, createdAt: .now, updatedAt: .now)
            books = [book]
            activeBookID = book.id
            state = initial
            scheduleSave()
        }
    }

    var accounts: [AccountViewModel] { LedgerCalculations.accountViews(state) }
    var activeTransactions: [LedgerTransaction] { LedgerCalculations.activeTransactions(state).sorted { $0.occurredAt > $1.occurredAt } }
    var activeBookName: String { books.first(where: { $0.id == activeBookID })?.name ?? "Ledger" }

    func switchBook(to id: UUID) {
        guard id != activeBookID else { return }
        commitActiveBook()
        guard let book = books.first(where: { $0.id == id }) else { return }
        activeBookID = book.id
        state = book.state
        undoTransaction = nil
        undoMessage = nil
        scheduleSave()
    }

    func createBook(named rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Ledger \(books.count + 1)" : trimmed
        commitActiveBook()
        let book = LedgerBook(id: UUID(), name: name, state: SeedData.makeEmpty(), createdAt: .now, updatedAt: .now)
        books.append(book)
        activeBookID = book.id
        state = book.state
        undoTransaction = nil
        undoMessage = nil
        scheduleSave()
    }

    func addTransaction(type: LedgerTransactionType, accountID: UUID, destinationAccountID: UUID?, amount: Double, currency: CurrencyCode, categoryID: LedgerCategoryID, occurredAt: Date, note: String?) {
        guard amount > 0, let source = state.accounts.first(where: { $0.id == accountID && $0.deletedAt == nil }) else { return }
        let destination = destinationAccountID.flatMap { id in state.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) }
        guard type != .transfer || (destination != nil && destination?.id != source.id) else { return }
        let rates = state.settings.rates
        let item = LedgerTransaction(id: UUID(), userID: state.settings.userID, type: type, accountID: source.id, destinationAccountID: type == .transfer ? destination?.id : nil, amount: amount, currency: currency, accountAmount: LedgerCalculations.convert(amount, from: currency, to: source.currency, rates: rates), destinationAmount: type == .transfer ? destination.map { LedgerCalculations.convert(amount, from: currency, to: $0.currency, rates: rates) } : nil, categoryID: type == .transfer ? .other : categoryID, occurredAt: occurredAt, note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, exchangeRateAtTransaction: rates[currency] ?? 1, createdAt: .now, updatedAt: .now, deletedAt: nil, version: 1, syncStatus: .pending)
        state.transactions.insert(item, at: 0)
        scheduleSave()
    }

    func updateTransaction(_ item: LedgerTransaction) {
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id }), let source = state.accounts.first(where: { $0.id == item.accountID }) else { return }
        var updated = item
        updated.accountAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: source.currency, rates: state.settings.rates)
        if item.type == .transfer, let destinationID = item.destinationAccountID, let destination = state.accounts.first(where: { $0.id == destinationID }) {
            updated.destinationAmount = LedgerCalculations.convert(item.amount, from: item.currency, to: destination.currency, rates: state.settings.rates)
            updated.categoryID = .other
        } else {
            updated.destinationAccountID = nil
            updated.destinationAmount = nil
        }
        updated.exchangeRateAtTransaction = state.settings.rates[item.currency] ?? 1
        updated.updatedAt = .now
        updated.version += 1
        updated.syncStatus = .pending
        state.transactions[index] = updated
        scheduleSave()
    }

    func deleteTransaction(_ item: LedgerTransaction) {
        guard let index = state.transactions.firstIndex(where: { $0.id == item.id }) else { return }
        undoTransaction = state.transactions[index]
        state.transactions[index].deletedAt = .now
        state.transactions[index].updatedAt = .now
        state.transactions[index].version += 1
        state.transactions[index].syncStatus = .pending
        undoMessage = "Transaction deleted"
        scheduleSave()
    }

    func undoDelete() {
        guard let item = undoTransaction, let index = state.transactions.firstIndex(where: { $0.id == item.id }) else { return }
        state.transactions[index] = item
        undoTransaction = nil
        undoMessage = nil
        scheduleSave()
    }

    func saveAccount(_ draft: LedgerAccount, desiredBalance: Double) {
        var account = draft
        var zeroOpening = draft
        zeroOpening.openingBalance = 0
        let ledgerDelta = LedgerCalculations.balance(for: zeroOpening, in: state)
        if let current = state.accounts.first(where: { $0.id == draft.id }) {
            account.openingBalance = desiredBalance - ledgerDelta
            account.version = current.version + 1
            account.createdAt = current.createdAt
        } else {
            account.openingBalance = desiredBalance - ledgerDelta
            account.version = 1
        }
        account.updatedAt = .now
        account.deletedAt = nil
        account.syncStatus = .pending
        if let index = state.accounts.firstIndex(where: { $0.id == account.id }) { state.accounts[index] = account }
        else { state.accounts.append(account) }
        scheduleSave()
    }

    func deleteAccount(_ account: LedgerAccount) {
        let deletedAt = Date.now
        if let index = state.accounts.firstIndex(where: { $0.id == account.id }) {
            state.accounts[index].deletedAt = deletedAt
            state.accounts[index].updatedAt = deletedAt
            state.accounts[index].version += 1
        }
        for index in state.transactions.indices where state.transactions[index].accountID == account.id || state.transactions[index].destinationAccountID == account.id {
            state.transactions[index].deletedAt = deletedAt
            state.transactions[index].updatedAt = deletedAt
            state.transactions[index].version += 1
        }
        scheduleSave()
    }

    func updateSettings(_ change: (inout LedgerSettings) -> Void) {
        change(&state.settings)
        state.settings.updatedAt = .now
        scheduleSave()
    }

    @discardableResult
    func addCategory(name rawName: String, detail rawDetail: String, symbol: String, colorHex: String) -> LedgerCategoryID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !symbol.isEmpty else { return nil }
        let id = LedgerCategoryID(rawValue: "custom-\(UUID().uuidString.lowercased())")
        state.categories.append(.init(id: id, name: name, detail: rawDetail.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol, colorHex: colorHex))
        scheduleSave()
        return id
    }

    func replace(with envelope: LedgerBackupEnvelope) {
        do {
            try BackupCodec.validate(envelope.data)
            state = envelope.data
            scheduleSave()
        } catch { presentedError = error.localizedDescription }
    }

    func backupEnvelope() -> LedgerBackupEnvelope { BackupCodec.envelope(for: state) }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = librarySnapshot()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            do { try Self.writeLibrary(snapshot) }
            catch { presentedError = "Local save failed: \(error.localizedDescription)" }
        }
    }

    private func commitActiveBook() {
        guard let index = books.firstIndex(where: { $0.id == activeBookID }) else { return }
        books[index].state = state
        books[index].updatedAt = .now
    }

    private func librarySnapshot() -> LedgerLibrary {
        var snapshotBooks = books
        if let index = snapshotBooks.firstIndex(where: { $0.id == activeBookID }) {
            snapshotBooks[index].state = state
            snapshotBooks[index].updatedAt = .now
        }
        return LedgerLibrary(schemaVersion: 1, activeBookID: activeBookID, books: snapshotBooks)
    }

    nonisolated private static var storageFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "WalletLedger", directoryHint: .isDirectory)
    }

    private static func loadLibrary() -> LedgerLibrary? {
        let url = storageFolder.appending(path: "library.json")
        guard let data = try? Data(contentsOf: url), let library = try? BackupCodec.decoder().decode(LedgerLibrary.self, from: data), !library.books.isEmpty else { return nil }
        guard library.books.allSatisfy({ (try? BackupCodec.validate($0.state)) != nil }) else { return nil }
        return library
    }

    private static func loadLegacyState() -> LedgerState? {
        let url = storageFolder.appending(path: "ledger.json")
        guard let data = try? Data(contentsOf: url), let state = try? BackupCodec.decoder().decode(LedgerState.self, from: data), (try? BackupCodec.validate(state)) != nil else { return nil }
        return state
    }

    nonisolated private static func writeLibrary(_ library: LedgerLibrary) throws {
        let url = storageFolder.appending(path: "library.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try BackupCodec.encoder().encode(library).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
