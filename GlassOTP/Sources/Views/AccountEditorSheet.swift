import GlassOTPCore
import SwiftUI

struct AccountEditorSheet: View {
    @Environment(VaultViewModel.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let existingAccount: OTPAccount?

    @State private var issuer: String
    @State private var label: String
    @State private var base32Secret: String
    @State private var type: OTPType
    @State private var algorithm: OTPAlgorithm
    @State private var digits: Int
    @State private var period: Int
    @State private var counter: UInt64
    @State private var folderID: UUID?
    @State private var isPinned: Bool
    @State private var showAdvanced = false

    init(account: OTPAccount?, defaultFolderID: UUID?) {
        self.existingAccount = account
        _issuer = State(initialValue: account?.issuer ?? "")
        _label = State(initialValue: account?.label ?? "")
        _base32Secret = State(initialValue: account.map { Base32.encode($0.secret) } ?? "")
        _type = State(initialValue: account?.type ?? .totp)
        _algorithm = State(initialValue: account?.algorithm ?? .sha1)
        _digits = State(initialValue: account?.digits ?? 6)
        _period = State(initialValue: account?.period ?? 30)
        _counter = State(initialValue: account?.counter ?? 0)
        _folderID = State(initialValue: account?.folderID ?? defaultFolderID)
        _isPinned = State(initialValue: account?.isPinned ?? false)
    }

    private var decodedSecret: Data? {
        let trimmed = base32Secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = try? Base32.decode(trimmed), !data.isEmpty else {
            return nil
        }
        return data
    }

    private var previewCode: String? {
        guard let secret = decodedSecret else { return nil }
        let temp = OTPAccount(
            issuer: issuer,
            label: label,
            secret: secret,
            type: type,
            algorithm: algorithm,
            digits: digits,
            period: period,
            counter: counter
        )
        return OTPGenerator.snapshot(for: temp).formattedCode
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackground()

                Form {
                    if let previewCode {
                        Section("Live Preview") {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issuer.isEmpty ? (label.isEmpty ? "Account" : label) : issuer)
                                        .font(.headline)
                                    if !issuer.isEmpty && !label.isEmpty {
                                        Text(label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(previewCode)
                                    .font(.title2.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    Section("Account Details") {
                        TextField("Issuer (e.g. GitHub, Cloudflare)", text: $issuer)
                            .textInputAutocapitalization(.words)
                        TextField("Account Label (e.g. alex@example.com)", text: $label)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Base32 Secret Key", text: $base32Secret)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()

                        if !base32Secret.isEmpty && decodedSecret == nil {
                            Label("Invalid Base32 secret (allowed: A–Z, 2–7)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("Organization") {
                        Toggle("Pin to Top & Widgets", isOn: $isPinned)

                        if !vault.folders.isEmpty {
                            Picker("Folder", selection: $folderID) {
                                Text("Uncategorized").tag(Optional<UUID>.none)
                                ForEach(vault.folders) { folder in
                                    Label(folder.name, systemImage: folder.symbolName)
                                        .tag(Optional(folder.id))
                                }
                            }
                        }

                        if let existingAccount {
                            if vault.accounts.contains(where: { $0.id == existingAccount.id }) {
                                Button {
                                    dismiss()
                                    vault.brandPickerAccount = existingAccount
                                } label: {
                                    HStack {
                                        Label("Service Logo", systemImage: "sparkles")
                                        Spacer()
                                        BrandAvatarView(account: existingAccount, size: 28, logoRevision: vault.logoCacheRevision)
                                            .equatable()
                                    }
                                }
                            } else {
                                Text("Save this scanned account first to choose a custom logo.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        DisclosureGroup("Advanced OTP Parameters", isExpanded: $showAdvanced) {
                            Picker("Type", selection: $type) {
                                ForEach(OTPType.allCases) { otpType in
                                    Text(otpType.displayName).tag(otpType)
                                }
                            }

                            Picker("Algorithm", selection: $algorithm) {
                                ForEach(OTPAlgorithm.selectableCases) { algo in
                                    Text(algo.displayName).tag(algo)
                                }
                            }

                            Picker("Digits", selection: $digits) {
                                ForEach(4...10, id: \.self) { count in
                                    Text("\(count) Digits").tag(count)
                                }
                            }

                            if type == .totp {
                                let periodOptions = Array(Set([15, 30, 60, 90, max(1, period)])).sorted()
                                Picker("Period", selection: $period) {
                                    ForEach(periodOptions, id: \.self) { secs in
                                        Text("\(secs) seconds").tag(secs)
                                    }
                                }
                            } else {
                                Stepper("Counter: \(counter)", value: $counter, in: 0...UInt64.max)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(existingAccount == nil ? "Add Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let secret = decodedSecret else { return }
                        let updated = OTPAccount(
                            id: existingAccount?.id ?? UUID(),
                            issuer: issuer,
                            label: label,
                            secret: secret,
                            type: type,
                            algorithm: algorithm,
                            digits: digits,
                            period: period,
                            counter: counter,
                            folderID: folderID,
                            isPinned: isPinned,
                            sortOrder: existingAccount?.sortOrder ?? vault.accounts.count,
                            createdAt: existingAccount?.createdAt ?? Date(),
                            updatedAt: Date(),
                            customBrandSlug: existingAccount?.customBrandSlug,
                            customLogoDomain: existingAccount?.customLogoDomain
                        )
                        if vault.upsertAccount(updated) {
                            dismiss()
                        }
                    }
                    .disabled(decodedSecret == nil || (issuer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }
}
