import SwiftUI

enum LedgerGlassStyle {
    case regular
    case clear
}

private struct LedgerGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    var style: LedgerGlassStyle = .regular

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? Glass.regular.interactive() : .regular, in: shape)
        } else {
            if style == .clear {
                content
                    .background(
                        shape
                            .fill(.white.opacity(0.04))
                            .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.8))
                    )
                    .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(.white.opacity(0.34), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.08), radius: 18, y: 9)
            }
        }
    }
}

extension View {
    func ledgerGlass<S: Shape>(style: LedgerGlassStyle = .regular, interactive: Bool = false, in shape: S) -> some View {
        modifier(LedgerGlassModifier(shape: shape, interactive: interactive, style: style))
    }
}

struct GlassIconButton: View {
    let systemName: String
    let label: String
    var prominent = false
    var tint: Color = .primary
    let action: () -> Void
    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            if prominent {
                Button(action: action) { Image(systemName: systemName).frame(width: 28, height: 28) }.buttonStyle(.glassProminent).tint(tint).accessibilityLabel(label)
            } else {
                Button(action: action) { Image(systemName: systemName).frame(width: 28, height: 28) }.buttonStyle(.glass).foregroundStyle(tint).accessibilityLabel(label)
            }
        } else {
            if prominent {
                Button(action: action) { Image(systemName: systemName).frame(width: 28, height: 28) }.buttonStyle(.borderedProminent).tint(tint).buttonBorderShape(.circle).accessibilityLabel(label)
            } else {
                Button(action: action) { Image(systemName: systemName).frame(width: 28, height: 28) }.buttonStyle(.bordered).foregroundStyle(tint).buttonBorderShape(.circle).accessibilityLabel(label)
            }
        }
    }
}

struct GlassPrimaryButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}

extension View { func glassPrimaryButton() -> some View { modifier(GlassPrimaryButtonStyle()) } }

struct ToolbarIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: systemName).frame(width: 24, height: 24) }
            .accessibilityLabel(label)
    }
}
