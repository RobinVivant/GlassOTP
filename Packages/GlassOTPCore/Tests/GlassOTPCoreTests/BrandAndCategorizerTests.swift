import CoreGraphics
import Foundation
import Testing
@testable import GlassOTPCore

struct BrandAndCategorizerTests {
    @Test("Every bundled SVG path in brand_logos.json parses into a valid non-empty CGPath")
    func parseAllBundledSVGPaths() throws {
        let brands = BrandCatalog.shared.allBrands()
        #expect(brands.count >= 250)

        let svgBrands = brands.filter { $0.svgPath != nil }
        #expect(svgBrands.count >= 240)

        for brand in svgBrands {
            let d = try #require(brand.svgPath)
            let path = try #require(SVGPathParser.parse(d), "Failed to parse SVG path for \(brand.slug)")
            #expect(!path.isEmpty, "Empty CGPath for \(brand.slug)")
            let box = path.boundingBoxOfPath
            #expect(box.width > 0 && box.height > 0, "Zero-area bounding box for \(brand.slug)")
            #expect(box.minX >= -3.0 && box.maxX <= 27.0, "Out-of-bounds X for \(brand.slug): \(box)")
            #expect(box.minY >= -3.0 && box.maxY <= 27.0, "Out-of-bounds Y for \(brand.slug): \(box)")
        }
    }

    @Test("SVGPathParser handles compact arc flags without spaces (e.g. a4 4 0 014 4)")
    func compactArcFlags() throws {
        let compact = "M4 8a4 4 0 014-4h8a4 4 0 014 4v8a4 4 0 01-4 4H8a4 4 0 01-4-4z"
        let path = try #require(SVGPathParser.parse(compact))
        #expect(!path.isEmpty)
        let box = path.boundingBoxOfPath
        #expect(box.minX >= 3.9 && box.maxX <= 20.1)
        #expect(box.minY >= 3.9 && box.maxY <= 20.1)
    }

    @Test("Brand matching resolves major services accurately and distinguishes AWS vs Amazon, GCP vs Google")
    func brandMatchingAccuracy() {
        let secret = Data("secret".utf8)
        let cases: [(issuer: String, label: String, expectedSlug: String, expectedCat: OTPCategory)] = [
            ("GitHub", "robin@gmail.com", "github", .dev),
            ("Amazon Web Services", "root@prod", "amazonaws", .cloud),
            ("AWS", "admin", "amazonaws", .cloud),
            ("Amazon", "robin@icloud.com", "amazon", .shopping),
            ("Google Cloud", "ops@company.com", "googlecloud", .cloud),
            ("Google", "robin@gmail.com", "google", .personal),
            ("Cloudflare", "dash.cloudflare.com", "cloudflare", .cloud),
            ("Microsoft Azure", "admin", "microsoftazure", .cloud),
            ("Microsoft", "robin@outlook.com", "microsoft", .work),
            ("Slack", "team", "slack", .work),
            ("Discord", "gamer#0001", "discord", .social),
            ("Stripe", "finance@company.com", "stripe", .finance),
            ("1Password", "family", "1password", .security),
            ("Proton", "robin@proton.me", "proton", .security),
            ("Tailscale", "home-net", "tailscale", .cloud),
            ("Synology", "nas", "synology", .cloud),
            ("Revolut", "personal", "revolut", .finance),
            ("Wise", "transfers", "wise", .finance),
            ("Steam", "player", "steam", .gaming),
            ("OpenAI", "platform", "openai", .dev),
            ("Anthropic", "claude.ai", "anthropic", .dev),
            ("BoursoBank", "client", "boursobank", .finance),
            ("VERO", "robin@vero.io", "vero", .work),
        ]

        for item in cases {
            let account = OTPAccount(issuer: item.issuer, label: item.label, secret: secret)
            let matched = BrandCatalog.shared.match(account: account)
            #expect(matched?.slug == item.expectedSlug, "Expected \(item.expectedSlug) for \(item.issuer), got \(matched?.slug ?? "nil")")
            #expect(AccountCategorizer.categorize(account: account) == item.expectedCat)
        }
    }

    @Test("Custom brand override takes precedence over issuer and label heuristics")
    func customBrandOverride() {
        let secret = Data("secret".utf8)
        let account = OTPAccount(
            issuer: "Custom Internal Portal",
            label: "user@example.com",
            secret: secret,
            customBrandSlug: "cloudflare",
            customLogoDomain: "internal.example.com"
        )
        let matched = BrandCatalog.shared.match(account: account)
        #expect(matched?.slug == "cloudflare")
        #expect(BrandCatalog.shared.inferredDomain(for: account) == "internal.example.com")
    }

    @Test("Auto-categorizer creates only used category folders, reuses existing ones, and drops empty default Accounts folder")
    func autoCategorizerPlanAndApply() {
        let secret = Data("secret".utf8)
        let defaultFolder = OTPFolder(name: "Accounts", symbolName: "folder.fill", sortOrder: 0)
        let existingWork = OTPFolder(name: "Work", symbolName: "briefcase.fill", sortOrder: 1)

        let gh = OTPAccount(issuer: "GitHub", label: "dev", secret: secret, folderID: defaultFolder.id)
        let cf = OTPAccount(issuer: "Cloudflare", label: "dns", secret: secret, folderID: defaultFolder.id)
        let slack = OTPAccount(issuer: "Slack", label: "team", secret: secret, folderID: defaultFolder.id)
        let unknownInfra = OTPAccount(issuer: "My Cool Proxmox Lab", label: "root", secret: secret)

        let plan = AccountCategorizer.buildPlan(
            accounts: [gh, cf, slack, unknownInfra],
            folders: [defaultFolder, existingWork]
        )
        #expect(plan.defaultAccountsFolderID == defaultFolder.id)

        let assignments = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0.category) })
        let result = AccountCategorizer.apply(
            assignments: assignments,
            toAccounts: [gh, cf, slack, unknownInfra],
            existingFolders: [defaultFolder, existingWork],
            removeEmptyDefaultFolder: true
        )

        let folderNames = Set(result.folders.map(\.name))
        #expect(!folderNames.contains("Accounts"))
        #expect(folderNames.contains("Work"))
        #expect(folderNames.contains("Dev & Code"))
        #expect(folderNames.contains("Cloud & Infra"))
        #expect(result.folders.count == 3)

        let workID = result.folders.first(where: { $0.name == "Work" })?.id
        #expect(result.accounts.first(where: { $0.id == slack.id })?.folderID == workID)
    }

    @Test("Backward compatibility: v1 JSON OTPVaultSnapshot without customBrandSlug/customLogoDomain decodes cleanly")
    func backwardCompatibleDecoding() throws {
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-11-24T20:00:00Z",
          "folders": [
            { "id": "11111111-1111-1111-1111-111111111111", "name": "Accounts", "symbolName": "folder.fill", "sortOrder": 0 }
          ],
          "accounts": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "issuer": "GitHub",
              "label": "robin@vero.io",
              "secret": "c3VwZXJzZWNyZXQ=",
              "type": "totp",
              "algorithm": "sha1",
              "digits": 6,
              "period": 30,
              "counter": 0,
              "folderID": "11111111-1111-1111-1111-111111111111",
              "isPinned": true,
              "sortOrder": 0,
              "createdAt": "2026-11-24T20:00:00Z",
              "updatedAt": "2026-11-24T20:00:00Z"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(OTPVaultSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.accounts[0].customBrandSlug == nil)
        #expect(snapshot.accounts[0].customLogoDomain == nil)
        #expect(BrandCatalog.shared.match(account: snapshot.accounts[0])?.slug == "github")
    }

    @Test("BrandCatalog memoization distinguishes overrides, hits, and misses consistently")
    func brandCatalogMemoizationConsistency() {
        let secret = Data("secret".utf8)
        let missAccount = OTPAccount(issuer: "UnknownInternalPortalXYZ", label: "alice@local", secret: secret)
        #expect(BrandCatalog.shared.match(account: missAccount) == nil)
        #expect(BrandCatalog.shared.match(account: missAccount) == nil)
        #expect(BrandCatalog.shared.inferredDomain(for: missAccount) == nil)
        #expect(BrandCatalog.shared.inferredDomain(for: missAccount, includeHeuristicFallback: true) == "unknowninternalportalxyz.com")

        let overrideAccount = OTPAccount(
            issuer: "UnknownInternalPortalXYZ",
            label: "alice@local",
            secret: secret,
            customBrandSlug: "github",
            customLogoDomain: "override.example.com"
        )
        #expect(BrandCatalog.shared.match(account: overrideAccount)?.slug == "github")
        #expect(BrandCatalog.shared.match(account: overrideAccount)?.slug == "github")
        #expect(BrandCatalog.shared.inferredDomain(for: overrideAccount) == "override.example.com")
        #expect(BrandCatalog.shared.match(account: missAccount) == nil)
    }

    @Test("AccountCategorizer fast suggestion check matches buildPlan results across vault states")
    func fastSuggestionCheckParity() {
        let secret = Data("secret".utf8)
        let defaultFolder = OTPFolder(name: "Accounts", symbolName: "folder.fill", sortOrder: 0)
        let devFolder = OTPFolder(name: "Dev & Code", symbolName: "chevron.left.forwardslash.chevron.right", sortOrder: 1)

        let ghDefault = OTPAccount(issuer: "GitHub", label: "a", secret: secret, folderID: defaultFolder.id)
        let cfDefault = OTPAccount(issuer: "Cloudflare", label: "b", secret: secret, folderID: defaultFolder.id)
        let ghUncat = OTPAccount(issuer: "GitHub", label: "a", secret: secret, folderID: nil)
        let cfUncat = OTPAccount(issuer: "Cloudflare", label: "b", secret: secret, folderID: nil)
        let ghDev = OTPAccount(issuer: "GitHub", label: "a", secret: secret, folderID: devFolder.id)
        let cfDev = OTPAccount(issuer: "Cloudflare", label: "b", secret: secret, folderID: devFolder.id)

        let cases: [(accounts: [OTPAccount], folders: [OTPFolder], expected: Bool)] = [
            ([ghDefault, cfDefault], [defaultFolder], true),
            ([ghUncat, cfUncat], [devFolder], true),
            ([ghUncat, cfDev], [devFolder], false),
            ([ghDev, cfDev], [devFolder], false),
            ([ghDefault], [defaultFolder], false),
        ]

        for testCase in cases {
            let fast = AccountCategorizer.hasUncategorizedOrDefaultOnly(
                accounts: testCase.accounts,
                folders: testCase.folders
            )
            let plan = AccountCategorizer.buildPlan(accounts: testCase.accounts, folders: testCase.folders)
            #expect(fast == testCase.expected)
            #expect(fast == plan.hasUncategorizedOrDefaultOnly)
        }
    }

    @Test("BrandLogoCache negative misses clear cleanly on savePNGData and clearAll")
    func brandLogoCacheInvalidation() {
        let domain = "perf-cache-\(UUID().uuidString.lowercased()).example.com"
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03, 0x04])

        #expect(BrandLogoCache.hasCachedLogo(forDomain: domain) == false)
        #expect(BrandLogoCache.loadPNGData(forDomain: domain) == nil)

        BrandLogoCache.savePNGData(payload, forDomain: domain)
        #expect(BrandLogoCache.hasCachedLogo(forDomain: domain) == true)
        #expect(BrandLogoCache.loadPNGData(forDomain: domain) == payload)

        BrandLogoCache.clearAll()
        #expect(BrandLogoCache.hasCachedLogo(forDomain: domain) == false)
        #expect(BrandLogoCache.loadPNGData(forDomain: domain) == nil)
    }

    @Test("OTPGenerator.totpTiming and snapshot(includeNextCode: false) match full snapshot")
    func lightweightTOTPTimingMatchesSnapshot() {
        let secret = Data("JBSWY3DPEHPK3PXP".utf8)
        let account = OTPAccount(issuer: "GitHub", label: "robin", secret: secret, period: 30)
        let testDate = Date(timeIntervalSince1970: 1_700_000_006.25)

        let full = OTPGenerator.snapshot(for: account, at: testDate, includeNextCode: true)
        let light = OTPGenerator.snapshot(for: account, at: testDate, includeNextCode: false)
        let timing = OTPGenerator.totpTiming(period: account.period, at: testDate)

        #expect(light.code == full.code)
        #expect(light.formattedCode == full.formattedCode)
        #expect(light.nextCode == nil)
        #expect(light.formattedNextCode == nil)
        #expect(full.nextCode != nil)

        #expect(abs(timing.remainingSeconds - full.remainingSeconds) < 0.0001)
        #expect(abs(timing.progress - full.progress) < 0.0001)
        #expect(abs(timing.remainingSeconds - 3.75) < 0.0001)

        let derivedCode = OTPGenerator.generateHOTP(
            secret: account.secret,
            counter: timing.counter,
            digits: account.digits,
            algorithm: account.algorithm
        )
        #expect(derivedCode == full.code)
    }
}
