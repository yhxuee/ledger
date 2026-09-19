import SwiftUI

/// Owns the floating currency dropdown for one presentation layer (window, sheet, full screen cover).
///
/// The tapped control publishes its frame here; a layer-level overlay draws the panel anchored to
/// that exact control, so no system popover, bubble arrow or detached menu is involved.
@MainActor
final class CurrencyDropdownPresenter: ObservableObject {
    struct Presentation: Identifiable {
        let id = UUID()
        /// Identity of the control that opened the dropdown, so it can show its expanded state.
        var ownerID: UUID
        /// The tapped control's frame, in global coordinates.
        var anchor: CGRect
        var codes: [CurrencyCode]
        var selection: CurrencyCode
        var showsStablecoinNames: Bool
        var requiresConfiguredRate: Bool
        var otherCurrencies: Bool
        var otherPageCodes: [CurrencyCode]?
        var onSelect: (CurrencyCode) -> Void
    }

    @Published private(set) var dropdown: Presentation?
    @Published private(set) var fullSelector: Presentation?

    func present(_ presentation: Presentation) { dropdown = presentation }
    func dismissDropdown() { dropdown = nil }

    /// `Other Currencies…` replaces the floating panel with the full searchable selector.
    func presentFullSelector(from presentation: Presentation) {
        dropdown = nil
        fullSelector = presentation
    }
    func dismissFullSelector() { fullSelector = nil }
}

private struct CurrencyDropdownPresenterKey: EnvironmentKey {
    /// `nil` keeps a missing host harmless instead of trapping.
    static let defaultValue: CurrencyDropdownPresenter? = nil
}

extension EnvironmentValues {
    var currencyDropdownPresenter: CurrencyDropdownPresenter? {
        get { self[CurrencyDropdownPresenterKey.self] }
        set { self[CurrencyDropdownPresenterKey.self] = newValue }
    }
}

extension View {
    /// Adds the dropdown host for this presentation layer. Apply it to the root of every screen or
    /// sheet that shows a currency control: `Form`, `List` and `ScrollView` clip their content, so
    /// the floating panel has to live above them.
    func anchoredCurrencyDropdownLayer() -> some View {
        modifier(CurrencyDropdownLayerModifier())
    }
}

private struct CurrencyDropdownLayerModifier: ViewModifier {
    @StateObject private var presenter = CurrencyDropdownPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.currencyDropdownPresenter, presenter)
            .overlay { CurrencyDropdownOverlay(presenter: presenter) }
    }
}

/// One reusable anchored currency control.
///
/// The label is the collapsed selection row and stays the visual origin of the expanded panel:
/// tapping it floats the options directly under (or above) the control, inside the surrounding
/// glass/card language. Layout of the enclosing `Form`, `List` or `ScrollView` never grows.
struct AnchoredCurrencyDropdown<Label: View>: View {
    @Environment(\.currencyDropdownPresenter) private var presenter
    /// Stable identity for this control, so it can report its own expanded state across redraws.
    @State private var ownerID = UUID()
    @State private var anchor: CGRect = .zero

    var title: String
    var codes: [CurrencyCode]
    var selection: CurrencyCode
    var otherCurrencies = false
    var otherPageCodes: [CurrencyCode]? = nil
    var showsStablecoinNames = true
    var requiresConfiguredRate = true
    var onSelect: (CurrencyCode) -> Void
    @ViewBuilder var label: () -> Label

    private var expanded: Bool { presenter?.dropdown?.ownerID == ownerID }

    var body: some View {
        Group {
            if let presenter {
                // Observed so the control can show its own expanded state across redraws.
                CurrencyDropdownExpandedState(presenter: presenter, ownerID: ownerID) { expanded in
                    decorated(expanded: expanded)
                }
            } else {
                decorated(expanded: false)
            }
        }
    }

    private func decorated(expanded: Bool) -> some View {
        label()
            .background {
                if expanded {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .padding(.horizontal, -7)
                        .padding(.vertical, -3)
                }
            }
            .background(anchorReader)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(selection.rawValue)
            .accessibilityAddTraits(.isButton)
    }

    private var anchorReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { anchor = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, value in anchor = value }
        }
    }

    private func toggle() {
        guard let presenter else { return }
        guard !expanded else { presenter.dismissDropdown(); return }
        presenter.present(.init(ownerID: ownerID,
                                anchor: anchor,
                                codes: codes,
                                selection: selection,
                                showsStablecoinNames: showsStablecoinNames,
                                requiresConfiguredRate: requiresConfiguredRate,
                                otherCurrencies: otherCurrencies,
                                otherPageCodes: otherPageCodes,
                                onSelect: onSelect))
    }
}

/// Reports whether the dropdown owned by `ownerID` is open, so the control renders its expanded
/// state without every screen having to observe the presenter itself.
private struct CurrencyDropdownExpandedState<Content: View>: View {
    @ObservedObject var presenter: CurrencyDropdownPresenter
    let ownerID: UUID
    @ViewBuilder var content: (_ expanded: Bool) -> Content

    var body: some View { content(presenter.dropdown?.ownerID == ownerID) }
}

/// Layer-level host: the transparent dismissal layer, the floating panel and the full selector.
struct CurrencyDropdownOverlay: View {
    @ObservedObject var presenter: CurrencyDropdownPresenter
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if presenter.dropdown != nil {
                    // Transparent full-screen dismissal layer behind the dropdown panel.
                    Color.black.opacity(0.0001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { presenter.dismissDropdown() }
                        .accessibilityHidden(true)
                        .zIndex(1)
                }
                if let presentation = presenter.dropdown {
                    CurrencyDropdownPanel(presentation: presentation, presenter: presenter, containerOrigin: origin, containerSize: proxy.size)
                        .zIndex(2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.16), value: presenter.dropdown?.ownerID)
        }
        .allowsHitTesting(presenter.dropdown != nil)
        .sheet(item: fullSelectorBinding) { presentation in
            NavigationStack {
                CurrencySearchList(codes: presentation.otherPageCodes ?? store.availableCurrencies,
                                   selection: presentation.selection,
                                   showsStablecoinNames: presentation.showsStablecoinNames) { code in
                    presentation.onSelect(code)
                    presenter.dismissFullSelector()
                }
                .navigationTitle("All Currencies")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { presenter.dismissFullSelector() } } }
            }
        }
    }

    private var fullSelectorBinding: Binding<CurrencyDropdownPresenter.Presentation?> {
        Binding(get: { presenter.fullSelector }, set: { if $0 == nil { presenter.dismissFullSelector() } })
    }
}

/// The floating options panel: measured against the tapped control, placed below or above it and
/// clamped so it can never leave the visible container.
struct CurrencyDropdownPanel: View {
    @EnvironmentObject private var store: LedgerStore
    let presentation: CurrencyDropdownPresenter.Presentation
    let presenter: CurrencyDropdownPresenter
    let containerOrigin: CGPoint
    let containerSize: CGSize

    private static let maxHeight: CGFloat = 340
    private static let minHeight: CGFloat = 46
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 12
    private static let minWidth: CGFloat = 216
    private static let rowHeight: CGFloat = 40
    private static let footerHeight: CGFloat = 46

    var body: some View {
        let frame = placement
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(presentation.codes) { code in row(code) }
                }
                .padding(.vertical, 6)
            }
            if presentation.otherCurrencies {
                Divider()
                Button { presenter.presentFullSelector(from: presentation) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "globe")
                        Text("Other Currencies…")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Self.footerHeight - 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .ledgerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 12)
        .offset(x: frame.minX, y: frame.minY)
    }

    /// Deterministic content height, so the placement decision matches the rendered panel exactly.
    private var contentHeight: CGFloat {
        let rows = CGFloat(presentation.codes.count) * Self.rowHeight + 12
        return rows + (presentation.otherCurrencies ? Self.footerHeight + 1 : 0)
    }

    private var placement: CGRect {
        let anchorMinY = presentation.anchor.minY - containerOrigin.y
        let anchorMaxY = presentation.anchor.maxY - containerOrigin.y
        let anchorMinX = presentation.anchor.minX - containerOrigin.x
        let width = min(max(presentation.anchor.width, Self.minWidth), max(Self.minWidth, containerSize.width - Self.margin * 2))
        let x = min(max(anchorMinX, Self.margin), max(Self.margin, containerSize.width - width - Self.margin))
        let below = containerSize.height - anchorMaxY - Self.gap - Self.margin
        let above = anchorMinY - Self.gap - Self.margin
        let desired = min(contentHeight, Self.maxHeight)
        var height = min(desired, below)
        var y = anchorMaxY + Self.gap
        if below < desired, above > below {
            height = min(desired, above)
            y = anchorMinY - Self.gap - height
        }
        height = max(Self.minHeight, height)
        y = min(max(y, Self.margin), max(Self.margin, containerSize.height - height - Self.margin))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func row(_ code: CurrencyCode) -> some View {
        let available = isAvailable(code)
        return Button {
            guard available else { return }
            presentation.onSelect(code)
            presenter.dismissDropdown()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 14)
                    .opacity(code == presentation.selection ? 1 : 0)
                Text(display(code)).lineLimit(1)
                Spacer(minLength: 8)
                if !available { Text("Set rate").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(available ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .disabled(!available)
        .accessibilityLabel(display(code))
    }

    private func display(_ code: CurrencyCode) -> String {
        guard presentation.showsStablecoinNames, let name = code.stablecoinName else { return code.rawValue }
        return "\(code.rawValue) · \(name)"
    }

    private func isAvailable(_ code: CurrencyCode) -> Bool {
        guard presentation.requiresConfiguredRate else { return true }
        return CurrencyRates.reference(code, in: store.state.settings.rates) != nil
    }
}

/// Fixed ordering and membership rules for the dropdowns, so no screen re-invents them.
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

/// Full searchable currency selector, reached only through `Other Currencies…`.
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

/// One selectable currency row on the full selector page.
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