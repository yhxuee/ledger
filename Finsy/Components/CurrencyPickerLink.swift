import SwiftUI

struct CurrencyPickerLink: View {
    @Binding var selection: CurrencyCode
    var codes: [CurrencyCode] = CurrencySelection.common
    var showsOther: Bool = true
    var stablecoinDescriptions = true
    var requiresConfiguredRate: Bool = true

    var body: some View {
        LabeledContent("Currency") {
            CurrencyMenuButton(selection: $selection, codes: codes,
                               showsOther: showsOther, showsStablecoinNames: stablecoinDescriptions,
                               requiresConfiguredRate: requiresConfiguredRate)
        }
    }
}
