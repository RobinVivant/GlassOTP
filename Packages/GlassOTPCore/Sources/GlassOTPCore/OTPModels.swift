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

    public static let selectableCases: [OTPAlgorithm] = [.sha1, .sha256, .sha512]
}

public struct OTPTombstone: Codable, Hashable, Sendable {
    public var id: UUID
    public var deletedAt: Date

    public init(id: UUID, deletedAt: Date = Date()) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

public struct OTPFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var sortOrder: Int
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, symbolName, sortOrder, updatedAt
    }

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "folder.fill",
        sortOrder: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.symbolName = try container.decode(String.self, forKey: .symbolName)
        self.sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
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
    public var counterResetAt: Date?
    public var customBrandSlug: String?
    public var customLogoDomain: String?

    enum CodingKeys: String, CodingKey {
        case id, issuer, label, secret, type, algorithm, digits, period, counter
        case folderID, isPinned, sortOrder, createdAt, updatedAt, counterResetAt
        case customBrandSlug, customLogoDomain
    }

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
        updatedAt: Date = Date(),
        counterResetAt: Date? = nil,
        customBrandSlug: String? = nil,
        customLogoDomain: String? = nil
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
        self.counterResetAt = counterResetAt
        self.customBrandSlug = customBrandSlug
        self.customLogoDomain = customLogoDomain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.issuer = (try container.decodeIfPresent(String.self, forKey: .issuer) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = (try container.decodeIfPresent(String.self, forKey: .label) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = try container.decode(Data.self, forKey: .secret)
        self.type = try container.decodeIfPresent(OTPType.self, forKey: .type) ?? .totp
        self.algorithm = try container.decodeIfPresent(OTPAlgorithm.self, forKey: .algorithm) ?? .sha1
        let decodedDigits = try container.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        self.digits = (4...10).contains(decodedDigits) ? decodedDigits : 6
        let decodedPeriod = try container.decodeIfPresent(Int.self, forKey: .period) ?? 30
        self.period = decodedPeriod > 0 ? decodedPeriod : 30
        self.counter = try container.decodeIfPresent(UInt64.self, forKey: .counter) ?? 0
        self.folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        self.counterResetAt = try container.decodeIfPresent(Date.self, forKey: .counterResetAt)
        self.customBrandSlug = try container.decodeIfPresent(String.self, forKey: .customBrandSlug)
        self.customLogoDomain = try container.decodeIfPresent(String.self, forKey: .customLogoDomain)
    }

    public var isSupportedAlgorithm: Bool {
        algorithm != .md5
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

        if let matched = BrandCatalog.shared.match(account: self) {
            return OTPBrandStyle(
                accentHex: "#\(matched.effectiveAccentHex)",
                secondaryHex: "#\(matched.effectiveSecondaryHex)",
                symbolName: matched.category.symbolName,
                monogram: monogram
            )
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
    public var accountTombstones: [OTPTombstone]
    public var folderTombstones: [OTPTombstone]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case folders
        case accounts
        case updatedAt
        case accountTombstones
        case folderTombstones
    }

    public init(
        schemaVersion: Int = 1,
        folders: [OTPFolder] = [],
        accounts: [OTPAccount] = [],
        updatedAt: Date = Date(),
        accountTombstones: [OTPTombstone] = [],
        folderTombstones: [OTPTombstone] = []
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.accounts = accounts
        self.updatedAt = updatedAt
        self.accountTombstones = accountTombstones
        self.folderTombstones = folderTombstones
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.folders = try container.decodeIfPresent([OTPFolder].self, forKey: .folders) ?? []
        self.accounts = try container.decodeIfPresent([OTPAccount].self, forKey: .accounts) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.accountTombstones = try container.decodeIfPresent([OTPTombstone].self, forKey: .accountTombstones) ?? []
        self.folderTombstones = try container.decodeIfPresent([OTPTombstone].self, forKey: .folderTombstones) ?? []
    }

    public func merged(with incoming: OTPVaultSnapshot, tombstoneLimit: Int? = nil) -> OTPVaultSnapshot {
        var folderTombstoneMap: [UUID: Date] = [:]
        for tombstone in folderTombstones + incoming.folderTombstones {
            if let existing = folderTombstoneMap[tombstone.id] {
                folderTombstoneMap[tombstone.id] = max(existing, tombstone.deletedAt)
            } else {
                folderTombstoneMap[tombstone.id] = tombstone.deletedAt
            }
        }

        var folderMap: [UUID: OTPFolder] = [:]
        for folder in folders {
            folderMap[folder.id] = folder
        }
        for folder in incoming.folders {
            if let existing = folderMap[folder.id] {
                if folder.updatedAt >= existing.updatedAt {
                    folderMap[folder.id] = folder
                }
            } else {
                folderMap[folder.id] = folder
            }
        }

        var mergedFolders: [OTPFolder] = []
        mergedFolders.reserveCapacity(folderMap.count)
        for (id, folder) in folderMap {
            if let deletedAt = folderTombstoneMap[id], deletedAt >= folder.updatedAt {
                continue
            }
            folderTombstoneMap.removeValue(forKey: id)
            mergedFolders.append(folder)
        }
        mergedFolders.sort {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        let validFolderIDs = Set(mergedFolders.map(\.id))

        var accountTombstoneMap: [UUID: Date] = [:]
        for tombstone in accountTombstones + incoming.accountTombstones {
            if let existing = accountTombstoneMap[tombstone.id] {
                accountTombstoneMap[tombstone.id] = max(existing, tombstone.deletedAt)
            } else {
                accountTombstoneMap[tombstone.id] = tombstone.deletedAt
            }
        }

        var accountMap: [UUID: OTPAccount] = [:]
        for account in accounts {
            accountMap[account.id] = account
        }
        for account in incoming.accounts {
            if let existing = accountMap[account.id] {
                var winner = account.updatedAt >= existing.updatedAt ? account : existing
                if existing.type == .hotp && account.type == .hotp {
                    let existingReset = existing.counterResetAt ?? .distantPast
                    let incomingReset = account.counterResetAt ?? .distantPast
                    if incomingReset > existingReset {
                        winner.counter = account.counter
                        winner.counterResetAt = account.counterResetAt
                    } else if existingReset > incomingReset {
                        winner.counter = existing.counter
                        winner.counterResetAt = existing.counterResetAt
                    } else {
                        let maxCounter = max(existing.counter, account.counter)
                        if winner.counter != maxCounter {
                            winner.counter = maxCounter
                            winner.updatedAt = max(existing.updatedAt, account.updatedAt)
                        }
                    }
                }
                accountMap[account.id] = winner
            } else {
                accountMap[account.id] = account
            }
        }

        var mergedAccounts: [OTPAccount] = []
        mergedAccounts.reserveCapacity(accountMap.count)
        for (id, var account) in accountMap {
            if let deletedAt = accountTombstoneMap[id], deletedAt >= account.updatedAt {
                continue
            }
            accountTombstoneMap.removeValue(forKey: id)
            if let folderID = account.folderID, !validFolderIDs.contains(folderID) {
                account.folderID = nil
            }
            mergedAccounts.append(account)
        }
        mergedAccounts.sort {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }

        let sortedFolderTombstones = folderTombstoneMap
            .map { OTPTombstone(id: $0.key, deletedAt: $0.value) }
            .sorted { $0.deletedAt > $1.deletedAt }
        let sortedAccountTombstones = accountTombstoneMap
            .map { OTPTombstone(id: $0.key, deletedAt: $0.value) }
            .sorted { $0.deletedAt > $1.deletedAt }

        let finalFolderTombstones = tombstoneLimit.map { Array(sortedFolderTombstones.prefix($0)) } ?? sortedFolderTombstones
        let finalAccountTombstones = tombstoneLimit.map { Array(sortedAccountTombstones.prefix($0)) } ?? sortedAccountTombstones

        return OTPVaultSnapshot(
            schemaVersion: max(schemaVersion, incoming.schemaVersion),
            folders: mergedFolders,
            accounts: mergedAccounts,
            updatedAt: max(updatedAt, incoming.updatedAt),
            accountTombstones: finalAccountTombstones,
            folderTombstones: finalFolderTombstones
        )
    }
}

public enum VaultImportReconciler {
    public struct Plan: Sendable, Equatable {
        public let folders: [OTPFolder]
        public let accounts: [OTPAccount]
        public let addedCount: Int
        public let skippedDuplicateCount: Int
    }

    public static func reconcile(
        importedAccounts: [OTPAccount],
        importedFolders: [OTPFolder],
        existingAccounts: [OTPAccount],
        existingFolders: [OTPFolder],
        existingAccountTombstones: [OTPTombstone] = [],
        existingFolderTombstones: [OTPTombstone] = [],
        selectedIDs: Set<UUID>? = nil,
        skipDuplicates: Bool = true,
        preserveEmptyFolders: Bool = false,
        importedAt: Date = Date()
    ) -> Plan {
        let filteredImports: [OTPAccount]
        if let selectedIDs {
            filteredImports = importedAccounts.filter { selectedIDs.contains($0.id) }
        } else {
            filteredImports = importedAccounts
        }

        var mergedFolders = existingFolders
        var folderIDByLowerName: [String: UUID] = [:]
        var usedFolderIDs = Set(existingFolders.map(\.id)).union(existingFolderTombstones.map(\.id))
        for folder in existingFolders {
            let key = folder.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, folderIDByLowerName[key] == nil {
                folderIDByLowerName[key] = folder.id
            }
        }
        let importedFolderByID = Dictionary(
            importedFolders.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var mergedAccounts = existingAccounts
        var seenAccountIDs = Set(existingAccounts.map(\.id)).union(existingAccountTombstones.map(\.id))
        var seenFingerprints = Set(existingAccounts.map(\.fingerprint))
        var folderIDMap: [UUID: UUID] = [:]
        var addedCount = 0
        var skippedDuplicateCount = 0

        func ensureFolder(_ importedFolder: OTPFolder) -> UUID {
            if let mappedID = folderIDMap[importedFolder.id] {
                return mappedID
            }
            let cleanName = importedFolder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = cleanName.lowercased()
            if !key.isEmpty, let existingID = folderIDByLowerName[key] {
                folderIDMap[importedFolder.id] = existingID
                return existingID
            }
            let resolvedFolderID = usedFolderIDs.contains(importedFolder.id) ? UUID() : importedFolder.id
            var folder = importedFolder
            folder.id = resolvedFolderID
            folder.sortOrder = mergedFolders.count
            folder.updatedAt = importedAt
            mergedFolders.append(folder)
            usedFolderIDs.insert(resolvedFolderID)
            if !key.isEmpty {
                folderIDByLowerName[key] = resolvedFolderID
            }
            folderIDMap[importedFolder.id] = resolvedFolderID
            return resolvedFolderID
        }

        for var account in filteredImports {
            let fp = account.fingerprint
            if skipDuplicates && seenFingerprints.contains(fp) {
                skippedDuplicateCount += 1
                continue
            }

            if seenAccountIDs.contains(account.id) {
                account.id = UUID()
            }

            if let sourceFolderID = account.folderID,
               let importedFolder = importedFolderByID[sourceFolderID] {
                account.folderID = ensureFolder(importedFolder)
            } else {
                account.folderID = nil
            }

            account.sortOrder = mergedAccounts.count
            account.updatedAt = importedAt
            seenAccountIDs.insert(account.id)
            seenFingerprints.insert(fp)
            mergedAccounts.append(account)
            addedCount += 1
        }

        if preserveEmptyFolders {
            for importedFolder in importedFolders {
                _ = ensureFolder(importedFolder)
            }
        }

        return Plan(
            folders: mergedFolders,
            accounts: mergedAccounts,
            addedCount: addedCount,
            skippedDuplicateCount: skippedDuplicateCount
        )
    }
}
