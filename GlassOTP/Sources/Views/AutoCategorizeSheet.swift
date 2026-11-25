import GlassOTPCore
import SwiftUI

struct AutoCategorizeSheet: View {
    @Environment(VaultViewModel.self) private var vault
    @Environment(\.dismiss) private var dismiss

    @State private var plan: CategorizationPlan?
    @State private var assignments: [UUID: OTPCategory] = [:]
    @State private var selectedIDs: Set<UUID> = []
    @State private var fetchWebLogos = true
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
                    LazyVStack(alignment: .leading, spacing: 18) {
                        summaryCard

                        ForEach(groupedCategories, id: \.category) { group in
                            categorySection(category: group.category, items: group.items)
                        }
                    }
                    .padding(16)
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

            Toggle("Fetch web logos for unmatched services", isOn: $fetchWebLogos)
                .font(.subheadline)

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

    private func categorySection(category: OTPCategory, items: [CategorizationItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: category.symbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Text(category.displayName.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    let isSelected = selectedIDs.contains(item.id)
                    HStack(spacing: 12) {
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
                            size: 38,
                            logoRevision: vault.logoCacheRevision
                        )
                        .equatable()

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.account.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let matched = item.matchedBrand {
                                    Text(matched.svgPath != nil ? "Vector logo" : matched.title)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
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
                        }

                        Spacer(minLength: 4)

                        Picker("Category", selection: Binding(
                            get: { assignments[item.id] ?? item.category },
                            set: { assignments[item.id] = $0 }
                        )) {
                            ForEach(OTPCategory.allCases) { cat in
                                Label(cat.displayName, systemImage: cat.symbolName).tag(cat)
                            }
                        }
                        .labelsHidden()
                        .tint(.secondary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func applyNow() {
        isApplying = true
        let filteredAssignments = assignments.filter { selectedIDs.contains($0.key) }
        vault.applyCategorization(filteredAssignments, removeEmptyDefaultFolder: removeEmptyDefaultFolder)

        if fetchWebLogos {
            Task {
                let fetched = await vault.fetchMissingWebLogos()
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
