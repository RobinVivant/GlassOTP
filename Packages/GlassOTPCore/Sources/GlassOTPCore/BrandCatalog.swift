import Foundation

public enum OTPCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case dev
    case cloud
    case work
    case finance
    case security
    case social
    case gaming
    case shopping
    case personal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dev: "Dev & Code"
        case .cloud: "Cloud & Infra"
        case .work: "Work"
        case .finance: "Finance & Crypto"
        case .security: "Security"
        case .social: "Social & Media"
        case .gaming: "Gaming"
        case .shopping: "Shopping & Travel"
        case .personal: "Personal"
        }
    }

    public var symbolName: String {
        switch self {
        case .dev: "chevron.left.forwardslash.chevron.right"
        case .cloud: "server.rack"
        case .work: "briefcase.fill"
        case .finance: "building.columns.fill"
        case .security: "lock.shield.fill"
        case .social: "bubble.left.and.bubble.right.fill"
        case .gaming: "gamecontroller.fill"
        case .shopping: "bag.fill"
        case .personal: "house.fill"
        }
    }
}

public struct BrandDefinition: Codable, Hashable, Sendable, Identifiable {
    public let slug: String
    public let title: String
    public let hex: String
    public let category: OTPCategory
    public let domain: String
    public let aliases: [String]
    public let svgPath: String?

    public var id: String { slug }

    public var relativeLuminance: Double {
        let rgb = Self.rgbComponents(from: hex)
        return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
    }

    public var isVeryDark: Bool {
        relativeLuminance < 0.10
    }

    public var usesDarkGlyph: Bool {
        relativeLuminance > 0.72
    }

    public var effectiveAccentHex: String {
        isVeryDark ? "2A3346" : hex
    }

    public var effectiveSecondaryHex: String {
        if isVeryDark {
            return "141A26"
        }
        return Self.darkenHex(hex, factor: 0.72)
    }

    private static func rgbComponents(from hex: String) -> (r: Double, g: Double, b: Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let int = UInt64(cleaned, radix: 16) else {
            return (0.22, 0.74, 0.97)
        }
        return (
            Double((int >> 16) & 0xFF) / 255.0,
            Double((int >> 8) & 0xFF) / 255.0,
            Double(int & 0xFF) / 255.0
        )
    }

    private static func darkenHex(_ hex: String, factor: Double) -> String {
        let rgb = rgbComponents(from: hex)
        let r = max(0, min(255, Int((rgb.r * factor * 255.0).rounded())))
        let g = max(0, min(255, Int((rgb.g * factor * 255.0).rounded())))
        let b = max(0, min(255, Int((rgb.b * factor * 255.0).rounded())))
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

private struct IndexedBrand: Sendable {
    let brand: BrandDefinition
    let normalizedAliases: [String]
}

private enum CachedValue<T: Sendable>: Sendable {
    case hit(T)
    case miss

    var optionalValue: T? {
        switch self {
        case .hit(let value): value
        case .miss: nil
        }
    }
}

private final class MatchCacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private var matchByKey: [String: CachedValue<BrandDefinition>] = [:]
    private var domainByKey: [String: CachedValue<String>] = [:]
    private let maxEntries = 2048

    func match(forKey key: String) -> BrandDefinition?? {
        lock.withLock {
            matchByKey[key].map(\.optionalValue)
        }
    }

    func setMatch(_ value: BrandDefinition?, forKey key: String) {
        lock.withLock {
            if matchByKey.count >= maxEntries {
                matchByKey.removeAll(keepingCapacity: true)
            }
            matchByKey[key] = value.map(CachedValue.hit) ?? .miss
        }
    }

    func domain(forKey key: String) -> String?? {
        lock.withLock {
            domainByKey[key].map(\.optionalValue)
        }
    }

    func setDomain(_ value: String?, forKey key: String) {
        lock.withLock {
            if domainByKey.count >= maxEntries {
                domainByKey.removeAll(keepingCapacity: true)
            }
            domainByKey[key] = value.map(CachedValue.hit) ?? .miss
        }
    }
}

public final class BrandCatalog: Sendable {
    public static let shared = BrandCatalog()

    private let brands: [BrandDefinition]
    private let bySlug: [String: BrandDefinition]
    private let indexedBrands: [IndexedBrand]
    private let exactAliasMap: [String: BrandDefinition]
    private let cache = MatchCacheStore()

    private static let consumerEmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "yahoo.fr", "ymail.com",
        "proton.me", "protonmail.com", "pm.me",
        "aol.com", "gmx.com", "gmx.net", "gmx.de", "orange.fr", "wanadoo.fr", "free.fr", "laposte.net",
    ]

    private init() {
        if let url = Bundle.module.url(forResource: "brand_logos", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([BrandDefinition].self, from: data) {
            self.brands = decoded
            self.bySlug = Dictionary(uniqueKeysWithValues: decoded.map { ($0.slug, $0) })

            var indexed: [IndexedBrand] = []
            indexed.reserveCapacity(decoded.count)
            var exactMap: [String: BrandDefinition] = [:]
            exactMap.reserveCapacity(decoded.count * 3)

            for brand in decoded {
                var rawCandidates: [String] = [brand.title, brand.slug]
                if !brand.domain.isEmpty {
                    rawCandidates.append(brand.domain)
                }
                rawCandidates.append(contentsOf: brand.aliases)

                var seenAliases = Set<String>()
                var normAliases: [String] = []
                normAliases.reserveCapacity(rawCandidates.count)

                for candidate in rawCandidates {
                    let norm = Self.normalizeText(candidate)
                    guard !norm.isEmpty else { continue }
                    if seenAliases.insert(norm).inserted {
                        normAliases.append(norm)
                    }
                    if exactMap[norm] == nil {
                        exactMap[norm] = brand
                    }
                }
                indexed.append(IndexedBrand(brand: brand, normalizedAliases: normAliases))
            }

            self.indexedBrands = indexed
            self.exactAliasMap = exactMap
        } else {
            self.brands = []
            self.bySlug = [:]
            self.indexedBrands = []
            self.exactAliasMap = [:]
        }
    }

    public func allBrands() -> [BrandDefinition] {
        brands
    }

    public func brand(slug: String) -> BrandDefinition? {
        bySlug[slug.lowercased()]
    }

    public func search(_ query: String) -> [BrandDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return brands }
        return brands.filter { brand in
            brand.title.lowercased().contains(trimmed)
                || brand.slug.contains(trimmed)
                || brand.domain.contains(trimmed)
                || brand.category.displayName.lowercased().contains(trimmed)
                || brand.aliases.contains(where: { $0.contains(trimmed) })
        }
    }

    public func match(account: OTPAccount) -> BrandDefinition? {
        let cacheKey = "\(account.customBrandSlug ?? "")\u{1F}\(account.issuer)\u{1F}\(account.label)"
        if let cached = cache.match(forKey: cacheKey) {
            return cached
        }
        let resolved = computeMatch(account: account)
        cache.setMatch(resolved, forKey: cacheKey)
        return resolved
    }

    private func computeMatch(account: OTPAccount) -> BrandDefinition? {
        if let customSlug = account.customBrandSlug?.lowercased(),
           let explicit = bySlug[customSlug] {
            return explicit
        }

        // Priority 1: Match issuer string (authoritative service name)
        if !account.issuer.isEmpty, let matched = bestMatch(in: account.issuer) {
            return matched
        }

        // Priority 2: Match label (only non-consumer domain or explicit service tokens, unless issuer is empty)
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            if let atIndex = label.lastIndex(of: "@") {
                let emailDomain = String(label[label.index(after: atIndex)...]).lowercased()
                let isConsumer = Self.consumerEmailDomains.contains(emailDomain)
                if !isConsumer || account.issuer.isEmpty {
                    if let domainMatch = bestMatch(in: emailDomain) {
                        return domainMatch
                    }
                }
                let localPart = String(label[..<atIndex])
                if account.issuer.isEmpty, let localMatch = bestMatch(in: localPart) {
                    return localMatch
                }
            } else if let matched = bestMatch(in: label) {
                return matched
            }
        }

        return nil
    }

    public func inferredDomain(for account: OTPAccount, includeHeuristicFallback: Bool = false) -> String? {
        let cacheKey = "\(includeHeuristicFallback ? "1" : "0")\u{1F}\(account.customLogoDomain ?? "")\u{1F}\(account.customBrandSlug ?? "")\u{1F}\(account.issuer)\u{1F}\(account.label)"
        if let cached = cache.domain(forKey: cacheKey) {
            return cached
        }
        let resolved = computeInferredDomain(for: account, includeHeuristicFallback: includeHeuristicFallback)
        cache.setDomain(resolved, forKey: cacheKey)
        return resolved
    }

    private func computeInferredDomain(for account: OTPAccount, includeHeuristicFallback: Bool) -> String? {
        if let custom = Self.cleanedDomain(account.customLogoDomain) {
            return custom
        }
        if let matched = match(account: account), !matched.domain.isEmpty {
            return matched.domain
        }
        if let host = Self.extractHostIfDomain(account.issuer) {
            return host
        }
        if let atIndex = account.label.lastIndex(of: "@") {
            let emailDomain = String(account.label[account.label.index(after: atIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if emailDomain.contains(".") && !Self.consumerEmailDomains.contains(emailDomain) {
                return emailDomain
            }
        }
        if includeHeuristicFallback {
            let base = account.issuer
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            if base.count >= 3 {
                return "\(base).com"
            }
        }
        return nil
    }

    private func bestMatch(in rawText: String) -> BrandDefinition? {
        let normalized = Self.normalizeText(rawText)
        guard !normalized.isEmpty else { return nil }

        if let exact = exactAliasMap[normalized] {
            return exact
        }

        let tokens = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        var bestBrand: BrandDefinition?
        var bestScore = 0

        for entry in indexedBrands {
            for normAlias in entry.normalizedAliases {
                let score = matchScore(normalizedAlias: normAlias, normalized: normalized, tokens: tokens)
                if score > bestScore {
                    bestScore = score
                    bestBrand = entry.brand
                }
            }
        }

        return bestBrand
    }

    private func matchScore(normalizedAlias normAlias: String, normalized: String, tokens: Set<String>) -> Int {
        if normalized == normAlias {
            return 10_000 + normAlias.count
        }
        if tokens.contains(normAlias) {
            return 4_000 + normAlias.count
        }

        // Multi-word or domain phrases ("google cloud", "aws.amazon.com", "amazon web services")
        if normAlias.contains(" ") || normAlias.contains(".") {
            if Self.containsPhrase(normalized, phrase: normAlias) {
                return 6_000 + normAlias.count
            }
        } else if normAlias.count >= 4 {
            // Compound tokens like "github-prod" or "icloudmail"
            if tokens.contains(where: { $0.hasPrefix(normAlias) || $0.hasSuffix(normAlias) }) {
                return 2_000 + normAlias.count
            }
        }

        return 0
    }

    private static func normalizeText(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
        }
        if s.hasPrefix("www.") {
            s.removeFirst(4)
        }
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        return s
    }

    private static func containsPhrase(_ text: String, phrase: String) -> Bool {
        guard let range = text.range(of: phrase) else { return false }
        let beforeOK: Bool
        if range.lowerBound == text.startIndex {
            beforeOK = true
        } else {
            let prev = text[text.index(before: range.lowerBound)]
            beforeOK = !prev.isLetter && !prev.isNumber
        }
        let afterOK: Bool
        if range.upperBound == text.endIndex {
            afterOK = true
        } else {
            let next = text[range.upperBound]
            afterOK = !next.isLetter && !next.isNumber
        }
        return beforeOK && afterOK
    }

    private static func extractHostIfDomain(_ raw: String) -> String? {
        let normalized = normalizeText(raw)
        guard normalized.contains("."), !normalized.contains(" ") else { return nil }
        return cleanedDomain(normalized)
    }

    public static func cleanedDomain(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = normalizeText(raw)
        guard !s.isEmpty, s.contains("."), !s.contains(" ") else { return nil }
        return s
    }
}
