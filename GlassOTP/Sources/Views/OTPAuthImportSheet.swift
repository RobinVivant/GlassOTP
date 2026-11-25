import GlassOTPCore
import SwiftUI
import UniformTypeIdentifiers

struct OTPAuthImportSheet: View {
    @Environment(VaultViewModel.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let initialFile: PendingImportFile?
    let onDismissCleanup: () -> Void

    @State private var selectedFile: PendingImportFile?
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showingFilePicker = false
    @State private var isDecrypting = false

    @State private var decryptedFormat: String?
    @State private var decryptedFolders: [OTPFolder] = []
    @State private var decryptedAccounts: [OTPAccount] = []
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var existingFingerprints: Set<String> = []
    @State private var skipDuplicates = true

    private var allowedImportTypes: [UTType] {
        var types: [UTType] = [.data, .item]
        if let otpDB = UTType("de.cooperrs.otpauth.backup") {
            types.insert(otpDB, at: 0)
        }
        if let otpAccount = UTType("de.cooperrs.otpauth.account") {
            types.insert(otpAccount, at: 0)
        }
        if let glassBackup = UTType("com.robinvivant.glassotp.backup") {
            types.insert(glassBackup, at: 0)
        }
        return types
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        if !decryptedAccounts.isEmpty {
                            reviewStepView
                        } else if let file = selectedFile {
                            decryptStepView(file: file)
                        } else {
                            selectFileStepView
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Import Backup")
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
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        let data = try Data(contentsOf: url)
                        selectedFile = PendingImportFile(filename: url.lastPathComponent, data: data)
                        errorMessage = nil
                    } catch {
                        errorMessage = "Couldn't read file: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .onAppear {
                if selectedFile == nil, let initialFile {
                    selectedFile = initialFile
                }
            }
            .onDisappear {
                onDismissCleanup()
            }
        }
    }

    private var selectFileStepView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)

                Text("Import from OTP Auth")
                    .font(.title3.bold())

                Text("Select an encrypted `.otpauthdb` database backup, `.otpauth` single account export, or `.glassotp` vault archive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingFilePicker = true
                } label: {
                    Label("Choose Backup File", systemImage: "folder.badge.plus")
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
                Label("Where to get your OTP Auth file", systemImage: "icloud.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text("1. Open OTP Auth on your iPhone -> Settings -> Backups -> Export Encrypted Backup -> choose GlassOTP or Save to Files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("2. Or copy `Accounts.otpauthdb` from your Mac's iCloud Drive (`iCloud~de~cooperrs~Authenticator`) into iCloud Drive / Files and select it here.")
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
                        Text("100% On-Device AES-256 Decryption • \(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Change") {
                        selectedFile = nil
                        password = ""
                        errorMessage = nil
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
                }

                SecureField("Backup Password", text: $password)
                    .textContentType(.password)
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

                if duplicateCount > 0 {
                    Toggle("Skip \(duplicateCount) duplicate \(duplicateCount == 1 ? "account" : "accounts")", isOn: $skipDuplicates)
                        .font(.subheadline)
                }

                Button {
                    let count = vault.importAccounts(
                        selectedAccounts,
                        folders: decryptedFolders,
                        skipDuplicates: skipDuplicates
                    )
                    if count > 0 && vault.shouldSuggestAutoCategorize {
                        let plan = AccountCategorizer.buildPlan(accounts: vault.accounts, folders: vault.folders)
                        let assignments = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.category) })
                        vault.applyCategorization(assignments, removeEmptyDefaultFolder: true)
                    }
                    Task {
                        _ = await vault.fetchMissingWebLogos()
                    }
                    vault.alertMessage = count == 0
                        ? "All selected accounts were already in your vault."
                        : "Imported \(count) \(count == 1 ? "account" : "accounts") into GlassOTP."
                    onDismissCleanup()
                    dismiss()
                } label: {
                    Text("Import \(finalImportCount) \(finalImportCount == 1 ? "Account" : "Accounts")")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(finalImportCount == 0)
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            LazyVStack(spacing: 10) {
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
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                            BrandAvatarView(account: account, size: 38, logoRevision: vault.logoCacheRevision)
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
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    private func decryptSelectedFile() {
        guard let file = selectedFile else { return }
        isDecrypting = true
        errorMessage = nil

        let fileData = file.data
        let filename = file.filename
        let enteredPassword = password

        Task {
            do {
                let result: OTPAuthImportResult = try await Task.detached(priority: .userInitiated) {
                    if GlassOTPBackupCodec.isGlassOTPBackup(fileData) {
                        let snapshot = try GlassOTPBackupCodec.decode(data: fileData, password: enteredPassword)
                        return OTPAuthImportResult(
                            formatDescription: "GlassOTP Encrypted Backup",
                            folders: snapshot.folders,
                            accounts: snapshot.accounts
                        )
                    }
                    return try OTPAuthImporter.importFile(
                        data: fileData,
                        password: enteredPassword,
                        filenameHint: filename
                    )
                }.value

                decryptedFormat = result.formatDescription
                decryptedFolders = result.folders
                decryptedAccounts = result.accounts
                selectedAccountIDs = Set(result.accounts.map(\.id))
                existingFingerprints = vault.existingFingerprints()
                isDecrypting = false
            } catch {
                errorMessage = error.localizedDescription
                isDecrypting = false
            }
        }
    }
}
