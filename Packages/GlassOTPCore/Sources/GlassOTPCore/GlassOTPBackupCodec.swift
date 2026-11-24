import Foundation

public enum GlassOTPBackupCodec {
    private static let magicHeader = Data("GLOTP1".utf8)

    public static func isGlassOTPBackup(_ data: Data) -> Bool {
        data.starts(with: magicHeader)
    }

    public static func encode(snapshot: OTPVaultSnapshot, password: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshot)
        let encrypted = try CryptoPrimitives.rncryptorV3Encrypt(plaintext: jsonData, password: password)
        var output = Data()
        output.reserveCapacity(magicHeader.count + encrypted.count)
        output.append(magicHeader)
        output.append(encrypted)
        return output
    }

    public static func decode(data: Data, password: String) throws -> OTPVaultSnapshot {
        guard isGlassOTPBackup(data) else {
            throw OTPImportError.invalidFileFormat
        }
        let payload = Data(data.dropFirst(magicHeader.count))
        let decrypted = try CryptoPrimitives.rncryptorV3Decrypt(data: payload, password: password)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(OTPVaultSnapshot.self, from: decrypted)
        } catch {
            throw OTPImportError.corruptedArchive("Unable to decode GlassOTP vault snapshot.")
        }
    }

    public static func exportURIs(accounts: [OTPAccount]) -> String {
        accounts.map { OTPUriParser.toURI($0) }.joined(separator: "\n")
    }
}
