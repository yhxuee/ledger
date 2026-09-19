import SwiftUI

/// The one currency-selection pattern used by every screen.
///
/// Tapping the control shows a small floating popover anchored to it, listing the common
/// currencies in a fixed order (plus stablecoins where the caller allows them). Choosing one
/// applies it immediately and closes the popover. Only `Other Currencies…` opens the full
/// searchable page, which is the only place a sheet/page is used.
struct CurrencyQuickPicker<Label: View>: View {
    @EnvironmentObject private var store: LedgerStore
    /// Currencies offered directly in the floating popover, in the given order.
    var codes: [CurrencyCode]
    /// Current value, used for the checkmark.
    var selection: CurrencyCode
    /// Adds the `Other Currencies…` row that opens the full searchable page.
    var otherCurrencies = false
    /// Page contents behind `Other Currencies…`; `nil` means every supported currency.
    var otherPageCodes: [CurrencyCode]? = nil
    /// Shows stablecoin names next to their codes.
    var showsStablecoinNames = true
    /// Pockets the account already holds stay selectable even without a configured rate.
    var requiresConfiguredRate = true
    var onSelect: (CurrencyCode) -> Void
    @ViewBuilder var label: () -> Label

    @State private var showingQuickPicker = false
    @State private var showingFullPicker = false

    init(codes: [CurrencyCode],
         selection: CurrencyCode,
         otherCurrencies: Bool = false,
         otherPageCodes: [CurrencyCode]? = nil,
         showsStablecoinNames: Bool = true,
         requiresConfiguredRate: Bool = true,
         onSelect: @escaping (CurrencyCode) -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.codes = codes
        self.selection = selection
        self.otherCurrencies = otherCurrencies
        self.otherPageCodes = otherPageCodes
        self.showsStablecoinNames = showsStablecoinNames
        self.requiresConfiguredRate = requiresConfiguredRate
        self.onSelect = onSelect
        self.label = label
    }

    var body: some View {
        Button { showingQuickPicker = true } label: { label() }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .popover(isPresented: $showingQuickPicker, arrowEdge: .bottom) {
                CurrencyQuickList(codes: codes, selection: selection, showsStablecoinNames: showsStablecoinNames, requiresConfiguredRate: requiresConfiguredRate, showsOtherCurrencies: otherCurrencies, onSelect: apply, onOther: openFullPicker)
                    // Keep the first-level selector floating even on compact iPhone widths.
                    .presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: $showingFullPicker) {
                NavigationStack {
                    CurrencySearchList(codes: otherPageCodes ?? store.availableCurrencies, selection: selection, showsStablecoinNames: showsStablecoinNames) { code in
                        apply(code)
                        showingFullPicker = false
                    }
                    .navigationTitle("All Currencies")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingFullPicker = false } } }
                }
            }
    }

    private func apply(_ code: CurrencyCode) {
        onSelect(code)
        showingQuickPicker = false
    }

    /// The floating popover has to finish dismissing before the full page is presented.
    private func openFullPicker() {
        showingQuickPicker = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { showingFullPicker = true }
    }
}

/// Fixed ordering and membership rules for the quick pickers, so no screen re-invents them.
enum CurrencySelection {
    /// Common currencies in the required order: HKD, USD, GBP, JPY, CNY, EUR, SGD, CHF.
    static var common: [CurrencyCode] { CurrencyCode.preferredFiat }

    /// Common currencies plus the USD stablecoins.
    static var commonWithStablecoins: [CurrencyCode] { CurrencyCode.preferredFiat + CurrencyCode.usdStablecoins }

    /// `commonWithStablecoins` reduced to those that are not already in `excluding`.
    static func addable(excluding existing: [CurrencyCode]) -> [CurrencyCode] {
        commonWithStablecoins.filter { !existing.contains($0) }
    }
}

/// Floating popover content: the common currencies, then `Other Currencies…`.
struct CurrencyQuickList: View {
    @EnvironmentObject private var store: LedgerStore
    let codes: [CurrencyCode]
    let selection: CurrencyCode
    var showsStablecoinNames = true
    var requiresConfiguredRate = true
    var showsOtherCurrencies = false
    let onSelect: (CurrencyCode) -> Void
    let onOther: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    if codes.isEmpty {
                        Text("No currencies available").font(.footnote).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(codes) { code in row(code) }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)
            if showsOtherCurrencies {
                Divider()
                Button(action: onOther) {
                    HStack(spacing: 8) {
                        Label("Other Currencies…", systemImage: "globe")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .frame(width: 234)
    }

    private func row(_ code: CurrencyCode) -> some View {
        let available = isAvailable(code)
        return Button {
            guard available else { return }
            onSelect(code)
        } label: {
            HStack(spacing: 8) {
                Text(display(code)).lineLimit(1)
                Spacer(minLength: 6)
                if code == selection { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                else if !available { Text("Set rate").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(available ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .disabled(!available)
        .accessibilityLabel(display(code))
    }

    private func display(_ code: CurrencyCode) -> String {
        guard showsStablecoinNames, let name = code.stablecoinName else { return code.rawValue }
        return "\(code.rawValue) · \(name)"
    }

    private func isAvailable(_ code: CurrencyCode) -> Bool {
        guard requiresConfiguredRate else { return true }
        return CurrencyRates.reference(code, in: store.state.settings.rates) != nil
    }
}

/// Full searchable currency page. Reached only through `Other Currencies…`.
struct CurrencySearchList: View {
    @EnvironmentObject private var store: LedgerStore
    let codes: [CurrencyCode]
    var selection: CurrencyCode? = nil
    var showsStablecoinNames = true
    let choose: (CurrencyCode) -> Void

    @State private var query = ""

    private var matches: [CurrencyCode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return codes }
        return codes.filter { code in
            code.rawValue.localizedCaseInsensitiveContains(needle) || (code.stablecoinName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var body: some View {
        List(matches) { code in
            CurrencySelectionRow(code: code, description: showsStablecoinNames ? code.stablecoinName : nil, selected: selection, available: CurrencyRates.reference(code, in: store.state.settings.rates) != nil) { choose(code) }
        }
        .searchable(text: $query, prompt: "Currency code or name")
    }
}

/// One selectable currency row, shared by the floating popover and the full page.
struct CurrencySelectionRow: View {
    let code: CurrencyCode
    var description: String? = nil
    var selected: CurrencyCode? = nil
    let available: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                Text(description.map { "\(code.rawValue) · \($0)" } ?? code.rawValue)
                Spacer()
                if code == selected { Image(systemName: "checkmark") }
                if !available { Text("Set rate first").font(.caption).foregroundStyle(.secondary) }
            }
        }.disabled(!available)
    }
}