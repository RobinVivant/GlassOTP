import GlassOTPCore
import SwiftUI
import UniformTypeIdentifiers

struct GlassOTPBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [
        UTType("com.robinvivant.glassotp.backup") ?? .data,
    ]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @Environment(VaultViewModel.self) private var vault
    @Environment(BiometricLockManager.self) private var security

    @State private var showingExportPasswordPrompt = false
    @State private var exportPassword = ""
    @State private var exportConfirmPassword = ""
    @State private var exportDocument: GlassOTPBackupDocument?
    @State private var showingFileExporter = false
    @State private var showingWidgetGuide = false
    @State private var showingICloudDisableConfirmation = false
    @State private var isExportingBackup = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportOperationID = UUID()
    @State private var exportErrorMessage: String?

    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { vault.iCloudSyncEnabled },
            set: { newValue in
                if newValue {
                    vault.updateICloudSync(enabled: true, removeFromICloud: true)
                } else {
                    showingICloudDisableConfirmation = true
                }
            }
        )
    }

    private var biometricLockBinding: Binding<Bool> {
        Binding(
            get: { security.biometricLockEnabled },
            set: { newValue in
                if newValue {
                    if !security.canEvaluateDeviceAuthentication() {
                        vault.alertMessage = "Set a device passcode or enable \(security.biometryDisplayName) in iOS Settings before enabling app lock."
                        return
                    }
                    security.biometricLockEnabled = true
                } else {
                    Task {
                        let result = await security.verifyDeviceOwner(reason: "Authenticate to disable GlassOTP App Lock")
                        if result.succeeded {
                            security.biometricLockEnabled = false
                        } else if let errorMessage = result.errorMessage {
                            vault.alertMessage = errorMessage
                        }
                    }
                }
            }
        )
    }

    var body: some View {
        @Bindable var bindableVault = vault
        @Bindable var bindableSecurity = security

        ZStack {
            AmbientGlassBackground()

            Form {
                Section {
                    Button {
                        vault.showingAutoCategorizeSheet = true
                    } label: {
                        Label("Auto-Categorize & Match Logos", systemImage: "wand.and.stars")
                    }
                    .disabled(vault.accounts.isEmpty)

                    Button {
                        Task {
                            let fetched = await vault.fetchMissingWebLogos()
                            vault.alertMessage = fetched == 0
                                ? "All recognizable service logos are already loaded."
                                : "Fetched \(fetched) additional service \(fetched == 1 ? "logo" : "logos")."
                        }
                    } label: {
                        Label("Fetch Missing Web Logos", systemImage: "arrow.down.circle")
                    }
                    .disabled(vault.accounts.isEmpty)
                } header: {
                    Text("Logos & Categorization")
                } footer: {
                    Text("Fetching web logos sends the service domains (never account usernames or secrets) to Google Favicons (www.google.com/s2/favicons).")
                }

                Section("Migration & Backup") {
                    Button {
                        vault.showingImportSheet = true
                    } label: {
                        Label("Import Backup or Export…", systemImage: "square.and.arrow.down.on.square")
                    }

                    Button {
                        exportTask?.cancel()
                        exportTask = nil
                        exportOperationID = UUID()
                        exportDocument = nil
                        exportErrorMessage = nil
                        isExportingBackup = false
                        exportPassword = ""
                        exportConfirmPassword = ""
                        showingExportPasswordPrompt = true
                    } label: {
                        Label("Export Encrypted Backup (.glassotp)", systemImage: "lock.doc")
                    }
                    .disabled(vault.accounts.isEmpty)
                }

                Section {
                    Toggle("iCloud Keychain Sync", isOn: iCloudSyncBinding)
                    if vault.hasPendingICloudCleanup && !vault.iCloudSyncEnabled {
                        Button("Retry Deleting iCloud Copy", role: .destructive) {
                            vault.retryPendingICloudCleanup()
                        }
                    }
                } header: {
                    Text("Sync & Storage")
                } footer: {
                    Text("Tokens are stored inside Apple's encrypted Keychain. When enabled, iCloud Keychain syncs your vault automatically across devices signed into your Apple Account.")
                }

                Section {
                    Toggle("Universal Clipboard (Copy Across Devices)", isOn: $bindableVault.universalClipboardEnabled)
                    Toggle("Require \(security.biometryDisplayName) Lock", isOn: biometricLockBinding)

                    if security.biometricLockEnabled {
                        Picker("Auto-Lock Delay", selection: $bindableSecurity.autoLockDelaySeconds) {
                            Text("Immediately").tag(0)
                            Text("After 30 seconds").tag(30)
                            Text("After 2 minutes").tag(120)
                        }
                    }

                    Toggle("Blur in App Switcher", isOn: $bindableSecurity.appSwitcherBlurEnabled)
                    Toggle("Mask Codes Until Tapped", isOn: $bindableVault.hideCodesInApp)
                } header: {
                    Text("Security & Privacy")
                } footer: {
                    Text("When Universal Clipboard is enabled, copied OTP codes sync to your nearby Mac and iPad via Handoff. Turn it off for silent local-only 60s copies from widgets. When App Lock is enabled, widgets stay masked and open GlassOTP.")
                }

                Section("Home & Lock Screen Widgets") {
                    Button {
                        showingWidgetGuide = true
                    } label: {
                        Label("How to Add & Customize Widgets", systemImage: "rectangle.3.group.bubble")
                    }
                }

                Section("About") {
                    LabeledContent("Vault Accounts", value: "\(vault.accounts.count)")
                    LabeledContent("Folders", value: "\(vault.folders.count)")
                    LabeledContent("Format", value: "RFC 4226 / 6238 • scrypt + AES-256-GCM")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Turn Off iCloud Keychain Sync?",
            isPresented: $showingICloudDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Use Local-Only & Keep iCloud Copy") {
                vault.updateICloudSync(enabled: false, removeFromICloud: false)
            }
            Button("Turn Off & Delete iCloud Copy", role: .destructive) {
                vault.updateICloudSync(enabled: false, removeFromICloud: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting the iCloud copy writes a synchronizable empty retirement record so other devices running GlassOTP 1.2 or later switch to local storage with the vault they last loaded. Update and open your other devices first, or keep the iCloud copy and switch only this device to local storage.")
        }
        .sheet(isPresented: $showingExportPasswordPrompt, onDismiss: {
            exportOperationID = UUID()
            exportTask?.cancel()
            exportTask = nil
            isExportingBackup = false
            exportErrorMessage = nil
            exportPassword = ""
            exportConfirmPassword = ""
            if exportDocument != nil {
                showingFileExporter = true
            }
        }) {
            NavigationStack {
                Form {
                    if let exportErrorMessage {
                        Section {
                            Label(exportErrorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Section {
                        SecureField("Backup Password (min 8 chars)", text: $exportPassword)
                        SecureField("Confirm Password", text: $exportConfirmPassword)
                    } header: {
                        Text("AES-256-GCM + scrypt (GLOTP2)")
                    } footer: {
                        Text("Use at least 8 characters. GlassOTP cannot recover lost backup passwords.")
                    }
                }
                .navigationTitle("Encrypt Vault Backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            exportOperationID = UUID()
                            exportTask?.cancel()
                            exportTask = nil
                            isExportingBackup = false
                            exportDocument = nil
                            showingExportPasswordPrompt = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            let snapshot = vault.makeBackupSnapshot()
                            let pwd = exportPassword
                            let currentOpID = UUID()
                            exportOperationID = currentOpID
                            exportErrorMessage = nil
                            isExportingBackup = true
                            exportTask?.cancel()
                            exportTask = Task {
                                do {
                                    let worker = Task.detached(priority: .userInitiated) {
                                        try GlassOTPBackupCodec.encode(snapshot: snapshot, password: pwd)
                                    }
                                    let encoded = try await withTaskCancellationHandler {
                                        try await worker.value
                                    } onCancel: {
                                        worker.cancel()
                                    }
                                    guard exportOperationID == currentOpID,
                                          !Task.isCancelled,
                                          showingExportPasswordPrompt else {
                                        return
                                    }
                                    isExportingBackup = false
                                    exportDocument = GlassOTPBackupDocument(data: encoded)
                                    showingExportPasswordPrompt = false
                                } catch is CancellationError {
                                    if exportOperationID == currentOpID {
                                        isExportingBackup = false
                                    }
                                } catch {
                                    guard exportOperationID == currentOpID, !Task.isCancelled else {
                                        return
                                    }
                                    isExportingBackup = false
                                    exportErrorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            if isExportingBackup {
                                ProgressView()
                            } else {
                                Text("Export")
                            }
                        }
                        .disabled(isExportingBackup || exportPassword.count < 8 || exportPassword != exportConfirmPassword)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .fileExporter(
            isPresented: $showingFileExporter,
            document: exportDocument,
            contentType: UTType("com.robinvivant.glassotp.backup") ?? .data,
            defaultFilename: "GlassOTP-Backup"
        ) { result in
            exportDocument = nil
            exportPassword = ""
            exportConfirmPassword = ""
            if case .failure(let error) = result {
                vault.alertMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingWidgetGuide) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        guideStep(
                            number: "1",
                            title: "Pin Favorite Accounts",
                            body: "Long-press any account in the Vault tab and tap Pin to Top & Widgets. Widgets prioritize pinned accounts automatically."
                        )
                        guideStep(
                            number: "2",
                            title: "Add a Home or Lock Screen Widget",
                            body: "Touch and hold your Home Screen, tap Edit > Add Widget, and pick GlassOTP (Small, Medium, Large, or Lock Screen)."
                        )
                        guideStep(
                            number: "3",
                            title: "Customize Account & Privacy Mode",
                            body: "Long-press a GlassOTP widget > Edit Widget to pick a specific account or turn on Tap to Reveal so codes stay masked until tapped. Tapping Copy on Home Screen or Lock Screen widgets copies via Universal Clipboard when enabled."
                        )
                        guideStep(
                            number: "4",
                            title: "Running on Your Own iPhone",
                            body: "In Xcode, select your Apple Developer Team on both GlassOTP and GlassOTPWidgetExtension targets so shared App Group and iCloud Keychain entitlements are signed for your device."
                        )
                    }
                    .padding(20)
                }
                .navigationTitle("Widget & Sync Guide")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingWidgetGuide = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func guideStep(number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
