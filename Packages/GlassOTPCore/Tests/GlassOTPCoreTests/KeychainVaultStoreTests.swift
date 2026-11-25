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
    var omitActualAccessGroupOnUnscopedRead = false

    func resolvedAccessGroup() -> String? {
        lock.withLock { accessGroup }
    }

    func key(account: String, synchronizable: Bool, accessGroup: String?) -> EntryKey {
        EntryKey(account: account, synchronizable: synchronizable, accessGroup: accessGroup ?? "__unscoped__")
    }

    func read(account: String, synchronizable: Bool, accessGroup: String?) -> (status: OSStatus, data: Data?, actualAccessGroup: String?) {
        lock.withLock {
            if let accessGroup {
                let k = key(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
                if let status = readOverrides[k] {
                    return (status, status == errSecSuccess ? items[k] : nil, status == errSecSuccess ? accessGroup : nil)
                }
                if let data = items[k] {
                    return (errSecSuccess, data, accessGroup)
                }
                return (errSecItemNotFound, nil, nil)
            }

            let unscopedKey = key(account: account, synchronizable: synchronizable, accessGroup: nil)
            if let status = readOverrides[unscopedKey], status != errSecSuccess {
                return (status, nil, nil)
            }
            let matches = items.keys
                .filter { $0.account == account && $0.synchronizable == synchronizable }
                .sorted { $0.accessGroup < $1.accessGroup }
            for match in matches {
                let reportedGroup = omitActualAccessGroupOnUnscopedRead ? nil : match.accessGroup
                if let status = readOverrides[match] {
                    return (status, status == errSecSuccess ? items[match] : nil, status == errSecSuccess ? reportedGroup : nil)
                }
                return (errSecSuccess, items[match], reportedGroup)
            }
            return (errSecItemNotFound, nil, nil)
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
            if let accessGroup {
                let k = key(account: account, synchronizable: synchronizable, accessGroup: accessGroup)
                if let status = deleteOverrides[k] {
                    return status
                }
                return items.removeValue(forKey: k) != nil ? errSecSuccess : errSecItemNotFound
            }

            // Simulate Apple SecItemDelete without kSecAttrAccessGroup: deletes across all matching groups
            let unscopedKey = key(account: account, synchronizable: synchronizable, accessGroup: nil)
            if let status = deleteOverrides[unscopedKey] {
                return status
            }
            let matchingKeys = items.keys.filter { $0.account == account && $0.synchronizable == synchronizable }
            for k in matchingKeys {
                if let status = deleteOverrides[k] {
                    return status
                }
            }
            guard !matchingKeys.isEmpty else {
                return errSecItemNotFound
            }
            for k in matchingKeys {
                items.removeValue(forKey: k)
            }
            return errSecSuccess
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

    @Test("Disabling iCloud with delete writes single retirement record, stops peer re-upload, and re-enables cleanly")
    func singleRecordCloudRetirementStopsPeerReuploadAndReEnableBumpsGeneration() throws {
        let (defaultsA, suiteA) = makeIsolatedDefaults()
        let (defaultsB, suiteB) = makeIsolatedDefaults()
        let (procA, procSuiteA) = makeIsolatedDefaults()
        let (procB, procSuiteB) = makeIsolatedDefaults()
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
            procA.removePersistentDomain(forName: procSuiteA)
            procB.removePersistentDomain(forName: procSuiteB)
        }

        let backendA = InMemoryKeychainBackend()
        let backendB = InMemoryKeychainBackend()
        let group = backendA.accessGroup!

        let storeA = KeychainVaultStore(defaults: defaultsA, processDefaults: procA, backend: backendA, lockFileURL: makeLockURL())
        let storeB = KeychainVaultStore(defaults: defaultsB, processDefaults: procB, backend: backendB, lockFileURL: makeLockURL())

        let initialAccount = OTPAccount(issuer: "GitHub", label: "a@example.com", secret: Data("12345".utf8))
        try storeA.saveSnapshot(OTPVaultSnapshot(accounts: [initialAccount]))

        // Sync initial cloud item to peer B, and mutate peer B locally before retirement arrives
        let cloudKey = backendA.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let localKeyB = backendB.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
        backendB.items[cloudKey] = backendA.items[cloudKey]
        _ = try storeB.loadSnapshot()
        _ = try storeB.mutateSnapshot { snap in
            snap.accounts[0].isPinned = true
        }

        // Device A disables iCloud and clears the cloud copy -> writes empty retirement record into primary-vault-v1
        try storeA.setICloudSyncEnabled(false, removeOppositeBucket: true)
        let replicaKeyA = backendA.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        #expect(backendA.items[replicaKeyA] == nil)
        let retiredBlob = try #require(backendA.items[cloudKey])
        let retiredSnap = try VaultSnapshotCoder.decode(from: retiredBlob)
        #expect(retiredSnap.accounts.isEmpty)
        #expect(retiredSnap.folders.isEmpty)
        #expect(retiredSnap.cloudRetiredAtMillis != nil)

        // Propagate retired primary cloud record to peer B AFTER B mutated
        backendB.items[cloudKey] = retiredBlob

        // Device B loads -> must preserve its mutated data locally, delete replica, switch local-only, and NOT republish
        let loadedB2 = try storeB.loadSnapshot()
        #expect(loadedB2?.accounts.count == 1)
        #expect(loadedB2?.accounts[0].isPinned == true)
        #expect(storeB.isICloudSyncEnabled() == false)
        #expect(backendB.items[localKeyB] != nil)
        let replicaKeyB = backendB.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        #expect(backendB.items[replicaKeyB] == nil)

        _ = try storeB.mutateSnapshot { snap in
            snap.accounts[0].label = "edited-local@example.com"
        }
        let postMutationCloud = try VaultSnapshotCoder.decode(from: #require(backendB.items[cloudKey]))
        #expect(postMutationCloud.accounts.isEmpty)
        #expect(postMutationCloud.cloudRetiredAtMillis != nil)

        // Re-enabling iCloud on Device A bumps cloudSyncGenerationMillis above retiredAtMillis so A republishes cleanly
        try storeA.setICloudSyncEnabled(true, removeOppositeBucket: true)
        #expect(storeA.isICloudSyncEnabled() == true)
        let republished = try VaultSnapshotCoder.decode(from: #require(backendA.items[cloudKey]))
        #expect(republished.accounts.count == 1)
        #expect(republished.cloudRetiredAtMillis == nil)
        #expect((republished.cloudSyncGenerationMillis ?? 0) > (retiredSnap.cloudRetiredAtMillis ?? 0))
    }

    @Test("Cloud cleanup failure persists pending flag and retryPendingICloudCleanup clears it")
    func cloudCleanupFailureAndRetry() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let lockURL = makeLockURL()
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: lockURL)

        let account = OTPAccount(issuer: "Stripe", label: "ops", secret: Data("999".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [account]))

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        backend.deleteOverrides[replicaKey] = errSecInteractionNotAllowed

        do {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            Issue.record("Expected cloudCleanupFailed error")
        } catch let error as KeychainVaultError {
            #expect(error == .cloudCleanupFailed(errSecInteractionNotAllowed))
        }
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == true)
        #expect(store.isICloudSyncEnabled() == false)

        // Retry even from a fresh store instance backed by the same defaults
        backend.deleteOverrides.removeValue(forKey: replicaKey)
        let relaunchedStore = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: lockURL)
        try relaunchedStore.retryPendingICloudCleanup()
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)
        #expect(backend.items[replicaKey] == nil)
        let retired = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
        #expect(retired.accounts.isEmpty)
        #expect(retired.cloudRetiredAtMillis != nil)
    }

    @Test("Replica rollback preserves old replica on cloud failure, and transient replica read errors preserve data")
    func replicaFailureSemanticsAndRollback() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let initial = OTPAccount(issuer: "Cloudflare", label: "v1", secret: Data("abc".utf8))
        let updated = OTPAccount(id: initial.id, issuer: "Cloudflare", label: "v2", secret: Data("abc".utf8), updatedAt: initial.updatedAt.addingTimeInterval(5))
        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

        try store.saveSnapshot(OTPVaultSnapshot(accounts: [initial]))
        let originalReplicaData = try #require(backend.items[replicaKey])

        // Cloud upsert fails during save -> replica must roll back to originalReplicaData
        backend.upsertOverrides[cloudKey] = errSecIO
        #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [updated]))
        }
        #expect(backend.items[replicaKey] == originalReplicaData)
        backend.upsertOverrides.removeValue(forKey: cloudKey)

        // Failed replica write on first save propagates error
        backend.upsertOverrides[replicaKey] = errSecIO
        #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [updated]))
        }
        backend.upsertOverrides.removeValue(forKey: replicaKey)

        // Transient replica read error must return readable cloud vault AND preserve replica bytes untouched
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [updated]))
        let v2ReplicaData = try #require(backend.items[replicaKey])
        backend.readOverrides[replicaKey] = errSecIO
        let loaded = try store.loadSnapshot()
        #expect(loaded?.accounts.first?.label == "v2")
        #expect(backend.items[replicaKey] == v2ReplicaData)
    }

    @Test("Retired cloud load propagates error without deleting replica if local copy write fails")
    func retirementWriteFailurePreservesReplicaAndSyncState() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let acc = OTPAccount(issuer: "Linear", label: "team", secret: Data("111".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

        let retiredData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))
        backend.items[cloudKey] = retiredData
        backend.upsertOverrides[localKey] = errSecIO

        #expect(throws: KeychainVaultError.self) {
            _ = try store.loadSnapshot()
        }
        #expect(backend.items[replicaKey] != nil)
        #expect(store.isICloudSyncEnabled() == true)
    }

    @Test("Explicit-group legacy migration preserves shared item and is skipped in extensions")
    func explicitGroupLegacyMigrationAndExtensionIsolation() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (extProcDefaults, extProcSuite) = makeIsolatedDefaults()
        let (appProcDefaults, appProcSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            extProcDefaults.removePersistentDomain(forName: extProcSuite)
            appProcDefaults.removePersistentDomain(forName: appProcSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let legacyGroup = "TEAMID.com.robinvivant.glassotp"
        let lockURL = makeLockURL()

        let legacyAccount = OTPAccount(issuer: "LegacyApp", label: "x", secret: Data("111".utf8))
        let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAccount]))
        let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
        let scopedKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.items[legacyKey] = legacyData

        // Extension process must NOT run legacy migration or set migration flag
        let extStore = KeychainVaultStore(defaults: defaults, processDefaults: extProcDefaults, backend: backend, isAppExtension: true, lockFileURL: lockURL)
        let extLoaded = try extStore.loadSnapshot()
        #expect(extLoaded == nil)
        #expect(backend.items[legacyKey] == legacyData)
        #expect(backend.items[scopedKey] == nil)
        let checkedKey = "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).sync"
        #expect(extProcDefaults.bool(forKey: checkedKey) == false)

        // Main app migrates from explicit legacyGroup to shared group and deletes ONLY legacyGroup
        let appStore = KeychainVaultStore(defaults: defaults, processDefaults: appProcDefaults, backend: backend, isAppExtension: false, lockFileURL: lockURL)
        let loaded = try appStore.loadSnapshot()
        #expect(loaded?.accounts.count == 1)
        #expect(loaded?.accounts[0].issuer == "LegacyApp")
        #expect(backend.items[scopedKey] == legacyData)
        #expect(backend.items[legacyKey] == nil)
        #expect(appProcDefaults.bool(forKey: checkedKey) == true)

        // When unscoped read omits actualAccessGroup (nil), migrate into shared group and NEVER call wildcard delete
        let nilGroupBackend = InMemoryKeychainBackend()
        nilGroupBackend.omitActualAccessGroupOnUnscopedRead = true
        nilGroupBackend.items[legacyKey] = legacyData
        let (nilProcDefaults, nilProcSuite) = makeIsolatedDefaults()
        defer { nilProcDefaults.removePersistentDomain(forName: nilProcSuite) }
        let nilGroupStore = KeychainVaultStore(defaults: defaults, processDefaults: nilProcDefaults, backend: nilGroupBackend, isAppExtension: false, lockFileURL: lockURL)
        let nilGroupLoaded = try nilGroupStore.loadSnapshot()
        #expect(nilGroupLoaded?.accounts.count == 1)
        #expect(nilGroupLoaded?.accounts[0].issuer == "LegacyApp")
        #expect(nilGroupBackend.items[scopedKey] == legacyData)
        #expect(nilGroupBackend.items[legacyKey] == legacyData)
        #expect(nilProcDefaults.bool(forKey: checkedKey) == true)
    }

    @Test("Lock contention keeps loadSnapshot strictly read-only without creating replica or retiring")
    func lockContentionLoadRemainsReadOnly() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let lockURL = makeLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let account = OTPAccount(issuer: "Contended", label: "c", secret: Data("123".utf8))
        let cloudData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [account]))
        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        backend.items[cloudKey] = cloudData

        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: lockURL, lockTimeout: 0.05)
        let loaded = try store.loadSnapshot()
        #expect(loaded?.accounts.count == 1)
        #expect(backend.items[replicaKey] == nil)
    }

    @Test("mutateSnapshotIfPresent skips writing on missing account and propagates strict entitlement errors")
    func mutateIfPresentAndStrictGroupErrors() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let missingResult = try store.mutateSnapshotIfPresent { _ in true }
        #expect(missingResult == nil)

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.readOverrides[cloudKey] = errSecMissingEntitlement
        #expect(throws: KeychainVaultError.unexpectedStatus(errSecMissingEntitlement)) {
            _ = try store.loadSnapshot()
        }
    }
}
