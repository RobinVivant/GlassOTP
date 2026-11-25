import AppKit
import Carbon.HIToolbox
import GlassOTPCore
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarPopoverView: View {
    @Bindable var vault: MacVaultViewModel
    let onDismiss: (Bool) -> Void
    let onPickImportURL: (NSOpenPanel) -> URL?

    @FocusState private var searchFocused: Bool
    @State private var recordingAccountID: UUID?
    @State private var activeRecorderID: String?
    @State private var importError: String?
    @State private var pendingImportData: (url: URL, data: Data)?
    @State private var detectedEncryptedFormat: String?
    @State private var importPassword = ""
    @State private var showingPasswordPrompt = false
    @State private var isReadingImport = false

    var body: some View {
        let displayed = vault.displayedAccounts

        VStack(spacing: 0) {
            headerBar

            Divider()
                .opacity(0.35)

            if vault.showingSettings {
                settingsContent
            } else if showingPasswordPrompt, let pending = pendingImportData {
                passwordPromptContent(filename: pending.url.lastPathComponent, data: pending.data)
            } else {
                vaultListContent(displayed: displayed)
            }
        }
        .frame(width: 382, height: 486)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            searchFocused = true
        }
        .onChange(of: vault.focusSearchToken) { _, _ in
            searchFocused = true
        }
        .onChange(of: vault.showingSettings) { _, isShowing in
            if !isShowing {
                activeRecorderID = nil
                recordingAccountID = nil
            }
        }
        .onExitCommand {
            if vault.showingSettings {
                vault.showingSettings = false
            } else if showingPasswordPrompt {
                showingPasswordPrompt = false
                pendingImportData = nil
                importPassword = ""
                importError = nil
            } else if !vault.searchText.isEmpty {
                vault.searchText = ""
            } else {
                onDismiss(true)
            }
        }
        .alert(
            "GlassOTP",
            isPresented: Binding(
                get: { vault.alertMessage != nil },
                set: { if !$0 { vault.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vault.alertMessage ?? "")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("GlassOTP")
                .font(.system(size: 14, weight: .bold))

            if !vault.accounts.isEmpty {
                Text("\(vault.accounts.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: Capsule())
            }

            Spacer()

            Button {
                vault.reloadFromStore()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Refresh iCloud Keychain Sync")

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    vault.showingSettings.toggle()
                }
            } label: {
                Image(systemName: vault.showingSettings ? "checkmark.circle.fill" : "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(vault.showingSettings ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(vault.showingSettings ? "Back to Codes" : "Shortcuts & Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func vaultListContent(displayed: [OTPAccount]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Search service, email, or folder…", text: $vault.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit {
                        copyHighlightedAccount(in: displayed)
                    }

                if !vault.searchText.isEmpty {
                    Button {
                        vault.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                } else if let pickerHotKey = vault.quickPickerHotKey {
                    Text(pickerHotKey.displayString)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if !vault.folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        folderChip(title: "All", symbol: "tray.full.fill", folderID: nil)
                        ForEach(vault.folders) { folder in
                            folderChip(title: folder.name, symbol: folder.symbolName, folderID: folder.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            if vault.accounts.isEmpty {
                emptyVaultView
            } else if displayed.isEmpty {
                ContentUnavailableView(
                    "No Matching Accounts",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term or folder filter.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, account in
                                MacAccountRowView(
                                    account: account,
                                    clock: vault.clock,
                                    folderName: vault.selectedFolderID == nil ? vault.folderName(for: account.folderID) : nil,
                                    hotKey: vault.hotKey(for: account.id),
                                    isMenuBarLive: vault.menuBarAccountID == account.id,
                                    isHighlighted: index == min(vault.selectedAccountIndex, displayed.count - 1),
                                    slotIndex: index < 9 ? index + 1 : nil,
                                    onCopy: {
                                        copyAndDismiss(account)
                                    },
                                    onTogglePin: {
                                        vault.togglePin(account)
                                    },
                                    onToggleMenuBar: {
                                        vault.menuBarAccountID = vault.menuBarAccountID == account.id ? nil : account.id
                                    },
                                    onAssignHotKey: { combo in
                                        vault.assignHotKey(combo, for: account.id)
                                    },
                                    onOpenShortcutSettings: {
                                        vault.showingSettings = true
                                    }
                                )
                                .id(account.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: vault.searchText) { _, _ in
                        vault.selectedAccountIndex = 0
                    }
                    .onChange(of: vault.selectedAccountIndex) { _, newIdx in
                        if displayed.indices.contains(newIdx) {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(displayed[newIdx].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            bottomStatusBar(displayedCount: displayed.count)
        }
        .onKeyPress(.upArrow) {
            guard !displayed.isEmpty else { return .ignored }
            vault.selectedAccountIndex = max(0, vault.selectedAccountIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !displayed.isEmpty else { return .ignored }
            vault.selectedAccountIndex = min(displayed.count - 1, vault.selectedAccountIndex + 1)
            return .handled
        }
        .onKeyPress(.return) {
            copyHighlightedAccount(in: displayed)
            return .handled
        }
        .background {
            ForEach(0..<min(9, displayed.count), id: \.self) { idx in
                Button("") {
                    copyAndDismiss(displayed[idx])
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                .hidden()
            }
        }
    }

    private func folderChip(title: String, symbol: String, folderID: UUID?) -> some View {
        let isSelected = vault.selectedFolderID == folderID
        return Button {
            vault.selectedFolderID = folderID
            vault.selectedAccountIndex = 0
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.65)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyVaultView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            Text("Waiting for iCloud Keychain Sync")
                .font(.headline)

            Text("Open GlassOTP on your iPhone (with iCloud Keychain Sync enabled) so Apple syncs your vault to this Mac, or import an encrypted backup file directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 8) {
                Button("Refresh Sync") {
                    vault.reloadFromStore()
                }
                .buttonStyle(.borderedProminent)

                Button("Import Backup…") {
                    openBackupFilePanel()
                }
                .buttonStyle(.bordered)
            }

            if let syncError = vault.syncError {
                Text(syncError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bottomStatusBar(displayedCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("Click or ↩ to copy • ⌘1–9 quick copy")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            Button("Shortcuts") {
                withAnimation(.easeOut(duration: 0.15)) {
                    vault.showingSettings = true
                }
            }
            .font(.caption2.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.28))
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GLOBAL SHORTCUTS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Quick Search Popover")
                                .font(.subheadline.weight(.semibold))
                            Text("Open Spotlight-style OTP search anywhere")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HotKeyRecorderButton(
                            recorderID: "quickPicker",
                            activeRecorderID: $activeRecorderID,
                            combo: Binding(
                                get: { vault.quickPickerHotKey },
                                set: { vault.quickPickerHotKey = $0 }
                            ),
                            hotKeyManager: vault.hotKeyManager
                        )
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("1-KEYSTROKE DAILY OTP SHORTCUTS")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !vault.accounts.isEmpty {
                            Menu {
                                ForEach(vault.accounts) { account in
                                    Button {
                                        if let slot = vault.nextAvailableQuickSlot() {
                                            vault.assignHotKey(slot, for: account.id)
                                        } else {
                                            recordingAccountID = account.id
                                            activeRecorderID = account.id.uuidString
                                        }
                                    } label: {
                                        Label(
                                            account.displaySubtitle.isEmpty
                                                ? account.displayTitle
                                                : "\(account.displayTitle) (\(account.displaySubtitle))",
                                            systemImage: vault.hotKey(for: account.id) != nil ? "checkmark" : "keyboard"
                                        )
                                    }
                                }
                            } label: {
                                Label("Add", systemImage: "plus.circle.fill")
                                    .font(.caption.weight(.semibold))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }

                    let boundAccounts = vault.accounts.filter {
                        vault.accountHotKeys[$0.id] != nil || recordingAccountID == $0.id
                    }

                    if boundAccounts.isEmpty {
                        Text("Bind your daily OTP (e.g. ⌃⌥1) here or via any row's context menu to copy with a single keystroke.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        VStack(spacing: 6) {
                            ForEach(boundAccounts) { account in
                                HStack(spacing: 8) {
                                    MacBrandBadgeView(account: account, size: 24)
                                        .equatable()

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(account.displayTitle)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        if !account.displaySubtitle.isEmpty {
                                            Text(account.displaySubtitle)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    HotKeyRecorderButton(
                                        recorderID: account.id.uuidString,
                                        activeRecorderID: $activeRecorderID,
                                        combo: Binding(
                                            get: { vault.hotKey(for: account.id) },
                                            set: {
                                                vault.assignHotKey($0, for: account.id)
                                                if recordingAccountID == account.id {
                                                    recordingAccountID = nil
                                                }
                                            }
                                        ),
                                        hotKeyManager: vault.hotKeyManager,
                                        onCancelRecording: {
                                            if recordingAccountID == account.id {
                                                recordingAccountID = nil
                                            }
                                        }
                                    )
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("BEHAVIOR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Auto-Type Digits on Direct Shortcut", isOn: $vault.autoTypeOnHotKey)
                            .font(.caption.weight(.medium))

                        if vault.autoTypeOnHotKey {
                            HStack(spacing: 8) {
                                Image(systemName: vault.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(vault.isAccessibilityTrusted ? .green : .orange)
                                Text(vault.isAccessibilityTrusted ? "Accessibility granted" : "Accessibility permission needed to type digits")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !vault.isAccessibilityTrusted {
                                    Button("Grant") {
                                        vault.requestAccessibilityPrompt()
                                    }
                                    .font(.caption2.weight(.semibold))
                                }
                            }
                        }

                        if !vault.accounts.isEmpty {
                            HStack {
                                Text("Live in Menu Bar")
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Picker("", selection: $vault.menuBarAccountID) {
                                    Text("Icon Only").tag(Optional<UUID>.none)
                                    ForEach(vault.accounts) { account in
                                        Text(account.displaySubtitle.isEmpty ? account.displayTitle : "\(account.displayTitle) — \(account.displaySubtitle)")
                                            .tag(Optional(account.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 190)
                            }
                        }

                        Toggle("Launch at Login", isOn: $vault.launchAtLogin)
                            .font(.caption.weight(.medium))
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("VAULT & APP")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("Import Backup…") {
                            openBackupFilePanel()
                        }
                        .font(.caption.weight(.medium))

                        Spacer()

                        Button("Refresh Sync") {
                            vault.reloadFromStore()
                        }
                        .font(.caption.weight(.medium))

                        Button("Quit", role: .destructive) {
                            NSApp.terminate(nil)
                        }
                        .font(.caption.weight(.medium))
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if let lastSync = vault.lastSyncDate {
                        Text("Last synced \(lastSync.formatted(date: .omitted, time: .shortened)) • iCloud Keychain (\(vault.accounts.count) tokens)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
        }
    }

    private func passwordPromptContent(filename: String, data: Data) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decrypt Backup")
                .font(.headline)
            Text(detectedEncryptedFormat.map { "\($0) • \(filename)" } ?? filename)
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Backup password", text: $importPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    runBackupImport(data: data, password: importPassword, filename: filename)
                }

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showingPasswordPrompt = false
                    pendingImportData = nil
                    detectedEncryptedFormat = nil
                    importPassword = ""
                    importError = nil
                }
                Spacer()
                Button("Import") {
                    runBackupImport(data: data, password: importPassword, filename: filename)
                }
                .buttonStyle(.borderedProminent)
                .disabled(importPassword.isEmpty)
            }
            Spacer()
        }
        .padding(18)
    }

    private func copyHighlightedAccount(in displayed: [OTPAccount]) {
        guard !displayed.isEmpty else { return }
        let idx = min(vault.selectedAccountIndex, displayed.count - 1)
        copyAndDismiss(displayed[idx])
    }

    private func copyAndDismiss(_ account: OTPAccount) {
        onDismiss(true)
        vault.copyCode(for: account, fromDirectHotKey: false)
    }

    private func openBackupFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an export from OTP Auth (.otpauthdb/.otpauth), 2FAS (.2fas), Aegis/Bitwarden/Raivo/Stratum/andOTP/FreeOTP+/Proton (.json), Apple Passwords/Bitwarden/1Password (.csv), Ente Auth/URI (.txt), or .glassotp."
        guard let url = onPickImportURL(panel) else {
            return
        }

        let filename = url.lastPathComponent
        isReadingImport = true
        Task.detached(priority: .userInitiated) {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = values.fileSize, fileSize > VaultImporter.maxImportFileBytes {
                    await MainActor.run {
                        isReadingImport = false
                        vault.alertMessage = "Import files are limited to 20 MB."
                    }
                    return
                }
                let data = try Data(contentsOf: url)
                guard data.count <= VaultImporter.maxImportFileBytes else {
                    await MainActor.run {
                        isReadingImport = false
                        vault.alertMessage = "Import files are limited to 20 MB."
                    }
                    return
                }
                let inspection = VaultImporter.inspect(data: data, filenameHint: filename)
                await MainActor.run {
                    isReadingImport = false
                    switch inspection {
                    case .plaintext:
                        vault.showingSettings = false
                        runBackupImport(data: data, password: nil, filename: filename)
                    case .encrypted(let hint):
                        detectedEncryptedFormat = hint
                        pendingImportData = (url, data)
                        importPassword = ""
                        importError = nil
                        vault.showingSettings = false
                        showingPasswordPrompt = true
                    case .unsupportedEncrypted(_, let guidance):
                        vault.alertMessage = guidance
                    case .fileTooLarge(let msg):
                        vault.alertMessage = msg
                    case .unrecognized:
                        vault.alertMessage = OTPImportError.invalidFileFormat.errorDescription
                    }
                }
            } catch {
                await MainActor.run {
                    isReadingImport = false
                    vault.alertMessage = "Couldn't read \(filename): \(error.localizedDescription)"
                }
            }
        }
    }

    private func runBackupImport(data: Data, password: String?, filename: String) {
        Task {
            let outcome = await vault.importBackupFile(data: data, password: password, filename: filename)
            switch outcome {
            case .success(let summary):
                showingPasswordPrompt = false
                pendingImportData = nil
                detectedEncryptedFormat = nil
                importPassword = ""
                importError = nil
                vault.alertMessage = summary
            case .failure(let error):
                if showingPasswordPrompt {
                    importError = error.localizedDescription
                } else {
                    vault.alertMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct MacAccountRowView: View {
    let account: OTPAccount
    let clock: MacOTPClock
    let folderName: String?
    let hotKey: HotKeyCombo?
    let isMenuBarLive: Bool
    let isHighlighted: Bool
    let slotIndex: Int?
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onToggleMenuBar: () -> Void
    let onAssignHotKey: (HotKeyCombo?) -> Void
    let onOpenShortcutSettings: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            MacBrandBadgeView(account: account, size: 30)
                .equatable()

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if account.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentColor)
                    }

                    if isMenuBarLive {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                if !account.displaySubtitle.isEmpty || folderName != nil {
                    HStack(spacing: 4) {
                        if !account.displaySubtitle.isEmpty {
                            Text(account.displaySubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let folderName {
                            Text(account.displaySubtitle.isEmpty ? folderName : "• \(folderName)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .layoutPriority(account.displaySubtitle.isEmpty ? 0 : 1)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let hotKey {
                Text(hotKey.displayString)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if let slotIndex {
                Text("⌘\(slotIndex)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering || isHighlighted ? 1 : 0.45)
            }

            MacLiveRightCluster(account: account, clock: clock)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isHovering || isHighlighted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onCopy()
        }
        .contextMenu {
            Button("Copy Code") {
                onCopy()
            }

            Menu("Assign Global Shortcut") {
                ForEach(1...5, id: \.self) { slot in
                    if let combo = HotKeyCombo.quickSlot(slot) {
                        Button {
                            onAssignHotKey(combo)
                        } label: {
                            Label(
                                combo.displayString,
                                systemImage: hotKey == combo ? "checkmark" : "keyboard"
                            )
                        }
                    }
                }
                Divider()
                Button("Custom Shortcut…") {
                    onOpenShortcutSettings()
                }
                if hotKey != nil {
                    Button("Clear Shortcut", role: .destructive) {
                        onAssignHotKey(nil)
                    }
                }
            }

            Button(isMenuBarLive ? "Hide from Menu Bar" : "Show Live in Menu Bar") {
                onToggleMenuBar()
            }

            Button(account.isPinned ? "Unpin" : "Pin to Top") {
                onTogglePin()
            }
        }
    }
}

private struct MacLiveRightCluster: View {
    let account: OTPAccount
    let clock: MacOTPClock

    var body: some View {
        HStack(spacing: 7) {
            if account.type == .totp {
                let timing = OTPGenerator.totpTiming(period: account.period, at: clock.now)
                let isExpiring = timing.remainingSeconds <= 5
                let code = OTPGenerator.formatCode(
                    OTPGenerator.generateHOTP(
                        secret: account.secret,
                        counter: timing.counter,
                        digits: account.digits,
                        algorithm: account.algorithm
                    )
                )

                VStack(alignment: .trailing, spacing: 0) {
                    Text(code)
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isExpiring ? Color.red : Color.primary)

                    if isExpiring {
                        let next = OTPGenerator.formatCode(
                            OTPGenerator.generateHOTP(
                                secret: account.secret,
                                counter: timing.counter &+ 1,
                                digits: account.digits,
                                algorithm: account.algorithm
                            )
                        )
                        Text("→ \(next)")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 30, alignment: .trailing)

                MacCountdownRingView(
                    remainingSeconds: timing.remainingSeconds,
                    progress: timing.progress,
                    size: 24,
                    period: timing.period
                )
            } else {
                let code = OTPGenerator.snapshot(for: account, at: Date(), includeNextCode: false).formattedCode
                Text(code)
                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(minHeight: 30, alignment: .trailing)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct HotKeyRecorderButton: View {
    let recorderID: String
    @Binding var activeRecorderID: String?
    @Binding var combo: HotKeyCombo?
    let hotKeyManager: GlobalHotKeyManager
    var onCancelRecording: (() -> Void)? = nil

    @State private var monitor: Any?

    private var isRecording: Bool {
        activeRecorderID == recorderID
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isRecording {
                    cancelRecording()
                } else {
                    beginRecording()
                }
            } label: {
                Text(isRecording ? "Press Shortcut…" : (combo?.displayString ?? "Record"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRecording ? .white : (combo != nil ? .primary : .secondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        isRecording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.75)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            .buttonStyle(.plain)

            if combo != nil && !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if isRecording {
                installMonitor()
            }
        }
        .onChange(of: activeRecorderID) { _, newValue in
            if newValue == recorderID {
                installMonitor()
            } else {
                removeMonitor()
            }
        }
        .onDisappear {
            if isRecording {
                cancelRecording()
            } else {
                removeMonitor()
            }
        }
    }

    private func beginRecording() {
        activeRecorderID = recorderID
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        hotKeyManager.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async {
                    cancelRecording()
                }
                return nil
            }
            if let captured = HotKeyCombo.from(event: event) {
                DispatchQueue.main.async {
                    combo = captured
                    activeRecorderID = nil
                    removeMonitor()
                }
                return nil
            }
            return nil
        }
    }

    private func cancelRecording() {
        activeRecorderID = nil
        onCancelRecording?()
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if activeRecorderID == nil {
            hotKeyManager.isPaused = false
        }
    }
}
