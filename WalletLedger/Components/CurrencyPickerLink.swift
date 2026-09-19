import SwiftUI

/// Form-row currency selector: tapping the row expands the anchored dropdown directly below or
/// above it. The full searchable page only appears after `Other Currencies…`.
struct CurrencyPickerLink: View {
    @Binding var selection: CurrencyCode
    var stablecoinDescriptions = true

    var body: some View {
        AnchoredCurrencyDropdown(title: "Currency",
                                 codes: CurrencySelection.commonWithStablecoins,
                                 selection: selection,
                                 otherCurrencies: true,
                                 showsStablecoinNames: stablecoinDescriptions,
                                 onSelect: { selection = $0 }) {
            HStack {
                Text("Currency")
                Spacer()
                Text(selection.rawValue).foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}
