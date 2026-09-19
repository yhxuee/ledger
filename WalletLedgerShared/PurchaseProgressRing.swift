import SwiftUI

/// Circular purchase-progress ring used in the app, on the Lock Screen and inside the
/// Dynamic Island. All styling is explicit because the Dynamic Island surface is dark and
/// the default `.tint` renders almost monochrome there.
struct PurchaseProgressRing: View {
    let fraction: Double
    var completed = false
    /// Explicit accent stroke color; defaults to coral while shopping and teal when complete.
    var tint: Color?
    var trackColor: Color?
    /// Center glyph color; defaults to the accent stroke color.
    var iconColor: Color?
    /// Center glyph size. Kept small so the ring never touches the Dynamic Island mask.
    var iconSize: CGFloat = 13
    var lineWidth: CGFloat = 4

    private var resolvedTint: Color { tint ?? PurchaseActivityPalette.progressTint(completed: completed) }
    private var resolvedTrack: Color { trackColor ?? PurchaseActivityPalette.track }

    var body: some View {
        ZStack {
            Circle().stroke(resolvedTrack, lineWidth: lineWidth)
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(resolvedTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: completed ? "checkmark" : "cart.fill")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(iconColor ?? resolvedTint)
        }
        .accessibilityLabel("Purchase progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

