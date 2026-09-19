import SwiftUI

/// Compact chip trigger for the transaction currency. The chip itself expands into the anchored
/// dropdown; the full searchable page is only reached through `Other Currencies…`.
struct TransactionCurrencyPicker: View {
    @Binding var selection: CurrencyCode
    var title = "Currency"

    var body: some View {
        PopupSelectionButton(title: title,
                                 codes: CurrencySelection.common,
                                 selection: selection,
                                 otherCurrencies: true,
                                 onSelect: { selection = $0 }) {
            HStack(spacing: 6) {
                Text(selection.rawValue).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .ledgerGlass(interactive: true, in: Capsule())
        }
    }
}

/// Currency-pocket selector for the account side of a transaction: the same anchored dropdown, but
/// limited to the currencies this account already holds. Single-currency accounts never show it.
struct AccountPocketPicker: View {
    let account: LedgerAccount
    @Binding var selection: CurrencyCode
    var title: String

    var body: some View {
        PopupSelectionButton(title: title,
                                 codes: account.pocketCurrencies,
                                 selection: selection,
                                 showsStablecoinNames: false,
                                 requiresConfiguredRate: false,
                                 onSelect: { selection = $0 }) {
            HStack(spacing: 6) {
                Text(selection.rawValue)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}