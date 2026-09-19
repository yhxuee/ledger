import SwiftUI

struct TransactionCurrencyPicker: View {
    @Binding var selection: CurrencyCode
    var title = "Currency"

    var body: some View {
        CurrencyMenuPicker(selection: $selection, codes: CurrencySelection.common,
                           title: title, showsOther: true)
    }
}

/// Account-side selection is limited to the account's existing currency pockets.
struct AccountPocketPicker: View {
    let account: LedgerAccount
    @Binding var selection: CurrencyCode
    var title: String

    var body: some View {
        CurrencyMenuPicker(selection: $selection, codes: account.pocketCurrencies,
                           title: title, requiresConfiguredRate: false)
    }
}
