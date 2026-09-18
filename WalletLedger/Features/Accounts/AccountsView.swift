import PhotosUI
import SwiftUI
import UIKit

struct AccountsView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var editing: AccountViewModel?
    @State private var creating = false
    @State private var deleting: LedgerAccount?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AccountCardView(account: nil, portfolioBalance: LedgerCalculations.portfolioBalance(store.state), baseCurrency: store.state.settings.baseCurrency)
                LazyVStack(spacing: 10) {
                    ForEach(store.accounts) { item in
                        Button { editing = item } label: {
                            HStack(spacing: 14) {
                                Text(item.account.logo).font(.caption.bold()).frame(width: 42, height: 42).background(LinearGradient(colors: [Color(hex: item.account.cardStyle.startHex), Color(hex: item.account.cardStyle.endHex)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading) { Text(item.account.name).font(.headline); Text("\(item.account.type.rawValue) · \(item.account.currency.rawValue)").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(LedgerFormat.money(item.balance, currency: item.account.currency)).font(.headline.monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }.padding(15).ledgerGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ToolbarIconButton(systemName: "plus", label: "Add account") { creating = true } }
            if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) { LedgerBookMenu() }
        }
        .sheet(item: $editing) { item in AccountEditorView(item: item) { deleting = $0 } }
        .sheet(isPresented: $creating) { AccountEditorView(item: nil) { deleting = $0 } }
        .confirmationDialog("Delete \(deleting?.name ?? "account")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Account and Linked Transactions", role: .destructive) { if let deleting { store.deleteAccount(deleting) }; deleting = nil }
        } message: { Text("The account and linked transactions will be soft-deleted and excluded from all totals.") }
    }
}

private struct AccountEditorView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let onDelete: (LedgerAccount) -> Void
    @State private var account: LedgerAccount
    @State private var desiredBalance: Double
    @State private var photoItem: PhotosPickerItem?
    private let isNew: Bool

    private let presets: [CardStyle] = [
        .init(startHex: "F6C3D8", endHex: "F4CC67"), .init(startHex: "86C5DA", endHex: "C6E7CF"),
        .init(startHex: "D4B8F4", endHex: "F8A58C"), .init(startHex: "203E59", endHex: "6A7D89"),
        .init(startHex: "F4A261", endHex: "E76F51")
    ]

    init(item: AccountViewModel?, onDelete: @escaping (LedgerAccount) -> Void) {
        self.onDelete = onDelete
        isNew = item == nil
        let new = LedgerAccount(id: UUID(), userID: SeedData.localUserID, name: "New Account", type: .checking, currency: .HKD, openingBalance: 0, budget: 1_000, includeInBudget: true, logo: "NEW", cardStyle: .init(startHex: "86C5DA", endHex: "C6E7CF"), createdAt: .now, updatedAt: .now, deletedAt: nil, version: 0, syncStatus: .pending)
        _account = State(initialValue: item?.account ?? new)
        _desiredBalance = State(initialValue: item?.balance ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { AccountCardView(account: .init(account: account, balance: desiredBalance), baseCurrency: account.currency, compact: true).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section("Account") {
                    TextField("Name", text: $account.name)
                    TextField("Logo", text: $account.logo).textInputAutocapitalization(.characters).onChange(of: account.logo) { _, value in account.logo = String(value.prefix(4)).uppercased() }
                    Picker("Type", selection: $account.type) { ForEach(AccountType.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Currency", selection: $account.currency) { ForEach(CurrencyCode.allCases) { Text($0.rawValue).tag($0) } }
                        .onChange(of: account.currency) { oldValue, newValue in
                            desiredBalance = LedgerCalculations.convert(desiredBalance, from: oldValue, to: newValue, rates: store.state.settings.rates)
                            account.budget = LedgerCalculations.convert(account.budget, from: oldValue, to: newValue, rates: store.state.settings.rates)
                        }
                    LabeledContent("Current Balance") { TextField("0", value: $desiredBalance, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                }
                Section("Budget") {
                    Toggle("Include in monthly budget", isOn: $account.includeInBudget)
                    if account.includeInBudget { LabeledContent("Monthly Budget") { TextField("0", value: $account.budget, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) } }
                }
                Section("Card Style") {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(presets, id: \.self) { style in Button { account.cardStyle = style } label: { RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: style.startHex), Color(hex: style.endHex)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 74, height: 48).overlay { if account.cardStyle == style { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white) } } }.buttonStyle(.plain) } } }
                    ColorPicker("Start Color", selection: Binding(get: { Color(hex: account.cardStyle.startHex) }, set: { account.cardStyle.startHex = $0.rgbHex }))
                    ColorPicker("End Color", selection: Binding(get: { Color(hex: account.cardStyle.endHex) }, set: { account.cardStyle.endHex = $0.rgbHex }))
                    PhotosPicker(selection: $photoItem, matching: .images) { Label(account.cardImageData == nil ? "Choose Card Photo" : "Replace Card Photo", systemImage: "photo") }
                    if account.cardImageData != nil { Button("Remove Card Photo", role: .destructive) { account.cardImageData = nil; photoItem = nil } }
                }
                if !isNew { Section { Button("Delete Account", role: .destructive) { onDelete(account); dismiss() } } }
            }
            .navigationTitle(isNew ? "Add Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines); account.logo = account.logo.isEmpty ? String(account.name.prefix(3)).uppercased() : account.logo; store.saveAccount(account, desiredBalance: desiredBalance); dismiss() }.disabled(account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
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
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}
