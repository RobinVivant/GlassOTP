import Darwin
import Foundation
import Security

public enum GlassOTPConstants {
    public static let appGroupID = "group.com.robinvivant.glassotp"
    public static let keychainService = "com.robinvivant.glassotp.vault"
    public static let keychainAccount = "primary-vault-v1"
    public static let keychainLocalReplicaAccount = "local-replica-v1"
    internal static let legacySyncMarkerAccount = "icloud-sync-marker-v1"
    public static let keychainAccessGroupSuffix = "com.robinvivant.glassotp.shared"
    public static let iCloudSyncPreferenceKey = "glassotp.icloud.sync.enabled"
    public static let universalClipboardPreferenceKey = "glassotp.universalClipboard.enabled"
    public static let appLockPreferenceKey = "glassotp.security.appLockEnabled"
    public static let pendingICloudDeletePreferenceKey = "glassotp.icloud.pendingDelete"
    public static let lastCloudRetirementGenerationKey = "glassotp.icloud.lastRetirementGeneration"
    public static let pendingCloudRetirementStepKey = "glassotp.icloud.pendingRetirementStep"
    public static let cloudCleanupSupersededByPeerKey = "glassotp.icloud.cleanupSupersededByPeer"
    public static let legacyMigrationCheckedKey = "glassotp.keychain.legacyMigrationChecked"
    public static let pendingLegacyMigrationKeyPrefix = "glassotp.keychain.pendingLegacyDelete"
}

public enum CloudCleanupOutcome: Sendable, Equatable {
    case nothingPending
    case clearedCloudCopy
    case localCleanupOnlyPeerSuperseded
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
    case cloudCleanupFailed(OSStatus)
    case lockUnavailable

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain error (\(status))."
        case .decodingFailed:
            "Stored vault data could not be decoded. If sync is enabled, try turning iCloud Keychain Sync off and back on in Settings to rebuild your local replica."
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

    public func isICloudSyncEnabled() -> Bool {
        lock.withLock { isICloudSyncEnabledUnlocked() }
    }

    private struct LegacyCloudSyncMarker: Decodable {
        let disabledAt: Date
    }

    public func setICloudSyncEnabled(_ enabled: Bool) throws {
        try setICloudSyncEnabled(enabled, removeOppositeBucket: true)
    }

    @discardableResult
    public func setICloudSyncEnabled(_ enabled: Bool, removeOppositeBucket: Bool = true) throws -> OTPVaultSnapshot? {
        try withVaultLock(isMutating: true) { _ in
            let syncData = try readKeychainData(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true,
                canMutate: true
            )
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

            let syncSnapshot: OTPVaultSnapshot? = enabled
                ? try syncData.map(decodeSnapshot)
                : syncData.flatMap { try? decodeSnapshot($0) }
            let localSnapshot = try localData.map(decodeSnapshot)
            let replicaSnapshot = replicaData.flatMap { try? decodeSnapshot($0) }
            let syncCorrupt = (syncData != nil && syncSnapshot == nil)
            let replicaCorrupt = (replicaData != nil && replicaSnapshot == nil)

            var combined: OTPVaultSnapshot?
            let rawCandidates: [OTPVaultSnapshot?] = [syncSnapshot, replicaSnapshot, localSnapshot]
            for case let candidate? in rawCandidates where candidate.cloudRetiredAtMillis == nil {
                combined = combined?.merged(with: candidate, tombstoneLimit: nil) ?? candidate
            }

            let savedRetireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            let maxObservedGen = [
                savedRetireGen,
                syncSnapshot?.cloudSyncGenerationMillis,
                syncSnapshot?.cloudRetiredAtMillis,
                localSnapshot?.cloudSyncGenerationMillis,
                localSnapshot?.cloudRetiredAtMillis,
                replicaSnapshot?.cloudSyncGenerationMillis,
                replicaSnapshot?.cloudRetiredAtMillis,
            ].compactMap { $0 }.max() ?? 0

            defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)

            if enabled {
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
                try? deleteKeychainItem(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true)
                if removeOppositeBucket {
                    try deleteKeychainItem(account: GlassOTPConstants.keychainAccount, synchronizable: false)
                }
                return normalized
            } else {
                if removeOppositeBucket && combined == nil && (syncCorrupt || replicaCorrupt) {
                    throw KeychainVaultError.decodingFailed
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
                    let retirementGen = max(Date().roundedEpochMillis, maxObservedGen + 1)
                    // Persist retirement state BEFORE mutating sync preference or performing fallible cleanup
                    defaults.set(retirementGen, forKey: GlassOTPConstants.lastCloudRetirementGenerationKey)
                    defaults.set("cloud", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                    defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
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
                    if !(localSnapshot == nil && replicaCorrupt) {
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
            let step = defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) ?? "cloud"
            let savedGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            if step == "cloud" && savedGen == 0 && defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey) {
                defaults.set("replica", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
            }
            let effectiveGen = savedGen > 0 ? savedGen : Date().roundedEpochMillis
            do {
                return try performCloudRetirementCleanupUnlocked(retirementGeneration: effectiveGen)
            } catch let error as KeychainVaultError {
                defaults.set(true, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
                if case .unexpectedStatus(let status) = error {
                    throw KeychainVaultError.cloudCleanupFailed(status)
                }
                throw error
            }
        }
    }

    @discardableResult
    private func performCloudRetirementCleanupUnlocked(retirementGeneration: Int64) throws -> CloudCleanupOutcome {
        let initialStep = defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) ?? "cloud"
        if initialStep != "replica" {
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
                    throw KeychainVaultError.decodingFailed
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

            if let group = backend.resolvedAccessGroup(), !isAppExtension {
                let pendingKey = pendingLegacyMigrationKey(group: group, synchronizable: true)
                if let pendingLegacyGroup = processDefaults.string(forKey: pendingKey),
                   !pendingLegacyGroup.isEmpty,
                   pendingLegacyGroup != group {
                    let legacyRead = backend.read(
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: true,
                        accessGroup: pendingLegacyGroup
                    )
                    if legacyRead.status == errSecSuccess, let legacyData = legacyRead.data {
                        let legacySnap = try decodeSnapshot(legacyData)
                        let existingLocal = try readKeychainData(
                            account: GlassOTPConstants.keychainAccount,
                            synchronizable: false,
                            canMutate: false
                        ).map(decodeSnapshot)
                        var mergedLocal = existingLocal?.merged(with: legacySnap, tombstoneLimit: nil) ?? legacySnap
                        mergedLocal.cloudRetiredAtMillis = nil
                        let mergedData = try encodeSnapshot(mergedLocal)
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
                    } else if legacyRead.status != errSecItemNotFound {
                        throw KeychainVaultError.unexpectedStatus(legacyRead.status)
                    }

                    let deleteStatus = backend.delete(
                        account: GlassOTPConstants.keychainAccount,
                        synchronizable: true,
                        accessGroup: pendingLegacyGroup
                    )
                    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                        throw KeychainVaultError.unexpectedStatus(deleteStatus)
                    }
                    processDefaults.removeObject(forKey: pendingKey)
                    processDefaults.set(true, forKey: "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).sync")
                }
            }

            defaults.set("replica", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
        }

        try deleteKeychainItem(
            account: GlassOTPConstants.keychainLocalReplicaAccount,
            synchronizable: false
        )

        var superseded = defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
        if !superseded, initialStep == "replica" {
            let savedGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            let cloudRead = readKeychainDataWithStatus(
                account: GlassOTPConstants.keychainAccount,
                synchronizable: true
            )
            if cloudRead.status == errSecSuccess,
               let data = cloudRead.data,
               let snap = try? decodeSnapshot(data),
               snap.cloudRetiredAtMillis == nil,
               (savedGen == 0 || (snap.cloudSyncGenerationMillis ?? 0) > savedGen) {
                superseded = true
            }
        }

        defaults.removeObject(forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
        defaults.removeObject(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
        defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)
        return superseded ? .localCleanupOnlyPeerSuperseded : .clearedCloudCopy
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
        let displaySnapshot = try loadSnapshot()
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
        let syncEnabled = isICloudSyncEnabledUnlocked()
        if let primaryData = try readKeychainData(
            account: GlassOTPConstants.keychainAccount,
            synchronizable: syncEnabled,
            canMutate: canMutate
        ) {
            let primarySnapshot = try decodeSnapshot(primaryData)
            guard syncEnabled else {
                if canMutate {
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
                        throw KeychainVaultError.decodingFailed
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
                return try decodeSnapshot(replicaFallback)
            }
        } else if canMutate {
            reconcileRetiredCloudStateOnLocalLoadUnlocked()
        }

        #if targetEnvironment(simulator)
        if let simData = try? Data(contentsOf: simulatorFallbackURL()), !simData.isEmpty {
            return try decodeSnapshot(simData)
        }
        #endif

        return nil
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
                    defaults.set("replica", forKey: GlassOTPConstants.pendingCloudRetirementStepKey)
                    defaults.set(true, forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey)
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
            throw KeychainVaultError.decodingFailed
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

        try deleteKeychainItem(
            account: GlassOTPConstants.keychainLocalReplicaAccount,
            synchronizable: false
        )
        defaults.set(false, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
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

    private func withVaultLock<T>(isMutating: Bool, _ body: (_ hasLock: Bool) throws -> T) throws -> T {
        try lock.withLock {
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

            if !acquired, isMutating {
                throw KeychainVaultError.lockUnavailable
            }

            return try body(acquired)
        }
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
        guard let pendingLegacyGroup = processDefaults.string(forKey: pendingKey),
              !pendingLegacyGroup.isEmpty else {
            return expectedData
        }
        var verifiedDestData = expectedData
        if pendingLegacyGroup != group {
            let legacyRead = backend.read(
                account: account,
                synchronizable: synchronizable,
                accessGroup: pendingLegacyGroup
            )
            switch legacyRead.status {
            case errSecItemNotFound:
                processDefaults.removeObject(forKey: pendingKey)
                processDefaults.set(true, forKey: checkedKey)
                return verifiedDestData

            case errSecSuccess:
                guard let legacyData = legacyRead.data else {
                    throw KeychainVaultError.decodingFailed
                }
                if legacyData != expectedData {
                    let destSnap = try decodeSnapshot(expectedData)
                    let legacySnap = try decodeSnapshot(legacyData)
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
        }
        processDefaults.removeObject(forKey: pendingKey)
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

        let legacy = backend.read(account: account, synchronizable: synchronizable, accessGroup: nil)
        if legacy.status == errSecSuccess, let legacyData = legacy.data {
            if legacy.actualAccessGroup == group {
                // Concurrent write landed in the shared group between the initial read and legacy scan
                processDefaults.set(true, forKey: checkedKey)
                return legacyData
            }

            if let legacyGroup = legacy.actualAccessGroup, !legacyGroup.isEmpty, legacyGroup != group {
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
                processDefaults.removeObject(forKey: pendingKey)
                throw KeychainVaultError.unexpectedStatus(upsertStatus)
            }

            let firstVerify = backend.read(account: account, synchronizable: synchronizable, accessGroup: group)
            guard firstVerify.status == errSecSuccess, firstVerify.data == legacyData else {
                processDefaults.removeObject(forKey: pendingKey)
                throw KeychainVaultError.unexpectedStatus(firstVerify.status == errSecSuccess ? errSecIO : firstVerify.status)
            }

            if let legacyGroup = legacy.actualAccessGroup, !legacyGroup.isEmpty {
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
            processDefaults.set(true, forKey: checkedKey)
            return legacyData
        }

        if legacy.status == errSecItemNotFound || legacy.status == errSecMissingEntitlement {
            processDefaults.set(true, forKey: checkedKey)
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
