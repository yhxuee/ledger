import PassKit
import SwiftUI

/// Custom shape representing a physical receipt or ticket with repeated triangular
/// tear/serration notches along the top and bottom edges and clean, straight vertical sides.
struct SerratedTicketShape: Shape {
    var toothWidth: CGFloat = 12
    var toothDepth: CGFloat = 6

    init(toothWidth: CGFloat = 12, toothDepth: CGFloat = 6) {
        self.toothWidth = toothWidth
        self.toothDepth = toothDepth
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        let count = max(2, Int((rect.width / toothWidth).rounded(.down)))
        let actualToothWidth = rect.width / CGFloat(count)

        // Top edge: starts at top-left tooth trough, peaks at minY, troughs at minY + toothDepth
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + toothDepth))
        for i in 0..<count {
            let startX = rect.minX + CGFloat(i) * actualToothWidth
            let midX = startX + actualToothWidth / 2
            let endX = startX + actualToothWidth
            path.addLine(to: CGPoint(x: midX, y: rect.minY))
            path.addLine(to: CGPoint(x: endX, y: rect.minY + toothDepth))
        }

        // Right edge: clean straight vertical line to bottom tooth trough
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - toothDepth))

        // Bottom edge: moves from right to left, peaks downward at maxY, troughs at maxY - toothDepth
        for i in 0..<count {
            let startX = rect.maxX - CGFloat(i) * actualToothWidth
            let midX = startX - actualToothWidth / 2
            let endX = startX - actualToothWidth
            path.addLine(to: CGPoint(x: midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: endX, y: rect.maxY - toothDepth))
        }

        // Left edge: clean straight vertical line back up to top-left tooth trough
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + toothDepth))
        path.closeSubpath()

        return path
    }
}

/// A subtle perforated/dashed line separator for ticket sections.
private struct PerforatedDivider: View {
    var body: some View {
        DividerLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(height: 1)
            .foregroundStyle(Color.secondary.opacity(0.3))
    }

    private struct DividerLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// A physical receipt/event-ticket styled summary card for purchase sessions.
/// Features top and bottom triangular tear notches, paper surface styling,
/// clean typography, and an integrated "Add to Apple Wallet" pass action.
struct PurchaseWalletTicketCard: View {
    let session: PurchaseSession
    let readOnly: Bool
    let baseCurrency: CurrencyCode?
    let baseCurrencyEquivalent: Double?
    let isGeneratingPass: Bool
    let onAddToWallet: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(
        session: PurchaseSession,
        readOnly: Bool,
        baseCurrency: CurrencyCode? = nil,
        baseCurrencyEquivalent: Double? = nil,
        isGeneratingPass: Bool = false,
        onAddToWallet: @escaping () -> Void
    ) {
        self.session = session
        self.readOnly = readOnly
        self.baseCurrency = baseCurrency
        self.baseCurrencyEquivalent = baseCurrencyEquivalent
        self.isGeneratingPass = isGeneratingPass
        self.onAddToWallet = onAddToWallet
    }

    private var completedItemsCount: Int {
        session.items.filter(\.isCompleted).count
    }

    private var isPassLibraryAvailable: Bool {
        WalletPassManager.shared.isPassLibraryAvailable
    }

    private var isIssuerConfigured: Bool {
        WalletPassManager.shared.isIssuerConfigured
    }

    private var isWalletActionEnabled: Bool {
        readOnly && isPassLibraryAvailable && isIssuerConfigured && !isGeneratingPass
    }

    private var walletStatusMessage: String? {
        if !readOnly {
            return String(localized: "Apple Wallet pass is available after completing purchase.")
        }
        if !isPassLibraryAvailable {
            return String(localized: "Apple Wallet is unavailable on this device.")
        }
        if !isIssuerConfigured {
            return String(localized: "Apple Wallet pass issuance is unavailable.")
        }
        return nil
    }

    private var formattedDate: String {
        let date = session.completedAt ?? session.createdAt
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public var body: some View {
        VStack(spacing: 14) {
            // Header: Receipt Badge & Session Title
            VStack(spacing: 6) {
                HStack {
                    Text("FINSY RECEIPT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(1.5)
                    Spacer()
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(session.name.isEmpty ? String(localized: "Purchase Session") : session.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }

                HStack {
                    Text(formattedDate)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            PerforatedDivider()

            // Summary Financial Section
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: String(localized: "%d completed items"), completedItemsCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SensitiveMoneyText(
                        amount: session.plannedAmount,
                        currency: session.currency,
                        maxIntegerDigits: 4
                    )
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                }

                if let converted = baseCurrencyEquivalent, let base = baseCurrency {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("≈")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        SensitiveMoneyText(
                            amount: converted,
                            currency: base,
                            maxIntegerDigits: 4
                        )
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }

            PerforatedDivider()

            // Integrated Apple Wallet Action
            VStack(spacing: 6) {
                Button(action: onAddToWallet) {
                    HStack(spacing: 8) {
                        Image(systemName: "wallet.pass.fill")
                            .font(.system(size: 15, weight: .medium))
                        Text(isGeneratingPass ? String(localized: "Adding to Apple Wallet...") : String(localized: "Add to Apple Wallet"))
                            .font(.subheadline.weight(.semibold))
                        if isGeneratingPass {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(isWalletActionEnabled ? Color.primary : Color.secondary.opacity(0.3))
                .disabled(!isWalletActionEnabled)

                if let message = walletStatusMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .background(
            SerratedTicketShape(toothWidth: 14, toothDepth: 7)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 8,
                    x: 0,
                    y: 4
                )
        )
        .overlay(
            SerratedTicketShape(toothWidth: 14, toothDepth: 7)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
