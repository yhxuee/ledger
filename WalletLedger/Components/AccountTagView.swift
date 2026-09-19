import SwiftUI

/// Adaptive Tag capsule providing clear readability across light gradients, dark gradients,
/// uploaded opaque artwork, transparent/glass cards, Light Mode, and Dark Mode.
struct AccountTagView: View {
    let tag: String
    var font: Font = .headline.bold()
    var isDarkOverride: Bool? = nil

    @Environment(\.cardIsDark) private var envCardIsDark

    private var isDark: Bool {
        isDarkOverride ?? envCardIsDark
    }

    var body: some View {
        Text(tag)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(isDark ? Color.white : Color.black.opacity(0.82))
            .background(
                isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.10),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.7)
            )
    }
}
