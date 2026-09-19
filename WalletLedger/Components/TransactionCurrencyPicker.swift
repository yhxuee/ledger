import SwiftUI

/// Compact chip trigger for the transaction currency. Tapping it floats the shared
/// common-currency popover; the full searchable page is only reached through `Other Currencies…`.
struct TransactionCurrencyPicker: View {
    @Binding var selection: CurrencyCode
    var title = "Currency"

    var body: some View {
        CurrencyQuickPicker(codes: CurrencySelection.commonWithStablecoins,
                            selection: selection,
                            otherCurrencies: true,
                            onSelect: { selection = $0 }) {
            HStack(spacing: 6) {
                Text(selection.rawValue).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .ledgerGlass(interactive: true, in: Capsule())
        }
        .accessibilityLabel(title)
        .accessibilityValue(selection.rawValue)
    }
}

/// Currency-pocket selector for the account side of a transaction: the same floating style, but
/// limited to the currencies this account already holds. Single-currency accounts never show it.
struct AccountPocketPicker: View {
    let account: LedgerAccount
    @Binding var selection: CurrencyCode
    var title: String

    var body: some View {
        CurrencyQuickPicker(codes: account.pocketCurrencies,
                            selection: selection,
                            showsStablecoinNames: false,
                            requiresConfiguredRate: false,
                            onSelect: { selection = $0 }) {
            HStack(spacing: 6) {
                Text(selection.rawValue).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(selection.rawValue)
    }
}