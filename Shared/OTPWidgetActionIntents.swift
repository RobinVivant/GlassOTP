import AppIntents
import Foundation
import GlassOTPCore
import UIKit
import UniformTypeIdentifiers
import WidgetKit

@MainActor
enum OTPClipboardWriter {
    static func copyOTP(_ code: String) {
        if SharedClipboardPreferences.isUniversalClipboardEnabled {
            // Assigning `.string` writes standard UTF-8 plain text with `localOnly = false`
            // and no short custom expirationDate so Continuity / Universal Clipboard can sync.
            UIPasteboard.general.string = code
        } else {
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: code]],
                options: [
                    .localOnly: true,
                    .expirationDate: Date().addingTimeInterval(60),
                ]
            )
        }
    }
}

struct CopyOTPWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Verification Code"
    static let description = IntentDescription(
        "Copies the current OTP code to your clipboard, including across devices via Universal Clipboard."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
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
        guard let id = UUID(uuidString: accountIDString),
              var snapshot = try? KeychainVaultStore.shared.loadSnapshot(),
              let index = snapshot.accounts.firstIndex(where: { $0.id == id }) else {
            return .result()
        }

        let now = Date()
        let account = snapshot.accounts[index]
        let codeSnapshot = OTPGenerator.snapshot(for: account, at: now, includeNextCode: false)

        await MainActor.run {
            OTPClipboardWriter.copyOTP(codeSnapshot.code)
        }

        if account.type == .hotp {
            snapshot.accounts[index].counter &+= 1
            snapshot.accounts[index].updatedAt = now
            try? KeychainVaultStore.shared.saveSnapshot(snapshot)
        }

        SharedWidgetStateStore.recordCopy(accountID: id, at: now)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RevealOTPWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Reveal Verification Code"
    static let description = IntentDescription("Temporarily reveals a masked OTP code for 15 seconds.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

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
        SharedWidgetStateStore.reveal(accountID: id, for: 15)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
