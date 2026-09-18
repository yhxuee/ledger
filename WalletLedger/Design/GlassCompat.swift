import SwiftUI

private struct LedgerGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? Glass.regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.34), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.08), radius: 18, y: 9)
        }
    }
}

extension View {
    func ledgerGlass<S: Shape>(interactive: Bool = false, in shape: S) -> some View {
        modifier(LedgerGlassModifier(shape: shape, interactive: interactive))
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
