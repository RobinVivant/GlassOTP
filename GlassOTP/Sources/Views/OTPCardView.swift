import GlassOTPCore
import SwiftUI

struct PinnedOTPCardView: View {
    @Environment(VaultViewModel.self) private var vault
    let account: OTPAccount
    let date: Date

    var body: some View {
        let snapshot = OTPGenerator.snapshot(for: account, at: date)
        let isVisible = vault.isCodeVisible(for: account.id)
        let brand = account.brandStyle

        Button {
            vault.copyCode(for: account, at: date)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BrandAvatarView(account: account, size: 32, logoRevision: vault.logoCacheRevision)
                    Spacer()
                    if account.type == .totp {
                        CountdownRingView(
                            remainingSeconds: snapshot.remainingSeconds,
                            progress: snapshot.progress,
                            size: 28
                        )
                    } else {
                        Image(systemName: "number.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !account.displaySubtitle.isEmpty {
                        Text(account.displaySubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(isVisible ? snapshot.formattedCode : "••• •••")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                    .foregroundStyle(
                        account.type == .totp && snapshot.remainingSeconds <= 5
                            ? Color.red
                            : Color.primary
                    )
            }
            .padding(14)
            .frame(width: 170, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [Color(hex: brand.accentHex).opacity(0.16), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct OTPCardView: View {
    @Environment(VaultViewModel.self) private var vault
    let account: OTPAccount
    let folderName: String?
    let date: Date

    var body: some View {
        let snapshot = OTPGenerator.snapshot(for: account, at: date)
        let isVisible = vault.isCodeVisible(for: account.id)
        let isExpiring = account.type == .totp && snapshot.remainingSeconds <= 5

        HStack(spacing: 14) {
            BrandAvatarView(account: account, size: 46, logoRevision: vault.logoCacheRevision)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.displayTitle)
                        .font(.headline)
                        .lineLimit(1)

                    if account.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }

                    if let folderName {
                        Text(folderName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                            .lineLimit(1)
                    }
                }

                if !account.displaySubtitle.isEmpty {
                    Text(account.displaySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(isVisible ? snapshot.formattedCode : "••• •••")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                    .foregroundStyle(isExpiring ? Color.red : Color.primary)
            }

            Spacer(minLength: 8)

            trailingControl(snapshot: snapshot, isVisible: isVisible, isExpiring: isExpiring)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    isExpiring ? Color.red.opacity(0.35) : Color.white.opacity(0.14),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            if vault.hideCodesInApp && !vault.revealedAccountIDs.contains(account.id) {
                vault.toggleReveal(for: account.id)
            } else {
                vault.copyCode(for: account, at: date)
            }
        }
        .contextMenu {
            Button {
                vault.copyCode(for: account, at: date)
            } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
            }

            Button {
                vault.togglePin(account)
            } label: {
                Label(account.isPinned ? "Unpin" : "Pin to Top & Widgets", systemImage: account.isPinned ? "pin.slash" : "pin")
            }

            if !vault.folders.isEmpty {
                Menu {
                    Button("Uncategorized") {
                        vault.moveAccount(account, to: nil)
                    }
                    ForEach(vault.folders) { folder in
                        Button {
                            vault.moveAccount(account, to: folder.id)
                        } label: {
                            Label(folder.name, systemImage: folder.symbolName)
                        }
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
            }

            Button {
                vault.brandPickerAccount = account
            } label: {
                Label("Change Service Logo", systemImage: "sparkles.square.filled.on.square")
            }

            Button {
                vault.qrDetailAccount = account
            } label: {
                Label("Show QR Code", systemImage: "qrcode")
            }

            Button {
                vault.editingAccount = account
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                vault.deleteAccount(account)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func trailingControl(snapshot: OTPCodeSnapshot, isVisible: Bool, isExpiring: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if account.type == .totp {
                CountdownRingView(
                    remainingSeconds: snapshot.remainingSeconds,
                    progress: snapshot.progress,
                    size: 36
                )

                if let next = snapshot.formattedNextCode {
                    Text("→ \(next)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.secondary)
                        .opacity(isVisible && isExpiring ? 1 : 0)
                }
            } else {
                Button {
                    vault.incrementHOTP(for: account)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Next HOTP Counter")
            }

            if vault.hideCodesInApp {
                Button {
                    vault.toggleReveal(for: account.id)
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 58, alignment: .trailing)
    }
}
