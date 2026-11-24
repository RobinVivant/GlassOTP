import AppIntents
import GlassOTPCore
import SwiftUI
import WidgetKit

struct OTPWidgetItem: Identifiable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let accentHex: String
    let symbolName: String
    let isHOTP: Bool
    let formattedCode: String
    let periodStart: Date
    let periodEnd: Date
    let isMasked: Bool
    let wasCopied: Bool
}

struct OTPWidgetEntry: TimelineEntry {
    let date: Date
    let items: [OTPWidgetItem]
    let requireTapToReveal: Bool
}

struct OTPWidgetTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = OTPWidgetEntry
    typealias Intent = OTPWidgetConfigIntent

    func placeholder(in context: Context) -> OTPWidgetEntry {
        let now = Date()
        return OTPWidgetEntry(
            date: now,
            items: [
                OTPWidgetItem(
                    id: UUID(),
                    title: "GitHub",
                    subtitle: "robin@vero.io",
                    accentHex: "#6E5494",
                    symbolName: "chevron.left.forwardslash.chevron.right",
                    isHOTP: false,
                    formattedCode: "482 917",
                    periodStart: now,
                    periodEnd: now.addingTimeInterval(30),
                    isMasked: false,
                    wasCopied: false
                ),
                OTPWidgetItem(
                    id: UUID(),
                    title: "Cloudflare",
                    subtitle: "infra@vero.io",
                    accentHex: "#F38020",
                    symbolName: "bolt.shield.fill",
                    isHOTP: false,
                    formattedCode: "910 342",
                    periodStart: now,
                    periodEnd: now.addingTimeInterval(30),
                    isMasked: false,
                    wasCopied: false
                ),
            ],
            requireTapToReveal: false
        )
    }

    func snapshot(for configuration: OTPWidgetConfigIntent, in context: Context) async -> OTPWidgetEntry {
        makeEntry(at: Date(), configuration: configuration)
    }

    func timeline(for configuration: OTPWidgetConfigIntent, in context: Context) async -> Timeline<OTPWidgetEntry> {
        let now = Date()
        let accounts = prioritizedAccounts(configuration: configuration)
        if accounts.isEmpty {
            let emptyEntry = OTPWidgetEntry(date: now, items: [], requireTapToReveal: configuration.requireTapToReveal)
            return Timeline(entries: [emptyEntry], policy: .after(now.addingTimeInterval(300)))
        }

        // Generate 120 entries at exact 30-second boundaries (~60 minutes ahead)
        var boundaryDates: [Date] = [now]
        let step: TimeInterval = 30
        let baseBoundary = floor(now.timeIntervalSince1970 / step) * step
        for idx in 1...120 {
            boundaryDates.append(Date(timeIntervalSince1970: baseBoundary + TimeInterval(idx) * step))
        }

        // Insert exact reveal expiry timestamps so masked widgets auto-hide on schedule
        if configuration.requireTapToReveal {
            for account in accounts.prefix(4) {
                if let expiry = SharedWidgetStateStore.revealExpiry(accountID: account.id, now: now) {
                    boundaryDates.append(expiry)
                }
            }
        }

        let uniqueSortedDates = Array(Set(boundaryDates)).sorted()
        let entries = uniqueSortedDates.map { date in
            makeEntry(at: date, accounts: accounts, requireTapToReveal: configuration.requireTapToReveal)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func prioritizedAccounts(configuration: OTPWidgetConfigIntent) -> [OTPAccount] {
        guard let snapshot = try? KeychainVaultStore.shared.loadSnapshot() else {
            return []
        }
        var ordered = snapshot.accounts.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.sortOrder < $1.sortOrder
        }
        if let primary = configuration.primaryAccount,
           let idx = ordered.firstIndex(where: { $0.id == primary.id }) {
            let chosen = ordered.remove(at: idx)
            ordered.insert(chosen, at: 0)
        }
        return ordered
    }

    private func makeEntry(at date: Date, configuration: OTPWidgetConfigIntent) -> OTPWidgetEntry {
        let accounts = prioritizedAccounts(configuration: configuration)
        return makeEntry(at: date, accounts: accounts, requireTapToReveal: configuration.requireTapToReveal)
    }

    private func makeEntry(
        at date: Date,
        accounts: [OTPAccount],
        requireTapToReveal: Bool
    ) -> OTPWidgetEntry {
        let items = accounts.prefix(4).map { account in
            let codeSnapshot = OTPGenerator.snapshot(for: account, at: date)
            let isRevealed = !requireTapToReveal || SharedWidgetStateStore.isRevealed(accountID: account.id, now: date)
            let wasCopied = SharedWidgetStateStore.wasRecentlyCopied(accountID: account.id, now: date)
            let brand = account.brandStyle

            return OTPWidgetItem(
                id: account.id,
                title: account.displayTitle,
                subtitle: account.displaySubtitle,
                accentHex: brand.accentHex,
                symbolName: brand.symbolName,
                isHOTP: account.type == .hotp,
                formattedCode: codeSnapshot.formattedCode,
                periodStart: codeSnapshot.periodStart,
                periodEnd: codeSnapshot.periodEnd,
                isMasked: !isRevealed,
                wasCopied: wasCopied
            )
        }
        return OTPWidgetEntry(date: date, items: items, requireTapToReveal: requireTapToReveal)
    }
}

struct GlassOTPWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: OTPWidgetEntry

    var body: some View {
        Group {
            if entry.items.isEmpty {
                emptyWidgetView
            } else {
                switch family {
                case .systemSmall:
                    smallView(item: entry.items[0])
                case .systemMedium:
                    multiRowView(items: Array(entry.items.prefix(2)))
                case .systemLarge:
                    multiRowView(items: Array(entry.items.prefix(4)))
                case .accessoryRectangular:
                    accessoryRectangularView(item: entry.items[0])
                case .accessoryCircular:
                    accessoryCircularView(item: entry.items[0])
                case .accessoryInline:
                    accessoryInlineView(item: entry.items[0])
                default:
                    smallView(item: entry.items[0])
                }
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color.clear
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.14),
                        Color.indigo.opacity(0.10),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var emptyWidgetView: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .widgetAccentable()
            Text("GlassOTP")
                .font(.headline)
            Text("Import or add an account in the app")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }

    private func smallView(item: OTPWidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.symbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .widgetAccentable()

                Spacer()

                actionButton(for: item, compact: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)

            codeText(for: item, size: 24)

            if !item.isHOTP {
                ProgressView(timerInterval: item.periodStart...item.periodEnd, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .widgetAccentable()
            }
        }
        .widgetURL(URL(string: "glassotp://account/\(item.id.uuidString)"))
    }

    private func multiRowView(items: [OTPWidgetItem]) -> some View {
        VStack(spacing: 10) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Link(destination: URL(string: "glassotp://account/\(item.id.uuidString)")!) {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbolName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .widgetAccentable()

                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 4)

                            VStack(alignment: .trailing, spacing: 3) {
                                codeText(for: item, size: 19)
                                if !item.isHOTP {
                                    ProgressView(timerInterval: item.periodStart...item.periodEnd, countsDown: true) {
                                        EmptyView()
                                    } currentValueLabel: {
                                        EmptyView()
                                    }
                                    .progressViewStyle(.linear)
                                    .frame(width: 78)
                                    .tint(Color.accentColor)
                                    .widgetAccentable()
                                }
                            }
                        }
                    }

                    actionButton(for: item, compact: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func accessoryRectangularView(item: OTPWidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if !item.isHOTP {
                    Text(item.periodEnd, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.isMasked ? "••• •••" : item.formattedCode)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .widgetAccentable()
        }
    }

    private func accessoryCircularView(item: OTPWidgetItem) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            if !item.isHOTP {
                Gauge(value: 0.5, in: 0...1) {
                    Text(item.title.prefix(2))
                } currentValueLabel: {
                    Text(item.isMasked ? "•••" : String(item.formattedCode.prefix(3)))
                        .font(.caption.bold())
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            } else {
                Text(item.isMasked ? "•••" : String(item.formattedCode.prefix(3)))
                    .font(.caption.bold())
                    .monospacedDigit()
                    .widgetAccentable()
            }
        }
    }

    private func accessoryInlineView(item: OTPWidgetItem) -> some View {
        Text("\(item.title): \(item.isMasked ? "••• •••" : item.formattedCode)")
            .monospacedDigit()
    }

    @ViewBuilder
    private func codeText(for item: OTPWidgetItem, size: CGFloat) -> some View {
        if item.isMasked {
            Text("••• •••")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text(item.formattedCode)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .widgetAccentable()
        }
    }

    @ViewBuilder
    private func actionButton(for item: OTPWidgetItem, compact: Bool) -> some View {
        if item.isMasked {
            Button(intent: RevealOTPWidgetIntent(accountID: item.id)) {
                Image(systemName: "eye.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .accessibilityLabel("Reveal \(item.title)")
        } else {
            Button(intent: CopyOTPWidgetIntent(accountID: item.id)) {
                Image(systemName: item.wasCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.wasCopied ? Color.green : Color.primary)
                    .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .accessibilityLabel("Copy \(item.title)")
        }
    }
}

struct GlassOTPWidget: Widget {
    let kind = "com.robinvivant.glassotp.widget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: OTPWidgetConfigIntent.self,
            provider: OTPWidgetTimelineProvider()
        ) { entry in
            GlassOTPWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("GlassOTP Codes")
        .description("View and copy live 2FA codes with optional Tap-to-Reveal privacy.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}

@main
struct GlassOTPWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlassOTPWidget()
    }
}
