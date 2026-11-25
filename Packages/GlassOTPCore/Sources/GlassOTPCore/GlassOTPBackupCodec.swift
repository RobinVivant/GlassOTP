import Foundation

public enum GlassOTPBackupCodec {
    private static let magicHeaderV1 = Data("GLOTP1".utf8)
    private static let magicHeaderV2 = Data("GLOTP2".utf8)
    private static let v2SaltLength = 16
    private static let v2NonceLength = 12
    private static let v2TagLength = 16
    private static let v2DefaultLog2N: UInt8 = 14 // N = 16,384 (16 MiB scrypt)
    private static let v2DefaultR: UInt8 = 8
    private static let v2DefaultP: UInt8 = 1

    public static func isGlassOTPBackup(_ data: Data) -> Bool {
        data.starts(with: magicHeaderV2) || data.starts(with: magicHeaderV1)
    }

    public static func encode(snapshot: OTPVaultSnapshot, password: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshot)

        let n = 1 << Int(v2DefaultLog2N)
        let r = Int(v2DefaultR)
        let p = Int(v2DefaultP)
        let salt = try CryptoPrimitives.randomBytes(count: v2SaltLength)
        let nonce = try CryptoPrimitives.randomBytes(count: v2NonceLength)
        let key = try CryptoPrimitives.scrypt(
            password: Data(password.utf8),
            salt: salt,
            n: n,
            r: r,
            p: p,
            keyLength: 32
        )
        let (ciphertext, tag) = try CryptoPrimitives.aes256GCMEncrypt(
            plaintext: jsonData,
            nonce: nonce,
            key: key
        )

        var output = Data()
        output.reserveCapacity(magicHeaderV2.count + 3 + v2SaltLength + v2NonceLength + v2TagLength + ciphertext.count)
        output.append(magicHeaderV2)
        output.append(v2DefaultLog2N)
        output.append(v2DefaultR)
        output.append(v2DefaultP)
        output.append(salt)
        output.append(nonce)
        output.append(tag)
        output.append(ciphertext)
        return output
    }

    public static func decode(data: Data, password: String) throws -> OTPVaultSnapshot {
        let plaintext: Data
        if data.starts(with: magicHeaderV2) {
            let minLength = magicHeaderV2.count + 3 + v2SaltLength + v2NonceLength + v2TagLength
            guard data.count > minLength else {
                throw OTPImportError.corruptedArchive("Truncated GlassOTP v2 backup.")
            }
            let payload = data.dropFirst(magicHeaderV2.count)
            let paramStart = payload.startIndex
            let log2N = Int(payload[paramStart])
            let r = Int(payload[paramStart + 1])
            let p = Int(payload[paramStart + 2])
            guard log2N >= 10, log2N <= 20 else {
                throw OTPImportError.corruptedArchive("Unsupported GlassOTP v2 key derivation parameters.")
            }
            let n = 1 << log2N

            let saltStart = paramStart + 3
            let nonceStart = saltStart + v2SaltLength
            let tagStart = nonceStart + v2NonceLength
            let cipherStart = tagStart + v2TagLength

            let salt = Data(payload[saltStart..<nonceStart])
            let nonce = Data(payload[nonceStart..<tagStart])
            let tag = Data(payload[tagStart..<cipherStart])
            let ciphertext = Data(payload[cipherStart..<payload.endIndex])

            let key = try CryptoPrimitives.scrypt(
                password: Data(password.utf8),
                salt: salt,
                n: n,
                r: r,
                p: p,
                keyLength: 32
            )
            plaintext = try CryptoPrimitives.aes256GCMDecrypt(
                ciphertext: ciphertext,
                nonce: nonce,
                tag: tag,
                key: key
            )
        } else if data.starts(with: magicHeaderV1) {
            let payload = Data(data.dropFirst(magicHeaderV1.count))
            plaintext = try CryptoPrimitives.rncryptorV3Decrypt(data: payload, password: password)
        } else {
            throw OTPImportError.invalidFileFormat
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(OTPVaultSnapshot.self, from: plaintext)
        } catch {
            throw OTPImportError.corruptedArchive("Unable to decode GlassOTP vault snapshot.")
        }
    }

    public static func exportURIs(accounts: [OTPAccount]) -> String {
        accounts.map { OTPUriParser.toURI($0) }.joined(separator: "\n")
    }
}
