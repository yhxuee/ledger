import SwiftUI

struct MarketDataSettingsView: View {
    @EnvironmentObject private var store: LedgerStore
    @ObservedObject private var refresh = StockQuoteRefreshService.shared
    @State private var key = ""
    @State private var configured = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsGlassSection("Alpha Vantage API Key") {
                    SecureField("API Key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    LabeledContent("Status", value: configured ? "Configured" : "Not Configured")

                    Divider()

                    HStack(spacing: 12) {
                        Button("Save") {
                            do {
                                try MarketDataKeychain.save(key)
                                key = ""; configured = true; message = "Saved in this device's Keychain."
                                Task {
                                    await AlphaVantageService.shared.resetCaches()
                                    await StockQuoteRefreshService.shared.refreshIfDue(store: store)
                                    MarketRefreshBackground.schedule(store: store)
                                }
                            } catch { message = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)

                        Button("Clear", role: .destructive) {
                            do {
                                try MarketDataKeychain.clear()
                                key = ""; configured = false; message = "API key cleared."
                                Task { await AlphaVantageService.shared.resetCaches() }
                            } catch { message = error.localizedDescription }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!configured || busy)

                        Spacer()

                        Button(busy ? "Testing…" : "Test") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    _ = try await AlphaVantageService.shared.marketStatus()
                                    message = "Connection successful."
                                } catch { message = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!configured || busy)
                    }
                }

                SettingsGlassSection("Status & Notes", footer: "Prices may be end-of-day, depending on your Alpha Vantage subscription. FX rates are supplied separately by Frankfurter.") {
                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    if let status = refresh.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(LedgerBackground())
        .navigationTitle("Market Data")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do { configured = try MarketDataKeychain.read() != nil }
            catch { message = error.localizedDescription }
        }
        .onDisappear { key = "" }
    }
}
