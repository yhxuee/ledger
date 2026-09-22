import SwiftUI

/// A receipt ticket whose top and bottom edges are cut into the actual card silhouette.
struct PurchaseWalletTicketCard: View {
    let session: PurchaseSession
    let baseCurrencyEquivalent: Double?
    let baseCurrency: CurrencyCode
    let canAddToWallet: Bool
    let generatingPass: Bool
    let addToWallet: () -> Void

    private var receiptDate: Date {
        session.completedAt ?? session.startedAt ?? session.createdAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FINSY")
                        .font(.caption.weight(.heavy))
                        .tracking(2)
                    Text("PURCHASE RECEIPT")
                        .font(.caption2.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "ticket.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(session.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiptDate.formatted(date: .abbreviated, time: .shortened))
                    Text("\(session.completedItemCount) items · \(session.currency.rawValue)")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }

            TicketPerforationDivider()

            HStack(alignment: .firstTextBaseline) {
                Text("TOTAL")
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                SensitiveMoneyText(amount: session.plannedAmount, currency: session.currency, maxIntegerDigits: 6)
                    .font(.title2.weight(.bold).monospacedDigit())
            }
            if let baseCurrencyEquivalent {
                HStack {
                    Spacer()
                    Text("≈")
                    SensitiveMoneyText(amount: baseCurrencyEquivalent, currency: baseCurrency, maxIntegerDigits: 6)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if canAddToWallet {
                Button(action: addToWallet) {
                    HStack {
                        Label("Add to Apple Wallet", systemImage: "wallet.pass")
                        if generatingPass {
                            Spacer()
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(generatingPass)
            } else {
                Label("Apple Wallet is unavailable right now.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .background {
            let ticket = PurchaseTicketEdge()
            ticket
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                .overlay {
                    ticket.stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TicketPerforationDivider: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
            }
            .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

private struct PurchaseTicketEdge: Shape {
    func path(in rect: CGRect) -> Path {
        let count = max(1, Int(rect.width / 16))
        let step = rect.width / CGFloat(count)
        let depth = min(7.0, rect.height / 8)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for index in 0..<count {
            path.addLine(to: CGPoint(x: rect.minX + (CGFloat(index) + 0.5) * step, y: rect.minY + depth))
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(index + 1) * step, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        for index in stride(from: count, to: 0, by: -1) {
            path.addLine(to: CGPoint(x: rect.minX + (CGFloat(index) - 0.5) * step, y: rect.maxY - depth))
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(index - 1) * step, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
