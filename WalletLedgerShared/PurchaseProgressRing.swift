import SwiftUI

struct PurchaseProgressRing: View {
    let fraction: Double
    var completed = false
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: completed ? "checkmark" : "cart.fill").font(.body.bold())
        }
        .padding(3)
        .accessibilityLabel("Purchase progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}
