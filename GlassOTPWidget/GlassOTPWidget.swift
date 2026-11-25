import AppIntents
import GlassOTPCore
import SwiftUI
import WidgetKit

struct OTPWidgetItem: Identifiable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let accentHex: String
    let secondaryHex: String
    let symbolName: String
    let brandSlug: String?
    let usesDarkGlyph: Bool
    let cachedLogoDomain: String?
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
                    accentHex: "#2A3346",
                    secondaryHex: "#141A26",
                    symbolName: "chevron.left.forwardslash.chevron.right",
                    brandSlug: "github",
                    usesDarkGlyph: false,
                    cachedLogoDomain: "github.com",
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
                    secondaryHex: "#AE5C17",
                    symbolName: "bolt.shield.fill",
                    brandSlug: "cloudflare",
                    usesDarkGlyph: false,
                    cachedLogoDomain: "cloudflare.com",
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
            let matchedBrand = BrandCatalog.shared.match(account: account)
            let cachedDomain = BrandCatalog.shared.inferredDomain(for: account, includeHeuristicFallback: true)

            return OTPWidgetItem(
                id: account.id,
                title: account.displayTitle,
                subtitle: account.displaySubtitle,
                accentHex: brand.accentHex,
                secondaryHex: brand.secondaryHex,
                symbolName: brand.symbolName,
                brandSlug: matchedBrand?.slug,
                usesDarkGlyph: matchedBrand?.usesDarkGlyph ?? false,
                cachedLogoDomain: cachedDomain,
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
                WidgetBrandBadge(item: item, size: 26)
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
                            WidgetBrandBadge(item: item, size: 30)
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
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(.secondary)
        } else {
            Text(item.formattedCode)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
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

private struct WidgetVectorShape: Shape {
    let svgPath: String

    func path(in rect: CGRect) -> Path {
        guard let cgPath = SVGPathParser.parse(svgPath) else { return Path() }
        let box = cgPath.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return Path() }

        let referenceSpan = max(24.0, max(box.width, box.height))
        let scale = min(rect.width, rect.height) / referenceSpan
        let scaledWidth = box.width * scale
        let scaledHeight = box.height * scale
        let offsetX = rect.minX + (rect.width - scaledWidth) / 2.0 - box.minX * scale
        let offsetY = rect.minY + (rect.height - scaledHeight) / 2.0 - box.minY * scale

        var transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scale, y: scale)
        guard let transformed = cgPath.copy(using: &transform) else {
            return Path(cgPath)
        }
        return Path(transformed)
    }
}

private struct WidgetBrandBadge: View {
    let item: OTPWidgetItem
    let size: CGFloat

    var body: some View {
        let matchedBrand = item.brandSlug.flatMap { BrandCatalog.shared.brand(slug: $0) }
        let cachedPNG: UIImage? = matchedBrand?.svgPath == nil
            ? item.cachedLogoDomain
                .flatMap { BrandLogoCache.loadPNGData(forDomain: $0) }
                .flatMap { UIImage(data: $0) }
            : nil
        let cornerRadius = size * 0.28

        ZStack {
            if let cachedPNG, matchedBrand?.svgPath == nil {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                Image(uiImage: cachedPNG)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.70, height: size * 0.70)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [widgetColor(item.accentHex), widgetColor(item.secondaryHex)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let svgPath = matchedBrand?.svgPath {
                    WidgetVectorShape(svgPath: svgPath)
                        .fill(item.usesDarkGlyph ? Color(red: 0.07, green: 0.09, blue: 0.15) : .white)
                        .frame(width: size * 0.56, height: size * 0.56)
                } else {
                    Image(systemName: item.symbolName)
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func widgetColor(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let int = UInt64(cleaned, radix: 16) else {
            return Color.accentColor
        }
        return Color(
            .sRGB,
            red: Double((int >> 16) & 0xFF) / 255.0,
            green: Double((int >> 8) & 0xFF) / 255.0,
            blue: Double(int & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
