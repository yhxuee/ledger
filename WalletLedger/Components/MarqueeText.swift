import SwiftUI

/// A single-line value that loops horizontally instead of truncating or wrapping.
///
/// - Values that fit the available width stay perfectly still (no animation at all).
/// - Longer values scroll continuously in one direction, never wrapping to a second line.
/// - The full value always reaches VoiceOver, even while only part of it is visible.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// Visible width reserved for roughly this many English characters before scrolling starts.
    var visibleCharacters: Int = 15
    /// Horizontal speed of the loop.
    var pointsPerSecond: Double = 34
    /// Spacing between the outgoing and the returning copy of the value.
    var gap: CGFloat = 26

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var reservedWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var reference: String { String(repeating: "a", count: max(1, visibleCharacters)) }
    private var scrolls: Bool { textWidth > 0 && containerWidth > 0 && textWidth > containerWidth + 0.5 }

    var body: some View {
        content
            .frame(minWidth: reservedWidth, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(measurements)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onAppear { restart() }
            .onChange(of: text) { _, _ in restart() }
            .onChange(of: scrolls) { _, _ in restart() }
    }

    private var label: some View {
        Text(text).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    private var content: some View {
        HStack(spacing: gap) {
            label
            if scrolls { label }
        }
        .offset(x: offset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Invisible measurements: the available width plus the natural widths of the value and of the
    /// reserved character count. Backgrounds never affect the parent's layout.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, value in containerWidth = value }
            }
            label.hidden().background(sizeReader { textWidth = $0.width })
            Text(reference).font(font).hidden().background(sizeReader { reservedWidth = $0.width })
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func sizeReader(_ apply: @escaping (CGSize) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { apply(proxy.size) }
                .onChange(of: proxy.size) { _, value in apply(value) }
        }
    }

    /// Restarts the loop, or stops it entirely when the value fits the available width.
    private func restart() {
        var stop = Transaction()
        stop.disablesAnimations = true
        withTransaction(stop) { offset = 0 }
        guard scrolls else { return }
        let distance = textWidth + gap
        let duration = max(1.2, Double(distance) / max(1, pointsPerSecond))
        DispatchQueue.main.async {
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                offset = -distance
            }
        }
    }
}