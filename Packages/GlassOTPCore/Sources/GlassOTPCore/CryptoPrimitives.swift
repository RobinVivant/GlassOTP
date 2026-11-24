import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum OTPImportError: Error, LocalizedError, Equatable, Sendable {
    case invalidFileFormat
    case wrongPassword
    case unsupportedVersion(Double)
    case corruptedArchive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileFormat:
            "This file isn't a recognized OTP Auth backup (.otpauthdb or .otpauth)."
        case .wrongPassword:
            "Incorrect backup password. Please verify and try again."
        case .unsupportedVersion(let version):
            "Unsupported backup format version (\(version))."
        case .corruptedArchive(let reason):
            "Could not parse backup archive: \(reason)"
        }
    }
}

public enum CryptoPrimitives {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    public static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw OTPImportError.corruptedArchive("Random generation failed (\(status)).")
        }
        return Data(bytes)
    }

    public static func aes256CBCDecrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256,
              iv.count == kCCBlockSizeAES128,
              !ciphertext.isEmpty,
              ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw OTPImportError.wrongPassword
        }

        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = output.withUnsafeMutableBytes { outputPtr in
            ciphertext.withUnsafeBytes { cipherPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress,
                            key.count,
                            ivPtr.baseAddress,
                            cipherPtr.baseAddress,
                            ciphertext.count,
                            outputPtr.baseAddress,
                            bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw OTPImportError.wrongPassword
        }
        output.count = numBytesDecrypted
        return output
    }

    public static func aes256CBCEncrypt(plaintext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw OTPImportError.corruptedArchive("Invalid AES key or IV size.")
        }

        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var output = Data(count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = output.withUnsafeMutableBytes { outputPtr in
            plaintext.withUnsafeBytes { plainPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress,
                            key.count,
                            ivPtr.baseAddress,
                            plainPtr.baseAddress,
                            plaintext.count,
                            outputPtr.baseAddress,
                            bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw OTPImportError.corruptedArchive("AES encryption failed (\(status)).")
        }
        output.count = numBytesEncrypted
        return output
    }

    public static func pbkdf2SHA1(
        password: Data,
        salt: Data,
        iterations: UInt32 = 10_000,
        keyLength: Int = 32
    ) throws -> Data {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            password.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw OTPImportError.corruptedArchive("Key derivation failed (\(status)).")
        }
        return derived
    }

    public static func rncryptorV3Decrypt(data: Data, password: String) throws -> Data {
        // RNCryptor v3 format:
        // version (1 byte = 0x03) + options (1 byte = 0x01) +
        // encSalt (8) + hmacSalt (8) + iv (16) + ciphertext (N*16) + hmac (32)
        let headerSize = 34
        let hmacSize = 32
        guard data.count >= headerSize + hmacSize else {
            throw OTPImportError.invalidFileFormat
        }
        guard data[data.startIndex] == 3 else {
            throw OTPImportError.unsupportedVersion(Double(data[data.startIndex]))
        }

        let start = data.startIndex
        let encSalt = Data(data[(start + 2)..<(start + 10)])
        let hmacSalt = Data(data[(start + 10)..<(start + 18)])
        let iv = Data(data[(start + 18)..<(start + 34)])
        let headerAndCiphertext = Data(data[start..<(data.endIndex - hmacSize)])
        let ciphertext = Data(data[(start + 34)..<(data.endIndex - hmacSize)])
        let expectedMAC = Data(data[(data.endIndex - hmacSize)..<data.endIndex])

        let passwordData = Data(password.utf8)
        let hmacKey = try pbkdf2SHA1(password: passwordData, salt: hmacSalt, iterations: 10_000, keyLength: 32)
        let calculatedMAC = Data(HMAC<SHA256>.authenticationCode(for: headerAndCiphertext, using: SymmetricKey(data: hmacKey)))

        guard constantTimeEqual(calculatedMAC, expectedMAC) else {
            throw OTPImportError.wrongPassword
        }

        let encryptionKey = try pbkdf2SHA1(password: passwordData, salt: encSalt, iterations: 10_000, keyLength: 32)
        return try aes256CBCDecrypt(ciphertext: ciphertext, key: encryptionKey, iv: iv)
    }

    public static func rncryptorV3Encrypt(plaintext: Data, password: String) throws -> Data {
        let encSalt = try randomBytes(count: 8)
        let hmacSalt = try randomBytes(count: 8)
        let iv = try randomBytes(count: 16)
        let passwordData = Data(password.utf8)

        let encKey = try pbkdf2SHA1(password: passwordData, salt: encSalt, iterations: 10_000, keyLength: 32)
        let hmacKey = try pbkdf2SHA1(password: passwordData, salt: hmacSalt, iterations: 10_000, keyLength: 32)
        let ciphertext = try aes256CBCEncrypt(plaintext: plaintext, key: encKey, iv: iv)

        var packet = Data()
        packet.append(3) // RNCryptor v3
        packet.append(1) // password-protected options byte
        packet.append(encSalt)
        packet.append(hmacSalt)
        packet.append(iv)
        packet.append(ciphertext)

        let mac = Data(HMAC<SHA256>.authenticationCode(for: packet, using: SymmetricKey(data: hmacKey)))
        packet.append(mac)
        return packet
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= (a ^ b)
        }
        return diff == 0
    }
}
