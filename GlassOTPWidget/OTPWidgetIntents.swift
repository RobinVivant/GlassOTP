import AppIntents
import Foundation
import GlassOTPCore
import UIKit
import UniformTypeIdentifiers
import WidgetKit

struct AccountWidgetEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = AccountWidgetEntityQuery()

    let id: UUID
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)"
        )
    }
}

struct AccountWidgetEntityQuery: EntityQuery {
    func entities(for identifiers: [AccountWidgetEntity.ID]) async throws -> [AccountWidgetEntity] {
        let all = loadAllEntities()
        let idSet = Set(identifiers)
        return all.filter { idSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AccountWidgetEntity] {
        loadAllEntities()
    }

    func defaultResult() async -> AccountWidgetEntity? {
        loadAllEntities().first
    }

    private func loadAllEntities() -> [AccountWidgetEntity] {
        guard let snapshot = try? KeychainVaultStore.shared.loadSnapshot() else {
            return []
        }
        let sorted = snapshot.accounts.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.sortOrder < $1.sortOrder
        }
        return sorted.map {
            AccountWidgetEntity(id: $0.id, title: $0.displayTitle, subtitle: $0.displaySubtitle)
        }
    }
}

struct OTPWidgetConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "GlassOTP Widget"
    static let description = IntentDescription("Choose an account and whether codes require a tap to reveal.")

    @Parameter(title: "Primary Account")
    var primaryAccount: AccountWidgetEntity?

    @Parameter(title: "Tap to Reveal (Privacy)", default: false)
    var requireTapToReveal: Bool

    init() {}
}

struct CopyOTPWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Verification Code"
    static let description = IntentDescription("Copies the current OTP code directly to your clipboard.")

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
        let codeSnapshot = OTPGenerator.snapshot(for: account, at: now)

        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: codeSnapshot.code]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(60),
            ]
        )

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
