import CryptoKit
import Foundation

public enum BrandLogoCache {
    private static let folderName = "BrandLogos"

    private static var cacheDirectory: URL {
        if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: GlassOTPConstants.appGroupID
        ) {
            return appGroupURL.appendingPathComponent(folderName, isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("GlassOTP-\(folderName)", isDirectory: true)
    }

    private static func fileURL(forDomain domain: String) -> URL? {
        guard let cleaned = BrandCatalog.cleanedDomain(domain) else { return nil }
        let digest = SHA256.hash(data: Data(cleaned.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).png")
    }

    public static func hasCachedLogo(forDomain domain: String) -> Bool {
        guard let url = fileURL(forDomain: domain) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public static func loadPNGData(forDomain domain: String) -> Data? {
        guard let url = fileURL(forDomain: domain) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func savePNGData(_ data: Data, forDomain domain: String) {
        guard let url = fileURL(forDomain: domain), !data.isEmpty else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
