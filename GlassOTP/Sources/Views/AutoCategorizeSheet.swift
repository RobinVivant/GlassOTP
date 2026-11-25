import GlassOTPCore
import SwiftUI

struct AutoCategorizeSheet: View {
    @Environment(VaultViewModel.self) private var vault
    @Environment(\.dismiss) private var dismiss

    @State private var plan: CategorizationPlan?
    @State private var assignments: [UUID: OTPCategory] = [:]
    @State private var selectedIDs: Set<UUID> = []
    @State private var fetchWebLogos = false
    @State private var removeEmptyDefaultFolder = true
    @State private var isApplying = false

    private var groupedCategories: [(category: OTPCategory, items: [CategorizationItem])] {
        guard let plan else { return [] }
        let grouped = Dictionary(grouping: plan.items) { item in
            assignments[item.id] ?? item.category
        }
        return OTPCategory.allCases.compactMap { category in
            guard let list = grouped[category], !list.isEmpty else { return nil }
            return (category, list)
        }
    }

    private var matchedVectorCount: Int {
        plan?.items.filter { $0.matchedBrand?.svgPath != nil }.count ?? 0
    }

    private var webFetchCandidateCount: Int {
        plan?.items.filter { $0.matchedBrand?.svgPath == nil && $0.inferredLogoDomain != nil }.count ?? 0
    }

    private var hasDefaultAccountsFolder: Bool {
        plan?.defaultAccountsFolderID != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackground()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        summaryCard
                            .padding(.bottom, 6)

                        ForEach(groupedCategories, id: \.category) { group in
                            Section {
                                ForEach(group.items) { item in
                                    itemRow(item)
                                }
                            } header: {
                                sectionHeader(category: group.category, count: group.items.count)
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .navigationTitle("Auto-Categorize & Logos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if plan == nil {
                    let built = AccountCategorizer.buildPlan(accounts: vault.accounts, folders: vault.folders)
                    plan = built
                    assignments = Dictionary(uniqueKeysWithValues: built.items.map { ($0.id, $0.category) })
                    selectedIDs = Set(built.items.map(\.id))
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedIDs.count) Accounts → \(groupedCategories.count) Categories")
                        .font(.headline)
                    Text("\(matchedVectorCount) matched to bundled vector logos • \(webFetchCandidateCount) web-fetchable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $fetchWebLogos) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fetch web logos for custom domains")
                        .font(.subheadline)
                    Text("Connects to each domain or Google Favicons to download icons for selected accounts.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if hasDefaultAccountsFolder {
                Toggle("Remove empty 'Accounts' folder", isOn: $removeEmptyDefaultFolder)
                    .font(.subheadline)
            }

            Button {
                applyNow()
            } label: {
                HStack {
                    if isApplying {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Label("Apply Categories & Logos", systemImage: "checkmark.circle.fill")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(selectedIDs.isEmpty || isApplying)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }

    private func sectionHeader(category: OTPCategory, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(category.displayName.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func itemRow(_ item: CategorizationItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        let currentCategory = assignments[item.id] ?? item.category

        return HStack(spacing: 12) {
            Button {
                if isSelected {
                    selectedIDs.remove(item.id)
                } else {
                    selectedIDs.insert(item.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            BrandAvatarView(
                account: item.account,
                size: 32,
                logoRevision: vault.logoCacheRevision
            )
            .equatable()

            VStack(alignment: .leading, spacing: 2) {
                Text(item.account.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 4) {
                    if let matched = item.matchedBrand {
                        Text(matched.svgPath != nil ? "Vector logo" : matched.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if let domain = item.inferredLogoDomain {
                        Text(domain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let current = item.currentFolderName {
                        Text("• from \(current)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Menu {
                ForEach(OTPCategory.allCases) { cat in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            assignments[item.id] = cat
                        }
                    } label: {
                        if cat == currentCategory {
                            Label(cat.displayName, systemImage: "checkmark")
                        } else {
                            Label(cat.displayName, systemImage: cat.symbolName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: currentCategory.symbolName)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Change category for \(item.account.displayTitle), currently \(currentCategory.displayName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func applyNow() {
        isApplying = true
        let filteredAssignments = assignments.filter { selectedIDs.contains($0.key) }
        guard vault.applyCategorization(filteredAssignments, removeEmptyDefaultFolder: removeEmptyDefaultFolder) else {
            isApplying = false
            return
        }

        if fetchWebLogos {
            let selectedAccounts = vault.accounts.filter { selectedIDs.contains($0.id) }
            Task {
                let fetched = await vault.fetchMissingWebLogos(for: selectedAccounts)
                isApplying = false
                if fetched > 0 {
                    vault.alertMessage = "Organized \(filteredAssignments.count) accounts and fetched \(fetched) service \(fetched == 1 ? "logo" : "logos")."
                }
                dismiss()
            }
        } else {
            isApplying = false
            dismiss()
        }
    }
}
