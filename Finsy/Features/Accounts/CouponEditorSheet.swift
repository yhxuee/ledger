import SwiftUI

struct CouponEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let existingCoupon: WalletCoupon?
    let defaultCurrency: CurrencyCode
    let availableCurrencies: [CurrencyCode]
    let onSave: (WalletCoupon) -> Void

    @State private var name: String
    @State private var faceValue: Double
    @State private var currency: CurrencyCode
    @State private var expirationDate: Date
    @State private var reminderEnabled: Bool

    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }

    init(coupon: WalletCoupon? = nil, defaultCurrency: CurrencyCode, availableCurrencies: [CurrencyCode] = [], onSave: @escaping (WalletCoupon) -> Void) {
        existingCoupon = coupon
        self.defaultCurrency = defaultCurrency
        self.availableCurrencies = availableCurrencies.isEmpty ? [defaultCurrency] : availableCurrencies
        self.onSave = onSave

        _name = State(initialValue: coupon?.name ?? "")
        _faceValue = State(initialValue: coupon?.faceValue ?? 10)
        _currency = State(initialValue: coupon?.currency ?? defaultCurrency)
        _expirationDate = State(initialValue: coupon?.expirationDate ?? Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now)
        _reminderEnabled = State(initialValue: coupon?.reminderEnabled ?? true)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && faceValue > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Coupon Information") {
                    TextField("Coupon Name", text: $name)
                    LabeledContent("Face Value") {
                        SensitiveNumericField(placeholder: "0.00", value: $faceValue, fractionDigits: 2, width: 120)
                    }
                    if availableCurrencies.count > 1 {
                        Picker("Currency", selection: $currency) {
                            ForEach(availableCurrencies, id: \.self) { code in
                                Text(code.rawValue).tag(code)
                            }
                        }
                    } else {
                        LabeledContent("Currency") {
                            Text(currency.rawValue).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Validity") {
                    DatePicker("Expiration Date", selection: $expirationDate, displayedComponents: [.date])
                    Toggle("Remind 1 Day Before Expiry", isOn: $reminderEnabled)
                }
            }
            .navigationTitle(existingCoupon == nil ? "Add Coupon" : "Edit Coupon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let now = Date.now
                        let coupon = WalletCoupon(
                            id: existingCoupon?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            currency: currency,
                            faceValue: faceValue,
                            expirationDate: expirationDate,
                            reminderEnabled: reminderEnabled,
                            usedAt: existingCoupon?.usedAt,
                            linkedTransactionID: existingCoupon?.linkedTransactionID,
                            createdAt: existingCoupon?.createdAt ?? now,
                            updatedAt: now
                        )
                        onSave(coupon)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
    }
}

