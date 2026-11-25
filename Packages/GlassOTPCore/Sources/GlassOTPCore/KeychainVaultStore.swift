import Darwin
import Foundation
import Security

public enum GlassOTPConstants {
    public static let appGroupID = "group.com.robinvivant.glassotp"
    public static let keychainService = "com.robinvivant.glassotp.vault"
    public static let keychainAccount = "primary-vault-v1"
    public static let keychainLocalReplicaAccount = "local-replica-v1"
    public static let keychainAccessGroupSuffix = "com.robinvivant.glassotp.shared"
    public static let iCloudSyncPreferenceKey = "glassotp.icloud.sync.enabled"
    public static let universalClipboardPreferenceKey = "glassotp.universalClipboard.enabled"
    public static let appLockPreferenceKey = "glassotp.security.appLockEnabled"
    public static let pendingICloudDeletePreferenceKey = "glassotp.icloud.pendingDelete"
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

public enum SharedSecurityPreferences {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: GlassOTPConstants.appGroupID) ?? .standard
    }

    public static var isAppLockEnabled: Bool {
        get {
            defaults.bool(forKey: GlassOTPConstants.appLockPreferenceKey)
        }
        set {
            defaults.set(newValue, forKey: GlassOTPConstants.appLockPreferenceKey)
        }
    }

    public static var hasPendingICloudCleanup: Bool {
        get {
            defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
        }
        set {
            defaults.set(newValue, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
        }
    }
}

public protocol VaultPersistence: Sendable {
    func isICloudSyncEnabled() -> Bool
    func loadSnapshot() throws -> OTPVaultSnapshot?
    func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws
    @discardableResult
    func saveMergedSnapshot(_ snapshot: OTPVaultSnapshot) throws -> OTPVaultSnapshot
    @discardableResult
    func mutateSnapshot(_ transform: (inout OTPVaultSnapshot) -> Void) throws -> OTPVaultSnapshot
    @discardableResult
    func mutateSnapshotIfPresent(_ transform: (inout OTPVaultSnapshot) -> Bool) throws -> OTPVaultSnapshot?
    func setICloudSyncEnabled(_ enabled: Bool) throws
}

public final class InMemoryVaultPersistence: VaultPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: OTPVaultSnapshot?
    public private(set) var iCloudSyncEnabled: Bool = true

    public init(snapshot: OTPVaultSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func isICloudSyncEnabled() -> Bool {
        lock.withLock { iCloudSyncEnabled }
    }

    public func loadSnapshot() throws -> OTPVaultSnapshot? {
        lock.withLock { snapshot }
    }

    public func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
    }

    @discardableResult
    public func saveMergedSnapshot(_ local: OTPVaultSnapshot) throws -> OTPVaultSnapshot {
        lock.withLock {
            let merged = self.snapshot?.merged(with: local, tombstoneLimit: KeychainVaultStore.maxTombstones) ?? local
            self.snapshot = merged
            return merged
        }
    }

    @discardableResult
    public func mutateSnapshot(_ transform: (inout OTPVaultSnapshot) -> Void) throws -> OTPVaultSnapshot {
        lock.withLock {
            var current = self.snapshot ?? OTPVaultSnapshot()
            transform(&current)
            current.updatedAt = Date()
            self.snapshot = current
            return current
        }
    }

    @discardableResult
    public func mutateSnapshotIfPresent(_ transform: (inout OTPVaultSnapshot) -> Bool) throws -> OTPVaultSnapshot? {
        lock.withLock {
            guard var current = self.snapshot else { return nil }
            guard transform(&current) else { return current }
            current.updatedAt = Date()
            self.snapshot = current
            return current
        }
    }

    public func setICloudSyncEnabled(_ enabled: Bool) throws {
        lock.withLock { iCloudSyncEnabled = enabled }
    }
}

public enum KeychainVaultError: Error, LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case decodingFailed
    case cloudCleanupFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error (\(status))."
        case .decodingFailed:
            "Stored vault data could not be decoded."
        case .cloudCleanupFailed(let status):
            "Local vault was saved, but deleting the iCloud Keychain copy failed (\(status))."
        }
    }
}

public final class KeychainVaultStore: VaultPersistence, @unchecked Sendable {
    public static let shared = KeychainVaultStore()
    public static let maxTombstones = 500

    private let lock = NSLock()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = UserDefaults(suiteName: GlassOTPConstants.appGroupID)) {
        let resolvedDefaults = defaults ?? .standard
        self.defaults = resolvedDefaults
        if resolvedDefaults.object(forKey: GlassOTPConstants.iCloudSyncPreferenceKey) == nil {
            resolvedDefaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        }
    }

    private func isICloudSyncEnabledUnlocked() -> Bool {
        if defaults.object(forKey: GlassOTPConstants.iCloudSyncPreferenceKey) == nil {
            defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        }
        return defaults.bool(forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
    }

    public func isICloudSyncEnabled() -> Bool {
        lock.withLock { isICloudSyncEnabledUnlocked() }
    }

    public func setICloudSyncEnabled(_ enabled: Bool) throws {
        try setICloudSyncEnabled(enabled, removeOppositeBucket: true)
    }

    @discardableResult
    public func setICloudSyncEnabled(_ enabled: Bool, removeOppositeBucket: Bool = true) throws -> OTPVaultSnapshot? {
        try withVaultLock {
            let syncSnapshot = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true
            ).map(decodeSnapshot)
            let localSnapshot = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false
            ).map(decodeSnapshot)
            let replicaSnapshot = try? readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            ).map(decodeSnapshot)

            var combined: OTPVaultSnapshot?
            for candidate in (enabled ? [localSnapshot, replicaSnapshot, syncSnapshot] : [syncSnapshot, replicaSnapshot, localSnapshot]).compactMap({ $0 }) {
                combined = combined?.merged(with: candidate, tombstoneLimit: Self.maxTombstones) ?? candidate
            }

            if let combined {
                let data = try encodeSnapshot(combined)
                let storedInSharedGroup = try writeKeychainData(
                    data,
                    account: GlassOTPConstants.keychainAccount,
                    synchronizable: enabled
                )
                if enabled {
                    _ = try? writeKeychainData(
                        data,
                        account: GlassOTPConstants.keychainLocalReplicaAccount,
                        synchronizable: false
                    )
                }
                #if targetEnvironment(simulator)
                if !storedInSharedGroup {
                    try writeSimulatorFallback(data)
                } else {
                    try? FileManager.default.removeItem(at: simulatorFallbackURL())
                }
                #else
                _ = storedInSharedGroup
                #endif
            }

            defaults.set(enabled, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)

            if enabled {
                SharedSecurityPreferences.hasPendingICloudCleanup = false
                if removeOppositeBucket {
                    try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: false)
                }
            } else if removeOppositeBucket {
                do {
                    try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: true)
                    SharedSecurityPreferences.hasPendingICloudCleanup = false
                } catch let error as KeychainVaultError {
                    if case .unexpectedStatus(let status) = error {
                        SharedSecurityPreferences.hasPendingICloudCleanup = true
                        throw KeychainVaultError.cloudCleanupFailed(status)
                    }
                    SharedSecurityPreferences.hasPendingICloudCleanup = true
                    throw error
                }
            } else {
                SharedSecurityPreferences.hasPendingICloudCleanup = false
            }

            return combined
        }
    }

    public func retryPendingICloudCleanup() throws {
        try withVaultLock {
            guard !isICloudSyncEnabledUnlocked() else {
                SharedSecurityPreferences.hasPendingICloudCleanup = false
                return
            }
            do {
                try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: true)
                SharedSecurityPreferences.hasPendingICloudCleanup = false
            } catch let error as KeychainVaultError {
                if case .unexpectedStatus(let status) = error {
                    SharedSecurityPreferences.hasPendingICloudCleanup = true
                    throw KeychainVaultError.cloudCleanupFailed(status)
                }
                SharedSecurityPreferences.hasPendingICloudCleanup = true
                throw error
            }
        }
    }

    public func loadSnapshot() throws -> OTPVaultSnapshot? {
        try withVaultLock { try loadSnapshotUnlocked() }
    }

    public func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws {
        try withVaultLock {
            try writeSnapshotUnlocked(snapshot)
        }
    }

    @discardableResult
    public func saveMergedSnapshot(_ local: OTPVaultSnapshot) throws -> OTPVaultSnapshot {
        try withVaultLock {
            let merged = try loadSnapshotUnlocked()?.merged(with: local, tombstoneLimit: Self.maxTombstones) ?? local
            try writeSnapshotUnlocked(merged)
            return merged
        }
    }

    @discardableResult
    public func mutateSnapshot(_ transform: (inout OTPVaultSnapshot) -> Void) throws -> OTPVaultSnapshot {
        try withVaultLock {
            var current = try loadSnapshotUnlocked() ?? OTPVaultSnapshot()
            transform(&current)
            current.updatedAt = Date()
            try writeSnapshotUnlocked(current)
            return current
        }
    }

    @discardableResult
    public func mutateSnapshotIfPresent(_ transform: (inout OTPVaultSnapshot) -> Bool) throws -> OTPVaultSnapshot? {
        try withVaultLock {
            guard var current = try loadSnapshotUnlocked() else {
                return nil
            }
            guard transform(&current) else {
                return current
            }
            current.updatedAt = Date()
            try writeSnapshotUnlocked(current)
            return current
        }
    }

    private func loadSnapshotUnlocked() throws -> OTPVaultSnapshot? {
        let syncEnabled = isICloudSyncEnabledUnlocked()
        if let primaryData = try readKeychainData(
            account: GlassOTPConstants.keychainAccount,
            synchronizable: syncEnabled
        ) {
            let primarySnapshot = try decodeSnapshot(primaryData)
            guard syncEnabled else {
                return primarySnapshot
            }

            if let replicaData = try readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            ) {
                if let replicaSnapshot = try? decodeSnapshot(replicaData) {
                    if primarySnapshot == replicaSnapshot {
                        return primarySnapshot
                    }
                    let reconciled = primarySnapshot.merged(with: replicaSnapshot, tombstoneLimit: Self.maxTombstones)
                    if reconciled.accounts != primarySnapshot.accounts || reconciled.folders != primarySnapshot.folders {
                        try writeSnapshotUnlocked(reconciled)
                    } else if reconciled != replicaSnapshot {
                        if let replicaEncoded = try? encodeSnapshot(reconciled) {
                            _ = try? writeKeychainData(
                                replicaEncoded,
                                account: GlassOTPConstants.keychainLocalReplicaAccount,
                                synchronizable: false
                            )
                        }
                    }
                    return reconciled
                }
            }

            if let seedData = try? encodeSnapshot(primarySnapshot) {
                _ = try? writeKeychainData(
                    seedData,
                    account: GlassOTPConstants.keychainLocalReplicaAccount,
                    synchronizable: false
                )
            }
            return primarySnapshot
        }

        if syncEnabled {
            if let localFallback = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false
            ) {
                return try decodeSnapshot(localFallback)
            }
            if let replicaFallback = try readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            ) {
                return try decodeSnapshot(replicaFallback)
            }
        }

        #if targetEnvironment(simulator)
        if let simData = try? Data(contentsOf: simulatorFallbackURL()), !simData.isEmpty {
            return try decodeSnapshot(simData)
        }
        #endif

        return nil
    }

    private func writeSnapshotUnlocked(_ snapshot: OTPVaultSnapshot) throws {
        let data = try encodeSnapshot(snapshot)
        let syncEnabled = isICloudSyncEnabledUnlocked()

        let storedInSharedGroup = try writeKeychainData(
            data,
            account: GlassOTPConstants.keychainAccount,
            synchronizable: syncEnabled
        )

        if syncEnabled {
            _ = try? writeKeychainData(
                data,
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )
        }

        #if targetEnvironment(simulator)
        if !storedInSharedGroup {
            try writeSimulatorFallback(data)
        } else {
            try? FileManager.default.removeItem(at: simulatorFallbackURL())
        }
        #else
        _ = storedInSharedGroup
        #endif
    }

    private func encodeSnapshot(_ snapshot: OTPVaultSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
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

    private func withVaultLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            let lockURL = vaultLockFileURL()
            try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            if fd >= 0 {
                defer {
                    flock(fd, LOCK_UN)
                    close(fd)
                }
                if flock(fd, LOCK_EX) == 0 {
                    return try body()
                }
            }
            return try body()
        }
    }

    private func vaultLockFileURL() -> URL {
        if let groupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GlassOTPConstants.appGroupID) {
            return groupDir.appendingPathComponent(".vault-lock")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("glassotp-vault.lock")
    }

    private func resolvedAccessGroup() -> String? {
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String {
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               !trimmed.contains("$("),
               trimmed != ".",
               trimmed.rangeOfCharacter(from: .alphanumerics) != nil {
                return trimmed + GlassOTPConstants.keychainAccessGroupSuffix
            }
        }
        return nil
    }

    private func baseQuery(account: String, synchronizable: Bool, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GlassOTPConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue!
        #endif
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func readKeychainData(account: String, synchronizable: Bool) throws -> Data? {
        if let group = resolvedAccessGroup() {
            var query = baseQuery(account: account, synchronizable: synchronizable, accessGroup: group)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return data
            }
            #if targetEnvironment(simulator)
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                throw KeychainVaultError.unexpectedStatus(status)
            }
            #else
            if status == errSecItemNotFound {
                return nil
            }
            throw KeychainVaultError.unexpectedStatus(status)
            #endif
        }

        var unscopedQuery = baseQuery(account: account, synchronizable: synchronizable, accessGroup: nil)
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
        #if targetEnvironment(simulator)
        if status == errSecMissingEntitlement {
            return nil
        }
        #endif
        throw KeychainVaultError.unexpectedStatus(status)
    }

    @discardableResult
    private func writeKeychainData(_ data: Data, account: String, synchronizable: Bool) throws -> Bool {
        if let group = resolvedAccessGroup() {
            let status = upsertKeychain(data: data, account: account, synchronizable: synchronizable, accessGroup: group)
            if status == errSecSuccess {
                return true
            }
            #if targetEnvironment(simulator)
            if status != errSecMissingEntitlement {
                throw KeychainVaultError.unexpectedStatus(status)
            }
            #else
            throw KeychainVaultError.unexpectedStatus(status)
            #endif
        }

        let unscopedStatus = upsertKeychain(data: data, account: account, synchronizable: synchronizable, accessGroup: nil)
        if unscopedStatus == errSecSuccess {
            return false
        }
        #if targetEnvironment(simulator)
        if unscopedStatus == errSecMissingEntitlement {
            return false
        }
        #endif
        throw KeychainVaultError.unexpectedStatus(unscopedStatus)
    }

    private func upsertKeychain(data: Data, account: String, synchronizable: Bool, accessGroup: String?) -> OSStatus {
        let query = baseQuery(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
        let accessibility: CFString = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibility
            return SecItemAdd(addQuery as CFDictionary, nil)
        }
        return updateStatus
    }

    private func deleteKeychainItem(account: String, synchronizable: Bool) throws {
        if let group = resolvedAccessGroup() {
            let status = SecItemDelete(baseQuery(account: account, synchronizable: synchronizable, accessGroup: group) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                return
            }
            #if targetEnvironment(simulator)
            if status != errSecMissingEntitlement {
                throw KeychainVaultError.unexpectedStatus(status)
            }
            #else
            throw KeychainVaultError.unexpectedStatus(status)
            #endif
        }

        let unscopedStatus = SecItemDelete(baseQuery(account: account, synchronizable: synchronizable, accessGroup: nil) as CFDictionary)
        if unscopedStatus == errSecSuccess || unscopedStatus == errSecItemNotFound {
            return
        }
        #if targetEnvironment(simulator)
        if unscopedStatus == errSecMissingEntitlement {
            return
        }
        #endif
        throw KeychainVaultError.unexpectedStatus(unscopedStatus)
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
        copyExpiry(accountID: accountID, now: now) != nil
    }

    public static func copyExpiry(accountID: UUID, now: Date = Date()) -> Date? {
        let ts = defaults.double(forKey: copiedTimestampPrefix + accountID.uuidString)
        guard ts > 0 else { return nil }
        let delta = now.timeIntervalSince1970 - ts
        guard delta >= 0 && delta < 2.5 else { return nil }
        return Date(timeIntervalSince1970: ts + 2.5)
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
