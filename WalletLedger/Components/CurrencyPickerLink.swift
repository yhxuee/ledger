import SwiftUI

/// The compact value button expands over its own frame; the form row keeps its size.
/// The full searchable page only appears after Other.
struct CurrencyPickerLink: View {
    @Binding var selection: CurrencyCode
    var stablecoinDescriptions = true

    var body: some View {
        LabeledContent("Currency") {
            PopupSelectionButton(title: "Currency",
                                     codes: CurrencySelection.common,
                                     selection: selection,
                                     otherCurrencies: true,
                                     showsStablecoinNames: stablecoinDescriptions,
                                     onSelect: { selection = $0 }) {
                HStack {
                    Text(selection.rawValue).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
