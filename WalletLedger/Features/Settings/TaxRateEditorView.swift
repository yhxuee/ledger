import SwiftUI

struct TaxRateEditorView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        List {
            Section {
                Toggle("Tax-Inclusive Amounts", isOn: Binding(
                    get: { store.state.settings.isTaxInclusive },
                    set: { newValue in
                        store.updateSettings { settings in
                            var taxes = settings.taxSettings ?? TaxSettings()
                            taxes.isTaxInclusive = newValue
                            settings.taxSettings = taxes
                        }
                    }
                ))
            } footer: {
                Text("When enabled, entered amounts include tax (or after-tax for income). When disabled, amounts are entered before tax.")
            }

            ratesSection("Expense Categories", kind: .expense)
            ratesSection("Income Categories", kind: .income)
        }
        .scrollContentBackground(.hidden)
        .background(LedgerBackground())
        .navigationTitle("Tax Rates")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ratesSection(_ title: LocalizedStringKey, kind: LedgerCategoryKind) -> some View {
        Section(title) {
            ForEach(store.state.categories.filter { $0.kind == kind }) { category in
                TaxRateField(category: category, rate: store.state.settings.taxRate(for: category)) { rate in
                    store.updateSettings { settings in
                        var taxes = settings.taxSettings ?? TaxSettings()
                        taxes.categoryRates[category.id] = rate
                        settings.taxSettings = taxes
                    }
                }
            }
        }
    }
}

private struct TaxRateField: View {
    let category: LedgerCategory
    let rate: Double
    let save: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.number(from: text)?.doubleValue
    }

    private var valid: Bool {
        guard let percent = parsed, percent.isFinite, percent >= 0 else { return false }
        return category.kind == .income ? percent < 100 : percent <= 1_000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                CategoryIcon(category: category, font: .system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: category.colorHex))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: category.colorHex).opacity(0.14), in: Circle())
                Text(category.name)
                Spacer()
                TextField("Rate", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .focused($focused)
                    .accessibilityLabel(Text(category.name) + Text(" Tax rate"))
                Text("%")
                    .foregroundStyle(.secondary)
            }
            if !valid && !text.isEmpty {
                Text(category.kind == .income ? "Income tax must be below 100%." : "Enter a rate from 0% to 1000%.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            text = TaxCalculations.percentString(rate)
        }
        .onChange(of: text) { _, _ in
            if valid, let percent = parsed {
                save(percent / 100)
            }
        }
        .onChange(of: rate) { _, newRate in
            if !focused {
                text = TaxCalculations.percentString(newRate)
            }
        }
    }
}
