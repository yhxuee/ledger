import SwiftUI

/// Form-row currency selector: tapping the row floats the common-currency popover next to it.
/// The full searchable page only appears after `Other Currencies…`.
struct CurrencyPickerLink: View {
    @Binding var selection: CurrencyCode
    var stablecoinDescriptions = true

    var body: some View {
        CurrencyQuickPicker(codes: CurrencySelection.commonWithStablecoins,
                            selection: selection,
                            otherCurrencies: true,
                            showsStablecoinNames: stablecoinDescriptions,
                            onSelect: { selection = $0 }) {
            HStack {
                Text("Currency")
                Spacer()
                Text(selection.rawValue).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel("Currency")
        .accessibilityValue(selection.rawValue)
    }
}
