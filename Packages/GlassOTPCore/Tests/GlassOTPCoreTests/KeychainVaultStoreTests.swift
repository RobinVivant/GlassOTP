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
    var reverseUnscopedOrder = false

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
                .sorted { reverseUnscopedOrder ? ($0.accessGroup > $1.accessGroup) : ($0.accessGroup < $1.accessGroup) }
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

    func readAll(account: String, synchronizable: Bool) -> (status: OSStatus, items: [(data: Data, actualAccessGroup: String?)]) {
        lock.withLock { () -> (status: OSStatus, items: [(data: Data, actualAccessGroup: String?)]) in
            let empty: [(data: Data, actualAccessGroup: String?)] = []
            let unscopedKey = key(account: account, synchronizable: synchronizable, accessGroup: nil)
            if let status = readOverrides[unscopedKey], status != errSecSuccess {
                return (status, empty)
            }
            let matches = items.keys
                .filter { $0.account == account && $0.synchronizable == synchronizable }
                .sorted { reverseUnscopedOrder ? ($0.accessGroup > $1.accessGroup) : ($0.accessGroup < $1.accessGroup) }
            var results: [(data: Data, actualAccessGroup: String?)] = []
            for match in matches {
                let reportedGroup = omitActualAccessGroupOnUnscopedRead ? nil : match.accessGroup
                if let status = readOverrides[match] {
                    if status == errSecSuccess, let data = items[match] {
                        results.append((data, reportedGroup))
                    } else {
                        return (status, empty)
                    }
                } else if let data = items[match] {
                    results.append((data, reportedGroup))
                }
            }
            if results.isEmpty {
                return (errSecItemNotFound, empty)
            }
            return (errSecSuccess, results)
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
        #expect(throws: KeychainVaultError.unreadableLocalReplica) {
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
        #expect(throws: KeychainVaultError.unreadableCloudVault) {
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

        #expect(throws: KeychainVaultError.unreadableLocalReplica) {
            try store.setICloudSyncEnabled(true, removeOppositeBucket: true)
        }
        #expect(backend.items[replicaKey] == badReplica)
        #expect(backend.items[cloudKey] == retiredCloudData)
        #expect(store.isICloudSyncEnabled() == false)

        // Case 3: Remote cloud retirement when no local copy exists and replica is unreadable must fail closed and preserve replica
        defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        backend.items[cloudKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))
        #expect(throws: KeychainVaultError.unreadableLocalReplica) {
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

        #expect(throws: KeychainVaultError.unreadableCloudVault) {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
        }
        #expect(store.isICloudSyncEnabled() == true)
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)
        #expect(backend.items[localKey] == nil)

        let keptRecovery = try store.setICloudSyncEnabled(false, removeOppositeBucket: false)
        #expect(keptRecovery?.accounts.map(\.issuer) == ["ReadableReplica"])
        #expect(store.isICloudSyncEnabled() == false)
        #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == false)

        // Case 5: Corrupt replica + no cloud/local fails "Turn Off & Delete" with .unreadableLocalReplica
        backend.items.removeValue(forKey: cloudKey)
        backend.items.removeValue(forKey: localKey)
        backend.items[replicaKey] = badReplica
        defaults.set(true, forKey: GlassOTPConstants.iCloudSyncPreferenceKey)
        #expect(throws: KeychainVaultError.unreadableLocalReplica) {
            try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
        }
        #expect(backend.items[replicaKey] == badReplica)
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

        #expect(throws: KeychainVaultError.unreadableLocalReplica) {
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

            // Retry marks superseded, advances step past cloud, saves legacy into local, and throws on legacy delete
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                _ = try store.retryPendingICloudCleanup()
            }
            #expect(defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey) == true)
            #expect(defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) == "replica")

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

    @Test("Corrupt replica with readable cloud or local vault quarantines bad bytes into content-addressed slots and recovers via off-then-on sync toggle")
    func corruptReplicaWithActiveCloudRecoversViaOffAndOnWithQuarantine() throws {
        for removeOpposite in [false, true] {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let acc = OTPAccount(issuer: "ActiveCloud", label: "a", secret: Data("111".utf8))
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
            let badReplica1 = Data("corrupt-replica-bytes-one".utf8)
            backend.items[replicaKey] = badReplica1

            #expect(throws: KeychainVaultError.unreadableLocalReplica) {
                _ = try store.mutateSnapshot { $0.folders.append(OTPFolder(name: "Fail")) }
            }

            let disabled = try store.setICloudSyncEnabled(false, removeOppositeBucket: removeOpposite)
            #expect(disabled?.accounts.map(\.issuer) == ["ActiveCloud"])
            if removeOpposite {
                #expect(try store.retryPendingICloudCleanup() == .nothingPending)
            }

            let reenabled = try store.setICloudSyncEnabled(true, removeOppositeBucket: true)
            #expect(reenabled?.accounts.map(\.issuer) == ["ActiveCloud"])
            let accountsList1 = defaults.stringArray(forKey: GlassOTPConstants.quarantinedReplicaAccountsKey) ?? []
            #expect(accountsList1.count == 1)
            let slot1Account = try #require(accountsList1.first)
            #expect(slot1Account.hasPrefix(GlassOTPConstants.keychainLocalReplicaQuarantinePrefix))
            let slot1Key = backend.key(account: slot1Account, synchronizable: false, accessGroup: group)
            #expect(backend.items[slot1Key] == badReplica1)
            let rebuiltReplica = try VaultSnapshotCoder.decode(from: #require(backend.items[replicaKey]))
            #expect(rebuiltReplica.accounts.map(\.issuer) == ["ActiveCloud"])

            // Second recovery with IDENTICAL corrupt bytes reuses slot 1 without duplicating entries
            backend.items[replicaKey] = badReplica1
            _ = try store.setICloudSyncEnabled(false, removeOppositeBucket: removeOpposite)
            _ = try store.setICloudSyncEnabled(true, removeOppositeBucket: true)
            #expect(defaults.stringArray(forKey: GlassOTPConstants.quarantinedReplicaAccountsKey) == [slot1Account])

            // Third recovery with DISTINCT corrupt bytes creates a second slot and preserves slot 1
            let badReplica2 = Data("corrupt-replica-bytes-two".utf8)
            backend.items[replicaKey] = badReplica2
            _ = try store.setICloudSyncEnabled(false, removeOppositeBucket: removeOpposite)
            _ = try store.setICloudSyncEnabled(true, removeOppositeBucket: true)
            let accountsList2 = defaults.stringArray(forKey: GlassOTPConstants.quarantinedReplicaAccountsKey) ?? []
            #expect(accountsList2.count == 2)
            #expect(backend.items[slot1Key] == badReplica1)
            let slot2Key = backend.key(account: accountsList2[1], synchronizable: false, accessGroup: group)
            #expect(backend.items[slot2Key] == badReplica2)

            let mutated = try store.mutateSnapshot { $0.folders.append(OTPFolder(name: "Recovered")) }
            #expect(mutated.folders.map(\.name) == ["Recovered"])
        }
    }

    @Test("Widget-first retirement and widget peer observation still recover legacy cloud and device-only accounts on main-app load")
    func widgetFirstRetirementAndCrossProcessSupersededCleanupRecoverLegacyCloud() throws {
        // Case 1: Widget processes retirement first when main app has pending legacy cloud AND unmigrated legacy device-only accounts
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (mainProcDefaults, mainProcSuite) = makeIsolatedDefaults()
            let (widgetProcDefaults, widgetProcSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                mainProcDefaults.removePersistentDomain(forName: mainProcSuite)
                widgetProcDefaults.removePersistentDomain(forName: widgetProcSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let lockURL = makeLockURL()
            defer { try? FileManager.default.removeItem(at: lockURL) }

            let mainStore = KeychainVaultStore(defaults: defaults, processDefaults: mainProcDefaults, backend: backend, isAppExtension: false, lockFileURL: lockURL)
            let widgetStore = KeychainVaultStore(defaults: defaults, processDefaults: widgetProcDefaults, backend: backend, isAppExtension: true, lockFileURL: lockURL)

            let legacyCloudAcc = OTPAccount(issuer: "LegacyCloud", label: "c", secret: Data("111".utf8))
            let legacyLocalAcc = OTPAccount(issuer: "LegacyLocalOnly", label: "l", secret: Data("222".utf8))
            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let legacyLocalKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: legacyGroup)
            let scopedSyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)

            backend.items[legacySyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyCloudAcc]))
            backend.items[legacyLocalKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyLocalAcc]))
            backend.upsertOverrides[scopedSyncKey] = errSecIO
            #expect(throws: KeychainVaultError.unexpectedStatus(errSecIO)) {
                _ = try mainStore.loadSnapshot()
            }
            backend.upsertOverrides.removeValue(forKey: scopedSyncKey)

            // Peer retires shared cloud before main app reloads, and widget loads first
            backend.items[scopedSyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))
            #expect(try widgetStore.loadSnapshot() == nil)
            #expect(widgetStore.isICloudSyncEnabled() == false)
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey) == true)

            // Main app reopens -> recovers BOTH legacy cloud and legacy local-only accounts and clears both legacy items
            let recovered = try mainStore.loadSnapshot()
            #expect(Set(recovered?.accounts.map(\OTPAccount.issuer) ?? []) == ["LegacyCloud", "LegacyLocalOnly"])
            #expect(backend.items[legacySyncKey] == nil)
            #expect(backend.items[legacyLocalKey] == nil)
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey) == false)

            let reloadedAgain = try mainStore.loadSnapshot()
            #expect(Set(reloadedAgain?.accounts.map(\OTPAccount.issuer) ?? []) == ["LegacyCloud", "LegacyLocalOnly"])
        }

        // Case 2: Widget observing peer re-enable must not skip main-app pending legacyGroup cleanup on retry
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (mainProcDefaults, mainProcSuite) = makeIsolatedDefaults()
            let (widgetProcDefaults, widgetProcSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                mainProcDefaults.removePersistentDomain(forName: mainProcSuite)
                widgetProcDefaults.removePersistentDomain(forName: widgetProcSuite)
            }

            let backend = InMemoryKeychainBackend()
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let lockURL = makeLockURL()
            defer { try? FileManager.default.removeItem(at: lockURL) }

            let mainStore = KeychainVaultStore(defaults: defaults, processDefaults: mainProcDefaults, backend: backend, isAppExtension: false, lockFileURL: lockURL)
            let widgetStore = KeychainVaultStore(defaults: defaults, processDefaults: widgetProcDefaults, backend: backend, isAppExtension: true, lockFileURL: lockURL)

            let acc = OTPAccount(issuer: "Active", label: "a", secret: Data("111".utf8))
            try mainStore.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

            let scopedSyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
            let pendingPrefKey = "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).sync"

            backend.upsertOverrides[scopedSyncKey] = errSecIO
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                try mainStore.setICloudSyncEnabled(false, removeOppositeBucket: true)
            }
            backend.upsertOverrides.removeValue(forKey: scopedSyncKey)

            let retireGen = (defaults.object(forKey: GlassOTPConstants.lastCloudRetirementGenerationKey) as? NSNumber)?.int64Value ?? 0
            let legacyAcc = OTPAccount(issuer: "LegacyPending", label: "l", secret: Data("222".utf8))
            backend.items[legacySyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            mainProcDefaults.set(legacyGroup, forKey: pendingPrefKey)

            backend.items[scopedSyncKey] = try VaultSnapshotCoder.encode(
                OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: retireGen + 500)
            )

            // Widget loads and detects peer re-enable -> step stays "cloud" and superseded flag is set
            _ = try widgetStore.loadSnapshot()
            #expect(defaults.bool(forKey: GlassOTPConstants.cloudCleanupSupersededByPeerKey) == true)
            #expect(defaults.string(forKey: GlassOTPConstants.pendingCloudRetirementStepKey) == "cloud")

            // Main app retry cleans up pendingLegacyGroup and preserves peer cloud vault
            let outcome = try mainStore.retryPendingICloudCleanup()
            #expect(outcome == .localCleanupOnlyPeerSuperseded)
            #expect(backend.items[legacySyncKey] == nil)
            #expect(mainProcDefaults.string(forKey: pendingPrefKey) == nil)
            let savedLocal = try VaultSnapshotCoder.decode(from: #require(backend.items[localKey]))
            #expect(Set(savedLocal.accounts.map(\.issuer)) == ["Active", "LegacyPending"])
        }

        // Case 3: Widget-first retirement with pendingKey UNSET and shared retired record sorting first
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (mainProcDefaults, mainProcSuite) = makeIsolatedDefaults()
            let (widgetProcDefaults, widgetProcSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                mainProcDefaults.removePersistentDomain(forName: mainProcSuite)
                widgetProcDefaults.removePersistentDomain(forName: widgetProcSuite)
            }

            let backend = InMemoryKeychainBackend()
            backend.reverseUnscopedOrder = true
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let lockURL = makeLockURL()
            defer { try? FileManager.default.removeItem(at: lockURL) }

            let mainStore = KeychainVaultStore(defaults: defaults, processDefaults: mainProcDefaults, backend: backend, isAppExtension: false, lockFileURL: lockURL)
            let widgetStore = KeychainVaultStore(defaults: defaults, processDefaults: widgetProcDefaults, backend: backend, isAppExtension: true, lockFileURL: lockURL)

            let legacyAcc = OTPAccount(issuer: "OrderShadowedLegacy", label: "s", secret: Data("111".utf8))
            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let scopedSyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)

            backend.items[legacySyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            backend.items[scopedSyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))

            #expect(try widgetStore.loadSnapshot() == nil)
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey) == true)

            let recovered = try mainStore.loadSnapshot()
            #expect(recovered?.accounts.map(\.issuer) == ["OrderShadowedLegacy"])
            #expect(backend.items[legacySyncKey] == nil)
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingMainAppLegacyRetirementRecoveryKey) == false)
        }

        // Case 4: Widget has readable replica (writes shared local primary on retirement) while unmigrated legacy device-only account exists
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (mainProcDefaults, mainProcSuite) = makeIsolatedDefaults()
            let (widgetProcDefaults, widgetProcSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                mainProcDefaults.removePersistentDomain(forName: mainProcSuite)
                widgetProcDefaults.removePersistentDomain(forName: widgetProcSuite)
            }

            let backend = InMemoryKeychainBackend()
            backend.reverseUnscopedOrder = true
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let lockURL = makeLockURL()
            defer { try? FileManager.default.removeItem(at: lockURL) }

            let mainStore = KeychainVaultStore(defaults: defaults, processDefaults: mainProcDefaults, backend: backend, isAppExtension: false, lockFileURL: lockURL)
            let widgetStore = KeychainVaultStore(defaults: defaults, processDefaults: widgetProcDefaults, backend: backend, isAppExtension: true, lockFileURL: lockURL)

            let replicaAcc = OTPAccount(issuer: "ReplicaActive", label: "r", secret: Data("111".utf8))
            let legacyLocalAcc = OTPAccount(issuer: "LegacyLocalWithReplica", label: "l", secret: Data("222".utf8))
            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
            let scopedSyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let legacyLocalKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: legacyGroup)
            let sharedLocalKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)

            backend.items[replicaKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [replicaAcc]))
            backend.items[scopedSyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(cloudRetiredAtMillis: Date().roundedEpochMillis))
            backend.items[legacyLocalKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyLocalAcc]))

            let widgetLoaded = try widgetStore.loadSnapshot()
            #expect(widgetLoaded?.accounts.map(\.issuer) == ["ReplicaActive"])
            #expect(backend.items[sharedLocalKey] != nil)

            let recovered = try mainStore.loadSnapshot()
            #expect(Set(recovered?.accounts.map(\OTPAccount.issuer) ?? []) == ["ReplicaActive", "LegacyLocalWithReplica"])
            #expect(backend.items[legacyLocalKey] == nil)

            let reloadedAgain = try mainStore.loadSnapshot()
            #expect(Set(reloadedAgain?.accounts.map(\OTPAccount.issuer) ?? []) == ["ReplicaActive", "LegacyLocalWithReplica"])
        }

        // Case 5: Main-app-first load when shared group already holds active peer vault AND legacy group exists
        do {
            let (defaults, suite) = makeIsolatedDefaults()
            let (procDefaults, procSuite) = makeIsolatedDefaults()
            defer {
                defaults.removePersistentDomain(forName: suite)
                procDefaults.removePersistentDomain(forName: procSuite)
            }

            let backend = InMemoryKeychainBackend()
            backend.reverseUnscopedOrder = true
            let group = backend.accessGroup!
            let legacyGroup = "TEAMID.com.robinvivant.glassotp"
            let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: makeLockURL())

            let peerAcc = OTPAccount(issuer: "ActivePeer", label: "p", secret: Data("111".utf8))
            let legacyAcc = OTPAccount(issuer: "LegacyUntouched", label: "l", secret: Data("222".utf8))
            let scopedSyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)

            backend.items[scopedSyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [peerAcc]))
            backend.items[legacySyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))

            let merged = try store.loadSnapshot()
            #expect(Set(merged?.accounts.map(\OTPAccount.issuer) ?? []) == ["ActivePeer", "LegacyUntouched"])
            #expect(backend.items[legacySyncKey] == nil)
        }
    }

    @Test("Turning off sync with Keep iCloud Copy preserves legacy cloud across subsequent local loads, edits, and corrupt legacy cloud items")
    func setICloudSyncEnabledOffWithPendingLegacyDoesNotMutateOrFailOnCorruptCloud() throws {
        // Case 1: Readable legacy sync item stays intact in iCloud across Keep Copy -> loadSnapshot -> mutateSnapshot
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

            let scopedSyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
            let pendingPrefKey = "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).sync"

            let badCloud = Data("corrupt-shared-cloud".utf8)
            let legacyAcc = OTPAccount(issuer: "LegacySync", label: "s", secret: Data("999".utf8))
            let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            backend.items[scopedSyncKey] = badCloud
            backend.items[legacySyncKey] = legacyData
            procDefaults.set(legacyGroup, forKey: pendingPrefKey)

            let kept = try store.setICloudSyncEnabled(false, removeOppositeBucket: false)
            #expect(kept?.accounts.map(\.issuer) == ["LegacySync"])
            #expect(store.isICloudSyncEnabled() == false)
            #expect(backend.items[scopedSyncKey] == badCloud)
            #expect(backend.items[legacySyncKey] == legacyData)

            // Subsequent local loads and edits must NOT delete the kept legacy cloud item
            let reloadedLocal = try store.loadSnapshot()
            #expect(reloadedLocal?.accounts.map(\.issuer) == ["LegacySync"])
            #expect(backend.items[legacySyncKey] == legacyData)

            let edited = try store.mutateSnapshot { $0.folders.append(OTPFolder(name: "LocalOnly")) }
            #expect(edited.folders.map(\.name) == ["LocalOnly"])
            #expect(backend.items[legacySyncKey] == legacyData)
            let persistedLocal = try VaultSnapshotCoder.decode(from: #require(backend.items[localKey]))
            #expect(persistedLocal.accounts.map(\.issuer) == ["LegacySync"])
        }

        // Case 2: Corrupt legacy sync item + readable local -> Keep Copy -> subsequent local load/edit still succeed
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

            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
            let pendingPrefKey = "\(GlassOTPConstants.pendingLegacyMigrationKeyPrefix).\(group).sync"
            let localAcc = OTPAccount(issuer: "LocalPrimary", label: "u", secret: Data("111".utf8))
            let badLegacyCloud = Data("corrupt-legacy-cloud".utf8)

            backend.items[localKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [localAcc]))
            backend.items[legacySyncKey] = badLegacyCloud
            procDefaults.set(legacyGroup, forKey: pendingPrefKey)

            let kept = try store.setICloudSyncEnabled(false, removeOppositeBucket: false)
            #expect(kept?.accounts.map(\.issuer) == ["LocalPrimary"])
            let reloaded = try store.loadSnapshot()
            #expect(reloaded?.accounts.map(\.issuer) == ["LocalPrimary"])
            let mutated = try store.mutateSnapshot { $0.folders.append(OTPFolder(name: "WorksOffline")) }
            #expect(mutated.folders.map(\.name) == ["WorksOffline"])
            #expect(backend.items[legacySyncKey] == badLegacyCloud)
        }
    }

    @Test("Disabling sync before prior legacy discovery completes discovers legacy sync account for Keep Copy and Delete Copy")
    func disableSyncBeforePriorLoadDiscoversAndHandlesLegacySync() throws {
        // Variant A: Keep iCloud Copy discovers legacy sync item locally without deleting it from iCloud
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

            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
            let legacyAcc = OTPAccount(issuer: "UndiscoveredLegacy", label: "u", secret: Data("123".utf8))
            let legacyData = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            backend.items[legacySyncKey] = legacyData

            let kept = try store.setICloudSyncEnabled(false, removeOppositeBucket: false)
            #expect(kept?.accounts.map(\.issuer) == ["UndiscoveredLegacy"])
            #expect(backend.items[legacySyncKey] == legacyData)
            let savedLocal = try VaultSnapshotCoder.decode(from: #require(backend.items[localKey]))
            #expect(savedLocal.accounts.map(\.issuer) == ["UndiscoveredLegacy"])
        }

        // Variant B: Delete iCloud Copy discovers legacy sync item, saves locally, and tracks deletion through retry completion
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

            let scopedSyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let legacySyncKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: legacyGroup)
            let localKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: false, accessGroup: group)
            let legacyAcc = OTPAccount(issuer: "DeleteLegacyOnDisable", label: "d", secret: Data("456".utf8))
            backend.items[legacySyncKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [legacyAcc]))
            backend.deleteOverrides[legacySyncKey] = errSecIO

            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            }
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == true)
            #expect(try store.loadSnapshot()?.accounts.map(\.issuer) == ["DeleteLegacyOnDisable"])
            #expect(backend.items[localKey] != nil)

            backend.deleteOverrides.removeValue(forKey: legacySyncKey)
            let retryOutcome = try store.retryPendingICloudCleanup()
            #expect(retryOutcome == .clearedCloudCopy)
            #expect(backend.items[legacySyncKey] == nil)
            let retiredCloud = try VaultSnapshotCoder.decode(from: #require(backend.items[scopedSyncKey]))
            #expect(retiredCloud.accounts.isEmpty)
            #expect(retiredCloud.cloudRetiredAtMillis != nil)
        }
    }

    @Test("Replica cleanup fails closed on transient replica read error, re-retires stale peer overwrites, and maps corrupt cloud error during retry")
    func replicaCleanupHandlesTransientReadErrorAndStalePeerOverwrite() throws {
        // Case 1: Transient replica read error must not authorize deleting unreadable replica bytes
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

            let acc = OTPAccount(issuer: "GitHub", label: "u", secret: Data("111".utf8))
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

            let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)
            let badReplica = Data("corrupt-replica".utf8)

            backend.upsertOverrides[cloudKey] = errSecIO
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            }
            backend.upsertOverrides.removeValue(forKey: cloudKey)
            backend.items[replicaKey] = badReplica
            backend.readOverrides[replicaKey] = errSecIO

            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                _ = try store.retryPendingICloudCleanup()
            }
            #expect(backend.items[replicaKey] == badReplica)
            #expect(defaults.bool(forKey: GlassOTPConstants.pendingICloudDeletePreferenceKey) == true)

            backend.readOverrides.removeValue(forKey: replicaKey)
            let outcome = try store.retryPendingICloudCleanup()
            #expect(outcome == .clearedCloudCopy)
            #expect(backend.items[replicaKey] == badReplica)
        }

        // Case 2: Replica-step retry observing stale active peer vault (generation nil or <= savedGen) re-retires immediately
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

            let acc = OTPAccount(issuer: "StalePeer", label: "p", secret: Data("222".utf8))
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

            let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            let replicaKey = backend.key(account: GlassOTPConstants.keychainLocalReplicaAccount, synchronizable: false, accessGroup: group)

            backend.deleteOverrides[replicaKey] = errSecInteractionNotAllowed
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecInteractionNotAllowed)) {
                try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            }
            backend.deleteOverrides.removeValue(forKey: replicaKey)

            // Stale peer overwrites cloud with active vault (nil generation)
            backend.items[cloudKey] = try VaultSnapshotCoder.encode(OTPVaultSnapshot(accounts: [acc], cloudSyncGenerationMillis: nil))

            let outcome = try store.retryPendingICloudCleanup()
            #expect(outcome == .clearedCloudCopy)
            let reRetired = try VaultSnapshotCoder.decode(from: #require(backend.items[cloudKey]))
            #expect(reRetired.accounts.isEmpty)
            #expect(reRetired.cloudRetiredAtMillis != nil)
        }

        // Case 3: Retry at "cloud" step against undecodable cloud item maps to .unreadableCloudVaultDuringCleanup
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

            let acc = OTPAccount(issuer: "PeerCorrupt", label: "c", secret: Data("333".utf8))
            try store.saveSnapshot(OTPVaultSnapshot(accounts: [acc]))

            let cloudKey = backend.key(account: GlassOTPConstants.keychainAccount, synchronizable: true, accessGroup: group)
            backend.upsertOverrides[cloudKey] = errSecIO
            #expect(throws: KeychainVaultError.cloudCleanupFailed(errSecIO)) {
                try store.setICloudSyncEnabled(false, removeOppositeBucket: true)
            }
            backend.upsertOverrides.removeValue(forKey: cloudKey)
            backend.items[cloudKey] = Data("future-schema-cloud".utf8)

            #expect(throws: KeychainVaultError.unreadableCloudVaultDuringCleanup) {
                _ = try store.retryPendingICloudCleanup()
            }
        }
    }

    @Test("TOTP copy does not wait behind in-process NSLock contention when another thread waits on flock")
    func nonBlockingTOTPCopyDoesNotWaitOnInProcessNSLockContention() throws {
        let (defaults, suite) = makeIsolatedDefaults()
        let (procDefaults, procSuite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            procDefaults.removePersistentDomain(forName: procSuite)
        }

        let backend = InMemoryKeychainBackend()
        let lockURL = makeLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL) }
        let store = KeychainVaultStore(defaults: defaults, processDefaults: procDefaults, backend: backend, lockFileURL: lockURL, lockTimeout: 2.0)

        let totpID = UUID()
        let totpAcc = OTPAccount(id: totpID, issuer: "FastTOTP", label: "f", secret: Data("111".utf8), type: .totp)
        try store.saveSnapshot(OTPVaultSnapshot(accounts: [totpAcc]))

        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        var lockReleased = false
        defer {
            if !lockReleased {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
        }

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            _ = try? store.loadSnapshot()
            finished.signal()
        }
        started.wait()
        usleep(80_000)

        let copyStart = Date()
        let result = try store.resolveAccountForCopy(accountID: totpID)
        _ = store.isICloudSyncEnabled()
        _ = store.consumePendingPeerRetirementNotice(nonBlocking: true)
        let copyElapsed = Date().timeIntervalSince(copyStart)
        #expect(copyElapsed < 0.5)
        #expect(result.didMutate == false)
        #expect(result.account?.id == totpID)

        _ = flock(fd, LOCK_UN)
        close(fd)
        lockReleased = true
        finished.wait()
    }
}
