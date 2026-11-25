import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum OTPImportError: Error, LocalizedError, Equatable, Sendable {
    case invalidFileFormat
    case passwordRequired(String)
    case passwordTooShort(Int)
    case wrongPassword
    case unsupportedVersion(Double)
    case unsupportedEncryptedFormat(String)
    case corruptedArchive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileFormat:
            "This file isn't a recognized OTP backup or export format."
        case .passwordRequired(let format):
            "This \(format) is encrypted. Enter the backup password to decrypt it."
        case .passwordTooShort(let minimum):
            "Use a backup password of at least \(minimum) characters."
        case .wrongPassword:
            "Incorrect backup password. Please verify and try again."
        case .unsupportedVersion(let version):
            "Unsupported backup format version (\(version))."
        case .unsupportedEncryptedFormat(let reason):
            reason
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
        try pbkdf2(
            password: password,
            salt: salt,
            algorithm: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            iterations: iterations,
            keyLength: keyLength
        )
    }

    public static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: UInt32 = 10_000,
        keyLength: Int = 32
    ) throws -> Data {
        try pbkdf2(
            password: password,
            salt: salt,
            algorithm: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations: iterations,
            keyLength: keyLength
        )
    }

    private static func pbkdf2(
        password: Data,
        salt: Data,
        algorithm: CCPseudoRandomAlgorithm,
        iterations: UInt32,
        keyLength: Int
    ) throws -> Data {
        guard iterations > 0, keyLength > 0 else {
            throw OTPImportError.corruptedArchive("Invalid PBKDF2 parameters.")
        }
        let safePassword = password.isEmpty ? Data([0]) : password
        let safeSalt = salt.isEmpty ? Data([0]) : salt
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            safePassword.withUnsafeBytes { passwordPtr in
                safeSalt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        algorithm,
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

    public static func aes256GCMDecrypt(
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        key: Data
    ) throws -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw OTPImportError.corruptedArchive("Invalid AES-GCM key size.")
        }
        let gcmNonce: AES.GCM.Nonce
        do {
            gcmNonce = try AES.GCM.Nonce(data: nonce)
        } catch {
            throw OTPImportError.corruptedArchive("Invalid AES-GCM nonce.")
        }
        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
        } catch {
            throw OTPImportError.wrongPassword
        }
    }

    public static func aes256GCMEncrypt(
        plaintext: Data,
        nonce: Data,
        key: Data
    ) throws -> (ciphertext: Data, tag: Data) {
        guard key.count == kCCKeySizeAES256 else {
            throw OTPImportError.corruptedArchive("Invalid AES-GCM key size.")
        }
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: gcmNonce)
        return (sealed.ciphertext, sealed.tag)
    }

    public static func hexDecode(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else {
            return cleaned.isEmpty ? Data() : nil
        }
        var data = Data()
        data.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            idx = next
        }
        return data
    }

    /// Pure-Swift RFC 7914 scrypt key derivation for encrypted vault imports (e.g. Aegis).
    public static func scrypt(
        password: Data,
        salt: Data,
        n: Int,
        r: Int,
        p: Int,
        keyLength: Int = 32
    ) throws -> Data {
        guard n >= 2,
              (n & (n - 1)) == 0,
              r >= 1,
              p >= 1,
              keyLength >= 1,
              keyLength <= 4096,
              n <= (1 << 20),
              r <= 32,
              p <= 16 else {
            throw OTPImportError.corruptedArchive("Invalid scrypt parameters.")
        }

        let (blockBytes, overflow1) = 128.multipliedReportingOverflow(by: r)
        let (scratchBytes, overflow2) = blockBytes.multipliedReportingOverflow(by: n)
        let (initialBytes, overflow3) = blockBytes.multipliedReportingOverflow(by: p)
        let (nr, overflow4) = n.multipliedReportingOverflow(by: r)
        let (nrp, overflow5) = nr.multipliedReportingOverflow(by: p)
        guard !overflow1, !overflow2, !overflow3, !overflow4, !overflow5,
              scratchBytes <= 128 * 1024 * 1024,
              initialBytes <= 64 * 1024,
              nrp <= 2_097_152,
              initialBytes > 0 else {
            throw OTPImportError.corruptedArchive("scrypt memory or work parameters out of supported range.")
        }

        let initialKeyMaterial = try pbkdf2SHA256(
            password: password,
            salt: salt,
            iterations: 1,
            keyLength: initialBytes
        )

        let blockWordCount = 32 * r
        var blocks = [UInt32](repeating: 0, count: p * blockWordCount)
        initialKeyMaterial.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for idx in 0..<blocks.count {
                let offset = idx * 4
                let b0 = UInt32(raw[offset])
                let b1 = UInt32(raw[offset + 1]) << 8
                let b2 = UInt32(raw[offset + 2]) << 16
                let b3 = UInt32(raw[offset + 3]) << 24
                blocks[idx] = b0 | b1 | b2 | b3
            }
        }

        var vBuffer = [UInt32](repeating: 0, count: n * blockWordCount)
        var xBuffer = [UInt32](repeating: 0, count: blockWordCount)
        var yBuffer = [UInt32](repeating: 0, count: blockWordCount)
        var salsaState = [UInt32](repeating: 0, count: 16)

        for blockIndex in 0..<p {
            let base = blockIndex * blockWordCount
            for idx in 0..<blockWordCount {
                xBuffer[idx] = blocks[base + idx]
            }

            scryptROMix(
                x: &xBuffer,
                y: &yBuffer,
                v: &vBuffer,
                salsaState: &salsaState,
                n: n,
                r: r,
                blockWordCount: blockWordCount
            )

            for idx in 0..<blockWordCount {
                blocks[base + idx] = xBuffer[idx]
            }
        }

        var derivedSalt = Data(count: initialBytes)
        derivedSalt.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
            for idx in 0..<blocks.count {
                let word = blocks[idx]
                let offset = idx * 4
                outRaw[offset] = UInt8(word & 0xFF)
                outRaw[offset + 1] = UInt8((word >> 8) & 0xFF)
                outRaw[offset + 2] = UInt8((word >> 16) & 0xFF)
                outRaw[offset + 3] = UInt8((word >> 24) & 0xFF)
            }
        }

        return try pbkdf2SHA256(
            password: password,
            salt: derivedSalt,
            iterations: 1,
            keyLength: keyLength
        )
    }

    private static func scryptROMix(
        x: inout [UInt32],
        y: inout [UInt32],
        v: inout [UInt32],
        salsaState: inout [UInt32],
        n: Int,
        r: Int,
        blockWordCount: Int
    ) {
        for i in 0..<n {
            let vOffset = i * blockWordCount
            for k in 0..<blockWordCount {
                v[vOffset + k] = x[k]
            }
            scryptBlockMixSalsa8(input: x, output: &y, temp: &salsaState, r: r)
            swap(&x, &y)
        }

        let mask = UInt64(n - 1)
        let lastChunkWordOffset = (2 * r - 1) * 16
        for _ in 0..<n {
            let integerLow = UInt64(x[lastChunkWordOffset])
            let integerHigh = UInt64(x[lastChunkWordOffset + 1]) << 32
            let j = Int((integerLow | integerHigh) & mask)
            let vOffset = j * blockWordCount
            for k in 0..<blockWordCount {
                x[k] ^= v[vOffset + k]
            }
            scryptBlockMixSalsa8(input: x, output: &y, temp: &salsaState, r: r)
            swap(&x, &y)
        }
    }

    private static func scryptBlockMixSalsa8(
        input: [UInt32],
        output: inout [UInt32],
        temp: inout [UInt32],
        r: Int
    ) {
        let lastOffset = (2 * r - 1) * 16
        for k in 0..<16 {
            temp[k] = input[lastOffset + k]
        }

        for i in 0..<(2 * r) {
            let inOffset = i * 16
            for k in 0..<16 {
                temp[k] ^= input[inOffset + k]
            }
            salsa20Eight(&temp)

            let outChunk = (i & 1 == 0) ? (i >> 1) : (r + (i >> 1))
            let outOffset = outChunk * 16
            for k in 0..<16 {
                output[outOffset + k] = temp[k]
            }
        }
    }

    private static func salsa20Eight(_ b: inout [UInt32]) {
        func rotl(_ value: UInt32, _ shift: Int) -> UInt32 {
            (value << shift) | (value >> (32 - shift))
        }

        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3]
        var x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11]
        var x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]

        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7)
            x8 ^= rotl(x4 &+ x0, 9)
            x12 ^= rotl(x8 &+ x4, 13)
            x0 ^= rotl(x12 &+ x8, 18)

            x9 ^= rotl(x5 &+ x1, 7)
            x13 ^= rotl(x9 &+ x5, 9)
            x1 ^= rotl(x13 &+ x9, 13)
            x5 ^= rotl(x1 &+ x13, 18)

            x14 ^= rotl(x10 &+ x6, 7)
            x2 ^= rotl(x14 &+ x10, 9)
            x6 ^= rotl(x2 &+ x14, 13)
            x10 ^= rotl(x6 &+ x2, 18)

            x3 ^= rotl(x15 &+ x11, 7)
            x7 ^= rotl(x3 &+ x15, 9)
            x11 ^= rotl(x7 &+ x3, 13)
            x15 ^= rotl(x11 &+ x7, 18)

            x1 ^= rotl(x0 &+ x3, 7)
            x2 ^= rotl(x1 &+ x0, 9)
            x3 ^= rotl(x2 &+ x1, 13)
            x0 ^= rotl(x3 &+ x2, 18)

            x6 ^= rotl(x5 &+ x4, 7)
            x7 ^= rotl(x6 &+ x5, 9)
            x4 ^= rotl(x7 &+ x6, 13)
            x5 ^= rotl(x4 &+ x7, 18)

            x11 ^= rotl(x10 &+ x9, 7)
            x8 ^= rotl(x11 &+ x10, 9)
            x9 ^= rotl(x8 &+ x11, 13)
            x10 ^= rotl(x9 &+ x8, 18)

            x12 ^= rotl(x15 &+ x14, 7)
            x13 ^= rotl(x12 &+ x15, 9)
            x14 ^= rotl(x13 &+ x12, 13)
            x15 ^= rotl(x14 &+ x13, 18)
        }

        b[0] &+= x0
        b[1] &+= x1
        b[2] &+= x2
        b[3] &+= x3
        b[4] &+= x4
        b[5] &+= x5
        b[6] &+= x6
        b[7] &+= x7
        b[8] &+= x8
        b[9] &+= x9
        b[10] &+= x10
        b[11] &+= x11
        b[12] &+= x12
        b[13] &+= x13
        b[14] &+= x14
        b[15] &+= x15
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
        guard data[data.startIndex + 1] == 1 else {
            throw OTPImportError.unsupportedEncryptedFormat("Unsupported RNCryptor backup options.")
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
