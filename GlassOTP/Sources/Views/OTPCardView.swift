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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    BrandAvatarView(account: account, size: 26, logoRevision: vault.logoCacheRevision)
                        .equatable()
                    Spacer()
                    PinnedOTPLiveRingView(account: account)
                }

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

                OTPLiveCodeText(account: account, fontSize: 19, isVisible: isVisible)
            }
            .padding(10)
            .frame(width: 148, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [Color(hex: accentHex).opacity(0.16), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.displayTitle) \(account.displaySubtitle)")
        .accessibilityHint(isVisible ? "Double-tap to copy code" : "Double-tap to reveal or copy code")
    }
}

struct OTPCardView: View {
    @Environment(VaultViewModel.self) private var vault
    let account: OTPAccount
    let folderName: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        let isVisible = vault.isCodeVisible(for: account.id)

        HStack(spacing: 10) {
            BrandAvatarView(account: account, size: 36, logoRevision: vault.logoCacheRevision)
                .equatable()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(account.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if account.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
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

            OTPLiveRightCluster(
                account: account,
                isVisible: isVisible,
                hideCodesInApp: vault.hideCodesInApp,
                onIncrementHOTP: { vault.incrementHOTP(for: account) },
                onToggleReveal: { vault.toggleReveal(for: account.id) }
            )
        }
        .frame(minHeight: 37)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            OTPExpiringBorderOverlay(account: account, cornerRadius: 16)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(account.displayTitle)\(account.displaySubtitle.isEmpty ? "" : ", \(account.displaySubtitle)")")
        .accessibilityHint(isVisible ? "Tap to copy verification code" : "Tap to reveal verification code")
        .confirmationDialog(
            "Delete \(account.displayTitle)?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                vault.deleteAccount(account)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the 2FA secret key for \(account.displayTitle) from your vault. Make sure you still have recovery access before deleting.")
        }
    }
}

private struct PinnedOTPLiveRingView: View {
    @Environment(OTPClock.self) private var clock
    let account: OTPAccount

    var body: some View {
        if !account.isSupportedAlgorithm {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        } else if account.type == .totp {
            let timing = OTPGenerator.totpTiming(period: account.period, at: clock.now)
            CountdownRingView(
                remainingSeconds: timing.remainingSeconds,
                progress: timing.progress,
                size: 24,
                period: timing.period
            )
        } else {
            Image(systemName: "number.circle.fill")
                .font(.subheadline)
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

        if !account.isSupportedAlgorithm {
            isExpiring = false
            displayedText = isVisible ? "Unsupported" : "••• •••"
        } else if account.type == .totp {
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

private struct OTPLiveRightCluster: View {
    @Environment(OTPClock.self) private var clock
    let account: OTPAccount
    let isVisible: Bool
    let hideCodesInApp: Bool
    let onIncrementHOTP: () -> Void
    let onToggleReveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if !account.isSupportedAlgorithm {
                codeStack(
                    codeText: isVisible ? "Unsupported" : "••• •••",
                    nextCodeText: nil,
                    isExpiring: false
                )

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 30, height: 30)
            } else if account.type == .totp {
                let timing = OTPGenerator.totpTiming(period: account.period, at: clock.now)
                let isExpiring = timing.remainingSeconds <= 5

                codeStack(
                    codeText: isVisible
                        ? OTPGenerator.formatCode(
                            OTPGenerator.generateHOTP(
                                secret: account.secret,
                                counter: timing.counter,
                                digits: account.digits,
                                algorithm: account.algorithm
                            )
                        )
                        : "••• •••",
                    nextCodeText: (isVisible && isExpiring)
                        ? OTPGenerator.formatCode(
                            OTPGenerator.generateHOTP(
                                secret: account.secret,
                                counter: timing.counter &+ 1,
                                digits: account.digits,
                                algorithm: account.algorithm
                            )
                        )
                        : nil,
                    isExpiring: isExpiring
                )

                CountdownRingView(
                    remainingSeconds: timing.remainingSeconds,
                    progress: timing.progress,
                    size: 30,
                    period: timing.period
                )
            } else {
                let formatted = isVisible
                    ? OTPGenerator.snapshot(for: account, at: Date(), includeNextCode: false).formattedCode
                    : "••• •••"
                codeStack(codeText: formatted, nextCodeText: nil, isExpiring: false)

                Button(action: onIncrementHOTP) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Next HOTP Counter")
            }

            if hideCodesInApp {
                Button(action: onToggleReveal) {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func codeStack(codeText: String, nextCodeText: String?, isExpiring: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(codeText)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .foregroundStyle(isExpiring ? Color.red : Color.primary)

            if let nextCodeText {
                Text("→ \(nextCodeText)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 37, alignment: .trailing)
    }
}

private struct OTPExpiringBorderOverlay: View {
    @Environment(OTPClock.self) private var clock
    let account: OTPAccount
    let cornerRadius: CGFloat

    var body: some View {
        let isExpiring = account.isSupportedAlgorithm
            && account.type == .totp
            && OTPGenerator.totpTiming(period: account.period, at: clock.now).remainingSeconds <= 5
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                isExpiring ? Color.red.opacity(0.35) : Color.white.opacity(0.14),
                lineWidth: 1
            )
    }
}
