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

    @Test("Clock-skewed peer generation cannot prevent iCloud retirement from taking effect")
    func clockSkewRetirementStopsPeerWithFutureGeneration() throws {
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

        // Peer B had a +180s skewed clock when enabling sync
        let futureGen = Date().roundedEpochMillis + 180_000
        let account = OTPAccount(issuer: "GitHub", label: "skew@example.com", secret: Data("skew".utf8))
        let skewedCloudData = try VaultSnapshotCoder.encode(
            OTPVaultSnapshot(accounts: [account], cloudSyncGenerationMillis: futureGen)
        )
        let cloudKey = backendA.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let replicaKeyB = backendB.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        backendB.items[cloudKey] = skewedCloudData
        _ = try storeB.loadSnapshot()
        #expect(backendB.items[replicaKeyB] != nil)

        // Peer A loads the future-stamped cloud item and retires iCloud on its earlier local clock
        backendA.items[cloudKey] = skewedCloudData
        _ = try storeA.loadSnapshot()
        try storeA.setICloudSyncEnabled(false, removeOppositeBucket: true)

        let retiredBlob = try #require(backendA.items[cloudKey])
        let retiredSnap = try VaultSnapshotCoder.decode(from: retiredBlob)
        #expect(retiredSnap.accounts.isEmpty)
        #expect((retiredSnap.cloudRetiredAtMillis ?? 0) > futureGen)

        // Propagate retired cloud record to Peer B -> Peer B must switch local-only without republishing
        backendB.items[cloudKey] = retiredBlob
        let loadedB = try storeB.loadSnapshot()
        #expect(loadedB?.accounts.count == 1)
        #expect(storeB.isICloudSyncEnabled() == false)
        #expect(backendB.items[replicaKeyB] == nil)
        let postBCloud = try VaultSnapshotCoder.decode(from: #require(backendB.items[cloudKey]))
        #expect(postBCloud.accounts.isEmpty)
        #expect(postBCloud.cloudRetiredAtMillis != nil)
    }

    @Test("Two-stage retry only deletes local replica after cloud retirement already succeeded, preserving newer peer sync")
    func twoStageCleanupRetryPreservesNewerPeerCloudVault() throws {
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

        let acc = OTPAccount(issuer: "Cloudflare", label: "a", secret: Data("123".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

        // Cloud write succeeds, replica delete fails -> step advances to "replica"
        backend.deleteOverrides[replicaKey] = errSecInteractionNotAllowed
        do {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            Issue.record("Expected cloudCleanupFailed error")
        } catch let error as KeychainVaultError {
            #expect(error == .cloudCleanupFailed(errSecInteractionNotAllowed))
        }
        #expect(defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) == "replica")
        let retireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0

        // Meanwhile another device explicitly re-enables sync with a newer generation and 1 active account
        let newPeerCloudData = try VaultSnapshotCoder.encode(
            OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: retireGen + 500)
        )
        backend.items[cloudKey] = newPeerCloudData

        // Retrying local cleanup must clear ONLY the local replica and preserve the peer's newer active cloud vault
        backend.deleteOverrides.removeValue(forKey: replicaKey)
        let cleanupOutcome = try store.retryPendingICloudCleanup()
        #expect(cleanupOutcome == .localCleanupOnlyPeerSuperseded)
        #expect(backend.items[replicaKey] == nil)
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)
        let preservedCloud = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
        #expect(preservedCloud.accounts.count == 1)
        #expect(preservedCloud.cloudRetiredAtMillis == nil)
        #expect(try store.retryPendingICloudCleanup() == .nothingPending)
    }

    @Test("Concurrent peer write that overwrote retirement is re-retired on next local load")
    func concurrentPeerCloudOverwriteReRetiredOnLocalLoad() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let acc = OTPAccount(issuer: "Discord", label: "ops", secret: Data("abc".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))
        try store.setICloudSyncEnabled(false, removeOppositeBucket: true)

        let retireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
        #expect(retireGen > 0)

        // Simulate stale-generation concurrent peer write landing in cloud primary
        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.items[cloudKey] = try VaultSnapshotCoder.encode(
            OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: retireGen - 10)
        )

        let loaded = try store.loadSnapshot()
        #expect(loaded?.accounts.count == 1)
        let reRetired = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
        #expect(reRetired.accounts.isEmpty)
        #expect(reRetired.cloudRetiredAtMillis == retireGen)
    }

    @Test("Replica read failures allow display load while blocking mutating writes")
    func replicaReadFailureBlocksMutationsWhileAllowingDisplay() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let acc1 = OTPAccount(issuer: "One", label: "1", secret: Data("111".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc1]))

        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        let replicaSnapshotBeforeFailure = try #require(backend.items[replicaKey])
        backend.readOverrides[replicaKey] = errSecIO

        // Read-only display still succeeds
        let displayed = try store.loadSnapshot()
        #expect(displayed?.accounts.count == 1)

        // Mutations must fail closed without overwriting replica
        #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
            _ = try store.mutateSnapshot { snap in
                snap.folders.append(OTPFolder(name: "Work"))
            }
        }
        #expect(backend.items[replicaKey] == replicaSnapshotBeforeFailure)

        backend.readOverrides.removeValue(forKey: replicaKey)
        backend.items[replicaKey] = Data("corrupt-replica".utf8)
        let displayedWithBadReplica = try store.loadSnapshot()
        #expect(displayedWithBadReplica?.accounts.count == 1)
        #expect(throws: KeychainVaultError.decodingFailed) {
            _ = try store.saveMergedSnapshot(OTPVaultSnapshot(accounts: [acc1]))
        }
    }

    @Test("Interrupted legacy migration delete completes on reload and before finishing cloud clear")
    func interruptedLegacyMigrationCleansOnReloadAndCloudClear() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let legacyGroup = "TEAMID.com.robinvivant.glassotp"
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let legacyAcc = OTPAccount(issuer: "Legacy", label: "u", secret: Data("111".utf8))
        let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
        let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
        let scopedKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.items[legacyKey] = legacyData
        backend.deleteOverrides[legacyKey] = errSecIO

        #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
            _ = try store.loadSnapshot()
        }
        // Copied to shared group, legacyGroup still exists, pending key recorded
        #expect(backend.items[scopedKey] == legacyData)
        #expect(backend.items[legacyKey] == legacyData)

        // Clear transient failure and reload -> resumes cleanup of legacyGroup
        backend.deleteOverrides.removeValue(forKey: legacyKey)
        let reloaded = try store.loadSnapshot()
        #expect(reloaded?.accounts.count == 1)
        #expect(backend.items[legacyKey] == nil)

        // Retrying when interrupted up until cloud retirement must also delete legacyGroup
        backend.items[legacyKey] = legacyData
        procDefaults.removeObject(forKey: "\(GlassOTPConstants.legacyMigrationCheckedKey).\(group).sync")
        procDefaults.set(legacyGroup, forKey: "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).sync")
        try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
        #expect(backend.items[legacyKey] == nil)
    }

    @Test("Upgrade from Round 4 icloud-sync-marker-v1 retires peer without republishing replica")
    func round4LegacySyncMarkerTransitionsPeerWithoutRepublish() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let acc = OTPAccount(issuer: "LegacyPeer", label: "u", secret: Data("abc".utf8))
        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        let markerKey = backend.key(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true, accessGroup: group)

        backend.items[replicaKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [acc]))
        backend.items[markerKey] = try VaultSnapshotCoder.encodeValue(["disabledAt": Date()])

        let loaded = try store.loadSnapshot()
        #expect(loaded?.accounts.count == 1)
        #expect(store.isICloudSyncEnabled() == false)
        #expect(backend.items[localKey] != nil)
        #expect(backend.items[replicaKey] == nil)
        #expect(backend.items[markerKey] == nil)
        let upgradedCloud = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
        #expect(upgradedCloud.accounts.isEmpty)
        #expect(upgradedCloud.cloudRetiredAtMillis != nil)
    }

    @Test("Lock contention fails closed on mutating operations on macOS too")
    func lockContentionFailsClosedOnMacMutations() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let lockURL = makeLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: lockURL, lockTimeout: 0.05)
        #expect(throws: KeychainVaultError.lockUnavailable) {
            _ = try store.mutateSnapshot { snap in
                snap.folders.append(OTPFolder(name: "Contended"))
            }
        }
        #expect(throws: KeychainVaultError.lockUnavailable) {
            _ = try store.saveMergedSnapshot(OTPVaultSnapshot())
        }
    }

    @Test("Undecodable replica or cloud item does not trap switching to local storage or retirement")
    func undecodableReplicaDoesNotTrapLocalSwitchOrRetirement() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let localAcc = OTPAccount(issuer: "Surviving", label: "a", secret: Data("111".utf8))
        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

        backend.items[cloudKey] = Data("future-cloud-format".utf8)
        backend.items[replicaKey] = Data("future-replica-format".utf8)
        backend.items[localKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [localAcc]))

        let switched = try store.setICloudSyncEnabled(false, removeOppositeBucket: false)
        #expect(switched?.accounts.count == 1)
        #expect(store.isICloudSyncEnabled() == false)

        // Re-enable then retire with bad replica bytes while stale local exists: unreadable replica is preserved
        backend.items[cloudKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))
        let badReplicaBytes = Data("bad-replica-bytes".utf8)
        backend.items[replicaKey] = badReplicaBytes
        defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        let retired = try store.loadSnapshot()
        #expect(retired?.accounts.count == 1)
        #expect(store.isICloudSyncEnabled() == false)
        #expect(backend.items[replicaKey] == badReplicaBytes)
    }

    @Test("Disabling sync or retiring preserves the last unreadable vault copy instead of deleting it")
    func unreadableVaultPreservedWhenDisablingSyncOrRetiring() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

        let badCloud = Data("future-v99-cloud".utf8)
        let badReplica = Data("future-v99-replica".utf8)
        backend.items[cloudKey] = badCloud
        backend.items[replicaKey] = badReplica
        defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)

        // Case 1: Turn Off & Delete iCloud Copy with corrupt cloud/replica and no local copy must fail closed
        #expect(throws: KeychainVaultError.decodingFailed) {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
        }
        #expect(backend.items[cloudKey] == badCloud)
        #expect(backend.items[replicaKey] == badReplica)
        #expect(backend.items[localKey] == nil)
        #expect(store.isICloudSyncEnabled() == true)

        // Case 2: Turning off sync without clearing cloud preserves corrupt replica; re-enabling fails closed while keeping replica & retired cloud
        let retiredCloudData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))
        backend.items[cloudKey] = retiredCloudData
        #expect(try store.setICloudSyncEnabled(false, removeOppositeBucket: false) == nil)
        #expect(backend.items[replicaKey] == badReplica)
        #expect(backend.items[cloudKey] == retiredCloudData)
        #expect(store.isICloudSyncEnabled() == false)

        #expect(throws: KeychainVaultError.decodingFailed) {
            try store.setICloudSyncEnabled(true, removeOppositeBucket: true)
        }
        #expect(backend.items[replicaKey] == badReplica)
        #expect(backend.items[cloudKey] == retiredCloudData)
        #expect(store.isICloudSyncEnabled() == false)

        // Case 3: Remote cloud retirement when no local copy exists and replica is unreadable must fail closed and preserve replica
        defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        backend.items[cloudKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))
        #expect(throws: KeychainVaultError.decodingFailed) {
            _ = try store.loadSnapshot()
        }
        #expect(backend.items[replicaKey] == badReplica)
        #expect(backend.items[localKey] == nil)

        // Case 4: Corrupt cloud + readable replica fails closed on "Turn Off & Delete", while "Keep iCloud Copy" recovers locally
        let acc = OTPAccount(issuer: "ReadableReplica", label: "u", secret: Data("333".utf8))
        backend.items[cloudKey] = badCloud
        backend.items[replicaKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [acc]))
        defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        defaults.set(false, forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey)

        #expect(throws: KeychainVaultError.decodingFailed) {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
        }
        #expect(store.isICloudSyncEnabled() == true)
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)
        #expect(backend.items[localKey] == nil)

        let keptRecovery = try store.setICloudSyncEnabled(false, removeOppositeBucket: false)
        #expect(keptRecovery?.accounts.map(\.issuer) == ["ReadableReplica"])
        #expect(store.isICloudSyncEnabled() == false)
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)
    }

    @Test("Interrupted legacy migration handles upsert failure, cloud delete, peer retirement, and peer merges")
    func interruptedMigrationUpsertFailAndPeerMergeOnResume() throws {
        // Case 1: Upsert failure retains pendingKey so peer write to shared group merges both and deletes legacyGroup on resume
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let legacyAcc = OTPAccount(issuer: "LegacyOnly", label: "a", secret: Data("111".utf8))
            let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let scopedKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)

            backend.items[legacyKey] = legacyData
            backend.upsertOverrides[scopedKey] = errSecIO

            #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
                _ = try store.loadSnapshot()
            }
            let pendingPrefKey = "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).sync"
            #expect(procDefaults.string(forKey: pendingPrefKey) == legacyGroup)
            #expect(backend.items[legacyKey] == legacyData)

            backend.upsertOverrides.removeValue(forKey: scopedKey)
            let peerAcc = OTPAccount(issuer: "PeerItem", label: "b", secret: Data("222".utf8))
            let peerData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [peerAcc]))
            backend.items[scopedKey] = peerData

            let reloaded = try store.loadSnapshot()
            #expect(Set(reloaded?.accounts.map(\.issuer) ?? []) == ["LegacyOnly", "PeerItem"])
            #expect(backend.items[legacyKey] == nil)
            #expect(procDefaults.string(forKey: pendingPrefKey) == nil)
        }

        // Case 2: Interrupted delete followed by peer write to shared group merges both before deleting legacyGroup
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let legacyAcc = OTPAccount(issuer: "LegacyKept", label: "a", secret: Data("111".utf8))
            let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let scopedKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)

            backend.items[legacyKey] = legacyData
            backend.deleteOverrides[legacyKey] = errSecIO

            #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
                _ = try store.loadSnapshot()
            }
            let pendingPrefKey = "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).sync"
            #expect(procDefaults.string(forKey: pendingPrefKey) == legacyGroup)

            // Peer updates shared group without legacyAcc while delete was pending
            let peerAcc = OTPAccount(issuer: "PeerAdded", label: "b", secret: Data("222".utf8))
            backend.items[scopedKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [peerAcc]))
            backend.deleteOverrides.removeValue(forKey: legacyKey)

            let resumed = try store.loadSnapshot()
            let issuers = Set(resumed?.accounts.map(\.issuer) ?? [])
            #expect(issuers == ["LegacyKept", "PeerAdded"])
            #expect(backend.items[legacyKey] == nil)
            #expect(procDefaults.string(forKey: pendingPrefKey) == nil)
            let persistedScoped = try VaultSnapshotCoder.decode(from: #require(backend.items[scopedKey]))
            #expect(Set(persistedScoped.accounts.map(\.issuer)) == ["LegacyKept", "PeerAdded"])
        }

        // Case 3: Upsert failure followed by peer write then "Delete iCloud Copy" saves both locally and clears legacyGroup
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let legacyAcc = OTPAccount(issuer: "LegacyRetained", label: "a", secret: Data("111".utf8))
            let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let scopedKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)

            backend.items[legacyKey] = legacyData
            backend.upsertOverrides[scopedKey] = errSecIO
            #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
                _ = try store.loadSnapshot()
            }
            backend.upsertOverrides.removeValue(forKey: scopedKey)

            let peerAcc = OTPAccount(issuer: "PeerCloud", label: "b", secret: Data("222".utf8))
            backend.items[scopedKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [peerAcc]))

            let disabled = try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            #expect(Set(disabled?.accounts.map(\.issuer) ?? []) == ["LegacyRetained", "PeerCloud"])
            #expect(backend.items[legacyKey] == nil)
            let retiredCloud = try VaultSnapshotCoder.decode(from: #require(backend.items[scopedKey]))
            #expect(retiredCloud.accounts.isEmpty)
            #expect(retiredCloud.cloudRetiredAtMillis != nil)
            let persistedLocal = try VaultSnapshotCoder.decode(from: #require(backend.items[localKey]))
            #expect(Set(persistedLocal.accounts.map(\.issuer)) == ["LegacyRetained", "PeerCloud"])
        }

        // Case 4: Interrupted legacy delete followed by peer retirement saves legacy locally, keeps cloud retired/empty, and emits notice
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let legacyAcc = OTPAccount(issuer: "LegacyLocal", label: "a", secret: Data("111".utf8))
            let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let scopedKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)

            backend.items[legacyKey] = legacyData
            backend.deleteOverrides[legacyKey] = errSecIO
            #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
                _ = try store.loadSnapshot()
            }
            backend.deleteOverrides.removeValue(forKey: legacyKey)

            let retireMillis = Date().roundedEpochMillis + 100
            backend.items[scopedKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: retireMillis))

            let loaded = try store.loadSnapshot()
            #expect(loaded?.accounts.map(\.issuer) == ["LegacyLocal"])
            #expect(store.isICloudSyncEnabled() == false)
            #expect(backend.items[legacyKey] == nil)
            let cloudAfter = try VaultSnapshotCoder.decode(from: #require(backend.items[scopedKey]))
            #expect(cloudAfter.accounts.isEmpty)
            #expect(cloudAfter.cloudRetiredAtMillis == retireMillis)
            let localAfter = try VaultSnapshotCoder.decode(from: #require(backend.items[localKey]))
            #expect(localAfter.accounts.map(\.issuer) == ["LegacyLocal"])
            #expect(store.consumePendingPeerRetirementNotice() == true)
            #expect(store.consumePendingPeerRetirementNotice() == false)
        }
    }

    @Test("Cloud failure then local load then retry preserves newer peer cloud vault")
    func cloudFailureThenLoadThenRetryPreservesNewerPeerCloudVault() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let acc = OTPAccount(issuer: "GitLab", label: "ops", secret: Data("123".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

        // Cloud write fails while step is "cloud"
        backend.upsertOverrides[cloudKey] = errSecIO
        do {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            Issue.record("Expected cloudCleanupFailed error")
        } catch let error as KeychainVaultError {
            #expect(error == .cloudCleanupFailed(errSecIO))
        }
        #expect(defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) == "cloud")
        let retireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
        #expect(retireGen > 0)

        // Peer B explicitly re-enables sync with generation > retireGen
        backend.upsertOverrides.removeValue(forKey: cloudKey)
        backend.items[cloudKey] = try VaultSnapshotCoder.encode(
            OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: retireGen + 500)
        )

        // Local load detects peer re-enable and advances cleanup step away from cloud
        let loaded = try store.loadSnapshot()
        #expect(loaded?.accounts.count == 1)
        #expect(defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) == "replica")

        // Retrying cleanup must only remove local replica and leave Peer B's active cloud vault untouched
        let outcome = try store.retryPendingICloudCleanup()
        #expect(outcome == .localCleanupOnlyPeerSuperseded)
        #expect(backend.items[replicaKey] == nil)
        let preserved = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
        #expect(preserved.accounts.count == 1)
        #expect(preserved.cloudRetiredAtMillis == nil)
        #expect(preserved.cloudSyncGenerationMillis == retireGen + 500)
    }

    @Test("Cloud read error or corrupt item during retry fails closed and preserves peer cloud vault")
    func cloudReadErrorDuringRetryPreservesPeerCloudVault() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let group = backend.accessGroup!
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

        let acc = OTPAccount(issuer: "Linear", label: "me", secret: Data("123".utf8))
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

        let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
        backend.upsertOverrides[cloudKey] = errSecIO
        #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
        }
        backend.upsertOverrides.removeValue(forKey: cloudKey)

        let retireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
        let peerCloud = try VaultSnapshotCoder.encode(
            OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: retireGen + 1000)
        )
        backend.items[cloudKey] = peerCloud
        backend.readOverrides[cloudKey] = errSecIO

        #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
            _ = try store.retryPendingICloudCleanup()
        }
        #expect(backend.items[cloudKey] == peerCloud)

        // Corrupt/unreadable cloud bytes during retry must also preserve existing cloud item
        backend.readOverrides.removeValue(forKey: cloudKey)
        let badCloud = Data("corrupt-peer-cloud".utf8)
        backend.items[cloudKey] = badCloud
        #expect(throws: (any Error).self) {
            _ = try store.retryPendingICloudCleanup()
        }
        #expect(backend.items[cloudKey] == badCloud)
    }

    @Test("Round 4 legacy marker handles transient read errors, cloud write failures, and newer replica republish")
    func round4LegacyMarkerTransientErrorAndNewerReplicaOrdering() throws {
        // Case 1 & 2: Transient marker read error allows display but blocks mutation; failed replacement keeps marker
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let acc = OTPAccount(issuer: "LegacyR4", label: "a", secret: Data("111".utf8))
            let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
            let markerKey = backend.key(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true, accessGroup: group)

            backend.items[replicaKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [acc]))
            defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
            backend.readOverrides[markerKey] = errSecIO

            let displayed = try store.loadSnapshot()
            #expect(displayed?.accounts.count == 1)
            #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
                _ = try store.mutateSnapshot { $0.folders.append(OTPFolder(name: "Blocked")) }
            }

            // Clear read error, plant marker, and fail replacement cloud write -> loads locally, preserves marker + sets retry pending
            backend.readOverrides.removeValue(forKey: markerKey)
            let markerData = try VaultSnapshotCoder.encodeValue(["disabledAt": Date()])
            backend.items[markerKey] = markerData
            backend.upsertOverrides[cloudKey] = errSecIO

            let migrated = try store.loadSnapshot()
            #expect(migrated?.accounts.count == 1)
            #expect(store.isICloudSyncEnabled() == false)
            #expect(backend.items[markerKey] == markerData)
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == true)

            // Retry after clearing upsert override deletes replica and upgrades cloud retirement cleanly
            backend.upsertOverrides.removeValue(forKey: cloudKey)
            let outcome = try store.retryPendingICloudCleanup()
            #expect(outcome == .clearedCloudCopy)
            #expect(backend.items[replicaKey] == nil)
            #expect(backend.items[markerKey] == nil)
            let retiredCloud = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
            #expect(retiredCloud.accounts.isEmpty)
            #expect(retiredCloud.cloudRetiredAtMillis != nil)
        }

        // Case 3: Replica with cloudSyncGenerationMillis > marker.disabledAt republishes accounts and clears marker
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let acc = OTPAccount(issuer: "Republish", label: "b", secret: Data("222".utf8))
            let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
            let markerKey = backend.key(account: GlassOTPConstants.legacySyncMarkerAccount, synchronizable: true, accessGroup: group)

            let markerMillis = Date().roundedEpochMillis - 10_000
            backend.items[markerKey] = try VaultSnapshotCoder.encodeValue(["disabledAt": Date(timeIntervalSince1970: Double(markerMillis) / 1000.0)])
            backend.items[replicaKey] = try VaultSnapshotCoder.encode(
                OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: markerMillis + 5_000)
            )
            defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)

            let loaded = try store.loadSnapshot()
            #expect(loaded?.accounts.count == 1)
            #expect(store.isICloudSyncEnabled() == true)
            #expect(backend.items[markerKey] == nil)
            let republishedCloud = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
            #expect(republishedCloud.accounts.count == 1)
            #expect(republishedCloud.cloudRetiredAtMillis == nil)
        }
    }

    @Test("resolveAccountForCopy allows read-only TOTP copy with unreadable replica or lock contention while keeping HOTP fail-closed")
    func resolveAccountForCopyTOTPWorksWithUnreadableReplicaOrContendedLock() throws {
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
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: lockURL, lockTimeout: 0.05)

        let totpID = UUID()
        let hotpID = UUID()
        let totpAcc = OTPAccount(id: totpID, issuer: "TOTP", label: "t", secret: Data("111".utf8), type: .totp)
        let hotpAcc = OTPAccount(id: hotpID, issuer: "HOTP", label: "h", secret: Data("222".utf8), type: .hotp, counter: 3)
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [totpAcc, hotpAcc]))

        // Corrupt replica: TOTP resolves read-only without mutation; HOTP throws decodingFailed
        let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
        backend.items[replicaKey] = Data("corrupt-replica".utf8)

        let totpCorruptResult = try store.resolveAccountForCopy(accountID: totpID)
        #expect(totpCorruptResult.didMutate == false)
        #expect(totpCorruptResult.account?.id == totpID)

        #expect(throws: KeychainVaultError.decodingFailed) {
            _ = try store.resolveAccountForCopy(accountID: hotpID)
        }

        // Repair replica and hold lock: TOTP succeeds read-only; HOTP throws lockUnavailable
        backend.items[replicaKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [totpAcc, hotpAcc]))
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        let totpLockedResult = try store.resolveAccountForCopy(accountID: totpID)
        #expect(totpLockedResult.didMutate == false)
        #expect(totpLockedResult.account?.id == totpID)

        #expect(throws: KeychainVaultError.lockUnavailable) {
            _ = try store.resolveAccountForCopy(accountID: hotpID)
        }

        // Timed verification: even with a long lockTimeout (2.0s), TOTP copy does not wait for flock
        let timedStore = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: lockURL, lockTimeout: 2.0)
        let start = Date()
        let fastTotp = try timedStore.resolveAccountForCopy(accountID: totpID)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5)
        #expect(fastTotp.didMutate == false)
        #expect(fastTotp.account?.id == totpID)
        #expect(throws: KeychainVaultError.lockUnavailable) {
            _ = try timedStore.resolveAccountForCopy(accountID: hotpID)
        }
    }

    @Test("Superseded retry preserves cloudCleanupSupersededByPeerKey across failed re-enable, cleans pending legacy group, and surfaces unverified cloud status")
    func supersededRetryAndUnverifiedCloudOutcomes() throws {
        // Case 1: Superseded cloud cleanup failing on legacyGroup delete retains flag across failed re-enable and finishes both cleanups on retry
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let acc = OTPAccount(issuer: "ActiveCloud", label: "a", secret: Data("111".utf8))
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

            let legacyAcc = OTPAccount(issuer: "PendingLegacy", label: "l", secret: Data("222".utf8))
            let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
            let legacyKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let pendingPrefKey = "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).sync"

            backend.upsertOverrides[cloudKey] = errSecIO
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            }
            backend.upsertOverrides.removeValue(forKey: cloudKey)

            let retireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            #expect(retireGen > 0)

            // Simulate pending legacy group still requiring cleanup + peer re-enabling sync
            backend.items[legacyKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            procDefaults.set(legacyGroup, forKey: pendingPrefKey)
            backend.deleteOverrides[legacyKey] = errSecIO
            backend.items[cloudKey] = try VaultSnapshotCoder.encode(
                OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: retireGen + 500)
            )

            // Retry marks superseded, saves legacy into local, and throws on legacy delete before advancing to "replica"
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                _ = try store.retryPendingICloudCleanup()
            }
            #expect(defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey) == true)
            #expect(defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) == "cloud")

            // Failed re-enable must NOT wipe cloudCleanupSupersededByPeerKey
            backend.upsertOverrides[cloudKey] = errSecIO
            #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
                try store.setICloudSyncEnabled(true, removeOppositeBucket: true)
            }
            #expect(defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey) == true)

            // Clear overrides and retry -> cleans legacyKey + replica while preserving peer's active cloud vault
            backend.upsertOverrides.removeValue(forKey: cloudKey)
            backend.deleteOverrides.removeValue(forKey: legacyKey)
            let outcome = try store.retryPendingICloudCleanup()
            #expect(outcome == .localCleanupOnlyPeerSuperseded)
            #expect(backend.items[legacyKey] == nil)
            #expect(backend.items[replicaKey] == nil)
            #expect(procDefaults.string(forKey: pendingPrefKey) == nil)
            let preservedCloud = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
            #expect(preservedCloud.accounts.map(\.issuer) == ["ActiveCloud"])
            #expect(preservedCloud.cloudSyncGenerationMillis == retireGen + 500)
            let mergedLocal = try VaultSnapshotCoder.decode(from: #require(backend.items[localKey]))
            #expect(Set(mergedLocal.accounts.map(\.issuer)) == ["ActiveCloud", "PendingLegacy"])
        }

        // Case 2: Replica-only retry encountering transient cloud read error reports .localCleanupOnlyCloudUnverified
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let acc = OTPAccount(issuer: "Cloudflare", label: "u", secret: Data("333".utf8))
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

            let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

            backend.deleteOverrides[replicaKey] = errSecInteractionNotAllowed
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecInteractionNotAllowed)) {
                try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            }
            #expect(defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) == "replica")
            let retireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0

            backend.items[cloudKey] = try VaultSnapshotCoder.encode(
                OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: retireGen + 500)
            )
            backend.deleteOverrides.removeValue(forKey: replicaKey)
            backend.readOverrides[cloudKey] = errSecIO

            let outcome = try store.retryPendingICloudCleanup()
            #expect(outcome == .localCleanupOnlyCloudUnverified)
            #expect(backend.items[replicaKey] == nil)
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)
        }
    }
}
