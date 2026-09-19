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
        let cardRatio: CGFloat = 85.60 / 53.98
        let ratio = image.size.width / image.size.height
        if abs(ratio / cardRatio - 1) <= 0.08 {
            surface = .fullBleed
        } else {
            let sample = Self.sample(image)
            surface = sample.transparent ? .glass : .opaque(sample.background)
        }
        foreground = Self.foreground(for: surface)
    }

    private static func foreground(for surface: Surface) -> Color {
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
                        .overlay {
                            if artwork != nil {
                                RoundedRectangle(cornerRadius: 25, style: .continuous)
                                    .fill(.white.opacity(0.08))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.8)
                                    }
                            }
                        }
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

private struct AsyncCardArtworkModifier: ViewModifier {
    let data: Data?
    let fallback: LinearGradient
    @State private var loaded: CardArtwork?
    @State private var loadedData: Data?

    func body(content: Content) -> some View {
        content
            .modifier(CardArtworkModifier(
                artwork: loadedData == data ? loaded : CardArtwork.cached(data), fallback: fallback))
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

    func cardArtwork(data: Data?, fallback: LinearGradient) -> some View {
        modifier(AsyncCardArtworkModifier(data: data, fallback: fallback))
    }
}
