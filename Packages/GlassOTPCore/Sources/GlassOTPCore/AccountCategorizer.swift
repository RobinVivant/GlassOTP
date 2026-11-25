import Foundation

public struct CategorizationItem: Identifiable, Sendable {
    public let id: UUID
    public let account: OTPAccount
    public let matchedBrand: BrandDefinition?
    public let category: OTPCategory
    public let currentFolderName: String?
    public let inferredLogoDomain: String?

    public init(
        account: OTPAccount,
        matchedBrand: BrandDefinition?,
        category: OTPCategory,
        currentFolderName: String?,
        inferredLogoDomain: String?
    ) {
        self.id = account.id
        self.account = account
        self.matchedBrand = matchedBrand
        self.category = category
        self.currentFolderName = currentFolderName
        self.inferredLogoDomain = inferredLogoDomain
    }
}

public struct CategorizationPlan: Sendable {
    public let items: [CategorizationItem]
    public let categoryCounts: [(category: OTPCategory, count: Int)]
    public let hasUncategorizedOrDefaultOnly: Bool
    public let defaultAccountsFolderID: UUID?

    public init(
        items: [CategorizationItem],
        categoryCounts: [(category: OTPCategory, count: Int)],
        hasUncategorizedOrDefaultOnly: Bool,
        defaultAccountsFolderID: UUID?
    ) {
        self.items = items
        self.categoryCounts = categoryCounts
        self.hasUncategorizedOrDefaultOnly = hasUncategorizedOrDefaultOnly
        self.defaultAccountsFolderID = defaultAccountsFolderID
    }
}

public enum AccountCategorizer {
    public static func categorize(account: OTPAccount) -> OTPCategory {
        if let brand = BrandCatalog.shared.match(account: account) {
            return brand.category
        }

        let combined = "\(account.issuer) \(account.label)".lowercased()

        let keywordRules: [(category: OTPCategory, keywords: [String])] = [
            (.dev, ["git", "repo", "ci", "cd", "dev", "staging", "npm", "docker", "kube", "k8s", "sentry", "grafana", "datadog", "api", "jenkins", "terraform", "vercel", "supabase", "cursor", "anthropic", "openai", "claude", "code"]),
            (.cloud, ["aws", "azure", "gcp", "cloud", "nas", "synology", "proxmox", "ssh", "vpn", "dns", "unifi", "server", "vps", "host", "domain", "ovh", "hetzner", "scaleway", "tailscale", "router", "firewall", "pfsense", "truenas", "homeassistant", "home-assistant"]),
            (.finance, ["bank", "banque", "pay", "crypto", "wallet", "ledger", "kraken", "binance", "coin", "trade", "broker", "bourse", "bourso", "qonto", "revolut", "wise", "n26", "bnp", "impots", "tax", "amex", "visa", "stripe", "invest"]),
            (.security, ["1password", "bitwarden", "vault", "pass", "key", "proton", "privacy", "security", "fastmail", "tuta", "vpn", "adguard", "nextdns", "yubi", "gpg", "pgp"]),
            (.work, ["corp", "company", "work", "office", "slack", "jira", "confluence", "notion", "sso", "okta", "hr", "swile", "alan", "vero", "ojingo", "zoom", "salesforce"]),
            (.gaming, ["steam", "game", "gaming", "xbox", "playstation", "psn", "nintendo", "epic", "riot", "blizzard", "battle.net", "ubisoft", "roblox", "twitch", "minecraft"]),
            (.shopping, ["shop", "store", "amazon", "ebay", "vinted", "ikea", "air", "flight", "sncf", "train", "booking", "hotel", "uber", "deliveroo", "fnac", "leboncoin"]),
            (.social, ["social", "discord", "twitter", "reddit", "insta", "facebook", "meta", "tiktok", "spotify", "netflix", "plex", "telegram", "signal", "whatsapp", "youtube"]),
        ]

        for rule in keywordRules {
            if rule.keywords.contains(where: { combined.contains($0) }) {
                return rule.category
            }
        }

        return .personal
    }

    public static func buildPlan(accounts: [OTPAccount], folders: [OTPFolder]) -> CategorizationPlan {
        let folderLookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        let items = accounts.map { account in
            let brand = BrandCatalog.shared.match(account: account)
            let category = categorize(account: account)
            let domain = BrandCatalog.shared.inferredDomain(for: account, includeHeuristicFallback: true)
            return CategorizationItem(
                account: account,
                matchedBrand: brand,
                category: category,
                currentFolderName: account.folderID.flatMap { folderLookup[$0] },
                inferredLogoDomain: domain
            )
        }

        var counts: [OTPCategory: Int] = [:]
        for item in items {
            counts[item.category, default: 0] += 1
        }
        let sortedCounts = OTPCategory.allCases.compactMap { cat -> (OTPCategory, Int)? in
            guard let count = counts[cat], count > 0 else { return nil }
            return (cat, count)
        }

        let defaultAccountsFolder = folders.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Accounts") == .orderedSame
        }
        let uncategorizedCount = accounts.filter { $0.folderID == nil }.count
        let onlyDefaultFolder = folders.count == 1 && defaultAccountsFolder != nil
        let hasUncategorizedOrDefaultOnly = uncategorizedCount >= 2 || (onlyDefaultFolder && accounts.count >= 2)

        return CategorizationPlan(
            items: items,
            categoryCounts: sortedCounts,
            hasUncategorizedOrDefaultOnly: hasUncategorizedOrDefaultOnly,
            defaultAccountsFolderID: defaultAccountsFolder?.id
        )
    }

    public static func apply(
        assignments: [UUID: OTPCategory],
        toAccounts accounts: [OTPAccount],
        existingFolders: [OTPFolder],
        removeEmptyDefaultFolder: Bool = true
    ) -> (folders: [OTPFolder], accounts: [OTPAccount]) {
        var updatedFolders = existingFolders
        var folderByCategory: [OTPCategory: UUID] = [:]

        // Reuse existing folders matching category names first
        for category in OTPCategory.allCases {
            if let existing = updatedFolders.first(where: {
                $0.name.caseInsensitiveCompare(category.displayName) == .orderedSame
            }) {
                folderByCategory[category] = existing.id
            }
        }

        var updatedAccounts = accounts
        for idx in updatedAccounts.indices {
            let id = updatedAccounts[idx].id
            guard let targetCategory = assignments[id] else { continue }

            let folderID: UUID
            if let existingID = folderByCategory[targetCategory] {
                folderID = existingID
            } else {
                let created = OTPFolder(
                    name: targetCategory.displayName,
                    symbolName: targetCategory.symbolName,
                    sortOrder: updatedFolders.count
                )
                updatedFolders.append(created)
                folderByCategory[targetCategory] = created.id
                folderID = created.id
            }

            updatedAccounts[idx].folderID = folderID
            updatedAccounts[idx].updatedAt = Date()
        }

        if removeEmptyDefaultFolder {
            let usedFolderIDs = Set(updatedAccounts.compactMap(\.folderID))
            updatedFolders.removeAll { folder in
                folder.name.caseInsensitiveCompare("Accounts") == .orderedSame
                    && !usedFolderIDs.contains(folder.id)
            }
        }

        for idx in updatedFolders.indices {
            updatedFolders[idx].sortOrder = idx
        }

        return (updatedFolders, updatedAccounts)
    }
}
