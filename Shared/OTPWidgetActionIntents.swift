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
    static let isDiscoverable: Bool = false
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
        guard !SharedSecurityPreferences.effectiveAppLockEnabled,
              let id = UUID(uuidString: accountIDString) else {
            return .result()
        }

        let outcome = try KeychainVaultStore.shared.resolveAccountForCopy(accountID: id)
        guard outcome.snapshot != nil,
              let accountToCopy = outcome.account,
              accountToCopy.isSupportedAlgorithm else {
            return .result()
        }

        let generationDate = Date()
        let codeSnapshot = OTPGenerator.snapshot(for: accountToCopy, at: generationDate, includeNextCode: false)

        await MainActor.run {
            OTPClipboardWriter.copyOTP(codeSnapshot.code)
            AudioServicesPlaySystemSound(1520)
        }

        SharedWidgetStateStore.recordCopy(accountID: id, at: generationDate)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RevealOTPWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Reveal Verification Code"
    static let description = IntentDescription("Temporarily reveals a masked OTP code for 15 seconds.")
    static let isDiscoverable: Bool = false
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
        guard !SharedSecurityPreferences.effectiveAppLockEnabled,
              let id = UUID(uuidString: accountIDString) else {
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
