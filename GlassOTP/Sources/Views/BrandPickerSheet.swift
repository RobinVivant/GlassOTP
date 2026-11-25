import GlassOTPCore
import SwiftUI

struct BrandPickerSheet: View {
    @Environment(VaultViewModel.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let account: OTPAccount

    @State private var searchQuery = ""
    @State private var customDomain: String
    @State private var isFetchingDomain = false
    @State private var domainError: String?

    init(account: OTPAccount) {
        self.account = account
        _customDomain = State(initialValue: account.customLogoDomain ?? "")
    }

    private var matchingBrands: [BrandDefinition] {
        BrandCatalog.shared.search(searchQuery)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 84, maximum: 112), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        autoResetSection
                        customDomainSection
                        brandGridSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Service Logo")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search 260+ services (GitHub, Stripe, AWS...)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var autoResetSection: some View {
        Button {
            vault.updateBrandOverride(for: account, brandSlug: nil, customDomain: nil)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic Match")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Detect logo from '\(account.displayTitle)'")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if account.customBrandSlug == nil && account.customLogoDomain == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var customDomainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FETCH FROM WEBSITE DOMAIN")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            HStack(spacing: 10) {
                TextField("e.g. boursobank.com or vero.co", text: $customDomain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    fetchCustomDomain()
                } label: {
                    if isFetchingDomain {
                        ProgressView()
                            .frame(width: 58, height: 22)
                    } else {
                        Text("Fetch")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(BrandCatalog.cleanedDomain(customDomain) == nil || isFetchingDomain)
            }

            if let domainError {
                Text(domainError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var brandGridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BUNDLED VECTOR LOGOS (\(matchingBrands.count))")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(matchingBrands) { brand in
                    let isSelected = account.customBrandSlug == brand.slug
                    Button {
                        vault.updateBrandOverride(for: account, brandSlug: brand.slug, customDomain: nil)
                        if brand.svgPath == nil {
                            Task {
                                _ = await BrandLogoFetcher.fetchLogo(forDomain: brand.domain)
                                vault.bumpLogoRevision()
                            }
                        }
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            BrandBadgeContent(
                                brand: brand,
                                fallbackStyle: brand.svgPath == nil ? account.brandStyle : nil,
                                cachedDomain: brand.svgPath == nil ? brand.domain : nil,
                                size: 46,
                                logoRevision: vault.logoCacheRevision
                            )

                            Text(brand.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.white.opacity(0.10),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func fetchCustomDomain() {
        guard let cleaned = BrandCatalog.cleanedDomain(customDomain) else { return }
        isFetchingDomain = true
        domainError = nil
        Task {
            let success = await BrandLogoFetcher.fetchLogo(forDomain: cleaned)
            isFetchingDomain = false
            if success {
                vault.updateBrandOverride(for: account, brandSlug: nil, customDomain: cleaned)
                dismiss()
            } else {
                domainError = "Couldn't find a high-resolution icon at \(cleaned)."
            }
        }
    }
}
