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
    let hasCustomLogoDomain: Bool
    let isHOTP: Bool
    let isSupportedAlgorithm: Bool
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
    let universalClipboardEnabled: Bool
    let hasVaultError: Bool
    let isAppLocked: Bool
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
                    subtitle: "alex@example.com",
                    accentHex: "#2A3346",
                    secondaryHex: "#141A26",
                    symbolName: "chevron.left.forwardslash.chevron.right",
                    brandSlug: "github",
                    usesDarkGlyph: false,
                    cachedLogoDomain: "github.com",
                    hasCustomLogoDomain: false,
                    isHOTP: false,
                    isSupportedAlgorithm: true,
                    formattedCode: "482 917",
                    periodStart: now,
                    periodEnd: now.addingTimeInterval(30),
                    isMasked: false,
                    wasCopied: false
                ),
                OTPWidgetItem(
                    id: UUID(),
                    title: "Cloudflare",
                    subtitle: "ops@example.com",
                    accentHex: "#F38020",
                    secondaryHex: "#AE5C17",
                    symbolName: "bolt.shield.fill",
                    brandSlug: "cloudflare",
                    usesDarkGlyph: false,
                    cachedLogoDomain: "cloudflare.com",
                    hasCustomLogoDomain: false,
                    isHOTP: false,
                    isSupportedAlgorithm: true,
                    formattedCode: "910 342",
                    periodStart: now,
                    periodEnd: now.addingTimeInterval(30),
                    isMasked: false,
                    wasCopied: false
                ),
            ],
            requireTapToReveal: false,
            universalClipboardEnabled: SharedClipboardPreferences.isUniversalClipboardEnabled,
            hasVaultError: false,
            isAppLocked: false
        )
    }

    func snapshot(for configuration: OTPWidgetConfigIntent, in context: Context) async -> OTPWidgetEntry {
        makeEntry(at: Date(), configuration: configuration)
    }

    func timeline(for configuration: OTPWidgetConfigIntent, in context: Context) async -> Timeline<OTPWidgetEntry> {
        let now = Date()
        let loaded = loadAccounts(configuration: configuration)
        let accounts = loaded.accounts
        let universalClipboardEnabled = SharedClipboardPreferences.isUniversalClipboardEnabled
        let isAppLocked = SharedSecurityPreferences.effectiveAppLockEnabled
        let effectiveRequireTapToReveal = configuration.requireTapToReveal || isAppLocked

        if accounts.isEmpty {
            let emptyEntry = OTPWidgetEntry(
                date: now,
                items: [],
                requireTapToReveal: effectiveRequireTapToReveal,
                universalClipboardEnabled: universalClipboardEnabled,
                hasVaultError: loaded.hasError,
                isAppLocked: isAppLocked
            )
            return Timeline(entries: [emptyEntry], policy: .after(now.addingTimeInterval(loaded.hasError ? 60 : 300)))
        }

        var boundaryDates: [Date] = [now]
        let horizonEnd = now.addingTimeInterval(3600)
        let activeAccounts = Array(accounts.prefix(4))
        let periods = Set(activeAccounts.compactMap {
            ($0.type == .totp && $0.isSupportedAlgorithm) ? max(1, $0.period) : nil
        })
        let targetPeriods = periods.isEmpty ? [30] : Array(periods).sorted()

        for period in targetPeriods {
            let step = TimeInterval(period)
            let baseBoundary = floor(now.timeIntervalSince1970 / step) * step
            var t = baseBoundary + step
            while t <= horizonEnd.timeIntervalSince1970 {
                boundaryDates.append(Date(timeIntervalSince1970: t))
                t += step
            }
        }

        for account in activeAccounts {
            if effectiveRequireTapToReveal && !isAppLocked,
               let expiry = SharedWidgetStateStore.revealExpiry(accountID: account.id, now: now) {
                boundaryDates.append(expiry)
            }
            if !isAppLocked,
               let copyExpiry = SharedWidgetStateStore.copyExpiry(accountID: account.id, now: now) {
                boundaryDates.append(copyExpiry)
            }
        }

        let uniqueSortedDates = Array(Set(boundaryDates)).sorted()
        let entries = uniqueSortedDates.prefix(160).map { date in
            makeEntry(
                at: date,
                accounts: accounts,
                requireTapToReveal: effectiveRequireTapToReveal,
                universalClipboardEnabled: universalClipboardEnabled,
                hasVaultError: false,
                isAppLocked: isAppLocked
            )
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func loadAccounts(configuration: OTPWidgetConfigIntent) -> (accounts: [OTPAccount], hasError: Bool) {
        let snapshot: OTPVaultSnapshot?
        do {
            snapshot = try KeychainVaultStore.shared.loadSnapshot()
        } catch {
            return ([], true)
        }
        guard let snapshot else {
            return ([], false)
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
        return (ordered, false)
    }

    private func makeEntry(at date: Date, configuration: OTPWidgetConfigIntent) -> OTPWidgetEntry {
        let loaded = loadAccounts(configuration: configuration)
        let isAppLocked = SharedSecurityPreferences.effectiveAppLockEnabled
        let effectiveRequireTapToReveal = configuration.requireTapToReveal || isAppLocked
        return makeEntry(
            at: date,
            accounts: loaded.accounts,
            requireTapToReveal: effectiveRequireTapToReveal,
            universalClipboardEnabled: SharedClipboardPreferences.isUniversalClipboardEnabled,
            hasVaultError: loaded.hasError,
            isAppLocked: isAppLocked
        )
    }

    private func makeEntry(
        at date: Date,
        accounts: [OTPAccount],
        requireTapToReveal: Bool,
        universalClipboardEnabled: Bool,
        hasVaultError: Bool,
        isAppLocked: Bool
    ) -> OTPWidgetEntry {
        let items = accounts.prefix(4).map { account in
            let supported = account.isSupportedAlgorithm
            let codeSnapshot = OTPGenerator.snapshot(for: account, at: date, includeNextCode: false)
            let isRevealed = !isAppLocked && (!requireTapToReveal || SharedWidgetStateStore.isRevealed(accountID: account.id, now: date))
            let wasCopied = !isAppLocked && supported && SharedWidgetStateStore.wasRecentlyCopied(accountID: account.id, now: date)
            let brand = account.brandStyle
            let matchedBrand = BrandCatalog.shared.match(account: account)
            let customDomain = BrandCatalog.cleanedDomain(account.customLogoDomain)
            let cachedDomain = customDomain ?? BrandCatalog.shared.inferredDomain(for: account, includeHeuristicFallback: false)

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
                hasCustomLogoDomain: customDomain != nil,
                isHOTP: account.type == .hotp,
                isSupportedAlgorithm: supported,
                formattedCode: supported ? codeSnapshot.formattedCode : "Unsupported",
                periodStart: codeSnapshot.periodStart,
                periodEnd: codeSnapshot.periodEnd,
                isMasked: !isRevealed,
                wasCopied: wasCopied
            )
        }
        return OTPWidgetEntry(
            date: date,
            items: items,
            requireTapToReveal: requireTapToReveal,
            universalClipboardEnabled: universalClipboardEnabled,
            hasVaultError: hasVaultError,
            isAppLocked: isAppLocked
        )
    }
}

struct GlassOTPWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: OTPWidgetEntry

    var body: some View {
        Group {
            if entry.items.isEmpty {
                if family == .accessoryInline {
                    Label(
                        entry.hasVaultError ? "Vault Unavailable" : "GlassOTP: Open App",
                        systemImage: entry.hasVaultError ? "exclamationmark.triangle.fill" : "lock.shield.fill"
                    )
                } else {
                    emptyOrErrorWidgetView
                }
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

    private var emptyOrErrorWidgetView: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.hasVaultError ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(entry.hasVaultError ? Color.orange : Color.accentColor)
                .widgetAccentable()
            Text(entry.hasVaultError ? "Vault Unavailable" : "GlassOTP")
                .font(.headline)
            Text(entry.hasVaultError ? "Open GlassOTP to reload your Keychain vault." : "Import or add an account in the app")
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

                actionButton(for: item, compact: true, allowLink: false)
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

            if !item.isHOTP && item.isSupportedAlgorithm {
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
                                if !item.isHOTP && item.isSupportedAlgorithm {
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

                    actionButton(for: item, compact: true, allowLink: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func accessoryRectangularView(item: OTPWidgetItem) -> some View {
        lockScreenActionContainer(for: item) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !item.isHOTP && item.isSupportedAlgorithm {
                        Text(item.periodEnd, style: .timer)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(item.isMasked ? "••• •••" : item.formattedCode)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .privacySensitive()
                        .widgetAccentable()
                    Spacer(minLength: 2)
                    Image(systemName: lockScreenActionSymbol(for: item))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.wasCopied ? .primary : .secondary)
                }
            }
        }
        .widgetURL(URL(string: "glassotp://account/\(item.id.uuidString)"))
    }

    private func accessoryCircularView(item: OTPWidgetItem) -> some View {
        lockScreenActionContainer(for: item) {
            ZStack {
                AccessoryWidgetBackground()
                if item.wasCopied {
                    Image(systemName: "checkmark")
                        .font(.title3.weight(.bold))
                        .widgetAccentable()
                } else if !item.isHOTP && item.isSupportedAlgorithm {
                    ProgressView(timerInterval: item.periodStart...item.periodEnd, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(item.isMasked ? "•••" : item.formattedCode)
                            .font(.caption2.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .privacySensitive()
                    }
                    .progressViewStyle(.circular)
                    .widgetAccentable()
                } else {
                    Text(item.isMasked ? "•••" : item.formattedCode)
                        .font(.caption2.bold())
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .privacySensitive()
                        .widgetAccentable()
                }
            }
        }
        .widgetURL(URL(string: "glassotp://account/\(item.id.uuidString)"))
    }

    private func accessoryInlineView(item: OTPWidgetItem) -> some View {
        Text("\(item.title): \(item.isMasked ? "••• •••" : item.formattedCode)")
            .monospacedDigit()
            .privacySensitive()
            .widgetURL(URL(string: "glassotp://account/\(item.id.uuidString)"))
    }

    @ViewBuilder
    private func lockScreenActionContainer<Content: View>(
        for item: OTPWidgetItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if entry.isAppLocked {
            content()
                .accessibilityLabel("Open GlassOTP to view \(item.title)")
        } else if item.isMasked {
            Button(intent: RevealOTPWidgetIntent(accountID: item.id)) {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reveal \(item.title)")
        } else if !item.isSupportedAlgorithm || entry.universalClipboardEnabled {
            content()
        } else {
            Button(intent: CopyOTPWidgetIntent(accountID: item.id)) {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(item.title)")
        }
    }

    private func lockScreenActionSymbol(for item: OTPWidgetItem) -> String {
        if entry.isAppLocked {
            return "lock.fill"
        }
        if item.isMasked {
            return "eye.fill"
        }
        if !item.isSupportedAlgorithm {
            return "exclamationmark.triangle.fill"
        }
        return item.wasCopied ? "checkmark.circle.fill" : "doc.on.doc"
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
                .privacySensitive()
                .widgetAccentable()
        }
    }

    @ViewBuilder
    private func actionButton(for item: OTPWidgetItem, compact: Bool, allowLink: Bool) -> some View {
        if entry.isAppLocked {
            let side: CGFloat = compact ? 28 : 34
            let badge = Image(systemName: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: side, height: side)
                .background(.quaternary.opacity(0.65), in: Circle())
            if allowLink {
                Link(destination: URL(string: "glassotp://account/\(item.id.uuidString)")!) {
                    badge
                }
                .accessibilityLabel("Unlock GlassOTP for \(item.title)")
            } else {
                badge
                    .accessibilityLabel("Unlock GlassOTP for \(item.title)")
            }
        } else if item.isMasked {
            Button(intent: RevealOTPWidgetIntent(accountID: item.id)) {
                Image(systemName: "eye.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .accessibilityLabel("Reveal \(item.title)")
        } else if !item.isSupportedAlgorithm {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
        } else if entry.universalClipboardEnabled {
            let badge = copyBadgeLabel(wasCopied: item.wasCopied, compact: compact)
            if allowLink {
                Link(destination: URL(string: "glassotp://account/\(item.id.uuidString)")!) {
                    badge
                }
                .accessibilityLabel("Copy \(item.title)")
            } else {
                badge
                    .accessibilityLabel("Copy \(item.title)")
            }
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

    private func copyBadgeLabel(wasCopied: Bool, compact: Bool) -> some View {
        let side: CGFloat = compact ? 28 : 34
        return Image(systemName: wasCopied ? "checkmark" : "doc.on.doc")
            .font(.caption.weight(.semibold))
            .foregroundStyle(wasCopied ? Color.green : Color.primary)
            .frame(width: side, height: side)
            .background(.quaternary.opacity(0.65), in: Circle())
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
        let matchedBrand = item.hasCustomLogoDomain ? nil : item.brandSlug.flatMap { BrandCatalog.shared.brand(slug: $0) }
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
