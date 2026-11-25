import Foundation
import Security
import Testing
@testable import GlassOTPCore

private final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    struct EntryKey: Hashable {
        let account: String
        let synchronizable: Bool
        let accessGroup: String
    }

    private let lock = NSLock()
    var accessGroup: String? = "TEAMID.com.robinvivant.glassotp.shared"
    var items: [EntryKey: Data] = [:]
    var readOverrides: [EntryKey: OSStatus] = [:]
    var upsertOverrides: [EntryKey: OSStatus] = [:]
    var deleteOverrides: [EntryKey: OSStatus] = [:]

    func resolvedAccessGroup() -> String? {
        lock.withLock { accessGroup }
    }

    func key(account: String, synchronizable: Bool, accessGroup: String?) -> EntryKey {
        EntryKey(account: account, synchronizable: synchronizable, accessGroup: accessGroup ?? "__unscoped__")
    }

    func read(account: String, synchronizable: Bool, accessGroup: String?) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            let k = key(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
            if let status = readOverrides[k] {
                return (status, status == errSecSuccess ? items[k] : nil)
            }
            if let data = items[k] {
                return (errSecSuccess, data)
            }
            return (errSecItemNotFound, nil)
        }
    }

    func upsert(data: Data, account: String, synchronizable: Bool, accessGroup: String?, accessibility: CFString) -> OSStatus {
        lock.withLock {
            let k = key(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
            if let status = upsertOverrides[k] {
                return status
            }
            items[k] = data
            return errSecSuccess
        }
    }

    func delete(account: String, synchronizable: Bool, accessGroup: String?) -> OSStatus {
        lock.withLock {
            let k = key(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
            if let status = deleteOverrides[k] {
                return status
            }
            return items.removeValue(forKey: k) != nil ? errSecSuccess : errSecItemNotFound
        }
    }
}

struct KeychainVaultStoreTests {
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "glassotp.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    private func makeLockURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("glassotp-test-\(UUID().uuidString).lock")
    }

    @Test("Disabling iCloud with delete writes retirement marker, deletes replica, and stops peer re-upload")
    func cloudDisableRetirementMarkerStopsPeerReupload() throws {
        let (defaultsA, suiteA) = makeIsolatedDefaults()
        let (defaultsB, suiteB) = makeIsolatedDefaults()
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }

        let backendA = InMemoryKeychainBackend()
        let backendB = InMemoryKeychainBackend()
        let group = backendA.accessGroup!

        let storeA = KeychainVaultStore(defaults: defaultsA, backend: backendA, lockFileURL: makeLockURL())
        let storeB = KeychainVaultStore(defaults: defaultsB, backend: backendB, lockFileURL: makeLockURL())

        let initialAccount = OTPAccount(issuer: "GitHub", label: "a@example.com", secret: Data("12345".utf8))
        try storeA.saveSnapshot(OTPVaultSnapshot(accounts: [initialAccount]))

        // Sync initial cloud item to peer B
        let cloudKey = backendA.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backendB.items[cloudKey] = backendA.items[cloudKey]
        let loadedB1 = try storeB.loadSnapshot()
        #expect(loadedB1?.accounts.count == 1)

        // Device A disables iCloud and deletes cloud copy
        try storeA.setICloudSyncEnabled(false, removeOppositeBucket: true)
        let replicaKey = backendA.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        #expect(backendA.items[replicaKey] == nil)
        #expect(backendA.items[cloudKey] == nil)

        // Propagate cloud state (no primary, retirement marker present) to peer B
        let markerKey = backendA.key(account: GlassOTPConstants.keychainSyncMarkerAccount, synchronizable: true, accessGroup: group)
        backendB.items.removeValue(forKey: cloudKey)
        backendB.items[markerKey] = backendA.items[markerKey]

        // Device B loads and later mutates an account -> must switch local-only and NOT re-upload to iCloud
        let loadedB2 = try storeB.loadSnapshot()
        #expect(loadedB2?.accounts.count == 1)
        #expect(storeB.isICloudSyncEnabled() == false)
        _ = try storeB.mutateSnapshot { snap in
            snap.accounts[0].isPinned = true
        }
        #expect(backendB.items[cloudKey] == nil)
    }

    @Test("Cloud cleanup failure sets pending flag and retryPendingICloudCleanup clears it")
    func cloudCleanupFailureAndRetry() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, backend: backend, lockFileURL: makeLockURL())

        let account = OTPAccount(issuer: "Stripe", label: "ops", secret: Data("999".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [account]))

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.deleteOverrides[cloudKey] = errSecInteractionNotAllowed

        do {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            Issue.record("Expected cloudCleanupFailed error")
        } catch let error as KeychainVaultError {
            #expect(error == .cloudCleanupFailed(errSecInteractionNotAllowed))
        }
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == true)
        #expect(store.isICloudSyncEnabled() == false)

        backend.deleteOverrides.removeValue(forKey: cloudKey)
        try store.retryPendingICloudCleanup()
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)
        #expect(backend.items[cloudKey] == nil)
    }

    @Test("Failed replica write propagates error while non-fatal replica read error does not break load")
    func replicaFailureSemantics() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, backend: backend, lockFileURL: makeLockURL())

        let account = OTPAccount(issuer: "Cloudflare", label: "a", secret: Data("abc".utf8))
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        backend.upsertOverrides[replicaKey] = errSecIO

        #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [account]))
        }

        // Write cleanly then break replica read -> loadSnapshot must still return readable primary
        backend.upsertOverrides.removeValue(forKey: replicaKey)
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [account]))
        backend.readOverrides[replicaKey] = errSecDecode

        let loaded = try store.loadSnapshot()
        #expect(loaded?.accounts.count == 1)
    }

    @Test("One-time legacy unscoped migration copies and verifies before deleting legacy item")
    func oneTimeLegacyUnscopedMigration() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, backend: backend, lockFileURL: makeLockURL())

        let legacyAccount = OTPAccount(issuer: "LegacyApp", label: "x", secret: Data("111".utf8))
        let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAccount]))
        let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: nil)
        let scopedKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.items[legacyKey] = legacyData

        let loaded = try store.loadSnapshot()
        #expect(loaded?.accounts.count == 1)
        #expect(loaded?.accounts[0].issuer == "LegacyApp")
        #expect(backend.items[scopedKey] == legacyData)
        #expect(backend.items[legacyKey] == nil)
        #expect(defaults.bool(forKey: GlassOTPConstants.legacyMigrationCheckedKey) == true)
    }

    @Test("mutateSnapshotIfPresent skips writing on missing account and propagates strict entitlement errors")
    func mutateIfPresentAndStrictGroupErrors() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, backend: backend, lockFileURL: makeLockURL())

        let missingResult = try store.mutateSnapshotIfPresent { _ in true }
        #expect(missingResult == nil)

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.readOverrides[cloudKey] = errSecMissingEntitlement
        #expect(throws: KeychainVaultError.unexpectedStatus(errSecMissingEntitlement)) {
            _ = try store.loadSnapshot()
        }
    }
}
