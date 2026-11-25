import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import GlassOTPCore
import Observation
import ServiceManagement

enum MacClipboardWriter {
    @MainActor private static var clearTask: Task<Void, Never>?

    @MainActor
    static func copyOTP(_ code: String, clearAfterSeconds: TimeInterval = 60) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])

        let expectedChangeCount = pasteboard.changeCount
        clearTask?.cancel()
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(clearAfterSeconds))
            guard !Task.isCancelled else { return }
            if NSPasteboard.general.changeCount == expectedChangeCount {
                NSPasteboard.general.clearContents()
            }
        }
    }
}

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
    private(set) var hasLoadError = false
    var syncError: String?
    var alertMessage: String?

    var quickPickerHotKey: HotKeyCombo? {
        didSet {
            if let picker = quickPickerHotKey {
                let collidingIDs = accountHotKeys.filter { $0.value == picker }.map(\.key)
                if !collidingIDs.isEmpty {
                    var updated = accountHotKeys
                    for id in collidingIDs {
                        updated.removeValue(forKey: id)
                    }
                    accountHotKeys = updated
                    alertMessage = "Shortcut \(picker.displayString) was reassigned to Quick Search Popover."
                }
            }
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
    @ObservationIgnored private var accountTombstones: [OTPTombstone] = []
    @ObservationIgnored private var folderTombstones: [OTPTombstone] = []

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
        if let combo, combo == quickPickerHotKey {
            alertMessage = "Shortcut \(combo.displayString) is already assigned to Quick Search Popover."
            return
        }
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

    private func applyLoadedSnapshot(_ snapshot: OTPVaultSnapshot?) {
        if let snapshot {
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
            if let pinnedID = menuBarAccountID, !sortedAccounts.contains(where: { $0.id == pinnedID }) {
                menuBarAccountID = nil
            }
        } else {
            folders = []
            accounts = []
            accountTombstones = []
            folderTombstones = []
            selectedFolderID = nil
            menuBarAccountID = nil
        }
        lastSyncDate = Date()
        hasLoadError = false
        syncError = nil
    }

    func reloadFromStore() {
        do {
            let snapshot = try store.loadSnapshot()
            applyLoadedSnapshot(snapshot)
        } catch {
            hasLoadError = true
            syncError = error.localizedDescription
        }
    }

    func reloadFromStoreAsync() async {
        let store = self.store
        do {
            let loaded = try await Task.detached(priority: .utility) {
                try store.loadSnapshot()
            }.value
            guard !Task.isCancelled else { return }
            applyLoadedSnapshot(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            hasLoadError = true
            syncError = error.localizedDescription
        }
    }

    @discardableResult
    func persist() -> Bool {
        guard !hasLoadError else {
            let message = "Cannot save changes because the existing Keychain vault could not be loaded."
            syncError = message
            alertMessage = message
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
            applyLoadedSnapshot(merged)
            return true
        } catch {
            syncError = error.localizedDescription
            alertMessage = error.localizedDescription
            return false
        }
    }

    func copyCode(for account: OTPAccount, fromDirectHotKey: Bool = false) {
        guard account.isSupportedAlgorithm else {
            alertMessage = "\(account.displayTitle) uses legacy \(account.algorithm.displayName), which GlassOTP no longer generates."
            return
        }
        let now = Date()
        var effectiveAccount = account

        if account.type == .hotp {
            guard !hasLoadError else {
                alertMessage = "Cannot advance HOTP counter because the Keychain vault failed to load."
                return
            }
            var reservedAccount: OTPAccount?
            do {
                let updatedSnapshot = try store.mutateSnapshotIfPresent { snapshot in
                    guard let idx = snapshot.accounts.firstIndex(where: { $0.id == account.id }) else {
                        return false
                    }
                    let current = snapshot.accounts[idx]
                    reservedAccount = current
                    guard current.isSupportedAlgorithm else {
                        return false
                    }
                    snapshot.accounts[idx].counter &+= 1
                    snapshot.accounts[idx].updatedAt = now
                    return true
                }
                if let updatedSnapshot {
                    applyLoadedSnapshot(updatedSnapshot)
                } else {
                    reloadFromStore()
                    return
                }
            } catch {
                syncError = error.localizedDescription
                alertMessage = error.localizedDescription
                return
            }
            guard let verified = reservedAccount else {
                reloadFromStore()
                return
            }
            guard verified.isSupportedAlgorithm else {
                alertMessage = "\(verified.displayTitle) uses legacy \(verified.algorithm.displayName), which GlassOTP no longer generates."
                return
            }
            effectiveAccount = verified
        }

        let snapshot = OTPGenerator.snapshot(for: effectiveAccount, at: now, includeNextCode: false)
        MacClipboardWriter.copyOTP(snapshot.code)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let willAutoType = fromDirectHotKey
            && autoTypeOnHotKey
            && AXIsProcessTrusted()
            && targetPID != nil
            && targetPID != ProcessInfo.processInfo.processIdentifier
        if willAutoType {
            scheduleAutoType(snapshot.code, targetPID: targetPID)
        }

        let remaining: Int? = effectiveAccount.type == .totp
            ? max(0, Int(ceil(snapshot.remainingSeconds)))
            : nil
        CopyHUDController.shared.show(
            account: effectiveAccount,
            formattedCode: snapshot.formattedCode,
            remainingSeconds: remaining,
            didAutoType: willAutoType
        )
    }

    func togglePin(_ account: OTPAccount) {
        let prevAccounts = accounts
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].isPinned.toggle()
        accounts[idx].updatedAt = Date()
        if !persist() {
            accounts = prevAccounts
        }
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
            reloadFromStore()
            if let match = accounts.first(where: { $0.id == accountID }) {
                copyCode(for: match, fromDirectHotKey: false)
            }
        } else if scheme == "otpauth" || scheme == "otpauth-migration" {
            do {
                let parsed = try OTPUriParser.parse(url.absoluteString)
                let names = parsed.prefix(3).map(\.displayTitle).joined(separator: ", ")
                let suffix = parsed.count > 3 ? ", …" : ""

                let alert = NSAlert()
                alert.messageText = "Import \(parsed.count) Account\(parsed.count == 1 ? "" : "s")?"
                alert.informativeText = "An external link wants to add \(names)\(suffix) to your GlassOTP Keychain vault."
                alert.addButton(withTitle: "Import")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return
                }

                let summary = importAccounts(parsed, folders: [], skipDuplicates: true)
                let outcomeTitle = summary.saved ? "GlassOTP Import" : "Import Failed"
                let outcomeText: String
                if summary.saved {
                    outcomeText = summary.addedCount > 0
                        ? "Imported \(summary.addedCount) account\(summary.addedCount == 1 ? "" : "s") into Keychain."
                        : "Account is already in your vault."
                } else {
                    outcomeText = alertMessage ?? "Couldn't save imported accounts to Keychain."
                }
                presentExternalAlert(title: outcomeTitle, message: outcomeText)
            } catch {
                presentExternalAlert(title: "Import Failed", message: error.localizedDescription)
            }
        }
    }

    private func presentExternalAlert(title: String, message: String) {
        let infoAlert = NSAlert()
        infoAlert.messageText = title
        infoAlert.informativeText = message
        infoAlert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        infoAlert.runModal()
    }

    struct ImportSummary {
        let addedCount: Int
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
        let foldersChanged = plan.folders != folders
        guard plan.addedCount > 0 || (preserveEmptyFolders && foldersChanged) else {
            return ImportSummary(addedCount: 0, skippedDuplicates: plan.skippedDuplicateCount, saved: true)
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
        return ImportSummary(addedCount: saved ? plan.addedCount : 0, skippedDuplicates: plan.skippedDuplicateCount, saved: saved)
    }

    func importBackupFile(data: Data, password: String?, filename: String) async -> Result<String, Error> {
        do {
            let result: OTPAuthImportResult = try await Task.detached(priority: .userInitiated) {
                try VaultImporter.importFile(
                    data: data,
                    password: password,
                    filenameHint: filename
                )
            }.value

            let preserveEmpty = result.formatDescription == "GlassOTP Encrypted Backup"
            let summary = importAccounts(
                result.accounts,
                folders: result.folders,
                skipDuplicates: true,
                preserveEmptyFolders: preserveEmpty
            )
            guard summary.saved else {
                return .failure(NSError(
                    domain: "GlassOTP",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: alertMessage ?? "Failed to save imported accounts to Keychain."]
                ))
            }
            if summary.addedCount == 0 {
                return .success("All \(result.accounts.count) accounts were already in your vault.")
            }
            if result.skippedEntries > 0 {
                return .success("Imported \(summary.addedCount) account\(summary.addedCount == 1 ? "" : "s") (\(result.formatDescription); \(result.skippedEntries) unsupported skipped).")
            }
            return .success("Imported \(summary.addedCount) account\(summary.addedCount == 1 ? "" : "s") (\(result.formatDescription)).")
        } catch {
            return .failure(error)
        }
    }

    private func registerHotKeys() {
        let failed = hotKeyManager.register(quickPicker: quickPickerHotKey, accountHotKeys: accountHotKeys)
        if !failed.isEmpty {
            let list = failed.map(\.displayString).joined(separator: ", ")
            alertMessage = "Shortcut \(list) is already in use by another app or system hotkey."
        }
    }

    private func startSyncLoop() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { break }
                await self.reloadFromStoreAsync()
            }
        }
    }

    private func scheduleAutoType(_ code: String, targetPID: pid_t?) {
        guard let targetPID else { return }
        autoTypeTask?.cancel()
        autoTypeTask = Task {
            let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            var modifiersReleased = false
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                let currentFlags = CGEventSource.flagsState(.hidSystemState)
                if currentFlags.intersection(modifierMask).isEmpty {
                    modifiersReleased = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(15))
            }
            guard !Task.isCancelled, modifiersReleased else { return }
            guard let source = CGEventSource(stateID: .privateState) else { return }

            for character in code {
                guard !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                    return
                }
                guard let keyCode = Self.virtualKeyCode(for: character) else { continue }
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                    continue
                }
                keyDown.flags = []
                keyUp.flags = []
                var utf16 = Array(String(character).utf16)
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                keyDown.postToPid(targetPID)
                keyUp.postToPid(targetPID)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private static func virtualKeyCode(for character: Character) -> CGKeyCode? {
        switch character {
        case "0": CGKeyCode(kVK_ANSI_0)
        case "1": CGKeyCode(kVK_ANSI_1)
        case "2": CGKeyCode(kVK_ANSI_2)
        case "3": CGKeyCode(kVK_ANSI_3)
        case "4": CGKeyCode(kVK_ANSI_4)
        case "5": CGKeyCode(kVK_ANSI_5)
        case "6": CGKeyCode(kVK_ANSI_6)
        case "7": CGKeyCode(kVK_ANSI_7)
        case "8": CGKeyCode(kVK_ANSI_8)
        case "9": CGKeyCode(kVK_ANSI_9)
        default: nil
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
