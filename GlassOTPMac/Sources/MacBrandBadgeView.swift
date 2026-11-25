import AppKit
import GlassOTPCore
import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let r, g, b: UInt64
        if cleaned.count == 6, let int = UInt64(cleaned, radix: 16) {
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        } else {
            (r, g, b) = (56, 189, 248)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }
}

private extension NSColor {
    static func fromHex(_ hex: String) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if cleaned.count == 6, let int = UInt64(cleaned, radix: 16) {
            return NSColor(
                srgbRed: CGFloat((int >> 16) & 0xFF) / 255.0,
                green: CGFloat((int >> 8) & 0xFF) / 255.0,
                blue: CGFloat(int & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        return NSColor(srgbRed: 56.0 / 255.0, green: 189.0 / 255.0, blue: 248.0 / 255.0, alpha: 1.0)
    }
}

@MainActor
final class MacBrandImageCache {
    static let shared = MacBrandImageCache()

    private let webLogoCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 150
        return cache
    }()

    private let vectorBadgeCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 250
        return cache
    }()

    private var missingWebDomains: Set<String> = []

    private init() {}

    func webLogo(forDomain domain: String) -> NSImage? {
        if let cached = webLogoCache.object(forKey: domain as NSString) {
            return cached
        }
        if missingWebDomains.contains(domain) {
            return nil
        }
        if let data = BrandLogoCache.loadPNGData(forDomain: domain),
           let image = NSImage(data: data) {
            webLogoCache.setObject(image, forKey: domain as NSString)
            return image
        }
        if missingWebDomains.count >= 512 {
            missingWebDomains.removeAll(keepingCapacity: true)
        }
        missingWebDomains.insert(domain)
        return nil
    }

    func vectorBadge(for brand: BrandDefinition, svgPath: String, size: CGFloat, scale: CGFloat) -> NSImage? {
        let normScale = max(2.0, scale)
        let key = "\(brand.slug)#\(Int((size * 10).rounded()))#\(Int((normScale * 10).rounded()))" as NSString
        if let cached = vectorBadgeCache.object(forKey: key) {
            return cached
        }
        guard let rendered = renderVectorBadge(for: brand, svgPath: svgPath, size: size, scale: normScale) else {
            return nil
        }
        vectorBadgeCache.setObject(rendered, forKey: key)
        return rendered
    }

    private func renderVectorBadge(
        for brand: BrandDefinition,
        svgPath: String,
        size: CGFloat,
        scale: CGFloat
    ) -> NSImage? {
        let pixelWidth = max(1, Int((size * scale).rounded()))
        let pixelHeight = max(1, Int((size * scale).rounded()))
        guard let cg = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Scale to points, then flip vertically so (0, 0) is top-left (matching SVG coordinates)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size)
        cg.scaleBy(x: 1, y: -1)

        let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        let cornerRadius = size * 0.30
        let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        cg.saveGState()
        cg.addPath(clipPath)
        cg.clip()

        let startColor = NSColor.fromHex(brand.effectiveAccentHex).cgColor
        let endColor = NSColor.fromHex(brand.effectiveSecondaryHex).cgColor
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [startColor, endColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            cg.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size, y: size),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        cg.restoreGState()

        let strokeRect = rect.insetBy(dx: 0.5, dy: 0.5)
        let strokePath = CGPath(
            roundedRect: strokeRect,
            cornerWidth: max(0, cornerRadius - 0.5),
            cornerHeight: max(0, cornerRadius - 0.5),
            transform: nil
        )
        cg.saveGState()
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        cg.setLineWidth(1.0)
        cg.addPath(strokePath)
        cg.strokePath()
        cg.restoreGState()

        if let cgPath = SVGPathParser.parse(svgPath) {
            let box = cgPath.boundingBoxOfPath
            if box.width > 0, box.height > 0 {
                let glyphSpan = size * 0.56
                let glyphRect = CGRect(
                    x: (size - glyphSpan) / 2.0,
                    y: (size - glyphSpan) / 2.0,
                    width: glyphSpan,
                    height: glyphSpan
                )
                let referenceSpan = max(24.0, max(box.width, box.height))
                let pathScale = min(glyphRect.width, glyphRect.height) / referenceSpan
                let scaledWidth = box.width * pathScale
                let scaledHeight = box.height * pathScale
                let offsetX = glyphRect.minX + (glyphRect.width - scaledWidth) / 2.0 - box.minX * pathScale
                let offsetY = glyphRect.minY + (glyphRect.height - scaledHeight) / 2.0 - box.minY * pathScale

                var transform = CGAffineTransform(translationX: offsetX, y: offsetY)
                    .scaledBy(x: pathScale, y: pathScale)
                if let transformed = cgPath.copy(using: &transform) {
                    cg.saveGState()
                    let fillColor = brand.usesDarkGlyph
                        ? NSColor.fromHex("#111827")
                        : NSColor.white
                    cg.setFillColor(fillColor.cgColor)
                    cg.addPath(transformed)
                    cg.fillPath()
                    cg.restoreGState()
                }
            }
        }

        guard let cgImage = cg.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

struct MacBrandBadgeView: View, Equatable {
    @Environment(\.displayScale) private var displayScale
    let account: OTPAccount
    var size: CGFloat = 30

    nonisolated static func == (lhs: MacBrandBadgeView, rhs: MacBrandBadgeView) -> Bool {
        lhs.account.id == rhs.account.id
            && lhs.account.issuer == rhs.account.issuer
            && lhs.account.label == rhs.account.label
            && lhs.account.customBrandSlug == rhs.account.customBrandSlug
            && lhs.account.customLogoDomain == rhs.account.customLogoDomain
            && lhs.size == rhs.size
    }

    var body: some View {
        let matched = BrandCatalog.shared.match(account: account)
        let customDomain = BrandCatalog.cleanedDomain(account.customLogoDomain)
        let resolvedBrand = customDomain != nil ? nil : matched
        let cornerRadius = size * 0.30

        Group {
            if let resolvedBrand,
               let svgPath = resolvedBrand.svgPath,
               let nsImage = MacBrandImageCache.shared.vectorBadge(
                   for: resolvedBrand,
                   svgPath: svgPath,
                   size: size,
                   scale: displayScale
               ) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: size, height: size)
            } else if let domain = customDomain ?? BrandCatalog.shared.inferredDomain(for: account, includeHeuristicFallback: false),
                      let webImage = MacBrandImageCache.shared.webLogo(forDomain: domain) {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                        )
                    Image(nsImage: webImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.68, height: size * 0.68)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.6, style: .continuous))
                }
            } else {
                let fallback = account.brandStyle
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: matched.map { "#\($0.effectiveAccentHex)" } ?? fallback.accentHex),
                                    Color(hex: matched.map { "#\($0.effectiveSecondaryHex)" } ?? fallback.secondaryHex),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                        )

                    Image(systemName: matched?.category.symbolName ?? fallback.symbolName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct MacCountdownRingView: View {
    let remainingSeconds: TimeInterval
    let progress: Double
    var size: CGFloat = 24
    var period: TimeInterval = 30

    private var ringColor: Color {
        if remainingSeconds <= 5 {
            return .red
        } else if remainingSeconds <= 8 {
            return .orange
        } else {
            return Color(hex: "#38BDF8")
        }
    }

    var body: some View {
        let strokeWidth = max(2.0, size * 0.095)
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: strokeWidth)

            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(remainingSeconds > period - 0.5 ? nil : .linear(duration: 0.98), value: progress)

            Text("\(max(0, Int(ceil(remainingSeconds))))")
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(remainingSeconds <= 5 ? ringColor : .secondary)
        }
        .frame(width: size, height: size)
    }
}
