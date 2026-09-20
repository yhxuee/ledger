import Foundation
import PassKit
import SwiftUI

@MainActor
final class WalletPassManager: ObservableObject {
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

        let formattedBalance = "\(currency.symbol)\(String(format: "%.2f", balance))"
        let activeAccountsCount = store.state.accounts.filter { $0.deletedAt == nil }.count

        return AccountPassSnapshot(
            passTypeIdentifier: Self.accountPassTypeIdentifier,
            serialNumber: Self.accountPassSerialNumber,
            title: title,
            balanceAmount: balance,
            currency: currency,
            formattedBalance: formattedBalance,
            accountCount: activeAccountsCount,
            locations: locations
        )
    }

    func buildPurchaseReceiptSnapshot(
        session: PurchaseSession,
        store: LedgerStore
    ) -> PurchaseReceiptPassSnapshot {
        let completedItems = session.items.filter { $0.isCompleted }
        let total = completedItems.reduce(0.0) { $0 + $1.amount }
        let formattedTotal = "\(session.currency.symbol)\(String(format: "%.2f", total))"
        let itemsSummary = completedItems.prefix(3).map(\.note).joined(separator: ", ") + (completedItems.count > 3 ? "..." : "")

        return PurchaseReceiptPassSnapshot(
            sessionID: session.id,
            storeName: session.name,
            totalAmount: total,
            currency: session.currency,
            formattedTotal: formattedTotal,
            itemCount: completedItems.count,
            itemsSummary: itemsSummary,
            finalizedAt: session.completedAt ?? Date.now
        )
    }

    func buildTaxReceiptSnapshot(
        year: Int,
        month: Int,
        store: LedgerStore
    ) -> TaxReceiptPassSnapshot {
        let baseCurrency = store.state.settings.baseCurrency
        let rates = store.state.settings.rates
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        let startDate = calendar.date(from: comps) ?? Date()
        let endDate = calendar.date(byAdding: .month, value: 1, to: startDate) ?? Date()

        // Monthly expense tax only (NOT income tax!)
        let expenseTxs = store.state.transactions.filter {
            $0.deletedAt == nil &&
            $0.type == .expense &&
            $0.occurredAt >= startDate &&
            $0.occurredAt < endDate
        }

        var totalExpenseTax = 0.0
        var totalTaxableExpense = 0.0

        for tx in expenseTxs {
            let convertedAmount = LedgerCalculations.convert(tx.recognizedExpenseAmount, from: tx.currency, to: baseCurrency, rates: rates)
            if let tax = tx.taxAmount, tax > 0 {
                let convertedTax = LedgerCalculations.convert(tax, from: tx.currency, to: baseCurrency, rates: rates)
                totalExpenseTax += convertedTax
                totalTaxableExpense += convertedAmount
            }
        }

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL yyyy"
        let monthName = monthFormatter.string(from: startDate)

        let formattedExpenseTax = "\(baseCurrency.symbol)\(String(format: "%.2f", totalExpenseTax))"
        let formattedTaxableExpense = "\(baseCurrency.symbol)\(String(format: "%.2f", totalTaxableExpense))"

        return TaxReceiptPassSnapshot(
            year: year,
            month: month,
            monthName: monthName,
            totalExpenseTax: totalExpenseTax,
            totalTaxableExpense: totalTaxableExpense,
            currency: baseCurrency,
            formattedExpenseTax: formattedExpenseTax,
            formattedTaxableExpense: formattedTaxableExpense
        )
    }

    func replaceAccountPass(with pass: PKPass) -> Bool {
        guard isPassLibraryAvailable else { return false }
        return passLibrary.replacePass(with: pass)
    }
}

/// SwiftUI wrapper for PKAddPassesViewController
struct AddPassSheetView: UIViewControllerRepresentable {
    let pass: PKPass
    var onCompletion: (@MainActor @Sendable () -> Void)? = nil

    @MainActor
    func makeUIViewController(context: Context) -> PKAddPassesViewController {
        guard let controller = PKAddPassesViewController(pass: pass) else {
            return PKAddPassesViewController()
        }
        controller.delegate = context.coordinator
        return controller
    }

    @MainActor
    func updateUIViewController(_ uiViewController: PKAddPassesViewController, context: Context) {}

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    @MainActor
    final class Coordinator: NSObject, PKAddPassesViewControllerDelegate {
        let onCompletion: (@MainActor @Sendable () -> Void)?

        init(onCompletion: (@MainActor @Sendable () -> Void)?) {
            self.onCompletion = onCompletion
        }

        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            controller.dismiss(animated: true) { [onCompletion] in
                onCompletion?()
            }
        }
    }
}
