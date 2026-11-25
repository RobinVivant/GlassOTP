import GlassOTPCore
import SwiftUI

struct PinnedOTPCardView: View {
    @Environment(VaultViewModel.self) private var vault
    let account: OTPAccount

    var body: some View {
        let isVisible = vault.isCodeVisible(for: account.id)
        let accentHex = BrandCatalog.shared.match(account: account).map { "#\($0.effectiveAccentHex)" }
            ?? account.brandStyle.accentHex

        Button {
            vault.copyCode(for: account)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BrandAvatarView(account: account, size: 32, logoRevision: vault.logoCacheRevision)
                        .equatable()
                    Spacer()
                    PinnedOTPLiveRingView(account: account)
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

                OTPLiveCodeText(account: account, fontSize: 22, isVisible: isVisible)
            }
            .padding(14)
            .frame(width: 170, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [Color(hex: accentHex).opacity(0.16), .clear],
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

    var body: some View {
        let isVisible = vault.isCodeVisible(for: account.id)

        HStack(spacing: 14) {
            BrandAvatarView(account: account, size: 46, logoRevision: vault.logoCacheRevision)
                .equatable()

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

                OTPLiveCodeText(account: account, fontSize: 28, isVisible: isVisible)
            }

            Spacer(minLength: 8)

            OTPLiveTrailingControl(
                account: account,
                isVisible: isVisible,
                hideCodesInApp: vault.hideCodesInApp,
                onIncrementHOTP: { vault.incrementHOTP(for: account) },
                onToggleReveal: { vault.toggleReveal(for: account.id) }
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            OTPExpiringBorderOverlay(account: account, cornerRadius: 22)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            if vault.hideCodesInApp && !vault.revealedAccountIDs.contains(account.id) {
                vault.toggleReveal(for: account.id)
            } else {
                vault.copyCode(for: account)
            }
        }
        .contextMenu {
            Button {
                vault.copyCode(for: account)
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
}

private struct PinnedOTPLiveRingView: View {
    @Environment(OTPClock.self) private var clock
    let account: OTPAccount

    var body: some View {
        if account.type == .totp {
            let timing = OTPGenerator.totpTiming(period: account.period, at: clock.now)
            CountdownRingView(
                remainingSeconds: timing.remainingSeconds,
                progress: timing.progress,
                size: 28,
                period: timing.period
            )
        } else {
            Image(systemName: "number.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OTPLiveCodeText: View {
    @Environment(OTPClock.self) private var clock
    let account: OTPAccount
    let fontSize: CGFloat
    let isVisible: Bool

    var body: some View {
        let isExpiring: Bool
        let displayedText: String

        if account.type == .totp {
            let timing = OTPGenerator.totpTiming(period: account.period, at: clock.now)
            isExpiring = timing.remainingSeconds <= 5
            if isVisible {
                let code = OTPGenerator.generateHOTP(
                    secret: account.secret,
                    counter: timing.counter,
                    digits: account.digits,
                    algorithm: account.algorithm
                )
                displayedText = OTPGenerator.formatCode(code)
            } else {
                displayedText = "••• •••"
            }
        } else {
            isExpiring = false
            if isVisible {
                displayedText = OTPGenerator.snapshot(
                    for: account,
                    at: Date(),
                    includeNextCode: false
                ).formattedCode
            } else {
                displayedText = "••• •••"
            }
        }

        return Text(displayedText)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .contentTransition(.numericText())
            .foregroundStyle(isExpiring ? Color.red : Color.primary)
    }
}

private struct OTPLiveTrailingControl: View {
    @Environment(OTPClock.self) private var clock
    let account: OTPAccount
    let isVisible: Bool
    let hideCodesInApp: Bool
    let onIncrementHOTP: () -> Void
    let onToggleReveal: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if account.type == .totp {
                let timing = OTPGenerator.totpTiming(period: account.period, at: clock.now)
                let isExpiring = timing.remainingSeconds <= 5

                CountdownRingView(
                    remainingSeconds: timing.remainingSeconds,
                    progress: timing.progress,
                    size: 36,
                    period: timing.period
                )

                let nextText: String = {
                    guard isVisible, isExpiring else {
                        return account.digits == 8 ? "0000 0000" : "000 000"
                    }
                    let next = OTPGenerator.generateHOTP(
                        secret: account.secret,
                        counter: timing.counter &+ 1,
                        digits: account.digits,
                        algorithm: account.algorithm
                    )
                    return OTPGenerator.formatCode(next)
                }()

                Text("→ \(nextText)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.secondary)
                    .opacity(isVisible && isExpiring ? 1 : 0)
                    .accessibilityHidden(!(isVisible && isExpiring))
            } else {
                Button(action: onIncrementHOTP) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Next HOTP Counter")
            }

            if hideCodesInApp {
                Button(action: onToggleReveal) {
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

private struct OTPExpiringBorderOverlay: View {
    @Environment(OTPClock.self) private var clock
    let account: OTPAccount
    let cornerRadius: CGFloat

    var body: some View {
        let isExpiring = account.type == .totp
            && OTPGenerator.totpTiming(period: account.period, at: clock.now).remainingSeconds <= 5
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                isExpiring ? Color.red.opacity(0.35) : Color.white.opacity(0.14),
                lineWidth: 1
            )
    }
}
