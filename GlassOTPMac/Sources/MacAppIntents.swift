import AppIntents
import AppKit
import Foundation
import GlassOTPCore

struct MacOTPAccountEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "OTP Account"
    static let defaultQuery = MacOTPAccountQuery()

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

struct MacOTPAccountQuery: EntityQuery {
    func entities(for identifiers: [MacOTPAccountEntity.ID]) async throws -> [MacOTPAccountEntity] {
        let all = loadAll()
        let idSet = Set(identifiers)
        return all.filter { idSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MacOTPAccountEntity] {
        loadAll()
    }

    func defaultResult() async -> MacOTPAccountEntity? {
        loadAll().first
    }

    private func loadAll() -> [MacOTPAccountEntity] {
        guard let snapshot = try? KeychainVaultStore.shared.loadSnapshot() else {
            return []
        }
        return snapshot.accounts
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.sortOrder < $1.sortOrder
            }
            .map {
                MacOTPAccountEntity(id: $0.id, title: $0.displayTitle, subtitle: $0.displaySubtitle)
            }
    }
}

struct CopyMacOTPIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy OTP Code"
    static let description = IntentDescription("Copies a 2FA code from GlassOTP to your Mac clipboard.")

    @Parameter(title: "Account")
    var account: MacOTPAccountEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let snapshot = try? KeychainVaultStore.shared.loadSnapshot(),
              let target = snapshot.accounts.first(where: { $0.id == account.id }) else {
            return .result(value: "")
        }

        let codeSnapshot = OTPGenerator.snapshot(for: target, at: Date(), includeNextCode: false)
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codeSnapshot.code, forType: .string)
            CopyHUDController.shared.show(
                account: target,
                formattedCode: codeSnapshot.formattedCode,
                remainingSeconds: target.type == .totp ? max(0, Int(ceil(codeSnapshot.remainingSeconds))) : nil,
                didAutoType: false
            )
        }
        return .result(value: codeSnapshot.code)
    }
}
