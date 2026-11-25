import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import GlassOTPCore
import Observation
import ServiceManagement

@MainActor
@Observable
final class MacVaultViewModel {
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
    var showingSettings: Bool = false
    var focusSearchToken: Int = 0
    var selectedAccountIndex: Int = 0

    private(set) var lastSyncDate: Date?
    var syncError: String?
    var alertMessage: String?

    var quickPickerHotKey: HotKeyCombo? {
        didSet {
            persistQuickPickerHotKey()
            registerHotKeys()
        }
    }

    var accountHotKeys: [UUID: HotKeyCombo] {
        didSet {
            persistAccountHotKeys()
            registerHotKeys()
        }
    }

    var menuBarAccountID: UUID? {
        didSet {
            if let id = menuBarAccountID {
                defaults.set(id.uuidString, forKey: Self.menuBarAccountKey)
            } else {
                defaults.removeObject(forKey: Self.menuBarAccountKey)
            }
            clock.setActive(menuBarAccountID != nil, reason: "menuBar")
        }
    }

    var autoTypeOnHotKey: Bool {
        didSet {
            defaults.set(autoTypeOnHotKey, forKey: Self.autoTypeKey)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != isLaunchAtLoginRegistered else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = isLaunchAtLoginRegistered
                alertMessage = "Couldn't update Launch at Login: \(error.localizedDescription)"
            }
        }
    }

    let clock = MacOTPClock()
    let hotKeyManager = GlobalHotKeyManager()

    @ObservationIgnored private let store: KeychainVaultStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var autoTypeTask: Task<Void, Never>?

    private static let quickPickerKey = "glassotp.mac.quickPickerHotKey"
    private static let accountHotKeysKey = "glassotp.mac.accountHotKeys"
    private static let menuBarAccountKey = "glassotp.mac.menuBarAccountID"
    private static let autoTypeKey = "glassotp.mac.autoTypeOnHotKey"

    init(store: KeychainVaultStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.quickPickerHotKey = Self.loadQuickPickerHotKey(from: defaults)
        self.accountHotKeys = Self.loadAccountHotKeys(from: defaults)
        if let idStr = defaults.string(forKey: Self.menuBarAccountKey),
           let id = UUID(uuidString: idStr) {
            self.menuBarAccountID = id
        } else {
            self.menuBarAccountID = nil
        }
        self.autoTypeOnHotKey = defaults.bool(forKey: Self.autoTypeKey)
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        clock.setActive(menuBarAccountID != nil, reason: "menuBar")
        reloadFromStore()
        registerHotKeys()
        startSyncLoop()
    }

    private var isLaunchAtLoginRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPrompt() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue!] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func rebuildFolderLookup() {
        folderNamesByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
    }

    private func rebuildPinnedAccounts() {
        pinnedAccounts = accounts.filter(\.isPinned)
    }

    var displayedAccounts: [OTPAccount] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = accounts.filter { account in
            let matchesFolder = selectedFolderID == nil || account.folderID == selectedFolderID
            guard matchesFolder else { return false }
            guard !query.isEmpty else { return true }
            return account.issuer.localizedCaseInsensitiveContains(query)
                || account.label.localizedCaseInsensitiveContains(query)
                || folderName(for: account.folderID)?.localizedCaseInsensitiveContains(query) == true
        }
        return filtered.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            let lhsHasHotKey = accountHotKeys[lhs.id] != nil
            let rhsHasHotKey = accountHotKeys[rhs.id] != nil
            if lhsHasHotKey != rhsHasHotKey {
                return lhsHasHotKey
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    func folderName(for id: UUID?) -> String? {
        id.flatMap { folderNamesByID[$0] }
    }

    func hotKey(for accountID: UUID) -> HotKeyCombo? {
        accountHotKeys[accountID]
    }

    func nextAvailableQuickSlot() -> HotKeyCombo? {
        let used = Set(accountHotKeys.values)
        for slot in 1...9 {
            if let candidate = HotKeyCombo.quickSlot(slot),
               !used.contains(candidate),
               candidate != quickPickerHotKey {
                return candidate
            }
        }
        return nil
    }

    func assignHotKey(_ combo: HotKeyCombo?, for accountID: UUID) {
        var updated = accountHotKeys
        if let combo {
            for (existingID, existingCombo) in updated where existingCombo == combo {
                updated.removeValue(forKey: existingID)
            }
            updated[accountID] = combo
        } else {
            updated.removeValue(forKey: accountID)
        }
        accountHotKeys = updated
    }

    func reloadFromStore() {
        do {
            if let snapshot = try store.loadSnapshot() {
                folders = snapshot.folders.sorted { $0.sortOrder < $1.sortOrder }
                accounts = snapshot.accounts.sorted { $0.sortOrder < $1.sortOrder }
                lastSyncDate = Date()
            }
            syncError = nil
        } catch {
            syncError = error.localizedDescription
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
            lastSyncDate = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
            alertMessage = error.localizedDescription
        }
    }

    func copyCode(for account: OTPAccount, fromDirectHotKey: Bool = false) {
        let now = Date()
        let snapshot = OTPGenerator.snapshot(for: account, at: now, includeNextCode: false)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.code, forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        if account.type == .hotp,
           let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].counter &+= 1
            accounts[idx].updatedAt = now
            persist()
        }

        let willAutoType = fromDirectHotKey && autoTypeOnHotKey && AXIsProcessTrusted()
        if willAutoType {
            scheduleAutoType(snapshot.code)
        }

        let remaining: Int? = account.type == .totp
            ? max(0, Int(ceil(snapshot.remainingSeconds)))
            : nil
        CopyHUDController.shared.show(
            account: account,
            formattedCode: snapshot.formattedCode,
            remainingSeconds: remaining,
            didAutoType: willAutoType
        )
    }

    func togglePin(_ account: OTPAccount) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].isPinned.toggle()
        accounts[idx].updatedAt = Date()
        persist()
    }

    func handleAccountHotKey(_ accountID: UUID) {
        if accounts.first(where: { $0.id == accountID }) == nil {
            reloadFromStore()
        }
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        copyCode(for: account, fromDirectHotKey: true)
    }

    func handleIncomingURL(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "glassotp",
           url.host?.lowercased() == "account",
           let idString = url.pathComponents.dropFirst().first,
           let accountID = UUID(uuidString: idString) {
            if accounts.first(where: { $0.id == accountID }) == nil {
                reloadFromStore()
            }
            if let match = accounts.first(where: { $0.id == accountID }) {
                copyCode(for: match, fromDirectHotKey: false)
            }
        } else if scheme == "otpauth" || scheme == "otpauth-migration" {
            do {
                let parsed = try OTPUriParser.parse(url.absoluteString)
                let count = importAccounts(parsed, folders: [], skipDuplicates: true)
                alertMessage = count > 0
                    ? "Imported \(count) account\(count == 1 ? "" : "s") into iCloud Keychain."
                    : "Account is already in your vault."
            } catch {
                alertMessage = error.localizedDescription
            }
        }
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

        var seenFingerprints = Set(accounts.map(\.fingerprint))
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

    func importBackupFile(data: Data, password: String, filename: String) async -> Result<String, Error> {
        do {
            let result: OTPAuthImportResult = try await Task.detached(priority: .userInitiated) {
                if GlassOTPBackupCodec.isGlassOTPBackup(data) {
                    let snapshot = try GlassOTPBackupCodec.decode(data: data, password: password)
                    return OTPAuthImportResult(
                        formatDescription: "GlassOTP Encrypted Backup",
                        folders: snapshot.folders,
                        accounts: snapshot.accounts
                    )
                }
                return try OTPAuthImporter.importFile(
                    data: data,
                    password: password,
                    filenameHint: filename
                )
            }.value

            let imported = importAccounts(result.accounts, folders: result.folders, skipDuplicates: true)
            if imported == 0 {
                return .success("All \(result.accounts.count) accounts were already in your vault.")
            }
            return .success("Imported \(imported) account\(imported == 1 ? "" : "s") (\(result.formatDescription)).")
        } catch {
            return .failure(error)
        }
    }

    private func registerHotKeys() {
        hotKeyManager.register(quickPicker: quickPickerHotKey, accountHotKeys: accountHotKeys)
    }

    private func startSyncLoop() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { break }
                self.reloadFromStore()
            }
        }
    }

    private func scheduleAutoType(_ code: String) {
        autoTypeTask?.cancel()
        autoTypeTask = Task {
            let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            for _ in 0..<24 {
                guard !Task.isCancelled else { return }
                let currentFlags = CGEventSource.flagsState(.hidSystemState)
                if currentFlags.intersection(modifierMask).isEmpty {
                    break
                }
                try? await Task.sleep(for: .milliseconds(15))
            }
            guard !Task.isCancelled else { return }
            guard let source = CGEventSource(stateID: .privateState) else { return }

            for character in code {
                var utf16 = Array(String(character).utf16)
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    continue
                }
                keyDown.flags = []
                keyUp.flags = []
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func persistQuickPickerHotKey() {
        if let quickPickerHotKey,
           let data = try? JSONEncoder().encode(quickPickerHotKey) {
            defaults.set(data, forKey: Self.quickPickerKey)
        } else {
            defaults.set(Data(), forKey: Self.quickPickerKey)
        }
    }

    private static func loadQuickPickerHotKey(from defaults: UserDefaults) -> HotKeyCombo? {
        guard let data = defaults.data(forKey: Self.quickPickerKey) else {
            return .defaultQuickPicker
        }
        if data.isEmpty {
            return nil
        }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    private func persistAccountHotKeys() {
        let stringKeyed = Dictionary(uniqueKeysWithValues: accountHotKeys.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stringKeyed) {
            defaults.set(data, forKey: Self.accountHotKeysKey)
        }
    }

    private static func loadAccountHotKeys(from defaults: UserDefaults) -> [UUID: HotKeyCombo] {
        guard let data = defaults.data(forKey: Self.accountHotKeysKey),
              let stringKeyed = try? JSONDecoder().decode([String: HotKeyCombo].self, from: data) else {
            return [:]
        }
        var mapped: [UUID: HotKeyCombo] = [:]
        for (key, value) in stringKeyed {
            if let uuid = UUID(uuidString: key) {
                mapped[uuid] = value
            }
        }
        return mapped
    }
}
