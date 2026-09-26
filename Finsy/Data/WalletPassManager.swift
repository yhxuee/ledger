import Foundation
@preconcurrency import PassKit
import SwiftUI

@MainActor
final class WalletPassManager: ObservableObject {
    @Published private(set) var refreshStatus: String? = nil
    private var lastRefreshKey: WalletPassRefreshKey?
    private var refreshing = false
    static let shared = WalletPassManager()

    static let accountPassTypeIdentifier = "pass.com.finsy.account"
    static let accountPassSerialNumber = "finsy-primary-account-pass"

    private let passLibrary = PKPassLibrary()
    var issuer: WalletPassIssuer

    init(issuer: WalletPassIssuer = NetworkWalletPassIssuer()) {
        self.issuer = issuer
    }

    var isPassLibraryAvailable: Bool {
        PKPassLibrary.isPassLibraryAvailable()
    }

    var canAddPasses: Bool {
        PKAddPassesViewController.canAddPasses()
    }

    var isIssuerConfigured: Bool {
        issuer.isConfigured
    }

    func isAccountPassInstalled() -> Bool {
        guard isPassLibraryAvailable else { return false }
        return passLibrary.pass(withPassTypeIdentifier: Self.accountPassTypeIdentifier, serialNumber: Self.accountPassSerialNumber) != nil
    }

    func isPassInstalled(passTypeIdentifier: String, serialNumber: String) -> Bool {
        guard isPassLibraryAvailable else { return false }
        return passLibrary.pass(withPassTypeIdentifier: passTypeIdentifier, serialNumber: serialNumber) != nil
    }

    func buildAccountPassSnapshot(
        store: LedgerStore,
        source: WalletAccountPassSource,
        locations: [WalletRelevantLocation]
    ) -> AccountPassSnapshot {
        let title: String
        let balance: Double
        let currency: CurrencyCode

        switch source {
        case .allAccounts:
            title = "Net Worth"
            currency = store.state.settings.baseCurrency
            balance = LedgerCalculations.portfolioBalance(store.state, target: currency)
        case .specificAccount(let id):
            if let account = store.state.accounts.first(where: { $0.id == id && $0.deletedAt == nil }) {
                title = account.name
                currency = account.currency
                balance = LedgerCalculations.balance(for: account, in: store.state)
            } else {
                title = "Account"
                currency = store.state.settings.baseCurrency
                balance = 0
            }
        }

        let formattedBalance = WalletPassFormatting.money(balance, currency: currency)
        let activeAccountsCount = store.state.accounts.filter { $0.deletedAt == nil }.count

        var snapshot = AccountPassSnapshot(
            passTypeIdentifier: Self.accountPassTypeIdentifier,
            serialNumber: Self.accountPassSerialNumber,
            title: title,
            balanceAmount: balance,
            currency: currency,
            formattedBalance: formattedBalance,
            accountCount: activeAccountsCount,
            locations: locations
        )
        let preferences = AppPreferencesStore.shared.value
        let now = Date.now
        let calendar = Calendar.current
        let selectedID: UUID? = { if case .specificAccount(let id) = source { return id }; return nil }()
        let transactions = store.state.transactions.filter {
            $0.deletedAt == nil && $0.occurredAt <= now && $0.isCompleted(asOf: now) &&
            (selectedID == nil || $0.accountID == selectedID || $0.destinationAccountID == selectedID)
        }
        let monthly = transactions.filter { calendar.isDate($0.occurredAt, equalTo: now, toGranularity: .month) }
        let index = LedgerIndex(state: store.state)
        func sum(_ values: [LedgerTransaction], _ type: LedgerTransactionType) -> Double {
            values.reduce(0) { $0 + (LedgerCalculations.transactionEffect($1, in: store.state, to: currency, type: type, now: now, index: index) ?? 0) }
        }
        snapshot.monthTitle = WalletPassFormatting.date(now, format: preferences.dateFormat, monthOnly: true)
        snapshot.formattedExpenses = WalletPassFormatting.money(sum(monthly, .expense), currency: currency)
        snapshot.formattedIncome = WalletPassFormatting.money(sum(monthly, .income), currency: currency)
        snapshot.entries = monthly.filter { !$0.isReversal }.count
        if store.state.settings.budgetPlan.mode == .account {
            let breakdown = LedgerCalculations.budgetBreakdown(store.state, now: now, index: index)
            let lines = breakdown.lines.filter { selectedID == nil || $0.id == "account:\(selectedID!.uuidString)" }
            let remaining = lines.reduce(0) { $0 + LedgerCalculations.convert($1.budget - $1.spent, from: $1.currency, to: currency, rates: store.state.settings.rates) }
            snapshot.remainingLabel = "BUDGET LEFT"
            snapshot.formattedRemaining = WalletPassFormatting.money(remaining, currency: currency)
        } else {
            snapshot.remainingLabel = "TODAY"
            snapshot.formattedRemaining = WalletPassFormatting.money(sum(transactions.filter { calendar.isDateInToday($0.occurredAt) }, .expense), currency: currency)
        }
        snapshot.recentEntries = transactions.sorted { $0.occurredAt > $1.occurredAt }.prefix(5).map { transaction in
            let date = WalletPassFormatting.date(transaction.occurredAt, format: preferences.dateFormat)
            let note = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = note?.isEmpty == false ? note! : transaction.type.rawValue
            return "\(date)  \(transaction.type.rawValue)\n\(title)\n\(WalletPassFormatting.money(transaction.amount, currency: transaction.currency))"
        }.joined(separator: "\n\n")
        snapshot.themeColorHex = preferences.statementThemeColorHex
        return snapshot
    }

    func buildPurchaseReceiptSnapshot(
        session: PurchaseSession,
        store: LedgerStore
    ) -> PurchaseReceiptPassSnapshot {
        let categoryMap = Dictionary(store.state.categories.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let orderedItems = session.orderedItems
        let passItems: [PurchaseReceiptPassItem] = orderedItems.map { item in
            let trimmedNote = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let catName = categoryMap[item.categoryID] ?? item.categoryID.rawValue
            let name = trimmedNote.isEmpty ? catName : trimmedNote
            let linked = store.state.transactions.first { $0.id == item.linkedTransactionID && $0.deletedAt == nil }
            let paidAmount = linked?.recognizedExpenseAmount ?? item.amount
            let formattedAmt = WalletPassFormatting.money(paidAmount, currency: session.currency, space: true)
            return PurchaseReceiptPassItem(
                name: name,
                category: catName,
                amount: paidAmount,
                formattedAmount: formattedAmt
            )
        }

        let total = passItems.reduce(0) { $0 + $1.amount }
        let formattedTotal = WalletPassFormatting.money(total, currency: session.currency, space: true)
        let tax = PurchaseReceiptCalculations.resolvedTax(for: session, in: store.state, isCompleted: true)
        let formattedTax = WalletPassFormatting.money(tax, currency: session.currency, space: true)

        let itemsSummary = orderedItems.prefix(3).map { item in
            let trimmedNote = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedNote.isEmpty ? (categoryMap[item.categoryID] ?? item.categoryID.rawValue) : trimmedNote
        }.joined(separator: ", ") + (orderedItems.count > 3 ? "..." : "")

        var snapshot = PurchaseReceiptPassSnapshot(
            sessionID: session.id,
            storeName: session.name,
            totalAmount: total,
            currency: session.currency,
            formattedTotal: formattedTotal,
            itemCount: orderedItems.count,
            itemsSummary: itemsSummary,
            items: passItems,
            taxAmount: tax,
            formattedTax: formattedTax,
            finalizedAt: session.completedAt ?? Date.now
        )
        let preferences = AppPreferencesStore.shared.value
        snapshot.formattedDate = WalletPassFormatting.date(session.completedAt ?? session.createdAt, format: preferences.dateFormat)
        snapshot.payment = store.state.accounts.first { $0.id == session.accountID }?.logo ?? "Unavailable"
        let orderedSessions = (store.state.purchaseSessions ?? []).sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        snapshot.invoiceNumber = String(format: "P-%06d", session.receiptNumber ?? ((orderedSessions.firstIndex { $0.id == session.id } ?? 0) + 1))
        let linkedIDs = Set(session.items.compactMap(\.linkedTransactionID))
        let originals = store.state.transactions.filter { $0.deletedAt == nil && !$0.isReversal && ($0.purchaseSessionID == session.id || linkedIDs.contains($0.id)) }
        let refunded = originals.filter(\.isRefunded).count
        snapshot.transactionStatus = refunded == 0 ? "Paid" : (refunded == originals.count ? "Refunded" : "Partially Refunded")
        snapshot.themeColorHex = preferences.statementThemeColorHex
        return snapshot
    }

    func replaceAccountPass(with pass: PKPass) -> Bool {
        guard isPassLibraryAvailable else { return false }
        return passLibrary.replacePass(with: pass)
    }

    /// Refresh installed passes after local edits, refunds, sync and source/theme changes.
    /// No claim of server push: refresh runs while the app is active.
    func refreshInstalledPasses(store: LedgerStore, preferences: AppPreferences, force: Bool = false) async {
        let key = WalletPassRefreshKey(bookID: store.activeBookID, modifiedAt: store.state.lastModifiedAt, preferences: preferences)
        guard isIssuerConfigured, isPassLibraryAvailable, force || lastRefreshKey != key else { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        // A previous signing request can still be finishing after its task was cancelled.
        // Wait for it rather than dropping the newest ledger revision.
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        guard force || lastRefreshKey != key else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if isAccountPassInstalled() {
                let snapshot = buildAccountPassSnapshot(store: store, source: preferences.walletAccountPassSource, locations: preferences.walletPassLocations)
                let pass = try await issuer.issueAccountPass(snapshot: snapshot)
                guard !Task.isCancelled else { return }
                guard passLibrary.replacePass(with: pass) else { throw WalletPassError.invalidPassData }
            }
            for session in store.purchaseSessions where session.status == .completed {
                let serial = "purchase-\(session.id.uuidString)"
                guard isPassInstalled(passTypeIdentifier: "pass.com.finsy.receipt", serialNumber: serial) else { continue }
                var snapshot = buildPurchaseReceiptSnapshot(session: session, store: store)
                // Preserve the scanned barcode when updating the ledger status.
                if let data = UserDefaults.standard.data(forKey: "wallet-barcode-\(serial)") {
                    snapshot.barcode = try? JSONDecoder().decode(WalletReceiptBarcode.self, from: data)
                }
                let pass = try await issuer.issuePurchaseReceiptPass(snapshot: snapshot)
                guard !Task.isCancelled else { return }
                guard passLibrary.replacePass(with: pass) else { throw WalletPassError.invalidPassData }
            }
            lastRefreshKey = key
            refreshStatus = "Up to date"
        } catch {
            refreshStatus = error.localizedDescription
        }
    }
}

struct WalletPassRefreshKey: Equatable {
    var bookID: UUID
    var modifiedAt: Date
    var preferences: AppPreferences
}

/// SwiftUI wrapper for PKAddPassesViewController
struct AddPassSheetView: UIViewControllerRepresentable {
    let pass: PKPass
    var onCompletion: (@MainActor @Sendable () -> Void)? = nil

    func makeUIViewController(context: Context) -> PKAddPassesViewController {
        guard let controller = PKAddPassesViewController(pass: pass) else {
            return PKAddPassesViewController()
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PKAddPassesViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, @preconcurrency PKAddPassesViewControllerDelegate {
        let onCompletion: (@MainActor @Sendable () -> Void)?

        init(onCompletion: (@MainActor @Sendable () -> Void)?) {
            self.onCompletion = onCompletion
        }

        @MainActor
        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            controller.dismiss(animated: true) { [onCompletion] in
                onCompletion?()
            }
        }
    }
}
