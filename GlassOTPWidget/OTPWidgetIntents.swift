import AppIntents
import Foundation
import GlassOTPCore

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
