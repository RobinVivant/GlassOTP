import Darwin
import Foundation
import Security

public enum GlassOTPConstants {
    public static let appGroupID = "group.com.robinvivant.glassotp"
    public static let keychainService = "com.robinvivant.glassotp.vault"
    public static let keychainAccount = "primary-vault-v1"
    public static let keychainLocalReplicaAccount = "local-replica-v1"
    public static let keychainSyncMarkerAccount = "icloud-sync-marker-v1"
    public static let keychainAccessGroupSuffix = "com.robinvivant.glassotp.shared"
    public static let iCloudSyncPreferenceKey = "glassotp.icloud.sync.enabled"
    public static let universalClipboardPreferenceKey = "glassotp.universalClipboard.enabled"
    public static let appLockPreferenceKey = "glassotp.security.appLockEnabled"
    public static let pendingICloudDeletePreferenceKey = "glassotp.icloud.pendingDelete"
    public static let legacyMigrationCheckedKey = "glassotp.keychain.legacyMigrationChecked"
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

    public static var isAppLockPreferenceInitialized: Bool {
        defaults.object(forKey: GlassOTPConstants.appLockPreferenceKey) != nil
    }

    public static var isAppLockEnabled: Bool {
        get {
            defaults.bool(forKey: GlassOTPConstants.appLockPreferenceKey)
        }
        set {
            defaults.set(newValue, forKey: GlassOTPConstants.appLockPreferenceKey)
        }
    }

    /// Fails closed before the updated main app writes the persisted app lock preference.
    public static var effectiveAppLockEnabled: Bool {
        isAppLockPreferenceInitialized ? isAppLockEnabled : true
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

public enum KeychainVaultError: Error, LocalizedError, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case decodingFailed
    case cloudCleanupFailed(OSStatus)
    case lockUnavailable

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error (\(status))."
        case .decodingFailed:
            "Stored vault data could not be decoded."
        case .cloudCleanupFailed(let status):
            "Local vault was saved, but deleting the iCloud Keychain copy failed (\(status))."
        case .lockUnavailable:
            "Could not acquire the shared vault lock."
        }
    }
}

internal protocol KeychainBackend: Sendable {
    func resolvedAccessGroup() -> String?
    func read(account: String, synchronizable: Bool, accessGroup: String?) -> (status: OSStatus, data: Data?)
    func upsert(data: Data, account: String, synchronizable: Bool, accessGroup: String?, accessibility: CFString) -> OSStatus
    func delete(account: String, synchronizable: Bool, accessGroup: String?) -> OSStatus
}

private struct SystemKeychainBackend: KeychainBackend {
    func resolvedAccessGroup() -> String? {
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

    func read(account: String, synchronizable: Bool, accessGroup: String?) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, status == errSecSuccess ? (item as? Data) : nil)
    }

    func upsert(data: Data, account: String, synchronizable: Bool, accessGroup: String?, accessibility: CFString) -> OSStatus {
        let query = baseQuery(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
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

    func delete(account: String, synchronizable: Bool, accessGroup: String?) -> OSStatus {
        SecItemDelete(baseQuery(account: account, synchronizable: synchronizable, accessGroup: accessGroup) as CFDictionary)
    }
}

private struct CloudSyncMarker: Codable {
    let disabledAt: Date
}

public final class KeychainVaultStore: VaultPersistence, @unchecked Sendable {
    public static let shared = KeychainVaultStore()
    public static let maxTombstones = 500

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let backend: any KeychainBackend
    private let customLockFileURL: URL?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: GlassOTPConstants.appGroupID)) {
        let resolvedDefaults = defaults ?? .standard
        self.defaults = resolvedDefaults
        self.backend = SystemKeychainBackend()
        self.customLockFileURL = nil
        if resolvedDefaults.object(forKey: GlassOTPConstants.iCloudSyncPreferenceKey) == nil {
            resolvedDefaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        }
    }

    internal init(
        defaults: UserDefaults,
        backend: any KeychainBackend,
        lockFileURL: URL? = nil
    ) {
        self.defaults = defaults
        self.backend = backend
        self.customLockFileURL = lockFileURL
        if defaults.object(forKey: GlassOTPConstants.iCloudSyncPreferenceKey) == nil {
            defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
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
        try withVaultLock(isMutating: true) {
            let syncSnapshot = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true
            ).map(decodeSnapshot)
            let localSnapshot = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false
            ).map(decodeSnapshot)
            let replicaSnapshot = (try? readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )).flatMap { try? decodeSnapshot($0) }

            var combined: OTPVaultSnapshot?
            let candidates = (enabled
                ? [localSnapshot, replicaSnapshot, syncSnapshot]
                : [syncSnapshot, replicaSnapshot, localSnapshot]
            ).compactMap { $0 }
            for candidate in candidates {
                combined = combined?.merged(with: candidate, tombstoneLimit: Self.maxTombstones) ?? candidate
            }

            if enabled {
                try deleteKeychainItem(account: GlassOTPConstants.keychainSyncMarkerAccount, synchronizable: true)
                var normalizedCombined: OTPVaultSnapshot?
                if let combined {
                    let data = try encodeSnapshot(combined)
                    normalizedCombined = try decodeSnapshot(data)
                    _ = try writeKeychainData(
                        data,
                        account: GlassOTPConstants.keychainLocalReplicaAccount,
                        synchronizable: false
                    )
                    let storedInSharedGroup = try writeKeychainData(
                        data,
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: true
                    )
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
                defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
                defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                if removeOppositeBucket {
                    try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: false)
                }
                return normalizedCombined
            } else {
                var normalizedCombined: OTPVaultSnapshot?
                if let combined {
                    let data = try encodeSnapshot(combined)
                    normalizedCombined = try decodeSnapshot(data)
                    let storedLocal = try writeKeychainData(
                        data,
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: false
                    )
                    #if targetEnvironment(simulator)
                    if !storedLocal {
                        try writeSimulatorFallback(data)
                    } else {
                        try? FileManager.default.removeItem(at: simulatorFallbackURL())
                    }
                    #else
                    _ = storedLocal
                    #endif
                }

                defaults.set(false, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
                try deleteKeychainItem(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false)

                if removeOppositeBucket {
                    do {
                        let markerData = try VaultSnapshotCoder.encodeValue(CloudSyncMarker(disabledAt: Date()))
                        _ = try writeKeychainData(
                            markerData,
                            account: GlassOTPConstants.keychainSyncMarkerAccount,
                            synchronizable: true
                        )
                        try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: true)
                        defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                    } catch let error as KeychainVaultError {
                        defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                        if case .unexpectedStatus(let status) = error {
                            throw KeychainVaultError.cloudCleanupFailed(status)
                        }
                        throw error
                    }
                } else {
                    defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                }
                return normalizedCombined
            }
        }
    }

    public func retryPendingICloudCleanup() throws {
        try withVaultLock(isMutating: true) {
            guard !isICloudSyncEnabledUnlocked() else {
                defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                return
            }
            do {
                let markerData = try VaultSnapshotCoder.encodeValue(CloudSyncMarker(disabledAt: Date()))
                _ = try writeKeychainData(
                    markerData,
                    account: GlassOTPConstants.keychainSyncMarkerAccount,
                    synchronizable: true
                )
                try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: true)
                defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
            } catch let error as KeychainVaultError {
                defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                if case .unexpectedStatus(let status) = error {
                    throw KeychainVaultError.cloudCleanupFailed(status)
                }
                throw error
            }
        }
    }

    public func loadSnapshot() throws -> OTPVaultSnapshot? {
        try withVaultLock(isMutating: false) { try loadSnapshotUnlocked() }
    }

    public func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws {
        try withVaultLock(isMutating: true) {
            _ = try writeSnapshotUnlocked(snapshot)
        }
    }

    @discardableResult
    public func saveMergedSnapshot(_ local: OTPVaultSnapshot) throws -> OTPVaultSnapshot {
        try withVaultLock(isMutating: true) {
            let merged = try loadSnapshotUnlocked()?.merged(with: local, tombstoneLimit: Self.maxTombstones) ?? local
            return try writeSnapshotUnlocked(merged)
        }
    }

    @discardableResult
    public func mutateSnapshot(_ transform: (inout OTPVaultSnapshot) -> Void) throws -> OTPVaultSnapshot {
        try withVaultLock(isMutating: true) {
            var current = try loadSnapshotUnlocked() ?? OTPVaultSnapshot()
            transform(&current)
            current.updatedAt = Date()
            return try writeSnapshotUnlocked(current)
        }
    }

    @discardableResult
    public func mutateSnapshotIfPresent(_ transform: (inout OTPVaultSnapshot) -> Bool) throws -> OTPVaultSnapshot? {
        try withVaultLock(isMutating: true) {
            guard var current = try loadSnapshotUnlocked() else {
                return nil
            }
            guard transform(&current) else {
                return current
            }
            current.updatedAt = Date()
            return try writeSnapshotUnlocked(current)
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

            if let replicaData = try? readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            ), let replicaSnapshot = try? decodeSnapshot(replicaData) {
                if primarySnapshot == replicaSnapshot {
                    return primarySnapshot
                }
                let reconciled = primarySnapshot.merged(with: replicaSnapshot, tombstoneLimit: Self.maxTombstones)
                let cloudNeedsSync = reconciled.accounts != primarySnapshot.accounts
                    || reconciled.folders != primarySnapshot.folders
                    || reconciled.accountTombstones != primarySnapshot.accountTombstones
                    || reconciled.folderTombstones != primarySnapshot.folderTombstones
                    || reconciled.tombstoneHorizon != primarySnapshot.tombstoneHorizon

                if cloudNeedsSync {
                    if let written = try? writeSnapshotUnlocked(reconciled) {
                        return written
                    }
                    return (try? normalizeSnapshot(reconciled)) ?? reconciled
                } else if reconciled != replicaSnapshot {
                    if let replicaEncoded = try? encodeSnapshot(reconciled) {
                        _ = try? writeKeychainData(
                            replicaEncoded,
                            account: GlassOTPConstants.keychainLocalReplicaAccount,
                            synchronizable: false
                        )
                    }
                    return (try? normalizeSnapshot(reconciled)) ?? reconciled
                }
                return (try? normalizeSnapshot(reconciled)) ?? reconciled
            }

            _ = try? writeKeychainData(
                primaryData,
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )
            return primarySnapshot
        }

        if syncEnabled {
            if let markerData = try? readKeychainData(
                account: GlassOTPConstants.keychainSyncMarkerAccount,
                synchronizable: true
            ), (try? VaultSnapshotCoder.decodeValue(CloudSyncMarker.self, from: markerData)) != nil {
                // Another device deleted the shared iCloud copy; retire this device to local-only without re-uploading.
                let localExisting = (try? readKeychainData(
                    account: GlassOTPConstants.keychainAccount,
                    synchronizable: false
                )).flatMap { try? decodeSnapshot($0) }
                let replicaExisting = (try? readKeychainData(
                    account: GlassOTPConstants.keychainLocalReplicaAccount,
                    synchronizable: false
                )).flatMap { try? decodeSnapshot($0) }

                let combined: OTPVaultSnapshot?
                if let localExisting, let replicaExisting {
                    combined = localExisting.merged(with: replicaExisting, tombstoneLimit: Self.maxTombstones)
                } else {
                    combined = localExisting ?? replicaExisting
                }

                var normalized: OTPVaultSnapshot?
                if let combined, let data = try? encodeSnapshot(combined) {
                    _ = try? writeKeychainData(
                        data,
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: false
                    )
                    normalized = (try? decodeSnapshot(data)) ?? combined
                }
                try? deleteKeychainItem(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false)
                defaults.set(false, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
                defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                return normalized
            }

            if let localFallback = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false
            ) {
                return try decodeSnapshot(localFallback)
            }
            if let replicaFallback = try? readKeychainData(
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

    @discardableResult
    private func writeSnapshotUnlocked(_ snapshot: OTPVaultSnapshot) throws -> OTPVaultSnapshot {
        let data = try encodeSnapshot(snapshot)
        let normalized = try decodeSnapshot(data)
        let syncEnabled = isICloudSyncEnabledUnlocked()

        if syncEnabled {
            // Write the device-only replica first and propagate any failure before publishing to iCloud.
            _ = try writeKeychainData(
                data,
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )
            let storedInSharedGroup = try writeKeychainData(
                data,
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true
            )
            #if targetEnvironment(simulator)
            if !storedInSharedGroup {
                try writeSimulatorFallback(data)
            } else {
                try? FileManager.default.removeItem(at: simulatorFallbackURL())
            }
            #else
            _ = storedInSharedGroup
            #endif
        } else {
            let storedInSharedGroup = try writeKeychainData(
                data,
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false
            )
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

        return normalized
    }

    private func encodeSnapshot(_ snapshot: OTPVaultSnapshot) throws -> Data {
        try VaultSnapshotCoder.encode(snapshot)
    }

    private func decodeSnapshot(_ data: Data) throws -> OTPVaultSnapshot {
        do {
            return try VaultSnapshotCoder.decode(from: data)
        } catch {
            throw KeychainVaultError.decodingFailed
        }
    }

    private func normalizeSnapshot(_ snapshot: OTPVaultSnapshot) throws -> OTPVaultSnapshot {
        try decodeSnapshot(try encodeSnapshot(snapshot))
    }

    private func withVaultLock<T>(isMutating: Bool, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            let resolvedURL: URL?
            if let customLockFileURL {
                resolvedURL = customLockFileURL
            } else {
                resolvedURL = vaultLockFileURL(isMutating: isMutating)
            }

            guard let lockURL = resolvedURL else {
                #if os(iOS) && !targetEnvironment(simulator)
                if isMutating {
                    throw KeychainVaultError.lockUnavailable
                }
                #endif
                return try body()
            }

            try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else {
                #if os(iOS) && !targetEnvironment(simulator)
                if isMutating {
                    throw KeychainVaultError.lockUnavailable
                }
                #endif
                return try body()
            }

            var acquired = false
            let deadline = Date().addingTimeInterval(5.0)
            while true {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    acquired = true
                    break
                }
                let err = errno
                if err == EINTR {
                    continue
                }
                if err == EWOULDBLOCK || err == EAGAIN {
                    if Date() >= deadline {
                        break
                    }
                    usleep(10_000)
                    continue
                }
                break
            }

            defer {
                if acquired {
                    flock(fd, LOCK_UN)
                }
                close(fd)
            }

            if !acquired {
                #if os(iOS) && !targetEnvironment(simulator)
                if isMutating {
                    throw KeychainVaultError.lockUnavailable
                }
                #endif
            }

            return try body()
        }
    }

    private func vaultLockFileURL(isMutating: Bool) -> URL? {
        if let groupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GlassOTPConstants.appGroupID) {
            return groupDir.appendingPathComponent(".vault-lock")
        }
        #if os(iOS) && !targetEnvironment(simulator)
        if isMutating {
            return nil
        }
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("glassotp-vault.lock")
    }

    private func readKeychainData(account: String, synchronizable: Bool) throws -> Data? {
        if let group = backend.resolvedAccessGroup() {
            let scoped = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
            if scoped.status == errSecSuccess, let data = scoped.data {
                return data
            }
            #if targetEnvironment(simulator)
            if scoped.status != errSecItemNotFound && scoped.status != errSecMissingEntitlement {
                throw KeychainVaultError.unexpectedStatus(scoped.status)
            }
            #else
            if scoped.status == errSecItemNotFound {
                if account == GlassOTPConstants.keychainAccount,
                   !defaults.bool(forKey: GlassOTPConstants.legacyMigrationCheckedKey) {
                    return try migrateUnscopedLegacyItemIfNeeded(account: account, synchronizable: synchronizable, group: group)
                }
                return nil
            }
            throw KeychainVaultError.unexpectedStatus(scoped.status)
            #endif
        }

        let unscoped = backend.read(account: account, synchronizable: synchronizable, accessGroup: nil)
        if unscoped.status == errSecSuccess, let data = unscoped.data {
            return data
        }
        if unscoped.status == errSecItemNotFound {
            return nil
        }
        #if targetEnvironment(simulator)
        if unscoped.status == errSecMissingEntitlement {
            return nil
        }
        #endif
        throw KeychainVaultError.unexpectedStatus(unscoped.status)
    }

    private func migrateUnscopedLegacyItemIfNeeded(account: String, synchronizable: Bool, group: String) throws -> Data? {
        let legacy = backend.read(account: account, synchronizable: synchronizable, accessGroup: nil)
        if legacy.status == errSecSuccess, let legacyData = legacy.data {
            let accessibility: CFString = synchronizable
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let upsertStatus = backend.upsert(
                data: legacyData,
                account: account,
                synchronizable: synchronizable,
                accessGroup: group,
                accessibility: accessibility
            )
            guard upsertStatus == errSecSuccess else {
                throw KeychainVaultError.unexpectedStatus(upsertStatus)
            }
            let verified = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
            guard verified.status == errSecSuccess, verified.data == legacyData else {
                throw KeychainVaultError.unexpectedStatus(verified.status)
            }
            _ = backend.delete(account: account, synchronizable: synchronizable, accessGroup: nil)
            defaults.set(true, forKey: GlassOTPConstants.legacyMigrationCheckedKey)
            return legacyData
        }

        if legacy.status == errSecItemNotFound || legacy.status == errSecMissingEntitlement {
            let oppositeStatus = backend.read(account: account, synchronizable: !synchronizable, accessGroup: nil).status
            if oppositeStatus == errSecItemNotFound || oppositeStatus == errSecMissingEntitlement {
                defaults.set(true, forKey: GlassOTPConstants.legacyMigrationCheckedKey)
            }
            return nil
        }

        throw KeychainVaultError.unexpectedStatus(legacy.status)
    }

    @discardableResult
    private func writeKeychainData(_ data: Data, account: String, synchronizable: Bool) throws -> Bool {
        let accessibility: CFString = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        if let group = backend.resolvedAccessGroup() {
            let status = backend.upsert(
                data: data,
                account: account,
                synchronizable: synchronizable,
                accessGroup: group,
                accessibility: accessibility
            )
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

        let unscopedStatus = backend.upsert(
            data: data,
            account: account,
            synchronizable: synchronizable,
            accessGroup: nil,
            accessibility: accessibility
        )
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

    private func deleteKeychainItem(account: String, synchronizable: Bool) throws {
        if let group = backend.resolvedAccessGroup() {
            let status = backend.delete(account: account, synchronizable: synchronizable, accessGroup: group)
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

        let unscopedStatus = backend.delete(account: account, synchronizable: synchronizable, accessGroup: nil)
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
