import PhotosUI
import SwiftUI
import UIKit

struct AccountsView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var stockRefresh = StockQuoteRefreshService.shared
    @State private var editing: AccountViewModel?
    @State private var creating = false
    @State private var deleting: LedgerAccount?
    @State private var isReordering = false
    private var portfolio: (netWorth: Double, assets: Double, liabilities: Double) { LedgerCalculations.portfolioSummary(store.state) }
    private var primaryActionColor: Color { LedgerPalette.primaryAction(for: colorScheme) }

    var body: some View {
        List {
            Section {
                AccountsPortfolioSummaryView(netWorth: portfolio.netWorth, assets: portfolio.assets, liabilities: portfolio.liabilities, currency: store.state.settings.baseCurrency)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if store.accounts.contains(where: { $0.account.type == .stocks }), let status = stockRefresh.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            if store.accounts.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text("No Accounts")
                            .font(.headline)
                        Button {
                            creating = true
                        } label: {
                            Label("Add Account", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(primaryActionColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.accounts) { item in
                        accountRowContent(item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !isReordering {
                                    editing = item
                                }
                            }
                            .onLongPressGesture {
                                if !isReordering {
                                    isReordering = true
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { offsets, destination in
                        store.moveAccounts(from: offsets, to: destination)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(LedgerBackground())
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        .navigationTitle("Accounts")
        .toolbar {
            if isReordering {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isReordering = false
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(primaryActionColor)
                    .accessibilityLabel("Done")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) { ToolbarIconButton(systemName: "plus", label: "Add account") { creating = true } }
                if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                ToolbarItem(placement: .topBarTrailing) { LedgerBookMenu() }
            }
        }
        .sheet(item: $editing) { item in
            AccountEditorView(item: item) { deleting = $0 }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $creating) {
            AccountEditorView(item: nil) { deleting = $0 }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "account")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Account and Linked Transactions", role: .destructive) { if let deleting { store.deleteAccount(deleting) }; deleting = nil }
        } message: { Text("The account and linked transactions will be soft-deleted and excluded from all totals.") }
    }

    private func accountRowContent(_ item: AccountViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text(item.account.logo).font(.caption.bold()).frame(width: 42, height: 42).background(LinearGradient(colors: [Color(hex: item.account.cardStyle.startHex), Color(hex: item.account.cardStyle.endHex)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading) { Text(item.account.name).font(.headline).lineLimit(1); Text(item.account.metadataLine).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                SensitiveMoneyText(amount: item.balance, currency: item.account.currency, maxIntegerDigits: 4).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.85)
                    .frame(minWidth: LedgerAmountWidth.row, alignment: .trailing)
                    .layoutPriority(1)
                if !isReordering {
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
            }
            if item.account.type == .stocks, let stock = item.account.stockMetadata {
                StockValuationView(stock: stock).font(.subheadline)
            }
        }.padding(15).ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AccountEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var primaryActionColor: Color {
        LedgerPalette.primaryAction(for: colorScheme)
    }
    let onDelete: (LedgerAccount) -> Void
    @State private var account: LedgerAccount
    @State private var desiredBalance: Double
    @State private var desiredPocketBalances: [CurrencyCode: Double] = [:]
    @State private var pocketBalancesInitialized = false
    @State private var symbolDraft: String = ""
    @State private var searchResults: [AlphaVantageService.Match] = []
    @State private var searchStatus: String?
    @State private var selectedProviderSymbol: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var interestEnabled: Bool
    private let isNew: Bool

    private let presets: [CardStyle] = [
        .init(startHex: "F6C3D8", endHex: "F4CC67"), .init(startHex: "86C5DA", endHex: "C6E7CF"),
        .init(startHex: "D4B8F4", endHex: "F8A58C"), .init(startHex: "203E59", endHex: "6A7D89"),
        .init(startHex: "F4A261", endHex: "E76F51")
    ]

    /// Manual entry remains available regardless of provider availability.
    @ViewBuilder private var stockSection: some View {
        Picker("Market", selection: stockMarketBinding) {
            ForEach(StockMarket.allCases) { market in Text(market.rawValue).tag(market) }
        }
        LabeledContent("Stock Code") {
            TextField(stockMarket.symbolExample, text: $symbolDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .onSubmit { commitStockSymbol() }
        }
        HStack {
            Text("Settlement Currency")
            Spacer()
            Text(stockMarket.settlementCurrency.rawValue).foregroundStyle(.secondary)
        }
        if !symbolDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stockMarket.isValidSymbol(symbolDraft) {
            Text("Expected format: \(stockMarket.symbolExample)").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(searchResults) { result in
            Button {
                selectedProviderSymbol = result.symbol
                symbolDraft = result.symbol
                commitStockSymbol()
                searchResults = []
                searchStatus = nil
            } label: {
                VStack(alignment: .leading) {
                    Text(result.symbol)
                    Text(result.name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let searchStatus { Text(searchStatus).font(.caption).foregroundStyle(.secondary) }
        LabeledContent("Cost Price") {
            SensitiveNumericField(placeholder: "0", value: stockNumber(\.averageCost), fractionDigits: 4, width: 130)
        }
        LabeledContent("Holdings / Quantity") {
            SensitiveNumericField(placeholder: "0", value: stockNumber(\.quantity), fractionDigits: 6, width: 130)
        }
        if let stock = account.stockMetadata { StockValuationView(stock: stock) }
    }

    private var stockMarket: StockMarket { account.stockMetadata?.market ?? .US }

    private var stockMarketBinding: Binding<StockMarket> {
        Binding(get: { account.stockMetadata?.market ?? .US }, set: { market in
            guard account.stockMetadata?.market != market else { return }
            let old = account.stockMetadata
            account.stockMetadata = .init(market: market, symbol: "", averageCost: old?.averageCost ?? 0, quantity: old?.quantity ?? 0)
            selectedProviderSymbol = nil
            searchResults = []
            account.currency = market.settlementCurrency
            symbolDraft = account.stockMetadata?.symbol ?? ""
        })
    }

    private func stockNumber(_ path: WritableKeyPath<StockMetadata, Double>) -> Binding<Double> {
        Binding(get: { account.stockMetadata?[keyPath: path] ?? 0 }, set: { value in
            if account.stockMetadata == nil { account.stockMetadata = .init(market: stockMarket, symbol: symbolDraft) }
            account.stockMetadata?[keyPath: path] = value.isFinite ? max(0, value) : 0
        })
    }

    private func commitStockSymbol() {
        var stock = account.stockMetadata ?? .init(market: stockMarket, symbol: "")
        let raw = symbolDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = raw == selectedProviderSymbol ? raw : raw.uppercased()
        if stock.symbol != symbol {
            stock.latestPrice = nil
            stock.latestPriceAt = nil
        }
        stock.symbol = symbol
        stock.providerSymbol = selectedProviderSymbol == symbol ? selectedProviderSymbol : nil
        account.stockMetadata = stock
    }

    private var searchIdentity: String { "\(stockMarket.rawValue):\(symbolDraft)" }
    private func searchSymbols() async {
        searchResults = []
        searchStatus = nil
        guard account.type == .stocks else { return }
        let query = symbolDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, query != selectedProviderSymbol else { return }
        let market = stockMarket
        do {
            try await Task.sleep(for: .milliseconds(500))
            try Task.checkCancellation()
            let results = try await AlphaVantageService.shared.search(query, market: market)
            try Task.checkCancellation()
            searchResults = results
            if results.isEmpty { searchStatus = "No matching symbols. Manual entry is available." }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { searchStatus = error.localizedDescription } }
    }

    private func pocketBalanceBinding(_ currency: CurrencyCode) -> Binding<Double> {
        Binding(get: { desiredPocketBalances[currency] ?? 0 }, set: { desiredPocketBalances[currency] = $0 })
    }

    private func addPocket(_ code: CurrencyCode) {
        var pockets = account.normalizedPockets
        guard !pockets.contains(where: { $0.currency == code }) else { return }
        pockets.append(.init(currency: code, openingBalance: 0))
        account.currencyPockets = pockets
        if desiredPocketBalances[code] == nil { desiredPocketBalances[code] = 0 }
    }

    /// Removes pockets from the editor list. The primary currency cannot be removed here, and a
    /// pocket that still holds money is rejected by `LedgerStore.pocketRemovalMessage`.
    private func removePockets(at offsets: IndexSet) {
        var pockets = account.normalizedPockets
        for index in offsets.filter({ pockets.indices.contains($0) && pockets[$0].currency != account.currency }).sorted(by: >) {
            pockets.remove(at: index)
        }
        account.currencyPockets = pockets
    }

    init(item: AccountViewModel?, onDelete: @escaping (LedgerAccount) -> Void) {
        self.onDelete = onDelete
        isNew = item == nil
        let new = LedgerAccount(id: UUID(), userID: SeedData.localUserID, name: "New Account", type: .checking, currency: .HKD, openingBalance: 0, budget: 0, includeInBudget: false, logo: "NEW", cardStyle: .init(startHex: "86C5DA", endHex: "C6E7CF"), createdAt: .now, updatedAt: .now, deletedAt: nil, version: 0, syncStatus: .pending)
        _account = State(initialValue: item?.account ?? new)
        _desiredBalance = State(initialValue: item?.account.type == .loan ? abs(item?.balance ?? 0) : item?.balance ?? 0)
        _interestEnabled = State(initialValue: item?.account.loanMetadata?.interestInterval != nil)
        _symbolDraft = State(initialValue: item?.account.stockMetadata?.symbol ?? "")
        _selectedProviderSymbol = State(initialValue: item?.account.stockMetadata?.providerSymbol)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { AccountCardView(account: .init(account: account, balance: account.type == .stocks ? (account.stockMetadata?.value ?? 0) : desiredBalance), baseCurrency: account.currency, compact: true).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section("Account") {
                    TextField("Name", text: $account.name)
                    TextField("Tag", text: $account.logo).textInputAutocapitalization(.characters).onChange(of: account.logo) { _, value in account.logo = String(value.prefix(4)).uppercased() }
                    Picker("Type", selection: $account.type) { ForEach(AccountType.allCases) { Text($0.rawValue).tag($0) } }
                        .onChange(of: account.type) { _, value in
                            if value == .loan, account.loanMetadata == nil { account.loanMetadata = .init(annualPercentageRate: 0, interestInterval: nil, customIntervalDays: 30, linkedRecurringRuleID: nil) }
                            if value != .loan { interestEnabled = false }
                            // Multi-currency only exists for checking / savings / credit.
                            if !account.supportsMultiCurrency { account.isMultiCurrency = false }
                            if value == .stocks {
                                let market = account.stockMetadata?.market ?? .US
                                if account.stockMetadata == nil { account.stockMetadata = .init(market: market, symbol: "") }
                                account.currency = market.settlementCurrency
                            }
                        }
                    if account.type == .stocks {
                        stockSection
                    } else {
                        if account.supportsMultiCurrency {
                            Toggle("Multi-Currency Account", isOn: $account.isMultiCurrency)
                        }
                        if account.usesCurrencyPockets {
                            LabeledContent("Primary Currency") {
                                CurrencyMenuButton(selection: $account.currency, codes: account.pocketCurrencies,
                                                   title: "Primary Currency", requiresConfiguredRate: false)
                            }
                            ForEach(account.normalizedPockets) { pocket in
                                LabeledContent(pocket.currency.rawValue) {
                                    SensitiveNumericField(placeholder: "0", value: pocketBalanceBinding(pocket.currency), fractionDigits: 2, width: 130)
                                }
                            }
                            .onDelete(perform: removePockets)
                            CurrencyMenuButton(adding: CurrencySelection.addable(excluding: account.pocketCurrencies),
                                                    otherCodes: store.availableCurrencies.filter { !account.pocketCurrencies.contains($0) },
                                                    onSelect: addPocket)
                        } else {
                            CurrencyPickerLink(selection: $account.currency)
                                .onChange(of: account.currency) { oldValue, newValue in
                                    desiredBalance = LedgerCalculations.convert(desiredBalance, from: oldValue, to: newValue, rates: store.state.settings.rates)
                                }
                            if account.type != .loan { LabeledContent("Current Balance") { SensitiveNumericField(placeholder: "0", value: $desiredBalance, fractionDigits: 2, width: 130) } }
                        }
                    }
                    if let warning = store.pocketRemovalMessage(for: account) {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                if account.type == .loan {
                    Section("Loan") {
                        LabeledContent("Outstanding Principal") { SensitiveNumericField(placeholder: "0", value: $desiredBalance, fractionDigits: 2, width: 130) }
                        LabeledContent("APR") { HStack { SensitiveNumericField(placeholder: "0", value: loanAPR, fractionDigits: 3, width: 100); Text("%").foregroundStyle(.secondary) } }
                        Toggle("Recurring Interest", isOn: $interestEnabled)
                        if interestEnabled {
                            Picker("Interest Frequency", selection: loanInterval) { ForEach(RecurringInterval.allCases) { Text($0.title).tag($0) } }
                            if loanInterval.wrappedValue == .customDays { Stepper("Every \(loanCustomDays.wrappedValue) days", value: loanCustomDays, in: 1...365) }
                        }
                        Text("Interest is recalculated from the current outstanding principal each time it runs.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Card Style") {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(presets, id: \.self) { style in Button { account.cardStyle = style } label: { RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: style.startHex), Color(hex: style.endHex)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 74, height: 48).overlay { if account.cardStyle == style { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white) } } }.buttonStyle(.plain) } } }
                    ColorPicker("Start Color", selection: Binding(get: { Color(hex: account.cardStyle.startHex) }, set: { account.cardStyle.startHex = $0.rgbHex }))
                    ColorPicker("End Color", selection: Binding(get: { Color(hex: account.cardStyle.endHex) }, set: { account.cardStyle.endHex = $0.rgbHex }))
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Choose Card Photo", systemImage: "photo") }
                    if account.cardImageData != nil { Button("Remove Card Photo", role: .destructive) { account.cardImageData = nil; photoItem = nil } }
                }
                if !isNew { Section { Button("Delete Account", role: .destructive) { onDelete(account); dismiss() } } }
            }
            .task(id: searchIdentity) { await searchSymbols() }
            .navigationTitle(isNew ? "Add Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if account.type == .stocks {
                    commitStockSymbol()
                }
                // Pocket balances come from the persisted account, never from the desired-balance field.
                guard !pocketBalancesInitialized else { return }
                pocketBalancesInitialized = true
                guard let existing = store.state.accounts.first(where: { $0.id == account.id }), existing.usesCurrencyPockets else { return }
                desiredPocketBalances = Dictionary(existing.normalizedPockets.map { pocket in
                    (pocket.currency, LedgerCalculations.pocketBalance(pocket.currency, for: existing, in: store.state))
                }, uniquingKeysWith: { first, _ in first })
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(primaryActionColor)
                    .disabled(account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.pocketRemovalMessage(for: account) != nil)
                    .accessibilityLabel("Save")
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self), let resized = resizeCardImage(data) { account.cardImageData = resized }
                    } catch { store.presentedError = "Photo import failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func resizeCardImage(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maximum: CGFloat = 1_200
        let scale = min(1, maximum / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        // Preserve alpha-bearing uploads instead of flattening transparent PNG artwork.
        let alpha = image.cgImage?.alphaInfo
        let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast || alpha == .alphaOnly
        return hasAlpha ? rendered.pngData() : rendered.jpegData(compressionQuality: 0.82)
    }

    private var loanAPR: Binding<Double> { Binding(get: { account.loanMetadata?.annualPercentageRate ?? 0 }, set: { value in ensureLoanMetadata(); account.loanMetadata?.annualPercentageRate = max(0, value) }) }
    private var loanInterval: Binding<RecurringInterval> { Binding(get: { account.loanMetadata?.interestInterval ?? .monthly }, set: { value in ensureLoanMetadata(); account.loanMetadata?.interestInterval = value }) }
    private var loanCustomDays: Binding<Int> { Binding(get: { account.loanMetadata?.customIntervalDays ?? 30 }, set: { value in ensureLoanMetadata(); account.loanMetadata?.customIntervalDays = max(1, value) }) }
    private func ensureLoanMetadata() { if account.loanMetadata == nil { account.loanMetadata = .init(annualPercentageRate: 0, interestInterval: nil, customIntervalDays: 30, linkedRecurringRuleID: nil) } }
    private func save() {
        if account.type == .stocks { commitStockSymbol() }
        account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.logo = account.logo.isEmpty ? String(account.name.prefix(3)).uppercased() : account.logo
        if account.type == .loan {
            ensureLoanMetadata()
            account.loanMetadata?.interestInterval = interestEnabled ? loanInterval.wrappedValue : nil
        } else { account.loanMetadata = nil }
        let primaryDesired = account.usesCurrencyPockets ? (desiredPocketBalances[account.currency] ?? desiredBalance) : desiredBalance
        store.saveAccount(account,
                          desiredBalance: account.type == .loan ? -abs(primaryDesired) : primaryDesired,
                          desiredPocketBalances: account.usesCurrencyPockets ? desiredPocketBalances : [:])
        MarketRefreshBackground.schedule(store: store)
        if account.type == .stocks {
            Task { await StockQuoteRefreshService.shared.refreshIfDue(store: store) }
        }
        dismiss()
    }
}
