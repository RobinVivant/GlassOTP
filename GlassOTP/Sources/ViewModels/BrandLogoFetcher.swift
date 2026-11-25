import Foundation
import GlassOTPCore
import UIKit

enum BrandLogoFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    static func fetchMissingLogos(for accounts: [OTPAccount]) async -> Int {
        var domainsToFetch: [String] = []
        var seen = Set<String>()

        for account in accounts {
            let matched = BrandCatalog.shared.match(account: account)
            // Skip bundled offline vector logos unless the user set a custom domain override
            if matched?.svgPath != nil && account.customLogoDomain == nil {
                continue
            }
            guard let domain = BrandCatalog.shared.inferredDomain(for: account, includeHeuristicFallback: true),
                  !BrandLogoCache.hasCachedLogo(forDomain: domain),
                  !seen.contains(domain) else {
                continue
            }
            seen.insert(domain)
            domainsToFetch.append(domain)
        }

        guard !domainsToFetch.isEmpty else { return 0 }

        var fetchedCount = 0
        await withTaskGroup(of: Bool.self) { group in
            var active = 0
            for domain in domainsToFetch {
                if active >= 4 {
                    if let ok = await group.next(), ok {
                        fetchedCount += 1
                    }
                    active -= 1
                }
                group.addTask {
                    await fetchLogo(forDomain: domain)
                }
                active += 1
            }
            for await ok in group where ok {
                fetchedCount += 1
            }
        }
        return fetchedCount
    }

    @discardableResult
    static func fetchLogo(forDomain rawDomain: String) async -> Bool {
        guard let domain = BrandCatalog.cleanedDomain(rawDomain) else { return false }

        let candidates: [URL?] = [
            URL(string: "https://\(domain)/apple-touch-icon.png"),
            URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128"),
        ]

        for candidate in candidates {
            guard let url = candidate else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let image = UIImage(data: data),
                      let cgImage = image.cgImage,
                      cgImage.width >= 32,
                      cgImage.height >= 32,
                      let pngData = image.pngData() else {
                    continue
                }
                BrandLogoCache.savePNGData(pngData, forDomain: domain)
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
