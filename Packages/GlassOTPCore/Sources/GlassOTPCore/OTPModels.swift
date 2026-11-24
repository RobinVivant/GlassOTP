import CryptoKit
import Foundation

public enum OTPType: String, Codable, Sendable, CaseIterable, Identifiable {
    case totp
    case hotp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .totp: "Time-based (TOTP)"
        case .hotp: "Counter-based (HOTP)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .totp: "TOTP"
        case .hotp: "HOTP"
        }
    }
}

public enum OTPAlgorithm: String, Codable, Sendable, CaseIterable, Identifiable {
    case sha1
    case sha256
    case sha512
    case md5

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.uppercased()
    }
}

public struct OTPFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "folder.fill",
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.sortOrder = sortOrder
    }
}

public struct OTPBrandStyle: Hashable, Sendable {
    public let accentHex: String
    public let secondaryHex: String
    public let symbolName: String
    public let monogram: String

    public init(accentHex: String, secondaryHex: String, symbolName: String, monogram: String) {
        self.accentHex = accentHex
        self.secondaryHex = secondaryHex
        self.symbolName = symbolName
        self.monogram = monogram
    }
}

public struct OTPAccount: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var issuer: String
    public var label: String
    public var secret: Data
    public var type: OTPType
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int
    public var counter: UInt64
    public var folderID: UUID?
    public var isPinned: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        issuer: String,
        label: String,
        secret: Data,
        type: OTPType = .totp,
        algorithm: OTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        counter: UInt64 = 0,
        folderID: UUID? = nil,
        isPinned: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
        self.type = type
        self.algorithm = algorithm
        self.digits = (4...10).contains(digits) ? digits : 6
        self.period = period > 0 ? period : 30
        self.counter = counter
        self.folderID = folderID
        self.isPinned = isPinned
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        if !issuer.isEmpty {
            return issuer
        }
        if !label.isEmpty {
            return label
        }
        return "Account"
    }

    public var displaySubtitle: String {
        if issuer.isEmpty {
            return ""
        }
        return label
    }

    public var fingerprint: String {
        var data = Data()
        let canonical = "\(type.rawValue)|\(issuer.lowercased())|\(label.lowercased())|\(digits)|\(period)|\(algorithm.rawValue)|"
        data.append(Data(canonical.utf8))
        data.append(secret)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public var brandStyle: OTPBrandStyle {
        let key = displayTitle.lowercased()
        let monogram = Self.makeMonogram(from: displayTitle)

        let knownBrands: [(matches: [String], accent: String, secondary: String, symbol: String)] = [
            (["github"], "#6E5494", "#2B3137", "chevron.left.forwardslash.chevron.right"),
            (["gitlab"], "#FC6D26", "#E24329", "flame.fill"),
            (["google", "gmail", "youtube", "gcp"], "#4285F4", "#34A853", "g.circle.fill"),
            (["apple", "icloud"], "#5E9EFF", "#1D4ED8", "apple.logo"),
            (["aws", "amazon"], "#FF9900", "#D97706", "cloud.fill"),
            (["cloudflare"], "#F38020", "#EA580C", "bolt.shield.fill"),
            (["slack"], "#4A154B", "#E01E5A", "number"),
            (["discord"], "#5865F2", "#404EED", "bubble.left.and.bubble.right.fill"),
            (["stripe"], "#635BFF", "#0A2540", "creditcard.fill"),
            (["microsoft", "azure", "outlook", "office"], "#00A4EF", "#0078D4", "square.grid.2x2.fill"),
            (["dropbox"], "#0061FF", "#0047B3", "shippingbox.fill"),
            (["facebook", "meta", "instagram"], "#1877F2", "#0C52B5", "person.2.fill"),
            (["evernote"], "#00A82D", "#047857", "note.text"),
            (["1password", "onepassword"], "#1A8CFF", "#0F4C81", "key.horizontal.fill"),
            (["proton", "protonmail"], "#6D4AFF", "#4C1D95", "envelope.badge.shield.half.filled.fill"),
            (["tailscale"], "#4F6BFF", "#1E293B", "network"),
            (["digitalocean"], "#0080FF", "#0284C7", "drop.fill"),
            (["vercel"], "#A855F7", "#18181B", "triangle.fill"),
            (["linear"], "#5E6AD2", "#312E81", "checklist"),
            (["figma"], "#A259FF", "#F24E1E", "paintbrush.fill"),
            (["npm", "node"], "#CB3837", "#991B1B", "cube.box.fill"),
            (["nas", "heim-nas", "synology", "truenas"], "#14B8A6", "#0F766E", "externaldrive.connected.to.line.below.fill"),
            (["ssh", "linux", "server", "vps"], "#10B981", "#047857", "terminal.fill"),
            (["bank", "chase", "revolut", "wise", "paypal"], "#0EA5E9", "#0369A1", "building.columns.fill"),
        ]

        for entry in knownBrands {
            if entry.matches.contains(where: { key.contains($0) }) {
                return OTPBrandStyle(
                    accentHex: entry.accent,
                    secondaryHex: entry.secondary,
                    symbolName: entry.symbol,
                    monogram: monogram
                )
            }
        }

        let palette: [(String, String, String)] = [
            ("#38BDF8", "#0284C7", "key.fill"),
            ("#818CF8", "#4F46E5", "lock.shield.fill"),
            ("#34D399", "#059669", "checkmark.shield.fill"),
            ("#F472B6", "#DB2777", "sparkles"),
            ("#FBBF24", "#D97706", "shield.lefthalf.filled"),
            ("#2DD4BF", "#0D9488", "cpu.fill"),
            ("#FB923C", "#EA580C", "bolt.fill"),
            ("#A78BFA", "#7C3AED", "hexagon.fill"),
        ]
        let hash = SHA256.hash(data: Data(key.utf8)).withUnsafeBytes { $0.first ?? 0 }
        let chosen = palette[Int(hash) % palette.count]
        return OTPBrandStyle(
            accentHex: chosen.0,
            secondaryHex: chosen.1,
            symbolName: chosen.2,
            monogram: monogram
        )
    }

    private static func makeMonogram(from title: String) -> String {
        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count >= 2,
           let first = words[0].first,
           let second = words[1].first {
            return String([first, second]).uppercased()
        }
        let cleaned = words.first ?? title
        return String(cleaned.prefix(2)).uppercased()
    }
}

public struct OTPVaultSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var folders: [OTPFolder]
    public var accounts: [OTPAccount]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        folders: [OTPFolder] = [],
        accounts: [OTPAccount] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.accounts = accounts
        self.updatedAt = updatedAt
    }
}
