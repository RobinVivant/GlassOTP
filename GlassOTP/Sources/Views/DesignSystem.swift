import GlassOTPCore
import SwiftUI
import UIKit

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

private extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if cleaned.count == 6, let int = UInt64(cleaned, radix: 16) {
            self.init(
                red: CGFloat((int >> 16) & 0xFF) / 255.0,
                green: CGFloat((int >> 8) & 0xFF) / 255.0,
                blue: CGFloat(int & 0xFF) / 255.0,
                alpha: 1.0
            )
        } else {
            self.init(red: 56.0 / 255.0, green: 189.0 / 255.0, blue: 248.0 / 255.0, alpha: 1.0)
        }
    }
}

@MainActor
final class BrandImageCache {
    static let shared = BrandImageCache()

    private let webLogoCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    private let vectorBadgeCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 250
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    private var missingWebLogoKeys: Set<String> = []
    private var lastLogoRevision: Int = 0

    private init() {}

    func webLogo(forDomain domain: String, revision: Int) -> UIImage? {
        if lastLogoRevision != revision {
            lastLogoRevision = revision
            webLogoCache.removeAllObjects()
            missingWebLogoKeys.removeAll(keepingCapacity: true)
        }

        let cacheKey = "\(domain)#\(revision)"
        if let cached = webLogoCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        if missingWebLogoKeys.contains(cacheKey) {
            return nil
        }

        if let data = BrandLogoCache.loadPNGData(forDomain: domain),
           let image = UIImage(data: data) {
            let cost = data.count
            webLogoCache.setObject(image, forKey: cacheKey as NSString, cost: cost)
            return image
        }

        if missingWebLogoKeys.count >= 512 {
            missingWebLogoKeys.removeAll(keepingCapacity: true)
        }
        missingWebLogoKeys.insert(cacheKey)
        return nil
    }

    func vectorBadge(for brand: BrandDefinition, svgPath: String, size: CGFloat, scale: CGFloat) -> UIImage {
        let normalizedScale = max(1.0, scale)
        let sizeTenths = Int((size * 10.0).rounded())
        let scaleTenths = Int((normalizedScale * 10.0).rounded())
        let cacheKey = "\(brand.slug)#\(sizeTenths)#\(scaleTenths)" as NSString

        if let cached = vectorBadgeCache.object(forKey: cacheKey) {
            return cached
        }

        let rendered = renderVectorBadge(for: brand, svgPath: svgPath, size: size, scale: normalizedScale)
        let pixelCost = max(1, Int(size * normalizedScale * size * normalizedScale * 4.0))
        vectorBadgeCache.setObject(rendered, forKey: cacheKey, cost: pixelCost)
        return rendered
    }

    private func renderVectorBadge(
        for brand: BrandDefinition,
        svgPath: String,
        size: CGFloat,
        scale: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let cornerRadius = size * 0.30
            let clipPath = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)

            cg.saveGState()
            clipPath.addClip()

            let startColor = UIColor(hex: brand.effectiveAccentHex).cgColor
            let endColor = UIColor(hex: brand.effectiveSecondaryHex).cgColor
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
            let strokePath = UIBezierPath(roundedRect: strokeRect, cornerRadius: max(0, cornerRadius - 0.5))
            UIColor.white.withAlphaComponent(0.28).setStroke()
            strokePath.lineWidth = 1.0
            strokePath.stroke()

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
                        let shadowColor = UIColor.black
                            .withAlphaComponent(brand.usesDarkGlyph ? 0.08 : 0.18)
                            .cgColor
                        cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: shadowColor)
                        let fillColor = brand.usesDarkGlyph ? UIColor(hex: "#111827") : UIColor.white
                        cg.setFillColor(fillColor.cgColor)
                        cg.addPath(transformed)
                        cg.fillPath()
                        cg.restoreGState()
                    }
                }
            }
        }
    }
}

struct AmbientGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(hex: "#060B16"),
                        Color(hex: "#0B1326"),
                        Color(hex: "#081C2B"),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [Color(hex: "#22D3EE").opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 420
                )

                RadialGradient(
                    colors: [Color(hex: "#6366F1").opacity(0.20), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 460
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(hex: "#EEF6FF"),
                        Color(hex: "#F4F7FB"),
                        Color(hex: "#E6F2F8"),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [Color(hex: "#38BDF8").opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 420
                )

                RadialGradient(
                    colors: [Color(hex: "#818CF8").opacity(0.16), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 440
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct BrandBadgeContent: View {
    @Environment(\.displayScale) private var displayScale

    let brand: BrandDefinition?
    let fallbackStyle: OTPBrandStyle?
    let cachedDomain: String?
    var size: CGFloat = 44
    var logoRevision: Int = 0

    var body: some View {
        let cornerRadius = size * 0.30

        Group {
            if let brand, let svgPath = brand.svgPath {
                let rendered = BrandImageCache.shared.vectorBadge(
                    for: brand,
                    svgPath: svgPath,
                    size: size,
                    scale: displayScale
                )
                Image(uiImage: rendered)
                    .resizable()
                    .frame(width: size, height: size)
            } else if let cachedDomain,
                      let cachedPNG = BrandImageCache.shared.webLogo(forDomain: cachedDomain, revision: logoRevision) {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                        )

                    Image(uiImage: cachedPNG)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.68, height: size * 0.68)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.6, style: .continuous))
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: brand.map { "#\($0.effectiveAccentHex)" } ?? fallbackStyle?.accentHex ?? "#38BDF8"),
                                    Color(hex: brand.map { "#\($0.effectiveSecondaryHex)" } ?? fallbackStyle?.secondaryHex ?? "#0284C7"),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                        )

                    Image(systemName: fallbackStyle?.symbolName ?? brand?.category.symbolName ?? "key.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct BrandAvatarView: View, Equatable {
    let account: OTPAccount
    var size: CGFloat = 44
    var logoRevision: Int = 0

    nonisolated static func == (lhs: BrandAvatarView, rhs: BrandAvatarView) -> Bool {
        lhs.account.id == rhs.account.id
            && lhs.account.issuer == rhs.account.issuer
            && lhs.account.label == rhs.account.label
            && lhs.account.customBrandSlug == rhs.account.customBrandSlug
            && lhs.account.customLogoDomain == rhs.account.customLogoDomain
            && lhs.size == rhs.size
            && lhs.logoRevision == rhs.logoRevision
    }

    var body: some View {
        let matched = BrandCatalog.shared.match(account: account)
        let needsFallback = matched?.svgPath == nil
        let domain = needsFallback
            ? BrandCatalog.shared.inferredDomain(for: account, includeHeuristicFallback: true)
            : nil

        BrandBadgeContent(
            brand: matched,
            fallbackStyle: needsFallback ? account.brandStyle : nil,
            cachedDomain: domain,
            size: size,
            logoRevision: logoRevision
        )
    }
}

struct CountdownRingView: View {
    let remainingSeconds: TimeInterval
    let progress: Double
    var size: CGFloat = 34
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
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: 3.2)

            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(remainingSeconds > period - 0.5 ? nil : .linear(duration: 0.98), value: progress)

            Text("\(max(0, Int(ceil(remainingSeconds))))")
                .font(.system(size: size * 0.33, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(remainingSeconds <= 5 ? ringColor : .secondary)
        }
        .frame(width: size, height: size)
    }
}

struct FloatingCopyToast: View {
    let toast: CopiedToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                Text("Copied \(toast.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(toast.formattedCode)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.green.opacity(0.14)), in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
