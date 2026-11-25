import CryptoKit
import Foundation

private final class LogoMemoryStore: @unchecked Sendable {
    enum LookupResult {
        case hit(Data)
        case knownMiss
        case unknown
    }

    private let lock = NSLock()
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 150
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private var negativeMisses: Set<String> = []
    private let maxNegativeMisses = 1024

    func lookupData(domain: String) -> LookupResult {
        lock.withLock {
            if let cached = cache.object(forKey: domain as NSString) {
                return .hit(Data(referencing: cached))
            }
            if negativeMisses.contains(domain) {
                return .knownMiss
            }
            return .unknown
        }
    }

    func hasMemoryState(domain: String) -> Bool? {
        lock.withLock {
            if cache.object(forKey: domain as NSString) != nil {
                return true
            }
            if negativeMisses.contains(domain) {
                return false
            }
            return nil
        }
    }

    func storeHit(_ data: Data, domain: String) {
        lock.withLock {
            negativeMisses.remove(domain)
            cache.setObject(NSData(data: data), forKey: domain as NSString, cost: data.count)
        }
    }

    func storeMiss(domain: String) {
        lock.withLock {
            if negativeMisses.count >= maxNegativeMisses {
                negativeMisses.removeAll(keepingCapacity: true)
            }
            negativeMisses.insert(domain)
        }
    }

    func clearAll() {
        lock.withLock {
            cache.removeAllObjects()
            negativeMisses.removeAll(keepingCapacity: true)
        }
    }
}

public enum BrandLogoCache {
    private static let folderName = "BrandLogos"
    private static let memoryStore = LogoMemoryStore()

    private static let cacheDirectory: URL = {
        if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GlassOTPConstants.appGroupID
        ) {
            return appGroupURL.appendingPathComponent(folderName, isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("GlassOTP-\(folderName)", isDirectory: true)
    }()

    private static func fileURL(forCleanedDomain cleaned: String) -> URL {
        let digest = SHA256.hash(data: Data(cleaned.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).png")
    }

    public static func hasCachedLogo(forDomain domain: String) -> Bool {
        guard let cleaned = BrandCatalog.cleanedDomain(domain) else { return false }
        if let known = memoryStore.hasMemoryState(domain: cleaned) {
            return known
        }
        let exists = FileManager.default.fileExists(atPath: fileURL(forCleanedDomain: cleaned).path)
        if !exists {
            memoryStore.storeMiss(domain: cleaned)
        }
        return exists
    }

    public static func loadPNGData(forDomain domain: String) -> Data? {
        guard let cleaned = BrandCatalog.cleanedDomain(domain) else { return nil }
        switch memoryStore.lookupData(domain: cleaned) {
        case .hit(let data):
            return data
        case .knownMiss:
            return nil
        case .unknown:
            break
        }

        let url = fileURL(forCleanedDomain: cleaned)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            memoryStore.storeHit(data, domain: cleaned)
            return data
        }

        memoryStore.storeMiss(domain: cleaned)
        return nil
    }

    public static func savePNGData(_ data: Data, forDomain domain: String) {
        guard let cleaned = BrandCatalog.cleanedDomain(domain), !data.isEmpty else { return }
        let url = fileURL(forCleanedDomain: cleaned)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        memoryStore.storeHit(data, domain: cleaned)
    }

    public static func clearAll() {
        memoryStore.clearAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
