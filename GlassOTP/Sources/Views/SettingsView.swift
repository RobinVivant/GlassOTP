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

    var body: some View {
        @Bindable var bindableVault = vault
        @Bindable var bindableSecurity = security

        ZStack {
            AmbientGlassBackground()

            Form {
                Section("Logos & Categorization") {
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
                }

                Section("Migration & Backup") {
                    Button {
                        vault.showingImportSheet = true
                    } label: {
                        Label("Import Backup or Export…", systemImage: "square.and.arrow.down.on.square")
                    }

                    Button {
                        exportPassword = ""
                        exportConfirmPassword = ""
                        showingExportPasswordPrompt = true
                    } label: {
                        Label("Export Encrypted Backup (.glassotp)", systemImage: "lock.doc")
                    }
                    .disabled(vault.accounts.isEmpty)
                }

                Section {
                    Toggle("iCloud Keychain Sync", isOn: $bindableVault.iCloudSyncEnabled)
                } header: {
                    Text("Sync & Storage")
                } footer: {
                    Text("Tokens are stored inside Apple's encrypted Keychain. When enabled, iCloud Keychain syncs your vault automatically across devices signed into your Apple Account.")
                }

                Section {
                    Toggle("Universal Clipboard (Copy Across Devices)", isOn: $bindableVault.universalClipboardEnabled)
                    Toggle("Require \(security.biometryDisplayName) Lock", isOn: $bindableSecurity.biometricLockEnabled)

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
                    Text("When Universal Clipboard is enabled, copied OTP codes sync to your nearby Mac and iPad via Handoff (tapping a Home Screen or Lock Screen widget briefly opens GlassOTP so iOS broadcasts across devices). Turn it off for silent local-only 60s copies from widgets.")
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
                    LabeledContent("Format", value: "RFC 4226 / 6238 + RNCryptor v3")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingExportPasswordPrompt) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Backup Password", text: $exportPassword)
                        SecureField("Confirm Password", text: $exportConfirmPassword)
                    } header: {
                        Text("AES-256 + RNCryptor v3")
                    } footer: {
                        Text("Choose a strong password. GlassOTP cannot recover lost backup passwords.")
                    }
                }
                .navigationTitle("Encrypt Vault Backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingExportPasswordPrompt = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Export") {
                            do {
                                let encoded = try GlassOTPBackupCodec.encode(
                                    snapshot: vault.makeBackupSnapshot(),
                                    password: exportPassword
                                )
                                exportDocument = GlassOTPBackupDocument(data: encoded)
                                showingExportPasswordPrompt = false
                                showingFileExporter = true
                            } catch {
                                vault.alertMessage = error.localizedDescription
                            }
                        }
                        .disabled(exportPassword.isEmpty || exportPassword != exportConfirmPassword)
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
                            body: "Long-press or swipe right on any account in the Vault tab and tap Pin. Widgets prioritize pinned accounts automatically."
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
