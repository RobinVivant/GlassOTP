import CryptoKit
import Darwin
import Foundation
import Security

public enum GlassOTPConstants {
    public static let appGroupID = "group.com.robinvivant.glassotp"
    public static let keychainService = "com.robinvivant.glassotp.vault"
    public static let keychainAccount = "primary-vault-v1"
    public static let keychainLocalReplicaAccount = "local-replica-v1"
    public static let keychainLocalReplicaQuarantineAccount = "local-replica-quarantine-v1"
    public static let keychainLocalReplicaQuarantinePrefix = "local-replica-quarantine-v1."
    internal static let legacySyncMarkerAccount = "icloud-sync-marker-v1"
    public static let keychainAccessGroupSuffix = "com.robinvivant.glassotp.shared"
    public static let iCloudSyncPreferenceKey = "glassotp.icloud.sync.enabled"
    public static let universalClipboardPreferenceKey = "glassotp.universalClipboard.enabled"
    public static let appLockPreferenceKey = "glassotp.security.appLockEnabled"
    public static let pendingICloudDeletePreferenceKey = "glassotp.icloud.pendingDelete"
    public static let lastCloudRetirementGenerationKey = "glassotp.icloud.lastRetirementGeneration"
    public static let pendingCloudRetirementStepKey = "glassotp.icloud.pendingRetirementStep"
    public static let cloudCleanupSupersededByPeerKey = "glassotp.icloud.cleanupSupersededByPeer"
    public static let pendingPeerRetirementNoticeKey = "glassotp.icloud.pendingPeerRetirementNotice"
    public static let pendingMainAppLegacyRetirementRecoveryKey = "glassotp.keychain.pendingMainAppLegacyRetirementRecovery"
    public static let quarantinedReplicaAccountsKey = "glassotp.keychain.quarantinedReplicaAccounts"
    public static let legacyMigrationCheckedKey = "glassotp.keychain.legacyMigrationChecked"
    public static let pendingLegacyMigrationKeyPrefix = "glassotp.keychain.pendingLegacyDelete"
}

public enum CloudCleanupOutcome: Sendable, Equatable {
    case nothingPending
    case clearedCloudCopy
    case localCleanupOnlyPeerSuperseded
    case localCleanupOnlyCloudUnverified
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
            let merged = self.snapshot?.merged(with: local, tombstoneLimit: nil) ?? local
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
    case unreadableCloudVault
    case unreadableCloudVaultDuringCleanup
    case unreadableLocalReplica
    case cloudCleanupFailed(OSStatus)
    case lockUnavailable

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error (\(status))."
        case .decodingFailed:
            "Stored local vault data could not be decoded by this version of GlassOTP. Update GlassOTP on this device, or restore your encrypted backup on a clean installation or another device."
        case .unreadableCloudVault:
            "The iCloud Keychain vault could not be decoded by this version of GlassOTP. Update GlassOTP on this device, or turn off iCloud Keychain Sync using \"Use Local-Only & Keep iCloud Copy\" in Settings."
        case .unreadableCloudVaultDuringCleanup:
            "Local cleanup is waiting because the iCloud Keychain copy could not be decoded by this version of GlassOTP. Update GlassOTP on this device and retry."
        case .unreadableLocalReplica:
            "Your local sync replica could not be decoded. Update GlassOTP on this device, or if a readable vault is available, turn iCloud Keychain Sync off and back on in Settings to rebuild it."
        case .cloudCleanupFailed(let status):
            "Local vault was saved, but clearing the iCloud Keychain copy failed (\(status))."
        case .lockUnavailable:
            "Could not acquire the shared vault lock."
        }
    }
}

internal protocol KeychainBackend: Sendable {
    func resolvedAccessGroup() -> String?
    func read(account: String, synchronizable: Bool, accessGroup: String?) -> (status: OSStatus, data: Data?, actualAccessGroup: String?)
    func readAll(account: String, synchronizable: Bool) -> (status: OSStatus, items: [(data: Data, actualAccessGroup: String?)])
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

    func read(account: String, synchronizable: Bool, accessGroup: String?) -> (status: OSStatus, data: Data?, actualAccessGroup: String?) {
        var query = baseQuery(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return (status, nil, nil)
        }
        if let dict = item as? [String: Any] {
            let data = dict[kSecValueData as String] as? Data
            let group = dict[kSecAttrAccessGroup as String] as? String
            return (status, data, group)
        }
        if let data = item as? Data {
            return (status, data, accessGroup)
        }
        return (errSecDecode, nil, nil)
    }

    func readAll(account: String, synchronizable: Bool) -> (status: OSStatus, items: [(data: Data, actualAccessGroup: String?)]) {
        var query = baseQuery(account: account, synchronizable: synchronizable, accessGroup: nil)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return (status, [])
        }
        var results: [(data: Data, actualAccessGroup: String?)] = []
        if let dicts = item as? [[String: Any]] {
            for dict in dicts {
                if let data = dict[kSecValueData as String] as? Data {
                    results.append((data, dict[kSecAttrAccessGroup as String] as? String))
                }
            }
        } else if let dict = item as? [String: Any],
                  let data = dict[kSecValueData as String] as? Data {
            results.append((data, dict[kSecAttrAccessGroup as String] as? String))
        } else {
            return (errSecDecode, [])
        }
        return (errSecSuccess, results)
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

public final class KeychainVaultStore: VaultPersistence, @unchecked Sendable {
    public static let shared = KeychainVaultStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let processDefaults: UserDefaults
    private let isAppExtension: Bool
    private let backend: any KeychainBackend
    private let customLockFileURL: URL?
    private let lockTimeout: TimeInterval

    public init(defaults: UserDefaults? = UserDefaults(suiteName: GlassOTPConstants.appGroupID)) {
        let resolvedDefaults = defaults ?? .standard
        self.defaults = resolvedDefaults
        self.processDefaults = .standard
        self.isAppExtension = Bundle.main.bundlePath.hasSuffix(".appex")
        self.backend = SystemKeychainBackend()
        self.customLockFileURL = nil
        self.lockTimeout = 5.0
        if resolvedDefaults.object(forKey: GlassOTPConstants.iCloudSyncPreferenceKey) == nil {
            resolvedDefaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        }
    }

    internal init(
        defaults: UserDefaults,
        processDefaults: UserDefaults = .standard,
        backend: any KeychainBackend,
        isAppExtension: Bool = false,
        lockFileURL: URL? = nil,
        lockTimeout: TimeInterval = 5.0
    ) {
        self.defaults = defaults
        self.processDefaults = processDefaults
        self.isAppExtension = isAppExtension
        self.backend = backend
        self.customLockFileURL = lockFileURL
        self.lockTimeout = lockTimeout
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

    private func isICloudSyncEnabledReadOnly() -> Bool {
        guard defaults.object(forKey: GlassOTPConstants.iCloudSyncPreferenceKey) != nil else {
            return true
        }
        return defaults.bool(forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
    }

    public func isICloudSyncEnabled() -> Bool {
        isICloudSyncEnabledReadOnly()
    }

    @discardableResult
    public func consumePendingPeerRetirementNotice(nonBlocking: Bool = false) -> Bool {
        if nonBlocking {
            guard lock.try() else { return false }
            defer { lock.unlock() }
            guard defaults.bool(forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey) else {
                return false
            }
            defaults.removeObject(forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey)
            return true
        }
        return lock.withLock {
            guard defaults.bool(forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey) else {
                return false
            }
            defaults.removeObject(forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey)
            return true
        }
    }

    private struct LegacyCloudSyncMarker: Decodable {
        let disabledAt: Date
    }

    public func setICloudSyncEnabled(_ enabled: Bool) throws {
        try setICloudSyncEnabled(enabled, removeOppositeBucket: true)
    }

    private func discoverLegacyItemsReadOnly(
        account: String,
        synchronizable: Bool,
        sharedGroup: String
    ) throws -> [(group: String, data: Data)] {
        let result = backend.readAll(account: account, synchronizable: synchronizable)
        switch result.status {
        case errSecItemNotFound, errSecMissingEntitlement:
            return []
        case errSecSuccess:
            var seen: Set<String> = []
            var legacy: [(group: String, data: Data)] = []
            for item in result.items {
                guard let actual = item.actualAccessGroup,
                      !actual.isEmpty,
                      actual != sharedGroup,
                      seen.insert(actual).inserted else {
                    continue
                }
                legacy.append((group: actual, data: item.data))
            }
            return legacy
        default:
            throw KeychainVaultError.unexpectedStatus(result.status)
        }
    }

    private func readLegacySyncDiscoveryReadOnly() throws -> [(group: String, data: Data)] {
        guard !isAppExtension, let group = backend.resolvedAccessGroup() else {
            return []
        }
        var results: [(group: String, data: Data)] = []
        var seenGroups: Set<String> = []
        let pendingKey = pendingLegacyMigrationKey(group: group, synchronizable: true)
        if let pendingLegacyGroup = processDefaults.string(forKey: pendingKey),
           !pendingLegacyGroup.isEmpty,
           pendingLegacyGroup != group {
            let legacyRead = backend.read(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true,
                accessGroup: pendingLegacyGroup
            )
            switch legacyRead.status {
            case errSecSuccess:
                if let data = legacyRead.data {
                    seenGroups.insert(pendingLegacyGroup)
                    results.append((group: pendingLegacyGroup, data: data))
                }
            case errSecItemNotFound:
                break
            default:
                throw KeychainVaultError.unexpectedStatus(legacyRead.status)
            }
        }
        let syncCheckedKey = "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).sync"
        if !processDefaults.bool(forKey: syncCheckedKey) {
            let discovered = try discoverLegacyItemsReadOnly(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true,
                sharedGroup: group
            )
            for item in discovered where seenGroups.insert(item.group).inserted {
                results.append(item)
            }
        }
        return results
    }

    private func quarantineUnreadableReplicaUnlocked(_ rawReplica: Data) throws {
        let digest = SHA256.hash(data: rawReplica).prefix(8).map { String(format: "%02x", $0) }.joined()
        let quarantineAccount = GlassOTPConstants.keychainLocalReplicaQuarantinePrefix + digest
        let existing = readKeychainDataWithStatus(account: quarantineAccount, synchronizable: false)
        if existing.status != errSecSuccess || existing.data != rawReplica {
            _ = try writeAndVerifyKeychainData(
                rawReplica,
                account: quarantineAccount,
                synchronizable: false
            )
        }
        var recorded = defaults.stringArray(forKey: GlassOTPConstants.quarantinedReplicaAccountsKey) ?? []
        if !recorded.contains(quarantineAccount) {
            recorded.append(quarantineAccount)
            defaults.set(recorded, forKey: GlassOTPConstants.quarantinedReplicaAccountsKey)
        }
    }

    @discardableResult
    public func setICloudSyncEnabled(_ enabled: Bool, removeOppositeBucket: Bool = true) throws -> OTPVaultSnapshot? {
        try withVaultLock(isMutating: true) { _ in
            let syncData = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true,
                canMutate: enabled
            )
            let legacySyncEntries = enabled ? [] : try readLegacySyncDiscoveryReadOnly()
            let localData = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false,
                canMutate: true
            )
            let replicaData = try readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false,
                canMutate: false
            )

            let syncSnapshot: OTPVaultSnapshot?
            if enabled {
                if let syncData {
                    do {
                        syncSnapshot = try decodeSnapshot(syncData)
                    } catch {
                        throw KeychainVaultError.unreadableCloudVault
                    }
                } else {
                    syncSnapshot = nil
                }
            } else {
                syncSnapshot = syncData.flatMap { try? decodeSnapshot($0) }
            }
            let legacySyncSnapshots = legacySyncEntries.compactMap { try? decodeSnapshot($0.data) }
            let localSnapshot = try localData.map(decodeSnapshot)
            let replicaSnapshot = replicaData.flatMap { try? decodeSnapshot($0) }
            let syncCorrupt = (syncData != nil && syncSnapshot == nil)
            let legacySyncCorrupt = legacySyncEntries.contains { (try? decodeSnapshot($0.data)) == nil }
            let replicaCorrupt = (replicaData != nil && replicaSnapshot == nil)

            var combined: OTPVaultSnapshot?
            let rawCandidates: [OTPVaultSnapshot?] = [syncSnapshot] + legacySyncSnapshots.map { Optional($0) } + [replicaSnapshot, localSnapshot]
            for case let candidate? in rawCandidates where candidate.cloudRetiredAtMillis == nil {
                combined = combined?.merged(with: candidate, tombstoneLimit: nil) ?? candidate
            }

            let savedRetireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            let maxObservedGen = ([
                savedRetireGen,
                syncSnapshot?.cloudSyncGenerationMillis,
                syncSnapshot?.cloudRetiredAtMillis,
                localSnapshot?.cloudSyncGenerationMillis,
                localSnapshot?.cloudRetiredAtMillis,
                replicaSnapshot?.cloudSyncGenerationMillis,
                replicaSnapshot?.cloudRetiredAtMillis,
            ] + legacySyncSnapshots.map(\.cloudSyncGenerationMillis) + legacySyncSnapshots.map(\.cloudRetiredAtMillis))
                .compactMap { $0 }.max() ?? 0

            if enabled {
                if replicaCorrupt {
                    guard combined != nil else {
                        throw KeychainVaultError.unreadableLocalReplica
                    }
                    if let rawReplica = replicaData {
                        try quarantineUnreadableReplicaUnlocked(rawReplica)
                    }
                }

                let newGeneration = max(Date().roundedEpochMillis, maxObservedGen + 1)
                var snapshotToPublish = combined ?? OTPVaultSnapshot()
                snapshotToPublish.cloudRetiredAtMillis = nil
                snapshotToPublish.cloudSyncGenerationMillis = newGeneration

                var normalized: OTPVaultSnapshot?
                if combined != nil || syncSnapshot?.cloudRetiredAtMillis != nil {
                    normalized = try writeSnapshotUnlocked(snapshotToPublish, syncEnabled: true)
                }

                defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
                defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                defaults.removeObject(forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                defaults.removeObject(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
                defaults.removeObject(forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey)
                defaults.removeObject(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey)
                try? deleteKeychainItem(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true)
                if removeOppositeBucket {
                    try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: false)
                }
                return normalized
            } else {
                if removeOppositeBucket {
                    if syncCorrupt || legacySyncCorrupt {
                        throw KeychainVaultError.unreadableCloudVault
                    }
                    if combined == nil && replicaCorrupt {
                        throw KeychainVaultError.unreadableLocalReplica
                    }
                }

                var normalizedLocal: OTPVaultSnapshot?
                if var localCopy = combined {
                    localCopy.cloudRetiredAtMillis = nil
                    let data = try encodeSnapshot(localCopy)
                    normalizedLocal = try decodeSnapshot(data)
                    let storedLocal = try writeAndVerifyKeychainData(
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

                if removeOppositeBucket {
                    if !isAppExtension, let group = backend.resolvedAccessGroup() {
                        let pendingKey = pendingLegacyMigrationKey(group: group, synchronizable: true)
                        if (processDefaults.string(forKey: pendingKey) ?? "").isEmpty,
                           let firstLegacy = legacySyncEntries.first {
                            processDefaults.set(firstLegacy.group, forKey: pendingKey)
                        }
                    }
                    let retirementGen = max(Date().roundedEpochMillis, maxObservedGen + 1)
                    // Persist retirement state BEFORE mutating sync preference or performing fallible cleanup
                    defaults.set(retirementGen, forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                    defaults.set("cloud", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                    defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                    defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
                    defaults.removeObject(forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey)
                    defaults.removeObject(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey)
                    defaults.set(false, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
                    do {
                        _ = try performCloudRetirementCleanupUnlocked(retirementGeneration: retirementGen)
                    } catch let error as KeychainVaultError {
                        defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                        if case .unexpectedStatus(let status) = error {
                            throw KeychainVaultError.cloudCleanupFailed(status)
                        }
                        throw error
                    }
                } else {
                    defaults.set(false, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
                    defaults.removeObject(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                    defaults.removeObject(forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                    defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
                    defaults.removeObject(forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey)
                    defaults.removeObject(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey)
                    if !replicaCorrupt {
                        try? deleteKeychainItem(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false)
                    }
                    defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                }

                return normalizedLocal
            }
        }
    }

    @discardableResult
    public func retryPendingICloudCleanup() throws -> CloudCleanupOutcome {
        try withVaultLock(isMutating: true) { _ in
            guard !isICloudSyncEnabledUnlocked() else {
                defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                defaults.removeObject(forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                defaults.removeObject(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
                return .nothingPending
            }
            guard defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) else {
                return .nothingPending
            }
            let savedGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            let effectiveGen = savedGen > 0 ? savedGen : Date().roundedEpochMillis
            do {
                return try performCloudRetirementCleanupUnlocked(retirementGeneration: effectiveGen)
            } catch let error as KeychainVaultError {
                defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                switch error {
                case .unexpectedStatus(let status):
                    throw KeychainVaultError.cloudCleanupFailed(status)
                case .unreadableCloudVault:
                    throw KeychainVaultError.unreadableCloudVaultDuringCleanup
                default:
                    throw error
                }
            }
        }
    }

    @discardableResult
    private func mergeAndDeletePendingLegacySyncToLocalUnlocked(
        legacyGroup: String,
        group: String,
        pendingKey: String
    ) throws -> OTPVaultSnapshot? {
        let legacyRead = backend.read(
            account: GlassOTPConstants.keychainAccount,
            synchronizable: true,
            accessGroup: legacyGroup
        )
        var recoveredSnapshot: OTPVaultSnapshot?
        var expectedLocalData: Data?
        switch legacyRead.status {
        case errSecItemNotFound:
            break
        case errSecSuccess:
            guard let legacyData = legacyRead.data else {
                throw KeychainVaultError.unreadableCloudVault
            }
            let legacySnap: OTPVaultSnapshot
            do {
                legacySnap = try decodeSnapshot(legacyData)
            } catch {
                throw KeychainVaultError.unreadableCloudVault
            }
            if legacySnap.cloudRetiredAtMillis == nil {
                let existingLocal = try readKeychainData(
                    account: GlassOTPConstants.keychainAccount,
                    synchronizable: false,
                    canMutate: true
                ).map(decodeSnapshot)
                let existingReplica = try readKeychainData(
                    account: GlassOTPConstants.keychainLocalReplicaAccount,
                    synchronizable: false,
                    canMutate: false
                ).flatMap { try? decodeSnapshot($0) }
                var mergedLocal: OTPVaultSnapshot?
                for case let candidate? in [legacySnap, existingLocal, existingReplica] where candidate.cloudRetiredAtMillis == nil {
                    mergedLocal = mergedLocal?.merged(with: candidate, tombstoneLimit: nil) ?? candidate
                }
                if var localToSave = mergedLocal {
                    localToSave.cloudRetiredAtMillis = nil
                    let mergedData = try encodeSnapshot(localToSave)
                    let stored = try writeAndVerifyKeychainData(
                        mergedData,
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: false
                    )
                    #if targetEnvironment(simulator)
                    if !stored {
                        try writeSimulatorFallback(mergedData)
                    } else {
                        try? FileManager.default.removeItem(at: simulatorFallbackURL())
                    }
                    #else
                    _ = stored
                    #endif
                    expectedLocalData = mergedData
                    recoveredSnapshot = try decodeSnapshot(mergedData)
                }
            }
        default:
            throw KeychainVaultError.unexpectedStatus(legacyRead.status)
        }

        let deleteStatus = backend.delete(
            account: GlassOTPConstants.keychainAccount,
            synchronizable: true,
            accessGroup: legacyGroup
        )
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainVaultError.unexpectedStatus(deleteStatus)
        }
        if let expectedLocalData {
            let localVerify = backend.read(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false,
                accessGroup: group
            )
            #if !targetEnvironment(simulator)
            guard localVerify.status == errSecSuccess, localVerify.data == expectedLocalData else {
                throw KeychainVaultError.unexpectedStatus(localVerify.status == errSecSuccess ? errSecIO : localVerify.status)
            }
            #else
            _ = localVerify
            _ = expectedLocalData
            #endif
        }
        processDefaults.removeObject(forKey: pendingKey)
        processDefaults.set(true, forKey: "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).sync")
        return recoveredSnapshot
    }

    @discardableResult
    private func performCloudRetirementCleanupUnlocked(retirementGeneration: Int64) throws -> CloudCleanupOutcome {
        let initialStep = defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) ?? "cloud"
        if initialStep != "replica" {
            if !defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey) {
                let existingCloudRead = readKeychainDataWithStatus(
                    account: GlassOTPConstants.keychainAccount,
                    synchronizable: true
                )
                guard existingCloudRead.status == errSecSuccess || existingCloudRead.status == errSecItemNotFound else {
                    throw KeychainVaultError.unexpectedStatus(existingCloudRead.status)
                }

                var effectiveGen = retirementGeneration
                var cloudAlreadySuperseded = false
                if existingCloudRead.status == errSecSuccess {
                    guard let existingCloudData = existingCloudRead.data,
                          let existingCloud = try? decodeSnapshot(existingCloudData) else {
                        throw KeychainVaultError.unreadableCloudVault
                    }
                    if existingCloud.cloudRetiredAtMillis == nil,
                       let cloudGen = existingCloud.cloudSyncGenerationMillis,
                       cloudGen > retirementGeneration {
                        cloudAlreadySuperseded = true
                        defaults.set(true, forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
                        defaults.removeObject(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                    } else {
                        let existingMax = [existingCloud.cloudSyncGenerationMillis, existingCloud.cloudRetiredAtMillis].compactMap { $0 }.max() ?? 0
                        if existingMax >= effectiveGen {
                            effectiveGen = existingMax + 1
                            defaults.set(effectiveGen, forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                        }
                    }
                }

                if !cloudAlreadySuperseded {
                    let retiredRecord = OTPVaultSnapshot(
                        schemaVersion: 1,
                        folders: [],
                        accounts: [],
                        updatedAt: Date(timeIntervalSince1970: Double(effectiveGen) / 1000.0),
                        accountTombstones: [],
                        folderTombstones: [],
                        cloudRetiredAtMillis: effectiveGen,
                        cloudSyncGenerationMillis: nil
                    )
                    let retiredData = try encodeSnapshot(retiredRecord)
                    _ = try writeKeychainData(
                        retiredData,
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: true
                    )
                    try? deleteKeychainItem(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true)
                }
            }

            defaults.set("replica", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
        }

        if let group = backend.resolvedAccessGroup(), !isAppExtension {
            let pendingKey = pendingLegacyMigrationKey(group: group, synchronizable: true)
            let syncCheckedKey = "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).sync"
            var handledGroups: Set<String> = []
            if let pendingLegacyGroup = processDefaults.string(forKey: pendingKey),
               !pendingLegacyGroup.isEmpty,
               pendingLegacyGroup != group {
                handledGroups.insert(pendingLegacyGroup)
                _ = try mergeAndDeletePendingLegacySyncToLocalUnlocked(
                    legacyGroup: pendingLegacyGroup,
                    group: group,
                    pendingKey: pendingKey
                )
            }
            if !processDefaults.bool(forKey: syncCheckedKey) {
                let remaining = try discoverLegacyItemsReadOnly(
                    account: GlassOTPConstants.keychainAccount,
                    synchronizable: true,
                    sharedGroup: group
                )
                for item in remaining where handledGroups.insert(item.group).inserted {
                    processDefaults.set(item.group, forKey: pendingKey)
                    _ = try mergeAndDeletePendingLegacySyncToLocalUnlocked(
                        legacyGroup: item.group,
                        group: group,
                        pendingKey: pendingKey
                    )
                }
                processDefaults.set(true, forKey: syncCheckedKey)
            }
            if defaults.bool(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey) {
                _ = try recoverPendingLegacySyncOnLocalLoadUnlocked()
            }
        }

        let replicaStatus = readKeychainDataWithStatus(
            account: GlassOTPConstants.keychainLocalReplicaAccount,
            synchronizable: false
        )
        switch replicaStatus.status {
        case errSecItemNotFound:
            break
        case errSecSuccess:
            let replicaDecodedOK = replicaStatus.data.map { (try? decodeSnapshot($0)) != nil } == true
            if replicaDecodedOK {
                try deleteKeychainItem(
                    account: GlassOTPConstants.keychainLocalReplicaAccount,
                    synchronizable: false
                )
            }
        default:
            throw KeychainVaultError.unexpectedStatus(replicaStatus.status)
        }

        let outcome: CloudCleanupOutcome
        if defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey) {
            outcome = .localCleanupOnlyPeerSuperseded
        } else if initialStep == "replica" {
            let savedGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            let cloudRead = readKeychainDataWithStatus(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true
            )
            switch cloudRead.status {
            case errSecItemNotFound:
                outcome = .clearedCloudCopy
            case errSecSuccess:
                if let data = cloudRead.data,
                   let snap = try? decodeSnapshot(data) {
                    if snap.cloudRetiredAtMillis != nil {
                        outcome = .clearedCloudCopy
                    } else if savedGen > 0, (snap.cloudSyncGenerationMillis ?? 0) <= savedGen {
                        let retiredRecord = OTPVaultSnapshot(
                            schemaVersion: 1,
                            folders: [],
                            accounts: [],
                            updatedAt: Date(timeIntervalSince1970: Double(savedGen) / 1000.0),
                            accountTombstones: [],
                            folderTombstones: [],
                            cloudRetiredAtMillis: savedGen,
                            cloudSyncGenerationMillis: nil
                        )
                        let retiredData = try encodeSnapshot(retiredRecord)
                        _ = try writeKeychainData(
                            retiredData,
                            account: GlassOTPConstants.keychainAccount,
                            synchronizable: true
                        )
                        try? deleteKeychainItem(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true)
                        outcome = .clearedCloudCopy
                    } else {
                        outcome = .localCleanupOnlyPeerSuperseded
                    }
                } else {
                    outcome = .localCleanupOnlyCloudUnverified
                }
            default:
                outcome = .localCleanupOnlyCloudUnverified
            }
        } else {
            outcome = .clearedCloudCopy
        }

        defaults.removeObject(forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
        defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
        defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
        return outcome
    }

    public func loadSnapshot() throws -> OTPVaultSnapshot? {
        try withVaultLock(isMutating: false) { hasLock in
            try loadSnapshotUnlocked(canMutate: hasLock, forMutation: false)
        }
    }

    public func saveSnapshot(_ snapshot: OTPVaultSnapshot) throws {
        try withVaultLock(isMutating: true) { _ in
            var normalizedInput = snapshot
            normalizedInput.cloudRetiredAtMillis = nil
            _ = try writeSnapshotUnlocked(normalizedInput, syncEnabled: isICloudSyncEnabledUnlocked())
        }
    }

    @discardableResult
    public func saveMergedSnapshot(_ local: OTPVaultSnapshot) throws -> OTPVaultSnapshot {
        try withVaultLock(isMutating: true) { _ in
            let existing = try loadSnapshotUnlocked(canMutate: true, forMutation: true)
            var cleanLocal = local
            cleanLocal.cloudRetiredAtMillis = nil
            if let existingGen = existing?.cloudSyncGenerationMillis,
               (cleanLocal.cloudSyncGenerationMillis ?? 0) < existingGen {
                cleanLocal.cloudSyncGenerationMillis = existingGen
            }
            let merged = existing?.merged(with: cleanLocal, tombstoneLimit: nil) ?? cleanLocal
            return try writeSnapshotUnlocked(merged, syncEnabled: isICloudSyncEnabledUnlocked())
        }
    }

    @discardableResult
    public func mutateSnapshot(_ transform: (inout OTPVaultSnapshot) -> Void) throws -> OTPVaultSnapshot {
        try withVaultLock(isMutating: true) { _ in
            var current = try loadSnapshotUnlocked(canMutate: true, forMutation: true) ?? OTPVaultSnapshot()
            transform(&current)
            current.updatedAt = Date()
            current.cloudRetiredAtMillis = nil
            return try writeSnapshotUnlocked(current, syncEnabled: isICloudSyncEnabledUnlocked())
        }
    }

    @discardableResult
    public func mutateSnapshotIfPresent(_ transform: (inout OTPVaultSnapshot) -> Bool) throws -> OTPVaultSnapshot? {
        try withVaultLock(isMutating: true) { _ in
            guard var current = try loadSnapshotUnlocked(canMutate: true, forMutation: true) else {
                return nil
            }
            guard transform(&current) else {
                return current
            }
            current.updatedAt = Date()
            current.cloudRetiredAtMillis = nil
            return try writeSnapshotUnlocked(current, syncEnabled: isICloudSyncEnabledUnlocked())
        }
    }

    public func resolveAccountForCopy(accountID: UUID) throws -> (snapshot: OTPVaultSnapshot?, account: OTPAccount?, didMutate: Bool) {
        var hadLock = false
        var displaySnapshot = try withVaultLock(isMutating: false, nonBlocking: true) { hasLock in
            hadLock = hasLock
            return try loadSnapshotUnlocked(canMutate: hasLock, forMutation: false)
        }
        if displaySnapshot == nil && !hadLock {
            displaySnapshot = try loadSnapshot()
        }
        guard let snapshot = displaySnapshot,
              let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
            return (displaySnapshot, nil, false)
        }
        guard account.isSupportedAlgorithm, account.type == .hotp else {
            return (snapshot, account, false)
        }

        var reservedAccount: OTPAccount?
        let updatedSnapshot = try mutateSnapshotIfPresent { mutableSnapshot in
            guard let idx = mutableSnapshot.accounts.firstIndex(where: { $0.id == accountID }) else {
                return false
            }
            let current = mutableSnapshot.accounts[idx]
            reservedAccount = current
            guard current.isSupportedAlgorithm, current.type == .hotp else {
                return false
            }
            mutableSnapshot.accounts[idx].counter &+= 1
            mutableSnapshot.accounts[idx].updatedAt = Date.monotonicTimestamp(after: current.updatedAt)
            return true
        }
        guard let mutated = updatedSnapshot else {
            return (nil, nil, false)
        }
        guard let resolved = reservedAccount else {
            return (mutated, nil, false)
        }
        return (mutated, resolved, resolved.isSupportedAlgorithm && resolved.type == .hotp)
    }

    private func loadSnapshotUnlocked(canMutate: Bool, forMutation: Bool) throws -> OTPVaultSnapshot? {
        let syncEnabled = canMutate ? isICloudSyncEnabledUnlocked() : isICloudSyncEnabledReadOnly()
        if let primaryData = try readKeychainData(
            account: GlassOTPConstants.keychainAccount,
            synchronizable: syncEnabled,
            canMutate: canMutate
        ) {
            let primarySnapshot: OTPVaultSnapshot
            do {
                primarySnapshot = try decodeSnapshot(primaryData)
            } catch {
                throw syncEnabled ? KeychainVaultError.unreadableCloudVault : KeychainVaultError.decodingFailed
            }
            guard syncEnabled else {
                if canMutate {
                    if let recovered = try recoverPendingLegacySyncOnLocalLoadUnlocked() {
                        reconcileRetiredCloudStateOnLocalLoadUnlocked()
                        return recovered
                    }
                    reconcileRetiredCloudStateOnLocalLoadUnlocked()
                }
                return primarySnapshot
            }

            if let retiredAt = primarySnapshot.cloudRetiredAtMillis {
                return try handleRetiredCloudRecordUnlocked(
                    retiredAtMillis: retiredAt,
                    canMutate: canMutate
                ).snapshot
            }

            let replicaRead = readKeychainDataWithStatus(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )

            switch replicaRead.status {
            case errSecItemNotFound:
                if canMutate {
                    _ = try? writeKeychainData(
                        primaryData,
                        account: GlassOTPConstants.keychainLocalReplicaAccount,
                        synchronizable: false
                    )
                }
                return primarySnapshot

            case errSecSuccess:
                guard let replicaData = replicaRead.data,
                      let replicaSnapshot = try? decodeSnapshot(replicaData) else {
                    if forMutation {
                        throw KeychainVaultError.unreadableLocalReplica
                    }
                    // Preserve an unreadable replica without overwriting it on read-only display
                    return primarySnapshot
                }
                if primarySnapshot == replicaSnapshot {
                    return primarySnapshot
                }

                let reconciled = primarySnapshot.merged(with: replicaSnapshot, tombstoneLimit: nil)
                let cloudNeedsSync = reconciled.accounts != primarySnapshot.accounts
                    || reconciled.folders != primarySnapshot.folders
                    || reconciled.accountTombstones != primarySnapshot.accountTombstones
                    || reconciled.folderTombstones != primarySnapshot.folderTombstones
                    || reconciled.cloudSyncGenerationMillis != primarySnapshot.cloudSyncGenerationMillis

                if canMutate {
                    if cloudNeedsSync {
                        if let written = try? writeSnapshotUnlocked(reconciled, syncEnabled: true) {
                            return written
                        }
                    } else if reconciled != replicaSnapshot,
                              let replicaEncoded = try? encodeSnapshot(reconciled) {
                        _ = try? writeKeychainData(
                            replicaEncoded,
                            account: GlassOTPConstants.keychainLocalReplicaAccount,
                            synchronizable: false
                        )
                    }
                }
                return (try? normalizeSnapshot(reconciled)) ?? reconciled

            default:
                if forMutation {
                    throw KeychainVaultError.unexpectedStatus(replicaRead.status)
                }
                // Transient replica read failure: display readable cloud vault without overwriting replica
                return primarySnapshot
            }
        }

        if syncEnabled {
            let legacyMarkerRead = readKeychainDataWithStatus(
                account: GlassOTPConstants.legacySyncMarkerAccount,
                synchronizable: true
            )
            switch legacyMarkerRead.status {
            case errSecSuccess:
                let decodedMarker = legacyMarkerRead.data.flatMap {
                    try? VaultSnapshotCoder.decodeValue(LegacyCloudSyncMarker.self, from: $0)
                }
                let markerMillis = decodedMarker?.disabledAt.roundedEpochMillis ?? Date().roundedEpochMillis
                let outcome = try handleRetiredCloudRecordUnlocked(
                    retiredAtMillis: markerMillis,
                    canMutate: canMutate
                )
                if canMutate {
                    if outcome.retired {
                        let retiredRecord = OTPVaultSnapshot(
                            schemaVersion: 1,
                            folders: [],
                            accounts: [],
                            updatedAt: Date(timeIntervalSince1970: Double(markerMillis) / 1000.0),
                            accountTombstones: [],
                            folderTombstones: [],
                            cloudRetiredAtMillis: markerMillis,
                            cloudSyncGenerationMillis: nil
                        )
                        do {
                            let retiredData = try encodeSnapshot(retiredRecord)
                            _ = try writeAndVerifyKeychainData(
                                retiredData,
                                account: GlassOTPConstants.keychainAccount,
                                synchronizable: true
                            )
                            try? deleteKeychainItem(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true)
                        } catch {
                            defaults.set(markerMillis, forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                            defaults.set("cloud", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                            defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                        }
                    } else {
                        let cloudCheck = readKeychainDataWithStatus(
                            account: GlassOTPConstants.keychainAccount,
                            synchronizable: true
                        )
                        if cloudCheck.status == errSecSuccess, cloudCheck.data != nil {
                            try? deleteKeychainItem(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true)
                        }
                    }
                }
                return outcome.snapshot

            case errSecItemNotFound:
                break

            default:
                if forMutation {
                    throw KeychainVaultError.unexpectedStatus(legacyMarkerRead.status)
                }
            }

            if let localFallback = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false,
                canMutate: canMutate
            ) {
                return try decodeSnapshot(localFallback)
            }
            if let replicaFallback = try readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false,
                canMutate: false
            ) {
                do {
                    return try decodeSnapshot(replicaFallback)
                } catch {
                    throw KeychainVaultError.unreadableLocalReplica
                }
            }
        } else if canMutate {
            if let recovered = try recoverPendingLegacySyncOnLocalLoadUnlocked() {
                reconcileRetiredCloudStateOnLocalLoadUnlocked()
                return recovered
            }
            reconcileRetiredCloudStateOnLocalLoadUnlocked()
        }

        #if targetEnvironment(simulator)
        if let simData = try? Data(contentsOf: simulatorFallbackURL()), !simData.isEmpty {
            return try decodeSnapshot(simData)
        }
        #endif

        return nil
    }

    private func recoverPendingLegacySyncOnLocalLoadUnlocked() throws -> OTPVaultSnapshot? {
        guard !isAppExtension, let group = backend.resolvedAccessGroup() else {
            return nil
        }
        guard defaults.bool(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey) else {
            return nil
        }

        var latestRecoveredSnapshot: OTPVaultSnapshot?

        // Step A: Recover any pending/unmigrated legacy device-only vault (even if widget already wrote shared local)
        let localPendingKey = pendingLegacyMigrationKey(group: group, synchronizable: false)
        let localCheckedKey = "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).local"
        var localGroups: [String] = []
        var seenLocalGroups: Set<String> = []
        if let savedLocalLegacy = processDefaults.string(forKey: localPendingKey),
           !savedLocalLegacy.isEmpty,
           savedLocalLegacy != group,
           seenLocalGroups.insert(savedLocalLegacy).inserted {
            localGroups.append(savedLocalLegacy)
        }
        if !processDefaults.bool(forKey: localCheckedKey) {
            let discoveredLocal = try discoverLegacyItemsReadOnly(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false,
                sharedGroup: group
            )
            for item in discoveredLocal where seenLocalGroups.insert(item.group).inserted {
                localGroups.append(item.group)
            }
        }

        for legacyLocalGroup in localGroups {
            processDefaults.set(legacyLocalGroup, forKey: localPendingKey)
            let legacyRead = backend.read(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false,
                accessGroup: legacyLocalGroup
            )
            var expectedLocalData: Data?
            switch legacyRead.status {
            case errSecItemNotFound:
                break
            case errSecSuccess:
                guard let legacyData = legacyRead.data else {
                    throw KeychainVaultError.decodingFailed
                }
                let legacySnap = try decodeSnapshot(legacyData)
                if legacySnap.cloudRetiredAtMillis == nil {
                    let sharedRead = backend.read(
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: false,
                        accessGroup: group
                    )
                    let sharedExisting: OTPVaultSnapshot?
                    switch sharedRead.status {
                    case errSecSuccess:
                        sharedExisting = try sharedRead.data.map(decodeSnapshot)
                    case errSecItemNotFound:
                        sharedExisting = nil
                    default:
                        throw KeychainVaultError.unexpectedStatus(sharedRead.status)
                    }
                    let existingReplica = try readKeychainData(
                        account: GlassOTPConstants.keychainLocalReplicaAccount,
                        synchronizable: false,
                        canMutate: false
                    ).flatMap { try? decodeSnapshot($0) }
                    var mergedLocal: OTPVaultSnapshot?
                    for case let candidate? in [legacySnap, sharedExisting, existingReplica] where candidate.cloudRetiredAtMillis == nil {
                        mergedLocal = mergedLocal?.merged(with: candidate, tombstoneLimit: nil) ?? candidate
                    }
                    if var localToSave = mergedLocal {
                        localToSave.cloudRetiredAtMillis = nil
                        let mergedData = try encodeSnapshot(localToSave)
                        let stored = try writeAndVerifyKeychainData(
                            mergedData,
                            account: GlassOTPConstants.keychainAccount,
                            synchronizable: false
                        )
                        #if targetEnvironment(simulator)
                        if !stored {
                            try writeSimulatorFallback(mergedData)
                        } else {
                            try? FileManager.default.removeItem(at: simulatorFallbackURL())
                        }
                        #else
                        _ = stored
                        #endif
                        expectedLocalData = mergedData
                        latestRecoveredSnapshot = try decodeSnapshot(mergedData)
                    }
                }
            default:
                throw KeychainVaultError.unexpectedStatus(legacyRead.status)
            }

            let deleteStatus = backend.delete(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false,
                accessGroup: legacyLocalGroup
            )
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw KeychainVaultError.unexpectedStatus(deleteStatus)
            }
            if let expectedLocalData {
                let verify = backend.read(
                    account: GlassOTPConstants.keychainAccount,
                    synchronizable: false,
                    accessGroup: group
                )
                #if !targetEnvironment(simulator)
                guard verify.status == errSecSuccess, verify.data == expectedLocalData else {
                    throw KeychainVaultError.unexpectedStatus(verify.status == errSecSuccess ? errSecIO : verify.status)
                }
                #else
                _ = verify
                _ = expectedLocalData
                #endif
            }
            processDefaults.removeObject(forKey: localPendingKey)
        }
        processDefaults.set(true, forKey: localCheckedKey)

        // Step B: Order-independent recovery of legacy synchronizable cloud vault into local storage
        let syncPendingKey = pendingLegacyMigrationKey(group: group, synchronizable: true)
        let syncCheckedKey = "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).sync"
        var syncGroups: [String] = []
        var seenSyncGroups: Set<String> = []
        if let savedSyncLegacy = processDefaults.string(forKey: syncPendingKey),
           !savedSyncLegacy.isEmpty,
           savedSyncLegacy != group,
           seenSyncGroups.insert(savedSyncLegacy).inserted {
            syncGroups.append(savedSyncLegacy)
        }
        if !processDefaults.bool(forKey: syncCheckedKey) {
            let discoveredSync = try discoverLegacyItemsReadOnly(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true,
                sharedGroup: group
            )
            for item in discoveredSync where seenSyncGroups.insert(item.group).inserted {
                syncGroups.append(item.group)
            }
        }

        for legacySyncGroup in syncGroups {
            processDefaults.set(legacySyncGroup, forKey: syncPendingKey)
            if let syncRecovered = try mergeAndDeletePendingLegacySyncToLocalUnlocked(
                legacyGroup: legacySyncGroup,
                group: group,
                pendingKey: syncPendingKey
            ) {
                latestRecoveredSnapshot = syncRecovered
            }
        }
        processDefaults.set(true, forKey: syncCheckedKey)
        defaults.removeObject(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey)
        return latestRecoveredSnapshot
    }

    private func reconcileRetiredCloudStateOnLocalLoadUnlocked() {
        let lastRetireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
        guard lastRetireGen > 0 else { return }

        let cloudRead = readKeychainDataWithStatus(
            account: GlassOTPConstants.keychainAccount,
            synchronizable: true
        )
        guard cloudRead.status == errSecSuccess,
              let cloudData = cloudRead.data,
              let cloudSnap = try? decodeSnapshot(cloudData) else {
            return
        }

        if cloudSnap.cloudRetiredAtMillis == nil {
            if (cloudSnap.cloudSyncGenerationMillis ?? 0) > lastRetireGen {
                if defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) {
                    defaults.set(true, forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
                    if !isAppExtension && !hasPendingLegacySyncMigration() {
                        defaults.set("replica", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                    }
                }
                defaults.removeObject(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
            } else {
                let retiredRecord = OTPVaultSnapshot(
                    schemaVersion: 1,
                    folders: [],
                    accounts: [],
                    updatedAt: Date(timeIntervalSince1970: Double(lastRetireGen) / 1000.0),
                    accountTombstones: [],
                    folderTombstones: [],
                    cloudRetiredAtMillis: lastRetireGen,
                    cloudSyncGenerationMillis: nil
                )
                do {
                    let retiredData = try encodeSnapshot(retiredRecord)
                    _ = try writeKeychainData(
                        retiredData,
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: true
                    )
                } catch {
                    defaults.set("cloud", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                    defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                }
            }
        }
    }

    private func hasPendingLegacySyncMigration() -> Bool {
        guard let group = backend.resolvedAccessGroup(), !isAppExtension else {
            return false
        }
        let pendingKey = pendingLegacyMigrationKey(group: group, synchronizable: true)
        guard let pendingLegacyGroup = processDefaults.string(forKey: pendingKey) else {
            return false
        }
        return !pendingLegacyGroup.isEmpty && pendingLegacyGroup != group
    }

    private func handleRetiredCloudRecordUnlocked(
        retiredAtMillis: Int64,
        canMutate: Bool
    ) throws -> (snapshot: OTPVaultSnapshot?, retired: Bool) {
        if !canMutate {
            let local = (try? readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false,
                canMutate: false
            )).flatMap { try? decodeSnapshot($0) }
            let replica = (try? readKeychainData(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false,
                canMutate: false
            )).flatMap { try? decodeSnapshot($0) }
            if let local, let replica {
                return (local.merged(with: replica, tombstoneLimit: nil), false)
            }
            return (local ?? replica, false)
        }

        let localExisting = try readKeychainData(
            account: GlassOTPConstants.keychainAccount,
            synchronizable: false,
            canMutate: true
        ).map(decodeSnapshot)
        let replicaRawData = try readKeychainData(
            account: GlassOTPConstants.keychainLocalReplicaAccount,
            synchronizable: false,
            canMutate: false
        )
        let replicaExisting = replicaRawData.flatMap { try? decodeSnapshot($0) }

        // If this device explicitly re-enabled sync AFTER retiredAtMillis, do not retire it
        if let replicaExisting,
           let replicaGen = replicaExisting.cloudSyncGenerationMillis,
           replicaGen > retiredAtMillis {
            let written = (try? writeSnapshotUnlocked(replicaExisting, syncEnabled: true)) ?? replicaExisting
            return (written, false)
        }

        var combined: OTPVaultSnapshot?
        for case let candidate? in [localExisting, replicaExisting] where candidate.cloudRetiredAtMillis == nil {
            combined = combined?.merged(with: candidate, tombstoneLimit: nil) ?? candidate
        }

        if combined == nil && replicaRawData != nil && replicaExisting == nil {
            throw KeychainVaultError.unreadableLocalReplica
        }

        var normalized: OTPVaultSnapshot?
        if var localVault = combined {
            localVault.cloudRetiredAtMillis = nil
            let data = try encodeSnapshot(localVault)
            _ = try writeAndVerifyKeychainData(
                data,
                account: GlassOTPConstants.keychainAccount,
                synchronizable: false
            )
            normalized = try decodeSnapshot(data)
        }

        let preserveUnreadableReplica = (replicaRawData != nil && replicaExisting == nil)
        if !preserveUnreadableReplica {
            try deleteKeychainItem(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )
        }
        defaults.set(false, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        defaults.set(true, forKey: GlassOTPConstants.pendingPeerRetirementNoticeKey)
        if isAppExtension {
            defaults.set(true, forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey)
        }
        defaults.removeObject(forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
        defaults.removeObject(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
        defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
        defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
        return (normalized, true)
    }

    @discardableResult
    private func writeSnapshotUnlocked(_ snapshot: OTPVaultSnapshot, syncEnabled: Bool) throws -> OTPVaultSnapshot {
        var cleanSnapshot = snapshot
        cleanSnapshot.cloudRetiredAtMillis = nil
        let data = try encodeSnapshot(cleanSnapshot)
        let normalized = try decodeSnapshot(data)

        if syncEnabled {
            let previousReplica = readKeychainDataWithStatus(
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )
            guard previousReplica.status == errSecSuccess || previousReplica.status == errSecItemNotFound else {
                throw KeychainVaultError.unexpectedStatus(previousReplica.status)
            }
            _ = try writeKeychainData(
                data,
                account: GlassOTPConstants.keychainLocalReplicaAccount,
                synchronizable: false
            )

            do {
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
            } catch {
                // Roll back the replica mutation if publishing to iCloud failed
                if previousReplica.status == errSecSuccess, let oldData = previousReplica.data {
                    _ = try? writeKeychainData(
                        oldData,
                        account: GlassOTPConstants.keychainLocalReplicaAccount,
                        synchronizable: false
                    )
                } else if previousReplica.status == errSecItemNotFound {
                    try? deleteKeychainItem(
                        account: GlassOTPConstants.keychainLocalReplicaAccount,
                        synchronizable: false
                    )
                }
                throw error
            }
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

    @discardableResult
    private func writeAndVerifyKeychainData(_ data: Data, account: String, synchronizable: Bool) throws -> Bool {
        let storedInGroup = try writeKeychainData(data, account: account, synchronizable: synchronizable)
        let verified = try readKeychainData(account: account, synchronizable: synchronizable, canMutate: false)
        guard verified == data else {
            throw KeychainVaultError.unexpectedStatus(errSecIO)
        }
        return storedInGroup
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

    private func withVaultLock<T>(isMutating: Bool, nonBlocking: Bool = false, _ body: (_ hasLock: Bool) throws -> T) throws -> T {
        if nonBlocking && !isMutating {
            guard lock.try() else {
                return try body(false)
            }
            defer { lock.unlock() }
            return try withFileLock(isMutating: false, nonBlocking: true, body)
        }
        return try lock.withLock {
            try withFileLock(isMutating: isMutating, nonBlocking: nonBlocking, body)
        }
    }

    private func withFileLock<T>(isMutating: Bool, nonBlocking: Bool, _ body: (_ hasLock: Bool) throws -> T) throws -> T {
        let resolvedURL: URL?
        if let customLockFileURL {
            resolvedURL = customLockFileURL
        } else {
            resolvedURL = vaultLockFileURL(isMutating: isMutating)
        }

        guard let lockURL = resolvedURL else {
            if isMutating {
                throw KeychainVaultError.lockUnavailable
            }
            return try body(false)
        }

        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            if isMutating {
                throw KeychainVaultError.lockUnavailable
            }
            return try body(false)
        }

        var acquired = false
        let deadline = Date().addingTimeInterval(lockTimeout)
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
                if nonBlocking || Date() >= deadline {
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

        if !acquired, isMutating {
            throw KeychainVaultError.lockUnavailable
        }

        return try body(acquired)
    }

    private func vaultLockFileURL(isMutating: Bool) -> URL? {
        #if !os(macOS)
        if let groupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GlassOTPConstants.appGroupID) {
            return groupDir.appendingPathComponent(".vault-lock")
        }
        #endif
        #if os(iOS) && !targetEnvironment(simulator)
        if isMutating {
            return nil
        }
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if os(macOS)
        return appSupport.appendingPathComponent("GlassOTP/.vault-lock")
        #else
        return appSupport.appendingPathComponent("glassotp-vault.lock")
        #endif
    }

    private func readKeychainDataWithStatus(account: String, synchronizable: Bool) -> (status: OSStatus, data: Data?) {
        if let group = backend.resolvedAccessGroup() {
            let scoped = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
            if scoped.status == errSecSuccess, let data = scoped.data {
                return (errSecSuccess, data)
            }
            #if !targetEnvironment(simulator)
            return (scoped.status, nil)
            #else
            if scoped.status != errSecItemNotFound && scoped.status != errSecMissingEntitlement {
                return (scoped.status, nil)
            }
            #endif
        }

        let unscoped = backend.read(account: account, synchronizable: synchronizable, accessGroup: nil)
        return (unscoped.status, unscoped.data)
    }

    private func pendingLegacyMigrationKey(group: String, synchronizable: Bool) -> String {
        "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).\(synchronizable ? "sync" : "local")"
    }

    private func completePendingLegacyMigrationDeleteIfNeeded(
        account: String,
        synchronizable: Bool,
        group: String,
        expectedData: Data
    ) throws -> Data {
        let pendingKey = pendingLegacyMigrationKey(group: group, synchronizable: synchronizable)
        let checkedKey = "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).\(synchronizable ? "sync" : "local")"

        var targetGroups: [String] = []
        var seenGroups: Set<String> = []
        if let savedPending = processDefaults.string(forKey: pendingKey),
           !savedPending.isEmpty,
           savedPending != group,
           seenGroups.insert(savedPending).inserted {
            targetGroups.append(savedPending)
        }
        if !processDefaults.bool(forKey: checkedKey) {
            let discovered = try discoverLegacyItemsReadOnly(
                account: account,
                synchronizable: synchronizable,
                sharedGroup: group
            )
            for item in discovered where seenGroups.insert(item.group).inserted {
                targetGroups.append(item.group)
            }
        }

        if targetGroups.isEmpty {
            if !processDefaults.bool(forKey: checkedKey) {
                processDefaults.set(true, forKey: checkedKey)
            }
            if processDefaults.string(forKey: pendingKey) != nil {
                processDefaults.removeObject(forKey: pendingKey)
            }
            return expectedData
        }

        var verifiedDestData = expectedData
        for pendingLegacyGroup in targetGroups {
            processDefaults.set(pendingLegacyGroup, forKey: pendingKey)
            let legacyRead = backend.read(
                account: account,
                synchronizable: synchronizable,
                accessGroup: pendingLegacyGroup
            )
            switch legacyRead.status {
            case errSecItemNotFound:
                processDefaults.removeObject(forKey: pendingKey)
                continue

            case errSecSuccess:
                guard let legacyData = legacyRead.data else {
                    throw synchronizable ? KeychainVaultError.unreadableCloudVault : KeychainVaultError.decodingFailed
                }
                if legacyData != verifiedDestData {
                    let destSnap: OTPVaultSnapshot
                    do {
                        destSnap = try decodeSnapshot(verifiedDestData)
                    } catch {
                        throw synchronizable ? KeychainVaultError.unreadableCloudVault : KeychainVaultError.decodingFailed
                    }
                    let legacySnap: OTPVaultSnapshot
                    do {
                        legacySnap = try decodeSnapshot(legacyData)
                    } catch {
                        throw synchronizable ? KeychainVaultError.unreadableCloudVault : KeychainVaultError.decodingFailed
                    }
                    if synchronizable && destSnap.cloudRetiredAtMillis != nil {
                        if legacySnap.cloudRetiredAtMillis == nil {
                            let existingLocal = try readKeychainData(
                                account: GlassOTPConstants.keychainAccount,
                                synchronizable: false,
                                canMutate: true
                            ).map(decodeSnapshot)
                            let existingReplica = try readKeychainData(
                                account: GlassOTPConstants.keychainLocalReplicaAccount,
                                synchronizable: false,
                                canMutate: false
                            ).flatMap { try? decodeSnapshot($0) }
                            var mergedLocal: OTPVaultSnapshot?
                            for case let candidate? in [legacySnap, existingLocal, existingReplica] where candidate.cloudRetiredAtMillis == nil {
                                mergedLocal = mergedLocal?.merged(with: candidate, tombstoneLimit: nil) ?? candidate
                            }
                            if var localToSave = mergedLocal {
                                localToSave.cloudRetiredAtMillis = nil
                                let localData = try encodeSnapshot(localToSave)
                                let stored = try writeAndVerifyKeychainData(
                                    localData,
                                    account: GlassOTPConstants.keychainAccount,
                                    synchronizable: false
                                )
                                #if targetEnvironment(simulator)
                                if !stored {
                                    try writeSimulatorFallback(localData)
                                } else {
                                    try? FileManager.default.removeItem(at: simulatorFallbackURL())
                                }
                                #else
                                _ = stored
                                #endif
                            }
                        }
                    } else {
                        let merged = destSnap.merged(with: legacySnap, tombstoneLimit: nil)
                        let mergedData = try encodeSnapshot(merged)
                        let accessibility: CFString = synchronizable
                            ? kSecAttrAccessibleAfterFirstUnlock
                            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                        let upsertStatus = backend.upsert(
                            data: mergedData,
                            account: account,
                            synchronizable: synchronizable,
                            accessGroup: group,
                            accessibility: accessibility
                        )
                        guard upsertStatus == errSecSuccess else {
                            throw KeychainVaultError.unexpectedStatus(upsertStatus)
                        }
                        let mergedVerify = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
                        guard mergedVerify.status == errSecSuccess, mergedVerify.data == mergedData else {
                            throw KeychainVaultError.unexpectedStatus(mergedVerify.status == errSecSuccess ? errSecIO : mergedVerify.status)
                        }
                        verifiedDestData = mergedData
                    }
                }

            default:
                throw KeychainVaultError.unexpectedStatus(legacyRead.status)
            }

            let deleteStatus = backend.delete(
                account: account,
                synchronizable: synchronizable,
                accessGroup: pendingLegacyGroup
            )
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw KeychainVaultError.unexpectedStatus(deleteStatus)
            }
            let verify = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
            guard verify.status == errSecSuccess, verify.data == verifiedDestData else {
                throw KeychainVaultError.unexpectedStatus(verify.status == errSecSuccess ? errSecIO : verify.status)
            }
            processDefaults.removeObject(forKey: pendingKey)
        }
        processDefaults.set(true, forKey: checkedKey)
        return verifiedDestData
    }

    private func readKeychainData(account: String, synchronizable: Bool, canMutate: Bool) throws -> Data? {
        if let group = backend.resolvedAccessGroup() {
            let scoped = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
            if scoped.status == errSecSuccess, let data = scoped.data {
                if canMutate,
                   !isAppExtension,
                   account == GlassOTPConstants.keychainAccount {
                    return try completePendingLegacyMigrationDeleteIfNeeded(
                        account: account,
                        synchronizable: synchronizable,
                        group: group,
                        expectedData: data
                    )
                }
                return data
            }
            #if targetEnvironment(simulator)
            if scoped.status != errSecItemNotFound && scoped.status != errSecMissingEntitlement {
                throw KeychainVaultError.unexpectedStatus(scoped.status)
            }
            #else
            if scoped.status == errSecItemNotFound {
                if canMutate,
                   !isAppExtension,
                   account == GlassOTPConstants.keychainAccount {
                    return try migrateUnscopedLegacyItemIfNeeded(
                        account: account,
                        synchronizable: synchronizable,
                        group: group
                    )
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
        let checkedKey = "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).\(synchronizable ? "sync" : "local")"
        let pendingKey = pendingLegacyMigrationKey(group: group, synchronizable: synchronizable)
        guard !processDefaults.bool(forKey: checkedKey) else {
            return nil
        }

        let all = backend.readAll(account: account, synchronizable: synchronizable)
        if all.status == errSecSuccess {
            let candidates = all.items.filter { $0.actualAccessGroup != group }
            guard let first = candidates.first else {
                let sharedCheck = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
                processDefaults.set(true, forKey: checkedKey)
                return sharedCheck.status == errSecSuccess ? sharedCheck.data : nil
            }

            let legacyData = first.data
            if let legacyGroup = first.actualAccessGroup, !legacyGroup.isEmpty {
                processDefaults.set(legacyGroup, forKey: pendingKey)
            }

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

            let firstVerify = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
            guard firstVerify.status == errSecSuccess, firstVerify.data == legacyData else {
                throw KeychainVaultError.unexpectedStatus(firstVerify.status == errSecSuccess ? errSecIO : firstVerify.status)
            }

            if let legacyGroup = first.actualAccessGroup, !legacyGroup.isEmpty {
                let deleteStatus = backend.delete(account: account, synchronizable: synchronizable, accessGroup: legacyGroup)
                guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                    throw KeychainVaultError.unexpectedStatus(deleteStatus)
                }

                let postDeleteVerify = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
                guard postDeleteVerify.status == errSecSuccess, postDeleteVerify.data == legacyData else {
                    throw KeychainVaultError.unexpectedStatus(postDeleteVerify.status == errSecSuccess ? errSecIO : postDeleteVerify.status)
                }
            }

            processDefaults.removeObject(forKey: pendingKey)
            if candidates.count == 1 {
                processDefaults.set(true, forKey: checkedKey)
                return legacyData
            }
            return try completePendingLegacyMigrationDeleteIfNeeded(
                account: account,
                synchronizable: synchronizable,
                group: group,
                expectedData: legacyData
            )
        }

        if all.status == errSecItemNotFound || all.status == errSecMissingEntitlement {
            processDefaults.set(true, forKey: checkedKey)
            return nil
        }

        throw KeychainVaultError.unexpectedStatus(all.status)
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
