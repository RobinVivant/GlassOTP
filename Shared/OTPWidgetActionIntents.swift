import AppIntents
import AudioToolbox
import Foundation
import GlassOTPCore
import UIKit
import UniformTypeIdentifiers
import WidgetKit

@MainActor
enum OTPClipboardWriter {
    static func copyOTP(_ code: String) {
        let expiration = Date().addingTimeInterval(SharedClipboardPreferences.isUniversalClipboardEnabled ? 120 : 60)
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: code]],
            options: [
                .localOnly: !SharedClipboardPreferences.isUniversalClipboardEnabled,
                .expirationDate: expiration,
            ]
        )
    }
}

struct CopyOTPWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Verification Code"
    static let description = IntentDescription(
        "Copies the current OTP code to your clipboard, including across devices via Universal Clipboard."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Account ID")
    var accountIDString: String

    init() {
        self.accountIDString = ""
    }

    init(accountID: UUID) {
        self.accountIDString = accountID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: accountIDString) else {
            return .result()
        }

        let now = Date()
        var targetAccount: OTPAccount?

        let updatedSnapshot = try KeychainVaultStore.shared.mutateSnapshotIfPresent { snapshot in
            guard let idx = snapshot.accounts.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let current = snapshot.accounts[idx]
            targetAccount = current
            guard current.isSupportedAlgorithm, current.type == .hotp else {
                return false
            }
            snapshot.accounts[idx].counter &+= 1
            snapshot.accounts[idx].updatedAt = now
            return true
        }

        guard updatedSnapshot != nil,
              let accountToCopy = targetAccount,
              accountToCopy.isSupportedAlgorithm else {
            return .result()
        }

        let codeSnapshot = OTPGenerator.snapshot(for: accountToCopy, at: now, includeNextCode: false)

        await MainActor.run {
            OTPClipboardWriter.copyOTP(codeSnapshot.code)
            AudioServicesPlaySystemSound(1520)
        }

        SharedWidgetStateStore.recordCopy(accountID: id, at: now)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RevealOTPWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Reveal Verification Code"
    static let description = IntentDescription("Temporarily reveals a masked OTP code for 15 seconds.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Account ID")
    var accountIDString: String

    init() {
        self.accountIDString = ""
    }

    init(accountID: UUID) {
        self.accountIDString = accountID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: accountIDString) else {
            return .result()
        }
        await MainActor.run {
            AudioServicesPlaySystemSound(1519)
        }
        SharedWidgetStateStore.reveal(accountID: id, for: 15)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
