import SwiftUI

/// Shared material-finish overlay for Finsy account cards.
///
/// Implements user-selected or auto-resolved Glass and Metal finishes,
/// providing glossy optical translucency or premium satin metallic sheen.
struct CardFinishOverlay: View {
    let style: AccountCardMaterialStyle
    let artwork: CardArtwork?
    let isDark: Bool
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(style: AccountCardMaterialStyle, artwork: CardArtwork?, isDark: Bool, cornerRadius: CGFloat = 25) {
        self.style = style
        self.artwork = artwork
        self.isDark = isDark
        self.cornerRadius = cornerRadius
    }

    /// Resolves the effective material finish.
    var resolvedFinish: AccountCardMaterialStyle {
        switch style {
        case .glass:
            return .glass
        case .metal:
            return .metal
        case .auto:
            if let artwork {
                switch artwork.surface {
                case .glass:
                    return .glass
                case .fullBleed:
                    return .glass
                case .opaque:
                    return .metal
                }
            } else {
                // Standard gradient / solid cards prefer Metal
                return .metal
            }
        }
    }

    var body: some View {
        ZStack {
            switch resolvedFinish {
            case .glass:
                glassFinish
            case .metal, .auto:
                metalFinish
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Glass Finish

    @ViewBuilder
    private var glassFinish: some View {
        ZStack {
            // A. Clear glossy surface / optical top glaze
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(isDark ? 0.16 : 0.24), location: 0.0),
                    .init(color: .white.opacity(isDark ? 0.04 : 0.08), location: 0.45),
                    .init(color: .clear, location: 0.70)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // B. Bright reflective sweep (angled specular highlight band)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white.opacity(isDark ? 0.24 : 0.32), location: 0.18),
                    .init(color: .white.opacity(isDark ? 0.09 : 0.15), location: 0.32),
                    .init(color: .clear, location: 0.54)
                ],
                startPoint: UnitPoint(x: -0.15, y: -0.10),
                endPoint: UnitPoint(x: 1.10, y: 0.85)
            )

            // Top-leading corner specular bloom
            RadialGradient(
                colors: [
                    .white.opacity(isDark ? 0.25 : 0.32),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 180
            )

            // Subtle bottom reflection catch (internal light reflection in glass)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.80),
                    .init(color: .white.opacity(isDark ? 0.08 : 0.14), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // C. Inner light border (crisp specular rim highlight)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isDark ? 0.55 : 0.68), location: 0.0),
                            .init(color: .white.opacity(isDark ? 0.24 : 0.32), location: 0.35),
                            .init(color: .white.opacity(isDark ? 0.08 : 0.14), location: 0.70),
                            .init(color: .white.opacity(isDark ? 0.22 : 0.30), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        }
    }

    // MARK: - Metal Finish

    @ViewBuilder
    private var metalFinish: some View {
        ZStack {
            // A. Broad metallic sheen (anisotropic satin brushed reflection)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(isDark ? 0.10 : 0.16), location: 0.0),
                    .init(color: .black.opacity(isDark ? 0.14 : 0.07), location: 0.22),
                    .init(color: .white.opacity(isDark ? 0.15 : 0.20), location: 0.42),
                    .init(color: .black.opacity(isDark ? 0.10 : 0.05), location: 0.65),
                    .init(color: .white.opacity(isDark ? 0.08 : 0.14), location: 0.85),
                    .init(color: .black.opacity(isDark ? 0.16 : 0.09), location: 1.0)
                ],
                startPoint: UnitPoint(x: 0.05, y: 0.0),
                endPoint: UnitPoint(x: 0.95, y: 1.0)
            )

            // B. Narrow specular streak (focused satin light glint)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.34),
                    .init(color: .white.opacity(isDark ? 0.18 : 0.25), location: 0.46),
                    .init(color: .white.opacity(isDark ? 0.26 : 0.34), location: 0.50),
                    .init(color: .white.opacity(isDark ? 0.14 : 0.20), location: 0.54),
                    .init(color: .clear, location: 0.66)
                ],
                startPoint: UnitPoint(x: 0.0, y: 0.20),
                endPoint: UnitPoint(x: 1.0, y: 0.80)
            )

            // D. Satin micro-shading & soft horizontal brush
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(isDark ? 0.06 : 0.03), location: 0.0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .white.opacity(isDark ? 0.05 : 0.08), location: 0.5),
                    .init(color: .clear, location: 0.7),
                    .init(color: .black.opacity(isDark ? 0.08 : 0.04), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // E. Depth shadow / denser body (subtle inner perimeter vignette)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    .black.opacity(isDark ? 0.22 : 0.10),
                    lineWidth: 1.8
                )

            // C. Subtle edge lighting / precision CNC chamfer
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isDark ? 0.48 : 0.58), location: 0.0),
                            .init(color: .white.opacity(isDark ? 0.20 : 0.26), location: 0.38),
                            .init(color: .black.opacity(isDark ? 0.35 : 0.18), location: 0.68),
                            .init(color: .black.opacity(isDark ? 0.48 : 0.26), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        }
    }
}
