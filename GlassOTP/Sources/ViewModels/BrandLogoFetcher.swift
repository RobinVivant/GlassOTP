import Foundation
import GlassOTPCore
import ImageIO
import UIKit

private final class LogoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private static let allowedGoogleHosts: Set<String> = [
        "google.com",
        "www.google.com",
        "gstatic.com",
        "t0.gstatic.com",
        "t1.gstatic.com",
        "t2.gstatic.com",
        "t3.gstatic.com",
    ]

    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]
    private static let maxRedirects = 3

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let hopAllowed = lock.withLock {
            let count = redirectCounts[task.taskIdentifier, default: 0] + 1
            redirectCounts[task.taskIdentifier] = count
            return count <= Self.maxRedirects
        }
        guard hopAllowed,
              let url = request.url,
              url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              Self.isAllowedGoogleHost(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            redirectCounts.removeValue(forKey: task.taskIdentifier)
        }
    }

    private static func isAllowedGoogleHost(_ host: String) -> Bool {
        allowedGoogleHosts.contains(host)
            || host.hasSuffix(".gstatic.com")
            || host.hasSuffix(".googleusercontent.com")
    }
}

enum BrandLogoFetcher {
    private static let maxDownloadBytes = 512 * 1024
    private static let maxOutputDimension: CGFloat = 128
    private static let redirectDelegate = LogoRedirectDelegate()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()

    static func fetchMissingLogos(for accounts: [OTPAccount]) async -> Int {
        var domainsToFetch: [String] = []
        var seen = Set<String>()

        for account in accounts {
            let matched = BrandCatalog.shared.match(account: account)
            let customDomain = BrandCatalog.cleanedDomain(account.customLogoDomain)
            // Skip bundled offline vector logos unless the user set a custom domain override
            if matched?.svgPath != nil && customDomain == nil {
                continue
            }
            guard let domain = BrandCatalog.shared.inferredDomain(for: account, includeHeuristicFallback: false),
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

        var googleComponents = URLComponents()
        googleComponents.scheme = "https"
        googleComponents.host = "www.google.com"
        googleComponents.path = "/s2/favicons"
        googleComponents.queryItems = [
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "sz", value: "128"),
        ]

        guard let url = googleComponents.url else { return false }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  http.expectedContentLength <= Int64(maxDownloadBytes) else {
                return false
            }

            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(Int(http.expectedContentLength))
            }
            for try await byte in bytes {
                if data.count >= maxDownloadBytes {
                    return false
                }
                data.append(byte)
            }

            guard !data.isEmpty,
                  let pngData = validatedDownsampledPNG(from: data) else {
                return false
            }
            BrandLogoCache.savePNGData(pngData, forDomain: domain)
            return true
        } catch {
            return false
        }
    }

    private static func validatedDownsampledPNG(from data: Data) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = props[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth >= 32,
              pixelHeight >= 32,
              pixelWidth <= 2048,
              pixelHeight <= 2048 else {
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxOutputDimension),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
              thumbnail.width >= 32,
              thumbnail.height >= 32 else {
            return nil
        }
        return UIImage(cgImage: thumbnail).pngData()
    }
}
