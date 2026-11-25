import GlassOTPCore
import SwiftUI
import UniformTypeIdentifiers

struct OTPAuthImportSheet: View {
    @Environment(VaultViewModel.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let initialFile: PendingImportFile?
    let onDismissCleanup: () -> Void

    @State private var selectedFile: PendingImportFile?
    @State private var detectedEncryptedFormat: String?
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showingFilePicker = false
    @State private var isDecrypting = false
    @State private var hasDecodedImport = false
    @State private var activeTask: Task<Void, Never>?

    @State private var decryptedFormat: String?
    @State private var decryptedFolders: [OTPFolder] = []
    @State private var decryptedAccounts: [OTPAccount] = []
    @State private var skippedEntriesCount = 0
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var existingFingerprints: Set<String> = []
    @State private var skipDuplicates = true

    private var allowedImportTypes: [UTType] {
        var types: [UTType] = [.json, .commaSeparatedText, .plainText, .data, .item]
        for identifier in [
            "com.robinvivant.glassotp.backup",
            "de.cooperrs.otpauth.backup",
            "de.cooperrs.otpauth.account",
        ] {
            if let utType = UTType(identifier) {
                types.insert(utType, at: 0)
            }
        }
        for ext in ["2fas", "authpro"] {
            if let utType = UTType(filenameExtension: ext) {
                types.insert(utType, at: 0)
            }
        }
        return types
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        if hasDecodedImport {
                            reviewStepView
                        } else if isDecrypting && detectedEncryptedFormat == nil {
                            loadingStepView
                        } else if let file = selectedFile {
                            decryptStepView(file: file)
                        } else {
                            selectFileStepView
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Import Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismissCleanup()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: allowedImportTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    loadPickedURL(url)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .onAppear {
                if selectedFile == nil, !hasDecodedImport, let initialFile {
                    handleSelectedFile(initialFile)
                }
            }
            .onDisappear {
                activeTask?.cancel()
                onDismissCleanup()
            }
        }
    }

    private var loadingStepView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Reading \(selectedFile?.filename ?? "export")…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var selectFileStepView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)

                Text("Import Accounts")
                    .font(.title3.bold())

                Text("Select an encrypted backup or export from 2FAS, Aegis, Ente Auth, Apple Passwords, Bitwarden, 1Password, Raivo, Stratum, FreeOTP+, Proton, OTP Auth, or GlassOTP.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingFilePicker = true
                } label: {
                    Label("Choose File", systemImage: "folder.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 10) {
                Label("Supported formats & tips", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text("• **Encrypted:** Aegis (`.json`), 2FAS (`.2fas`), OTP Auth (`.otpauthdb`, `.otpauth`), Authenticator Pro legacy (`.authpro`), GlassOTP (`.glassotp`).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("• **JSON / CSV / URI Lists:** Aegis, 2FAS, Bitwarden, Raivo, Stratum, andOTP, FreeOTP+, Proton Authenticator, Apple Passwords, 1Password, Ente Auth (`.txt`).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("• **OTP Auth Tip:** Export via OTP Auth -> Settings -> Backups -> Export Encrypted Backup -> Share directly to GlassOTP or Save to Files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
    }

    private func decryptStepView(file: PendingImportFile) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.doc.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(detectedEncryptedFormat ?? "Encrypted Backup") • \(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Change") {
                        activeTask?.cancel()
                        isDecrypting = false
                        hasDecodedImport = false
                        selectedFile = nil
                        detectedEncryptedFormat = nil
                        decryptedFormat = nil
                        decryptedFolders = []
                        decryptedAccounts = []
                        password = ""
                        errorMessage = nil
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
                    .disabled(isDecrypting)
                }

                SecureField("Backup Password", text: $password)
                    .textContentType(.password)
                    .disabled(isDecrypting)
                    .padding(14)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .submitLabel(.go)
                    .onSubmit {
                        decryptSelectedFile()
                    }

                if let errorMessage {
                    errorBanner(errorMessage)
                }

                Button {
                    decryptSelectedFile()
                } label: {
                    HStack {
                        if isDecrypting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label("Decrypt Backup", systemImage: "key.fill")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(password.isEmpty || isDecrypting)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
        }
    }

    private var reviewStepView: some View {
        let existing = existingFingerprints
        let selectedAccounts = decryptedAccounts.filter { selectedAccountIDs.contains($0.id) }
        let duplicateCount = selectedAccounts.filter { existing.contains($0.fingerprint) }.count
        let finalImportCount = skipDuplicates ? (selectedAccounts.count - duplicateCount) : selectedAccounts.count
        let preserveEmpty = decryptedFormat == "GlassOTP Encrypted Backup"
            && selectedAccounts.count == decryptedAccounts.count
        let previewPlan = VaultImportReconciler.reconcile(
            importedAccounts: selectedAccounts,
            importedFolders: decryptedFolders,
            existingAccounts: vault.accounts,
            existingFolders: vault.folders,
            skipDuplicates: skipDuplicates,
            preserveEmptyFolders: preserveEmpty
        )
        let newFolderCount = max(0, previewPlan.folders.count - vault.folders.count)
        let canImport = finalImportCount > 0 || (preserveEmpty && newFolderCount > 0)
        let buttonTitle: String = {
            if finalImportCount == 0 && newFolderCount > 0 {
                return "Import \(newFolderCount) \(newFolderCount == 1 ? "Folder" : "Folders")"
            }
            return "Import \(finalImportCount) \(finalImportCount == 1 ? "Account" : "Accounts")"
        }()

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(decryptedFormat ?? "Decrypted Archive", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Spacer()
                    Text("\(decryptedAccounts.count) found")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if !decryptedFolders.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(decryptedFolders) { folder in
                                Label(folder.name, systemImage: folder.symbolName)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                        }
                    }
                }

                if skippedEntriesCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Skipped \(skippedEntriesCount) unsupported \(skippedEntriesCount == 1 ? "entry" : "entries") (such as Steam, mOTP, MD5, or invalid secrets).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if duplicateCount > 0 {
                    Toggle("Skip \(duplicateCount) duplicate \(duplicateCount == 1 ? "account" : "accounts")", isOn: $skipDuplicates)
                        .font(.subheadline)
                }

                if let errorMessage {
                    errorBanner(errorMessage)
                }

                Button {
                    let summary = vault.importAccounts(
                        selectedAccounts,
                        folders: decryptedFolders,
                        skipDuplicates: skipDuplicates,
                        preserveEmptyFolders: preserveEmpty
                    )
                    guard summary.saved else {
                        errorMessage = vault.alertMessage ?? "Couldn't save imported accounts to Keychain."
                        vault.alertMessage = nil
                        return
                    }
                    let count = summary.addedCount
                    let folderCount = summary.addedFoldersCount
                    if count == 0 && folderCount > 0 {
                        vault.alertMessage = "Imported \(folderCount) \(folderCount == 1 ? "folder" : "folders") into GlassOTP."
                    } else if skippedEntriesCount > 0 && count > 0 {
                        vault.alertMessage = "Imported \(count) \(count == 1 ? "account" : "accounts") into GlassOTP (\(skippedEntriesCount) unsupported skipped)."
                    } else {
                        vault.alertMessage = count == 0
                            ? "All selected accounts were already in your vault."
                            : "Imported \(count) \(count == 1 ? "account" : "accounts") into GlassOTP."
                    }
                    onDismissCleanup()
                    dismiss()
                } label: {
                    Text(buttonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canImport)
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            LazyVStack(spacing: 6) {
                ForEach(decryptedAccounts) { account in
                    let isDuplicate = existing.contains(account.fingerprint)
                    let isSelected = selectedAccountIDs.contains(account.id)
                    Button {
                        if isSelected {
                            selectedAccountIDs.remove(account.id)
                        } else {
                            selectedAccountIDs.insert(account.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                            BrandAvatarView(account: account, size: 32, logoRevision: vault.logoCacheRevision)
                                .equatable()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if !account.displaySubtitle.isEmpty {
                                    Text(account.displaySubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if isDuplicate {
                                Text("Duplicate")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.orange.opacity(0.14), in: Capsule())
                            } else {
                                Text(account.type.shortLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadPickedURL(_ url: URL) {
        activeTask?.cancel()
        isDecrypting = true
        errorMessage = nil
        selectedFile = PendingImportFile(filename: url.lastPathComponent, data: Data())

        activeTask = Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = values.fileSize, fileSize > VaultImporter.maxImportFileBytes {
                    await MainActor.run {
                        selectedFile = nil
                        isDecrypting = false
                        errorMessage = "Import files are limited to 20 MB."
                    }
                    return
                }
                let data = try Data(contentsOf: url)
                try Task.checkCancellation()
                guard data.count <= VaultImporter.maxImportFileBytes else {
                    await MainActor.run {
                        selectedFile = nil
                        isDecrypting = false
                        errorMessage = "Import files are limited to 20 MB."
                    }
                    return
                }
                let loaded = PendingImportFile(filename: url.lastPathComponent, data: data)
                await MainActor.run {
                    handleSelectedFile(loaded)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    selectedFile = nil
                    isDecrypting = false
                    errorMessage = "Couldn't read file: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleSelectedFile(_ file: PendingImportFile) {
        activeTask?.cancel()
        password = ""
        errorMessage = nil
        detectedEncryptedFormat = nil
        skippedEntriesCount = 0
        isDecrypting = true

        let fileData = file.data
        let filename = file.filename

        activeTask = Task.detached(priority: .userInitiated) {
            let inspection = VaultImporter.inspect(data: fileData, filenameHint: filename)
            if Task.isCancelled { return }

            switch inspection {
            case .plaintext:
                do {
                    let result = try VaultImporter.importFile(data: fileData, password: nil, filenameHint: filename)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        selectedFile = file
                        decryptedFormat = result.formatDescription
                        decryptedFolders = result.folders
                        decryptedAccounts = result.accounts
                        skippedEntriesCount = result.skippedEntries
                        selectedAccountIDs = Set(result.accounts.map(\.id))
                        existingFingerprints = vault.existingFingerprints()
                        hasDecodedImport = true
                        isDecrypting = false
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        selectedFile = nil
                        errorMessage = error.localizedDescription
                        isDecrypting = false
                    }
                }
            case .encrypted(let formatHint):
                await MainActor.run {
                    selectedFile = file
                    detectedEncryptedFormat = formatHint
                    isDecrypting = false
                }
            case .unsupportedEncrypted(_, let guidance):
                await MainActor.run {
                    selectedFile = nil
                    errorMessage = guidance
                    isDecrypting = false
                }
            case .fileTooLarge(let msg):
                await MainActor.run {
                    selectedFile = nil
                    errorMessage = msg
                    isDecrypting = false
                }
            case .unrecognized:
                await MainActor.run {
                    selectedFile = nil
                    errorMessage = OTPImportError.invalidFileFormat.errorDescription
                    isDecrypting = false
                }
            }
        }
    }

    private func decryptSelectedFile() {
        guard !isDecrypting, !password.isEmpty, let file = selectedFile else { return }
        activeTask?.cancel()
        isDecrypting = true
        errorMessage = nil
        skippedEntriesCount = 0

        let fileData = file.data
        let filename = file.filename
        let enteredPassword = password

        activeTask = Task.detached(priority: .userInitiated) {
            do {
                let result: OTPAuthImportResult = try VaultImporter.importFile(
                    data: fileData,
                    password: enteredPassword,
                    filenameHint: filename
                )
                if Task.isCancelled { return }

                await MainActor.run {
                    decryptedFormat = result.formatDescription
                    decryptedFolders = result.folders
                    decryptedAccounts = result.accounts
                    skippedEntriesCount = result.skippedEntries
                    selectedAccountIDs = Set(result.accounts.map(\.id))
                    existingFingerprints = vault.existingFingerprints()
                    hasDecodedImport = true
                    isDecrypting = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDecrypting = false
                }
            }
        }
    }
}
