import SwiftUI

struct CurrencyPickerLink: View {
    @Binding var selection: CurrencyCode
    var stablecoinDescriptions = true

    var body: some View {
        LabeledContent("Currency") {
            CurrencyMenuPicker(selection: $selection, codes: CurrencySelection.common,
                               showsOther: true, showsStablecoinNames: stablecoinDescriptions)
        }
    }
}
