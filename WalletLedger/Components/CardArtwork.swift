import SwiftUI
import UIKit

/// Decode and classify once per uploaded image, not while the carousel scrolls.
@MainActor
final class CardArtwork {
    enum Surface {
        case fullBleed
        case opaque(UIColor)
        case glass
    }

    let image: UIImage
    let surface: Surface
    private static let cache: NSCache<NSData, CardArtwork> = {
        let cache = NSCache<NSData, CardArtwork>()
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func load(_ data: Data?) -> CardArtwork? {
        guard let data else { return nil }
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data), image.size.height > 0 else { return nil }
        let artwork = CardArtwork(image: image)
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        cache.setObject(artwork, forKey: key, cost: cost)
        return artwork
    }

    private init(image: UIImage) {
        self.image = image
        let cardRatio: CGFloat = 85.60 / 53.98
        let ratio = image.size.width / image.size.height
        if abs(ratio / cardRatio - 1) <= 0.08 {
            surface = .fullBleed
        } else {
            let sample = Self.sample(image)
            surface = sample.transparent ? .glass : .opaque(sample.background)
        }
    }

    var foreground: Color {
        switch surface {
        case .fullBleed: return .white
        case .glass: return .primary
        case .opaque(let color):
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5 ? .white : .black.opacity(0.84)
        }
    }

    /// A small RGBA sample detects real transparency and the dominant border color.
    /// Quantized border colors favor the background rather than a central logo.
    private static func sample(_ image: UIImage) -> (transparent: Bool, background: UIColor) {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let source = image.cgImage else { return (true, .clear) }
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard rendered else { return (true, .clear) }
        var colors: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                if pixels[offset + 3] < 255 { return (true, .clear) }
                guard x < 3 || y < 3 || x >= side - 3 || y >= side - 3 else { continue }
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
                let previous = colors[key] ?? (0, 0, 0, 0)
                colors[key] = (previous.count + 1, previous.red + r, previous.green + g, previous.blue + b)
            }
        }
        guard let dominant = colors.max(by: { $0.value.count < $1.value.count })?.value else { return (false, .gray) }
        let divisor = CGFloat(dominant.count) * 255
        return (false, UIColor(red: CGFloat(dominant.red) / divisor,
                               green: CGFloat(dominant.green) / divisor,
                               blue: CGFloat(dominant.blue) / divisor, alpha: 1))
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

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(CardInformationBounds.self) { anchors in
                GeometryReader { geometry in
                    surface(size: geometry.size, regions: anchors.map { geometry[$0] })
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
            .foregroundStyle(artwork?.foreground ?? Color.black.opacity(0.84))
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
                    Color.clear.ledgerGlass(in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                    centeredArtwork(artwork.image, size: size, regions: regions)
                }
            }
        } else {
            fallback
        }
    }

    private func centeredArtwork(_ image: UIImage, size: CGSize, regions: [CGRect]) -> some View {
        let centerY = size.height / 2
        // Reserve the actual header, amount and metadata bounds, including Dynamic Type.
        // The available band shrinks symmetrically about the card center; text never moves.
        let clearance = regions.reduce(size.height * 0.22) { clearance, rect in
            let distance = max(0, max(rect.minY - centerY, centerY - rect.maxY) - 10)
            return min(clearance, distance)
        }
        let safeHeight = regions.isEmpty ? 0 : max(0, clearance * 2)
        return Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width * 0.64, height: safeHeight)
            .position(x: size.width / 2, y: centerY)
    }
}

extension View {
    func cardInformationRegion() -> some View {
        anchorPreference(key: CardInformationBounds.self, value: .bounds) { [$0] }
    }

    func cardArtwork(_ artwork: CardArtwork?, fallback: LinearGradient) -> some View {
        modifier(CardArtworkModifier(artwork: artwork, fallback: fallback))
    }
}
