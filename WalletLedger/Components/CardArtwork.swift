import SwiftUI
import UIKit
import ImageIO

/// Decode and classify once per uploaded image, not while the carousel scrolls.
// Immutable after construction. UIImage/UIColor are only read by rendering after
// publication; decoding and analysis finish before crossing back to the main actor.
final class CardArtwork: @unchecked Sendable {
    enum Surface {
        case fullBleed
        case opaque(UIColor)
        case glass
    }

    let image: UIImage
    let surface: Surface
    let foreground: Color
    let isDarkArtwork: Bool
    let averageLuminance: CGFloat
    @MainActor private static let cache: NSCache<NSData, CardArtwork> = {
        let cache = NSCache<NSData, CardArtwork>()
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    @MainActor private static var pending: [Data: Task<CardArtwork?, Never>] = [:]

    @MainActor static func cached(_ data: Data?) -> CardArtwork? {
        guard let data else { return nil }
        return cache.object(forKey: data as NSData)
    }

    @MainActor static func load(_ data: Data?) async -> CardArtwork? {
        guard let data else { return nil }
        if let cached = cached(data) { return cached }
        if let task = pending[data] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> CardArtwork? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_200,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return CardArtwork(image: UIImage(cgImage: decoded))
        }
        pending[data] = task
        let artwork = await task.value
        if let artwork {
            let cost = artwork.image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
            cache.setObject(artwork, forKey: data as NSData, cost: cost)
        }
        pending[data] = nil
        return artwork
    }

    private init(image: UIImage) {
        self.image = image
        let sample = Self.sample(image)
        let cardRatio: CGFloat = 85.60 / 53.98
        let ratio = image.size.width / image.size.height
        let matchesCardRatio = abs(ratio / cardRatio - 1) <= 0.02

        self.averageLuminance = sample.overallLuminance

        if sample.transparent {
            surface = .glass
            isDarkArtwork = false
        } else if matchesCardRatio {
            surface = .fullBleed
            isDarkArtwork = sample.centerLuminance * 0.75 < 0.55
        } else {
            surface = .opaque(sample.background)
            let effectiveLuminance = 0.55 * sample.bgLuminance + 0.45 * sample.centerLuminance
            isDarkArtwork = effectiveLuminance < 0.5
        }
        self.foreground = isDarkArtwork ? .white : .black.opacity(0.86)
    }

    func isDark(for colorScheme: ColorScheme) -> Bool {
        switch surface {
        case .fullBleed, .opaque:
            return isDarkArtwork
        case .glass:
            if colorScheme == .dark {
                return true
            } else {
                return averageLuminance < 0.25
            }
        }
    }

    func foregroundStyles(for colorScheme: ColorScheme) -> (primary: Color, secondary: Color) {
        if isDark(for: colorScheme) {
            return (Color.white, Color.white.opacity(0.72))
        } else {
            return (Color.black.opacity(0.86), Color.black.opacity(0.56))
        }
    }

    private struct AnalysisResult {
        let transparent: Bool
        let background: UIColor
        let bgLuminance: CGFloat
        let centerLuminance: CGFloat
        let overallLuminance: CGFloat
    }

    /// A small RGBA sample detects real transparency, average luminance, and dominant border color.
    private static func sample(_ image: UIImage) -> AnalysisResult {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let source = image.cgImage else {
            return AnalysisResult(transparent: true, background: .clear, bgLuminance: 0.5, centerLuminance: 0.5, overallLuminance: 0.5)
        }
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard rendered else {
            return AnalysisResult(transparent: true, background: .clear, bgLuminance: 0.5, centerLuminance: 0.5, overallLuminance: 0.5)
        }

        var hasTransparency = false
        var colors: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        var totalLuminance: CGFloat = 0
        var visibleCount: CGFloat = 0
        var centerLuminance: CGFloat = 0
        var centerCount: CGFloat = 0

        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let alpha = pixels[offset + 3]
                if alpha < 255 {
                    hasTransparency = true
                }
                if alpha > 32 {
                    let aFloat = CGFloat(alpha)
                    let r = CGFloat(pixels[offset]) / aFloat
                    let g = CGFloat(pixels[offset + 1]) / aFloat
                    let b = CGFloat(pixels[offset + 2]) / aFloat
                    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    totalLuminance += lum
                    visibleCount += 1
                    if x >= 8 && x <= 39 && y >= 8 && y <= 39 {
                        centerLuminance += lum
                        centerCount += 1
                    }
                }
                if alpha == 255 && (x < 3 || y < 3 || x >= side - 3 || y >= side - 3) {
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
                    let previous = colors[key] ?? (0, 0, 0, 0)
                    colors[key] = (previous.count + 1, previous.red + r, previous.green + g, previous.blue + b)
                }
            }
        }

        let overall = visibleCount > 0 ? totalLuminance / visibleCount : 0.5
        let center = centerCount > 0 ? centerLuminance / centerCount : overall

        if hasTransparency {
            return AnalysisResult(transparent: true, background: .clear, bgLuminance: 0.5, centerLuminance: center, overallLuminance: overall)
        }

        guard let dominant = colors.max(by: { $0.value.count < $1.value.count })?.value else {
            return AnalysisResult(transparent: false, background: .gray, bgLuminance: 0.5, centerLuminance: center, overallLuminance: overall)
        }
        let divisor = CGFloat(dominant.count) * 255
        let bgR = CGFloat(dominant.red) / divisor
        let bgG = CGFloat(dominant.green) / divisor
        let bgB = CGFloat(dominant.blue) / divisor
        let bgLum = 0.2126 * bgR + 0.7152 * bgG + 0.0722 * bgB
        let bgColor = UIColor(red: bgR, green: bgG, blue: bgB, alpha: 1)

        return AnalysisResult(transparent: false, background: bgColor, bgLuminance: bgLum, centerLuminance: center, overallLuminance: overall)
    }
}

private struct CardInformationBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private struct CardArtworkModifier: ViewModifier {
    let artwork: CardArtwork?
    let fallback: LinearGradient
    let context: CardArtworkLayoutContext
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool {
        artwork?.isDark(for: colorScheme) ?? false
    }

    private var foregroundStyles: (primary: Color, secondary: Color) {
        artwork?.foregroundStyles(for: colorScheme) ?? (Color.black.opacity(0.84), Color.black.opacity(0.56))
    }

    func body(content: Content) -> some View {
        let (primary, secondary) = foregroundStyles
        content
            .foregroundStyle(primary, secondary)
            .shadow(color: artwork != nil ? (isDark ? Color.black.opacity(0.30) : Color.white.opacity(0.40)) : .clear,
                    radius: 1.5, x: 0, y: 1)
            .backgroundPreferenceValue(CardInformationBounds.self) { anchors in
                GeometryReader { geometry in
                    surface(size: geometry.size, regions: anchors.map { geometry[$0] })
                        .overlay {
                            if artwork != nil {
                                RoundedRectangle(cornerRadius: 25, style: .continuous)
                                    .fill(.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                                            .stroke(.white.opacity(0.12), lineWidth: 0.8)
                                    )
                            }
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
    }

    @ViewBuilder private func surface(size: CGSize, regions: [CGRect]) -> some View {
        if let artwork {
            switch artwork.surface {
            case .fullBleed:
                Image(uiImage: artwork.image)
                    .resizable().scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .overlay(LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.48)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            case .opaque(let color):
                ZStack {
                    Color(uiColor: color)
                    centeredArtwork(artwork.image, size: size, regions: regions)
                }
            case .glass:
                ZStack {
                    Color.clear.ledgerGlass(style: .clear, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                    centeredArtwork(artwork.image, size: size, regions: regions)
                }
            }
        } else {
            fallback
        }
    }

    @ViewBuilder private func centeredArtwork(_ image: UIImage, size: CGSize, regions: [CGRect]) -> some View {
        switch context {
        case .horizontal:
            let horizontalInset = size.width * 0.23
            let availableWidth = max(0, size.width - horizontalInset * 2)
            let availableHeight = size.height * 0.68
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: availableWidth, maxHeight: availableHeight)
                .position(x: size.width / 2, y: size.height / 2)

        case .portrait:
            let horizontalInset = size.width * 0.16
            let availableWidth = max(0, size.width - horizontalInset * 2)
            let centerY = size.height / 2
            let baseMaxHeight = size.height * 0.50

            let clearance = regions.reduce(baseMaxHeight / 2) { clearance, rect in
                let distance = max(0, max(rect.minY - centerY, centerY - rect.maxY) - 10)
                return min(clearance, distance)
            }
            let safeHeight = regions.isEmpty ? baseMaxHeight : max(0, clearance * 2)
            let availableHeight = min(baseMaxHeight, safeHeight)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: availableWidth, maxHeight: availableHeight)
                .position(x: size.width / 2, y: centerY)
        }
    }
}

private struct AsyncCardArtworkModifier: ViewModifier {
    let data: Data?
    let fallback: LinearGradient
    let context: CardArtworkLayoutContext
    @State private var loaded: CardArtwork?
    @State private var loadedData: Data?

    func body(content: Content) -> some View {
        content
            .modifier(CardArtworkModifier(
                artwork: loadedData == data ? loaded : CardArtwork.cached(data),
                fallback: fallback,
                context: context))
            .task(id: data) {
                let result = await CardArtwork.load(data)
                guard !Task.isCancelled else { return }
                loaded = result
                loadedData = data
            }
    }
}

extension View {
    func cardInformationRegion() -> some View {
        anchorPreference(key: CardInformationBounds.self, value: .bounds) { [$0] }
    }

    func cardArtwork(data: Data?, fallback: LinearGradient, layout: AccountCardLayout = .horizontal) -> some View {
        modifier(AsyncCardArtworkModifier(data: data, fallback: fallback, context: layout))
    }

    func cardArtwork(data: Data?, fallback: LinearGradient, context: AccountCardLayout) -> some View {
        modifier(AsyncCardArtworkModifier(data: data, fallback: fallback, context: context))
    }
}
