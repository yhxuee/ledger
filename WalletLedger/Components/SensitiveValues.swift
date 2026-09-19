import SwiftUI

struct SensitiveValueText: View {
    @EnvironmentObject private var privacy: PrivacyController
    let value: String
    var maskLength = 6
    init(_ value: String, maskLength: Int = 6) { self.value = value; self.maskLength = maskLength }
    var body: some View { Text(privacy.isLocked ? String(repeating: "*", count: maskLength) : value) }
}

struct SensitiveMoneyText: View {
    let amount: Double
    let currency: CurrencyCode
    var compact = false
    var body: some View { SensitiveValueText(LedgerFormat.money(amount, currency: currency, compact: compact), maskLength: 8) }
}

struct SensitiveNumericField: View {
    @EnvironmentObject private var privacy: PrivacyController
    let placeholder: String
    @Binding var value: Double
    var fractionDigits = 2
    var width: CGFloat?

    var body: some View {
        Group {
            if privacy.isLocked { Text("********").foregroundStyle(.secondary) }
            else {
                TextField(placeholder, value: $value, format: .number.precision(.fractionLength(0...fractionDigits)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
        }.frame(width: width)
    }
}

struct SensitiveValueContent<Content: View>: View {
    @EnvironmentObject private var privacy: PrivacyController
    let maskLength: Int
    let content: Content
    init(maskLength: Int = 8, @ViewBuilder content: () -> Content) { self.maskLength = maskLength; self.content = content() }
    var body: some View {
        if privacy.isLocked { Text(String(repeating: "*", count: maskLength)).foregroundStyle(.secondary) }
        else { content }
    }
}
