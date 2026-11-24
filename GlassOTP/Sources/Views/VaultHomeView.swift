import GlassOTPCore
import SwiftUI

struct VaultHomeView: View {
    @Environment(VaultViewModel.self) private var vault
    @Namespace private var filterNamespace

    var body: some View {
        ZStack {
            AmbientGlassBackground()

            if vault.accounts.isEmpty {
                emptyVaultView
            } else {
                populatedVaultView
            }
        }
        .navigationTitle("GlassOTP")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    vault.hideCodesInApp.toggle()
                } label: {
                    Image(systemName: vault.hideCodesInApp ? "eye.slash.fill" : "eye.fill")
                }
                .accessibilityLabel(vault.hideCodesInApp ? "Show Codes" : "Mask Codes")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        vault.showingImportSheet = true
                    } label: {
                        Label("Import from OTP Auth (.otpauthdb)", systemImage: "square.and.arrow.down.on.square")
                    }

                    Button {
                        vault.showingScannerSheet = true
                    } label: {
                        Label("Scan QR Code or Photo", systemImage: "qrcode.viewfinder")
                    }

                    Button {
                        vault.showingNewAccountSheet = true
                    } label: {
                        Label("Add Account Manually", systemImage: "keyboard")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private var emptyVaultView: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: 82, height: 82)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .circle)

                    VStack(spacing: 6) {
                        Text("Welcome to GlassOTP")
                            .font(.title2.bold())
                        Text("Bring all your existing 2FA tokens from OTP Auth in seconds — decrypted 100% locally on your iPhone and synced via iCloud Keychain.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 10) {
                        Button {
                            vault.showingImportSheet = true
                        } label: {
                            Label("Import from OTP Auth", systemImage: "square.and.arrow.down.on.square")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)

                        HStack(spacing: 10) {
                            Button {
                                vault.showingScannerSheet = true
                            } label: {
                                Label("Scan QR", systemImage: "qrcode.viewfinder")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.glass)

                            Button {
                                vault.showingNewAccountSheet = true
                            } label: {
                                Label("Manual Entry", systemImage: "keyboard")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Label("How to export from OTP Auth", systemImage: "info.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)

                    Text("Open OTP Auth on your iPhone -> Settings -> Backups -> Export Encrypted Backup (.otpauthdb) -> Share directly to GlassOTP, or save to Files and pick it above. Supports both .otpauthdb and single .otpauth files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
        }
    }

    private var populatedVaultView: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !vault.folders.isEmpty {
                        folderFilterBar
                    }

                    if vault.selectedFolderID == nil && !vault.pinnedAccounts.isEmpty {
                        pinnedSection(date: context.date)
                    }

                    accountsSection(date: context.date)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var folderFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    filterChip(title: "All", symbol: "tray.full.fill", folderID: nil)

                    ForEach(vault.folders) { folder in
                        filterChip(title: folder.name, symbol: folder.symbolName, folderID: folder.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    private func filterChip(title: String, symbol: String, folderID: UUID?) -> some View {
        let isSelected = vault.selectedFolderID == folderID
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                vault.selectedFolderID = folderID
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(
                    isSelected
                        ? .regular.tint(Color.accentColor).interactive()
                        : .regular.interactive(),
                    in: .capsule
                )
                .glassEffectID(folderID?.uuidString ?? "all", in: filterNamespace)
        }
        .buttonStyle(.plain)
    }

    private func pinnedSection(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PINNED")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vault.pinnedAccounts) { account in
                        PinnedOTPCardView(account: account, date: date)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func accountsSection(date: Date) -> some View {
        let displayed = vault.filteredAccounts
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(vault.selectedFolderID == nil ? "ALL CODES" : (vault.folderName(for: vault.selectedFolderID)?.uppercased() ?? "FOLDER"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(displayed.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)

            if displayed.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("No accounts are assigned to this folder yet.")
                )
                .padding(.top, 20)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayed) { account in
                        OTPCardView(
                            account: account,
                            folderName: vault.selectedFolderID == nil ? vault.folderName(for: account.folderID) : nil,
                            date: date
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}
