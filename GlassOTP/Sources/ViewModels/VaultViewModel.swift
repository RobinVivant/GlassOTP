import Foundation
import GlassOTPCore
import Observation
import SwiftUI
import UIKit
import WidgetKit

struct CopiedToast: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let formattedCode: String
}

struct PendingImportFile: Identifiable {
    let id = UUID()
    let filename: String
    let data: Data
}

@MainActor
@Observable
final class VaultViewModel {
    var folders: [OTPFolder] = [] {
        didSet { rebuildFolderLookup() }
    }
    var accounts: [OTPAccount] = [] {
        didSet { rebuildPinnedAccounts() }
    }
    private(set) var pinnedAccounts: [OTPAccount] = []
    @ObservationIgnored private var folderNamesByID: [UUID: String] = [:]
    var selectedFolderID: UUID?
    var searchText: String = ""

    var copiedToast: CopiedToast?
    var pendingImportFile: PendingImportFile?
    var pendingURIAccounts: [OTPAccount]?
    var alertMessage: String?

    var showingImportSheet = false
    var showingScannerSheet = false
    var showingNewAccountSheet = false
    var showingAutoCategorizeSheet = false
    var editingAccount: OTPAccount?
    var qrDetailAccount: OTPAccount?
    var brandPickerAccount: OTPAccount?
    var logoCacheRevision: Int = 0

    var dismissedAutoCategorizeBanner: Bool {
        didSet {
            UserDefaults.standard.set(dismissedAutoCategorizeBanner, forKey: Self.dismissBannerKey)
        }
    }

    private(set) var iCloudSyncEnabled: Bool
    private(set) var hasPendingICloudCleanup: Bool
    private(set) var hasLoadError = false

    var hideCodesInApp: Bool {
        didSet {
            UserDefaults.standard.set(hideCodesInApp, forKey: Self.hideCodesKey)
        }
    }

    var universalClipboardEnabled: Bool {
        didSet {
            SharedClipboardPreferences.isUniversalClipboardEnabled = universalClipboardEnabled
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    var revealedAccountIDs: Set<UUID> = []

    private let store: KeychainVaultStore
    private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var pendingForegroundCopyCode: String?
    @ObservationIgnored private var pendingIncomingURL: URL?
    @ObservationIgnored private var accountTombstones: [OTPTombstone] = []
    @ObservationIgnored private var folderTombstones: [OTPTombstone] = []
    @ObservationIgnored private var hasCompletedInitialLoad = false
    private static let hideCodesKey = "glassotp.hideCodesInApp"
    private static let dismissBannerKey = "glassotp.dismissAutoCategorizeBanner"

    init(store: KeychainVaultStore = .shared) {
        self.store = store
        self.iCloudSyncEnabled = store.isICloudSyncEnabled()
        self.hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
        self.hideCodesInApp = UserDefaults.standard.bool(forKey: Self.hideCodesKey)
        self.universalClipboardEnabled = SharedClipboardPreferences.isUniversalClipboardEnabled
        self.dismissedAutoCategorizeBanner = UserDefaults.standard.bool(forKey: Self.dismissBannerKey)
        reloadFromStore()
    }

    private func rebuildFolderLookup() {
        var map: [UUID: String] = [:]
        map.reserveCapacity(folders.count)
        for folder in folders {
            map[folder.id] = folder.name
        }
        folderNamesByID = map
    }

    private func rebuildPinnedAccounts() {
        pinnedAccounts = accounts.filter(\.isPinned)
    }

    var shouldSuggestAutoCategorize: Bool {
        guard !accounts.isEmpty, !dismissedAutoCategorizeBanner else { return false }
        return AccountCategorizer.hasUncategorizedOrDefaultOnly(accounts: accounts, folders: folders)
    }

    var filteredAccounts: [OTPAccount] {
        accounts.filter { account in
            let matchesFolder = selectedFolderID == nil || account.folderID == selectedFolderID
            guard matchesFolder else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return account.issuer.localizedCaseInsensitiveContains(query)
                || account.label.localizedCaseInsensitiveContains(query)
        }
    }

    func searchResults(for query: String) -> [OTPAccount] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return accounts }
        return accounts.filter {
            $0.issuer.localizedCaseInsensitiveContains(trimmed)
                || $0.label.localizedCaseInsensitiveContains(trimmed)
                || folderName(for: $0.folderID)?.localizedCaseInsensitiveContains(trimmed) == true
        }
    }

    func folderName(for id: UUID?) -> String? {
        id.flatMap { folderNamesByID[$0] }
    }

    func accountsCount(in folderID: UUID) -> Int {
        accounts.filter { $0.folderID == folderID }.count
    }

    private func applySnapshotToMemory(_ snapshot: OTPVaultSnapshot) {
        iCloudSyncEnabled = store.isICloudSyncEnabled()
        let sortedFolders = snapshot.folders.sorted { $0.sortOrder < $1.sortOrder }
        let sortedAccounts = snapshot.accounts.sorted { $0.sortOrder < $1.sortOrder }
        if folders != sortedFolders {
            folders = sortedFolders
        }
        if accounts != sortedAccounts {
            accounts = sortedAccounts
        }
        accountTombstones = snapshot.accountTombstones
        folderTombstones = snapshot.folderTombstones
        if let selectedFolderID, !sortedFolders.contains(where: { $0.id == selectedFolderID }) {
            self.selectedFolderID = nil
        }
        hasLoadError = false
        hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
    }

    func reloadFromStore() {
        let prevFolders = folders
        let prevAccounts = accounts
        let prevSync = iCloudSyncEnabled
        defer { hasCompletedInitialLoad = true }

        do {
            iCloudSyncEnabled = store.isICloudSyncEnabled()
            hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
            if let snapshot = try store.loadSnapshot() {
                iCloudSyncEnabled = store.isICloudSyncEnabled()
                applySnapshotToMemory(snapshot)
            } else {
                iCloudSyncEnabled = store.isICloudSyncEnabled()
                if !folders.isEmpty { folders = [] }
                if !accounts.isEmpty { accounts = [] }
                accountTombstones = []
                folderTombstones = []
                selectedFolderID = nil
                hasLoadError = false
            }
            if hasCompletedInitialLoad
                && (folders != prevFolders || accounts != prevAccounts || iCloudSyncEnabled != prevSync) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            hasLoadError = true
            hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
            alertMessage = error.localizedDescription
        }
    }

    func updateICloudSync(enabled: Bool, removeFromICloud: Bool = true) {
        do {
            let migrated = try store.setICloudSyncEnabled(enabled, removeOppositeBucket: removeFromICloud)
            iCloudSyncEnabled = store.isICloudSyncEnabled()
            hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
            if let migrated {
                applySnapshotToMemory(migrated)
            }
            hasLoadError = false
            WidgetCenter.shared.reloadAllTimelines()
        } catch let error as KeychainVaultError {
            iCloudSyncEnabled = store.isICloudSyncEnabled()
            hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
            if case .cloudCleanupFailed = error {
                reloadFromStore()
                WidgetCenter.shared.reloadAllTimelines()
            }
            alertMessage = error.localizedDescription
        } catch {
            iCloudSyncEnabled = store.isICloudSyncEnabled()
            hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
            alertMessage = error.localizedDescription
        }
    }

    func retryPendingICloudCleanup() {
        do {
            let cleaned = try store.retryPendingICloudCleanup()
            hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
            if cleaned {
                alertMessage = "Deleted the leftover iCloud Keychain copy."
            }
        } catch {
            hasPendingICloudCleanup = SharedSecurityPreferences.hasPendingICloudCleanup
            alertMessage = error.localizedDescription
        }
    }

    @discardableResult
    func persist() -> Bool {
        guard !hasLoadError else {
            alertMessage = "Cannot save changes because the existing Keychain vault could not be loaded."
            return false
        }
        let snapshot = OTPVaultSnapshot(
            schemaVersion: 1,
            folders: folders,
            accounts: accounts,
            updatedAt: Date(),
            accountTombstones: accountTombstones,
            folderTombstones: folderTombstones
        )
        do {
            let merged = try store.saveMergedSnapshot(snapshot)
            applySnapshotToMemory(merged)
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func commitPendingForegroundCopyIfNeeded() {
        guard let pending = pendingForegroundCopyCode else { return }
        pendingForegroundCopyCode = nil
        OTPClipboardWriter.copyOTP(pending)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    func copyCode(for account: OTPAccount, at date: Date? = nil, reloadWidgets: Bool = false) {
        guard !hasLoadError else {
            alertMessage = "Cannot copy codes because the existing Keychain vault could not be loaded."
            return
        }

        let store = self.store
        let accountID = account.id
        Task { @MainActor in
            var resolvedAccount: OTPAccount?
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { () -> (updated: OTPVaultSnapshot?, resolved: OTPAccount?) in
                    var resolved: OTPAccount?
                    let updated = try store.mutateSnapshotIfPresent { snapshot in
                        guard let idx = snapshot.accounts.firstIndex(where: { $0.id == accountID }) else {
                            return false
                        }
                        let current = snapshot.accounts[idx]
                        resolved = current
                        guard current.isSupportedAlgorithm, current.type == .hotp else {
                            return false
                        }
                        snapshot.accounts[idx].counter &+= 1
                        snapshot.accounts[idx].updatedAt = Date.monotonicTimestamp(after: current.updatedAt, now: date ?? Date())
                        return true
                    }
                    return (updated, resolved)
                }.value

                resolvedAccount = outcome.resolved
                if let updatedSnapshot = outcome.updated {
                    applySnapshotToMemory(updatedSnapshot)
                } else {
                    reloadFromStore()
                    alertMessage = "That account is no longer in your vault."
                    return
                }
            } catch {
                alertMessage = error.localizedDescription
                return
            }

            guard let effectiveAccount = resolvedAccount else {
                alertMessage = "That account is no longer in your vault."
                return
            }
            guard effectiveAccount.isSupportedAlgorithm else {
                alertMessage = "\(effectiveAccount.displayTitle) uses legacy \(effectiveAccount.algorithm.displayName), which GlassOTP no longer generates."
                return
            }

            let generationDate = date ?? Date()
            let snapshot = OTPGenerator.snapshot(for: effectiveAccount, at: generationDate)
            OTPClipboardWriter.copyOTP(snapshot.code)

            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)

            if UIApplication.shared.applicationState != .active {
                pendingForegroundCopyCode = snapshot.code
            }

            SharedWidgetStateStore.recordCopy(accountID: effectiveAccount.id, at: generationDate)
            if reloadWidgets || effectiveAccount.type == .hotp {
                WidgetCenter.shared.reloadAllTimelines()
            }
            showToast(title: effectiveAccount.displayTitle, formattedCode: snapshot.formattedCode)
        }
    }

    func incrementHOTP(for account: OTPAccount) {
        guard account.isSupportedAlgorithm else {
            alertMessage = "\(account.displayTitle) uses legacy \(account.algorithm.displayName), which GlassOTP no longer generates."
            return
        }
        guard !hasLoadError else {
            alertMessage = "Cannot save changes because the existing Keychain vault could not be loaded."
            return
        }
        var found = false
        do {
            if let updated = try store.mutateSnapshotIfPresent({ snapshot in
                guard let idx = snapshot.accounts.firstIndex(where: { $0.id == account.id }),
                      snapshot.accounts[idx].isSupportedAlgorithm else {
                    return false
                }
                found = true
                snapshot.accounts[idx].counter &+= 1
                snapshot.accounts[idx].updatedAt = Date.monotonicTimestamp(after: snapshot.accounts[idx].updatedAt)
                return true
            }), found {
                applySnapshotToMemory(updated)
                WidgetCenter.shared.reloadAllTimelines()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else {
                reloadFromStore()
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleReveal(for accountID: UUID) {
        if revealedAccountIDs.contains(accountID) {
            revealedAccountIDs.remove(accountID)
        } else {
            revealedAccountIDs.insert(accountID)
        }
    }

    func isCodeVisible(for accountID: UUID) -> Bool {
        !hideCodesInApp || revealedAccountIDs.contains(accountID)
    }

    func togglePin(_ account: OTPAccount) {
        let prevAccounts = accounts
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].isPinned.toggle()
        accounts[index].updatedAt = Date.monotonicTimestamp(after: accounts[index].updatedAt)
        if persist() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            accounts = prevAccounts
        }
    }

    func moveAccount(_ account: OTPAccount, to folderID: UUID?) {
        let prevAccounts = accounts
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].folderID = folderID
        accounts[index].updatedAt = Date.monotonicTimestamp(after: accounts[index].updatedAt)
        if !persist() {
            accounts = prevAccounts
        }
    }

    @discardableResult
    func upsertAccount(_ account: OTPAccount) -> Bool {
        let prevFolders = folders
        let prevAccounts = accounts
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            var updated = account
            updated.updatedAt = Date.monotonicTimestamp(after: accounts[index].updatedAt)
            accounts[index] = updated
        } else {
            var created = account
            created.sortOrder = accounts.count
            accounts.append(created)
        }
        guard persist() else {
            folders = prevFolders
            accounts = prevAccounts
            return false
        }
        return true
    }

    func deleteAccount(_ account: OTPAccount) {
        let prevAccounts = accounts
        let prevTombstones = accountTombstones
        let prevRevealed = revealedAccountIDs
        accountTombstones.append(OTPTombstone(id: account.id, deletedAt: Date.monotonicTimestamp(after: account.updatedAt)))
        accounts.removeAll { $0.id == account.id }
        revealedAccountIDs.remove(account.id)
        if !persist() {
            accounts = prevAccounts
            accountTombstones = prevTombstones
            revealedAccountIDs = prevRevealed
        }
    }

    @discardableResult
    func updateBrandOverride(for account: OTPAccount, brandSlug: String?, customDomain: String?) -> Bool {
        let prevAccounts = accounts
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return false }
        accounts[index].customBrandSlug = brandSlug
        accounts[index].customLogoDomain = customDomain
        accounts[index].updatedAt = Date.monotonicTimestamp(after: accounts[index].updatedAt)
        if persist() {
            bumpLogoRevision()
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } else {
            accounts = prevAccounts
            return false
        }
    }

    @discardableResult
    func applyCategorization(_ assignments: [UUID: OTPCategory], removeEmptyDefaultFolder: Bool) -> Bool {
        let prevFolders = folders
        let prevAccounts = accounts
        let prevTombstones = folderTombstones
        let prevSelected = selectedFolderID
        let prevDismissed = dismissedAutoCategorizeBanner

        let result = AccountCategorizer.apply(
            assignments: assignments,
            toAccounts: accounts,
            existingFolders: folders,
            removeEmptyDefaultFolder: removeEmptyDefaultFolder
        )
        let keptFolderIDs = Set(result.folders.map(\.id))
        let now = Date()
        for folder in folders where !keptFolderIDs.contains(folder.id) {
            folderTombstones.append(OTPTombstone(id: folder.id, deletedAt: now))
        }
        folders = result.folders
        accounts = result.accounts
        if let selected = selectedFolderID, !folders.contains(where: { $0.id == selected }) {
            selectedFolderID = nil
        }
        dismissedAutoCategorizeBanner = true
        if !persist() {
            folders = prevFolders
            accounts = prevAccounts
            folderTombstones = prevTombstones
            selectedFolderID = prevSelected
            dismissedAutoCategorizeBanner = prevDismissed
            return false
        }
        return true
    }

    @discardableResult
    func fetchMissingWebLogos(for targetAccounts: [OTPAccount]? = nil) async -> Int {
        let fetched = await BrandLogoFetcher.fetchMissingLogos(for: targetAccounts ?? accounts)
        if fetched > 0 {
            bumpLogoRevision()
            WidgetCenter.shared.reloadAllTimelines()
        }
        return fetched
    }

    func bumpLogoRevision() {
        logoCacheRevision &+= 1
    }

    @discardableResult
    func addFolder(name: String, symbolName: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            alertMessage = "A folder named \"\(trimmed)\" already exists."
            return false
        }
        let prevFolders = folders
        let folder = OTPFolder(name: trimmed, symbolName: symbolName, sortOrder: folders.count)
        folders.append(folder)
        if !persist() {
            folders = prevFolders
            return false
        }
        return true
    }

    @discardableResult
    func renameFolder(_ folder: OTPFolder, to newName: String, symbolName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == folder.id }) else { return false }
        if folders.contains(where: {
            $0.id != folder.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            alertMessage = "A folder named \"\(trimmed)\" already exists."
            return false
        }
        let prevFolders = folders
        folders[index].name = trimmed
        folders[index].symbolName = symbolName
        folders[index].updatedAt = Date.monotonicTimestamp(after: folders[index].updatedAt)
        if !persist() {
            folders = prevFolders
            return false
        }
        return true
    }

    func deleteFolder(_ folder: OTPFolder) {
        let prevFolders = folders
        let prevAccounts = accounts
        let prevTombstones = folderTombstones
        let prevSelected = selectedFolderID

        let deletedAt = Date.monotonicTimestamp(after: folder.updatedAt)
        folderTombstones.append(OTPTombstone(id: folder.id, deletedAt: deletedAt))
        folders.removeAll { $0.id == folder.id }
        for idx in accounts.indices where accounts[idx].folderID == folder.id {
            accounts[idx].folderID = nil
            accounts[idx].updatedAt = Date.monotonicTimestamp(after: accounts[idx].updatedAt)
        }
        if selectedFolderID == folder.id {
            selectedFolderID = nil
        }
        if !persist() {
            folders = prevFolders
            accounts = prevAccounts
            folderTombstones = prevTombstones
            selectedFolderID = prevSelected
        }
    }

    func existingFingerprints() -> Set<String> {
        Set(accounts.map(\.fingerprint))
    }

    struct ImportSummary {
        let addedCount: Int
        let addedFoldersCount: Int
        let skippedDuplicates: Int
        let saved: Bool
    }

    @discardableResult
    func importAccounts(
        _ incomingAccounts: [OTPAccount],
        folders incomingFolders: [OTPFolder],
        skipDuplicates: Bool,
        preserveEmptyFolders: Bool = false
    ) -> ImportSummary {
        let plan = VaultImportReconciler.reconcile(
            importedAccounts: incomingAccounts,
            importedFolders: incomingFolders,
            existingAccounts: accounts,
            existingFolders: folders,
            existingAccountTombstones: accountTombstones,
            existingFolderTombstones: folderTombstones,
            skipDuplicates: skipDuplicates,
            preserveEmptyFolders: preserveEmptyFolders
        )

        let addedFoldersCount = max(0, plan.folders.count - folders.count)
        let foldersChanged = plan.folders != folders
        guard plan.addedCount > 0 || (preserveEmptyFolders && foldersChanged) else {
            return ImportSummary(
                addedCount: 0,
                addedFoldersCount: 0,
                skippedDuplicates: plan.skippedDuplicateCount,
                saved: true
            )
        }

        let prevFolders = folders
        let prevAccounts = accounts
        folders = plan.folders
        accounts = plan.accounts
        let saved = persist()
        if !saved {
            folders = prevFolders
            accounts = prevAccounts
        }
        return ImportSummary(
            addedCount: saved ? plan.addedCount : 0,
            addedFoldersCount: saved ? addedFoldersCount : 0,
            skippedDuplicates: plan.skippedDuplicateCount,
            saved: saved
        )
    }

    func dismissSensitivePresentationsForLock() {
        revealedAccountIDs.removeAll()
        pendingForegroundCopyCode = nil
        toastDismissTask?.cancel()
        copiedToast = nil
        qrDetailAccount = nil
        editingAccount = nil
        brandPickerAccount = nil
        showingScannerSheet = false
        showingNewAccountSheet = false
        showingImportSheet = false
        showingAutoCategorizeSheet = false
    }

    func makeBackupSnapshot() -> OTPVaultSnapshot {
        OTPVaultSnapshot(
            schemaVersion: 1,
            folders: folders,
            accounts: accounts,
            updatedAt: Date()
        )
    }

    func processPendingIncomingURLIfUnlocked(isLocked: Bool) {
        guard !isLocked, let url = pendingIncomingURL else { return }
        pendingIncomingURL = nil
        handleIncomingURL(url, isLocked: false)
    }

    func handleIncomingURL(_ url: URL, isLocked: Bool = false) {
        if isLocked {
            if let oldPending = pendingIncomingURL, oldPending != url {
                cleanupInboxFileIfNeeded(oldPending)
            }
            pendingIncomingURL = url
            return
        }

        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                cleanupInboxFileIfNeeded(url)
            }
            do {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = resourceValues.fileSize, fileSize > VaultImporter.maxImportFileBytes {
                    alertMessage = "Import files are limited to 20 MB."
                    return
                }
                let data = try Data(contentsOf: url)
                guard data.count <= VaultImporter.maxImportFileBytes else {
                    alertMessage = "Import files are limited to 20 MB."
                    return
                }
                pendingImportFile = PendingImportFile(filename: url.lastPathComponent, data: data)
                showingImportSheet = true
            } catch {
                alertMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            }
            return
        }

        let scheme = url.scheme?.lowercased()
        if scheme == "otpauth" || scheme == "otpauth-migration" {
            do {
                let parsed = try OTPUriParser.parse(url.absoluteString)
                if parsed.count == 1, let single = parsed.first {
                    editingAccount = single
                } else {
                    pendingURIAccounts = parsed
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            return
        }

        if scheme == "glassotp",
           url.host?.lowercased() == "account",
           let idString = url.pathComponents.dropFirst().first,
           let accountID = UUID(uuidString: idString) {
            reloadFromStore()
            guard let match = accounts.first(where: { $0.id == accountID }) else {
                return
            }
            selectedFolderID = match.folderID
            copyCode(for: match, reloadWidgets: true)
        }
    }

    private func cleanupInboxFileIfNeeded(_ url: URL) {
        guard url.isFileURL,
              url.resolvingSymlinksInPath().standardizedFileURL.path.contains("/Documents/Inbox/") else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func purgeStaleInboxFiles(olderThan age: TimeInterval = 300) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
        ) else {
            return
        }
        let pendingResolved = pendingIncomingURL?.resolvingSymlinksInPath().standardizedFileURL
        let cutoff = Date().addingTimeInterval(-age)
        for fileURL in contents {
            if let pendingResolved,
               fileURL.resolvingSymlinksInPath().standardizedFileURL == pendingResolved {
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let modified = values?.contentModificationDate ?? values?.creationDate ?? Date()
            guard modified <= cutoff else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    #if DEBUG
    func seedDemoDataIfNeeded() {
        let defaultFolder = OTPFolder(name: "Accounts", symbolName: "folder.fill", sortOrder: 0)
        dismissedAutoCategorizeBanner = false

        folders = [defaultFolder]
        accounts = [
            OTPAccount(
                issuer: "GitHub",
                label: "alex@example.com",
                secret: Data("JBSWY3DPEHPK3PXP".utf8),
                folderID: defaultFolder.id,
                isPinned: true,
                sortOrder: 0
            ),
            OTPAccount(
                issuer: "Cloudflare",
                label: "ops@example.com",
                secret: Data("MZXW6YTBOI======".utf8),
                folderID: defaultFolder.id,
                isPinned: true,
                sortOrder: 1
            ),
            OTPAccount(
                issuer: "AWS",
                label: "root-admin@aws",
                secret: Data("GEZDGNBVGY3TQOJQ".utf8),
                algorithm: .sha256,
                digits: 6,
                period: 30,
                folderID: defaultFolder.id,
                isPinned: true,
                sortOrder: 2
            ),
            OTPAccount(
                issuer: "Google",
                label: "alex.demo@gmail.com",
                secret: Data("KRUGS4ZANFZSAYJA".utf8),
                folderID: defaultFolder.id,
                isPinned: false,
                sortOrder: 3
            ),
            OTPAccount(
                issuer: "1Password",
                label: "family-vault",
                secret: Data("ONSWG4TFOQYTEMZU".utf8),
                folderID: defaultFolder.id,
                isPinned: false,
                sortOrder: 4
            ),
            OTPAccount(
                issuer: "Stripe",
                label: "billing@example.com",
                secret: Data("JBSWY3DPEHPK3PXP".utf8),
                folderID: defaultFolder.id,
                isPinned: false,
                sortOrder: 5
            ),
            OTPAccount(
                issuer: "Discord",
                label: "alex#0001",
                secret: Data("MZXW6YTBOI======".utf8),
                folderID: defaultFolder.id,
                isPinned: false,
                sortOrder: 6
            ),
            OTPAccount(
                issuer: "Steam",
                label: "alexdev",
                secret: Data("GEZDGNBVGY3TQOJQ".utf8),
                folderID: defaultFolder.id,
                isPinned: false,
                sortOrder: 7
            ),
        ]
        persist()
    }
    #endif

    private func showToast(title: String, formattedCode: String) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            copiedToast = CopiedToast(title: title, formattedCode: formattedCode)
        }
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                copiedToast = nil
            }
        }
    }
}
