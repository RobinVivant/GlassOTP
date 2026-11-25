import Foundation
import GlassOTPCore
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
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

    var iCloudSyncEnabled: Bool {
        didSet {
            store.setICloudSyncEnabled(iCloudSyncEnabled)
        }
    }

    var hideCodesInApp: Bool {
        didSet {
            UserDefaults.standard.set(hideCodesInApp, forKey: Self.hideCodesKey)
        }
    }

    var revealedAccountIDs: Set<UUID> = []

    private let store: KeychainVaultStore
    private var toastDismissTask: Task<Void, Never>?
    private static let hideCodesKey = "glassotp.hideCodesInApp"
    private static let dismissBannerKey = "glassotp.dismissAutoCategorizeBanner"

    init(store: KeychainVaultStore = .shared) {
        self.store = store
        self.iCloudSyncEnabled = store.isICloudSyncEnabled()
        self.hideCodesInApp = UserDefaults.standard.bool(forKey: Self.hideCodesKey)
        self.dismissedAutoCategorizeBanner = UserDefaults.standard.bool(forKey: Self.dismissBannerKey)
        reloadFromStore()
    }

    private func rebuildFolderLookup() {
        folderNamesByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
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

    func reloadFromStore() {
        do {
            if let snapshot = try store.loadSnapshot() {
                folders = snapshot.folders.sorted { $0.sortOrder < $1.sortOrder }
                accounts = snapshot.accounts.sorted { $0.sortOrder < $1.sortOrder }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func persist() {
        let snapshot = OTPVaultSnapshot(
            schemaVersion: 1,
            folders: folders,
            accounts: accounts,
            updatedAt: Date()
        )
        do {
            try store.saveSnapshot(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func copyCode(for account: OTPAccount, at date: Date = Date()) {
        let snapshot = OTPGenerator.snapshot(for: account, at: date)
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: snapshot.code]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(60),
            ]
        )

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        SharedWidgetStateStore.recordCopy(accountID: account.id, at: date)
        showToast(title: account.displayTitle, formattedCode: snapshot.formattedCode)
    }

    func incrementHOTP(for account: OTPAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].counter &+= 1
        accounts[index].updatedAt = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        persist()
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
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].isPinned.toggle()
        accounts[index].updatedAt = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        persist()
    }

    func moveAccount(_ account: OTPAccount, to folderID: UUID?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].folderID = folderID
        accounts[index].updatedAt = Date()
        persist()
    }

    func upsertAccount(_ account: OTPAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            var updated = account
            updated.updatedAt = Date()
            accounts[index] = updated
        } else {
            var created = account
            created.sortOrder = accounts.count
            accounts.append(created)
        }
        persist()
    }

    func deleteAccount(_ account: OTPAccount) {
        accounts.removeAll { $0.id == account.id }
        revealedAccountIDs.remove(account.id)
        persist()
    }

    func updateBrandOverride(for account: OTPAccount, brandSlug: String?, customDomain: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].customBrandSlug = brandSlug
        accounts[index].customLogoDomain = customDomain
        accounts[index].updatedAt = Date()
        bumpLogoRevision()
        persist()
    }

    func applyCategorization(_ assignments: [UUID: OTPCategory], removeEmptyDefaultFolder: Bool) {
        let result = AccountCategorizer.apply(
            assignments: assignments,
            toAccounts: accounts,
            existingFolders: folders,
            removeEmptyDefaultFolder: removeEmptyDefaultFolder
        )
        folders = result.folders
        accounts = result.accounts
        if let selected = selectedFolderID, !folders.contains(where: { $0.id == selected }) {
            selectedFolderID = nil
        }
        dismissedAutoCategorizeBanner = true
        persist()
    }

    @discardableResult
    func fetchMissingWebLogos() async -> Int {
        let fetched = await BrandLogoFetcher.fetchMissingLogos(for: accounts)
        if fetched > 0 {
            bumpLogoRevision()
            WidgetCenter.shared.reloadAllTimelines()
        }
        return fetched
    }

    func bumpLogoRevision() {
        logoCacheRevision &+= 1
    }

    func addFolder(name: String, symbolName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        let folder = OTPFolder(name: trimmed, symbolName: symbolName, sortOrder: folders.count)
        folders.append(folder)
        persist()
    }

    func renameFolder(_ folder: OTPFolder, to newName: String, symbolName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].name = trimmed
        folders[index].symbolName = symbolName
        persist()
    }

    func deleteFolder(_ folder: OTPFolder) {
        folders.removeAll { $0.id == folder.id }
        for idx in accounts.indices where accounts[idx].folderID == folder.id {
            accounts[idx].folderID = nil
        }
        if selectedFolderID == folder.id {
            selectedFolderID = nil
        }
        persist()
    }

    func existingFingerprints() -> Set<String> {
        Set(accounts.map(\.fingerprint))
    }

    @discardableResult
    func importAccounts(
        _ incomingAccounts: [OTPAccount],
        folders incomingFolders: [OTPFolder],
        skipDuplicates: Bool
    ) -> Int {
        var folderMap: [UUID: UUID] = [:]
        for incomingFolder in incomingFolders {
            if let existing = folders.first(where: {
                $0.name.caseInsensitiveCompare(incomingFolder.name) == .orderedSame
            }) {
                folderMap[incomingFolder.id] = existing.id
            } else {
                var newFolder = incomingFolder
                newFolder.sortOrder = folders.count
                folders.append(newFolder)
                folderMap[incomingFolder.id] = newFolder.id
            }
        }

        var seenFingerprints = existingFingerprints()
        var importedCount = 0

        for var account in incomingAccounts {
            if skipDuplicates && seenFingerprints.contains(account.fingerprint) {
                continue
            }
            if let oldFolderID = account.folderID, let mappedFolderID = folderMap[oldFolderID] {
                account.folderID = mappedFolderID
            }
            account.sortOrder = accounts.count
            accounts.append(account)
            seenFingerprints.insert(account.fingerprint)
            importedCount += 1
        }

        if importedCount > 0 || !incomingFolders.isEmpty {
            persist()
        }
        return importedCount
    }

    func makeBackupSnapshot() -> OTPVaultSnapshot {
        OTPVaultSnapshot(
            schemaVersion: 1,
            folders: folders,
            accounts: accounts,
            updatedAt: Date()
        )
    }

    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
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
           let accountID = UUID(uuidString: idString),
           let match = accounts.first(where: { $0.id == accountID }) {
            if let folderID = match.folderID {
                selectedFolderID = folderID
            } else {
                selectedFolderID = nil
            }
            copyCode(for: match)
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
                label: "robin@vero.io",
                secret: Data("JBSWY3DPEHPK3PXP".utf8),
                folderID: defaultFolder.id,
                isPinned: true,
                sortOrder: 0
            ),
            OTPAccount(
                issuer: "Cloudflare",
                label: "infra-prod@vero.io",
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
                label: "robin.vivant@gmail.com",
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
                label: "billing@vero.io",
                secret: Data("JBSWY3DPEHPK3PXP".utf8),
                folderID: defaultFolder.id,
                isPinned: false,
                sortOrder: 5
            ),
            OTPAccount(
                issuer: "Discord",
                label: "robin#0001",
                secret: Data("MZXW6YTBOI======".utf8),
                folderID: defaultFolder.id,
                isPinned: false,
                sortOrder: 6
            ),
            OTPAccount(
                issuer: "Steam",
                label: "rvivant",
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
