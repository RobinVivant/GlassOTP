import Foundation
import Security

public enum GlassOTPConstants {
    public static let appGroupID = "group.com.robinvivant.glassotp"
    public static let keychainService = "com.robinvivant.glassotp.vault"
    public static let keychainAccount = "primary-vault-v1"
    public static let keychainAccessGroupSuffix = "com.robinvivant.glassotp.shared"
    public static let iCloudSyncPreferenceKey = "glassotp.icloud.sync.enabled"
    public static let universalClipboardPreferenceKey = "glassotp.universalClipboard.enabled"
}

public enum SharedClipboardPreferences {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: GlassOTPConstants.appGroupID) ?? .standard
    }

    public static var isUniversalClipboardEnabled: Bool {
        get {
            if defaults.object(forKey: GlassOTPConstants.universalClipboardPreferenceKey) == nil {
                return true
            }
            return defaults.bool(forKey: GlassOTPConstants.universalClipboardPreferenceKey)
        }
        set {
            defaults.set(newValue, forKey: GlassOTPConstants.universalClipboardPreferenceKey)
        }
    }
}

public protocol VaultPersistence: Sendable {
    func loadSnapshot() throws -> OTPVaultSnapshot?
    func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws
    func setICloudSyncEnabled(_ enabled: Bool)
}

public final class InMemoryVaultPersistence: VaultPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: OTPVaultSnapshot?
    public private(set) var iCloudSyncEnabled: Bool = true

    public init(snapshot: OTPVaultSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func loadSnapshot() throws -> OTPVaultSnapshot? {
        lock.withLock { snapshot }
    }

    public func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
    }

    public func setICloudSyncEnabled(_ enabled: Bool) {
        lock.withLock { iCloudSyncEnabled = enabled }
    }
}

public enum KeychainVaultError: Error, LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error (\(status))."
        case .decodingFailed:
            "Stored vault data could not be decoded."
        }
    }
}

public final class KeychainVaultStore: VaultPersistence, @unchecked Sendable {
    public static let shared = KeychainVaultStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var iCloudSyncEnabled: Bool

    public init(defaults: UserDefaults? = UserDefaults(suiteName: GlassOTPConstants.appGroupID)) {
        let resolvedDefaults = defaults ?? .standard
        self.defaults = resolvedDefaults
        if resolvedDefaults.object(forKey: GlassOTPConstants.iCloudSyncPreferenceKey) == nil {
            resolvedDefaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        }
        self.iCloudSyncEnabled = resolvedDefaults.bool(forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
    }

    public func isICloudSyncEnabled() -> Bool {
        lock.withLock { iCloudSyncEnabled }
    }

    public func setICloudSyncEnabled(_ enabled: Bool) {
        let currentSnapshot = try? loadSnapshot()
        lock.withLock {
            iCloudSyncEnabled = enabled
            defaults.set(enabled, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        }
        if let currentSnapshot {
            try? saveSnapshot(currentSnapshot)
        }
    }

    public func loadSnapshot() throws -> OTPVaultSnapshot? {
        let syncEnabled = lock.withLock { iCloudSyncEnabled }
        if let data = try readKeychainData(synchronizable: syncEnabled) ?? readKeychainData(synchronizable: !syncEnabled) {
            return try decodeSnapshot(data)
        }

        #if targetEnvironment(simulator)
        if let simData = try? Data(contentsOf: simulatorFallbackURL()), !simData.isEmpty {
            return try decodeSnapshot(simData)
        }
        #endif

        return nil
    }

    public func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let syncEnabled = lock.withLock { iCloudSyncEnabled }

        // Remove stale entries in the opposite synchronizable bucket so only one authoritative item exists.
        deleteKeychainItem(synchronizable: !syncEnabled)

        let storedInSharedGroup = try writeKeychainData(data, synchronizable: syncEnabled)

        #if targetEnvironment(simulator)
        if !storedInSharedGroup {
            try? writeSimulatorFallback(data)
        } else {
            try? FileManager.default.removeItem(at: simulatorFallbackURL())
        }
        #else
        _ = storedInSharedGroup
        #endif
    }

    private func decodeSnapshot(_ data: Data) throws -> OTPVaultSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(OTPVaultSnapshot.self, from: data)
        } catch {
            throw KeychainVaultError.decodingFailed
        }
    }

    private func resolvedAccessGroup() -> String? {
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
           !prefix.isEmpty,
           !prefix.contains("$(") {
            return prefix + GlassOTPConstants.keychainAccessGroupSuffix
        }
        return nil
    }

    private func baseQuery(synchronizable: Bool, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GlassOTPConstants.keychainService,
            kSecAttrAccount as String: GlassOTPConstants.keychainAccount,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func readKeychainData(synchronizable: Bool) throws -> Data? {
        if let group = resolvedAccessGroup() {
            var query = baseQuery(synchronizable: synchronizable, accessGroup: group)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return data
            }
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                throw KeychainVaultError.unexpectedStatus(status)
            }
        }

        var unscopedQuery = baseQuery(synchronizable: synchronizable, accessGroup: nil)
        unscopedQuery[kSecReturnData as String] = kCFBooleanTrue
        unscopedQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(unscopedQuery as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return data
        }
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecMissingEntitlement {
            return nil
        }
        throw KeychainVaultError.unexpectedStatus(status)
    }

    @discardableResult
    private func writeKeychainData(_ data: Data, synchronizable: Bool) throws -> Bool {
        if let group = resolvedAccessGroup() {
            let status = upsertKeychain(data: data, synchronizable: synchronizable, accessGroup: group)
            if status == errSecSuccess {
                return true
            }
            if status != errSecMissingEntitlement {
                throw KeychainVaultError.unexpectedStatus(status)
            }
        }

        let unscopedStatus = upsertKeychain(data: data, synchronizable: synchronizable, accessGroup: nil)
        if unscopedStatus == errSecSuccess {
            return false
        }
        if unscopedStatus == errSecMissingEntitlement {
            return false
        }
        throw KeychainVaultError.unexpectedStatus(unscopedStatus)
    }

    private func upsertKeychain(data: Data, synchronizable: Bool, accessGroup: String?) -> OSStatus {
        let query = baseQuery(synchronizable: synchronizable, accessGroup: accessGroup)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil)
        }
        return updateStatus
    }

    private func deleteKeychainItem(synchronizable: Bool) {
        if let group = resolvedAccessGroup() {
            SecItemDelete(baseQuery(synchronizable: synchronizable, accessGroup: group) as CFDictionary)
        }
        SecItemDelete(baseQuery(synchronizable: synchronizable, accessGroup: nil) as CFDictionary)
    }

    #if targetEnvironment(simulator)
    private func simulatorFallbackURL() -> URL {
        if let groupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GlassOTPConstants.appGroupID) {
            return groupDir.appendingPathComponent("simulator-vault.json")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("glassotp-simulator-vault.json")
    }

    private func writeSimulatorFallback(_ data: Data) throws {
        let url = simulatorFallbackURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    #endif
}

public enum SharedWidgetStateStore {
    private static let copiedTimestampPrefix = "glassotp.widget.copied."
    private static let revealExpiryPrefix = "glassotp.widget.reveal."

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: GlassOTPConstants.appGroupID) ?? .standard
    }

    public static func recordCopy(accountID: UUID, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: copiedTimestampPrefix + accountID.uuidString)
    }

    public static func wasRecentlyCopied(accountID: UUID, now: Date = Date()) -> Bool {
        let ts = defaults.double(forKey: copiedTimestampPrefix + accountID.uuidString)
        guard ts > 0 else { return false }
        let delta = now.timeIntervalSince1970 - ts
        return delta >= 0 && delta <= 2.5
    }

    public static func reveal(accountID: UUID, for seconds: TimeInterval = 15, now: Date = Date()) {
        let expiry = now.addingTimeInterval(seconds).timeIntervalSince1970
        defaults.set(expiry, forKey: revealExpiryPrefix + accountID.uuidString)
    }

    public static func revealExpiry(accountID: UUID, now: Date = Date()) -> Date? {
        let expiry = defaults.double(forKey: revealExpiryPrefix + accountID.uuidString)
        guard expiry > now.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }

    public static func isRevealed(accountID: UUID, now: Date = Date()) -> Bool {
        revealExpiry(accountID: accountID, now: now) != nil
    }
}
