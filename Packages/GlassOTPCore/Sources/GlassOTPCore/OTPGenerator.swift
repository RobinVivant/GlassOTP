import CryptoKit
import Foundation

public struct OTPCodeSnapshot: Equatable, Sendable {
    public let code: String
    public let formattedCode: String
    public let nextCode: String?
    public let formattedNextCode: String?
    public let periodStart: Date
    public let periodEnd: Date
    public let remainingSeconds: TimeInterval
    public let progress: Double

    public init(
        code: String,
        formattedCode: String,
        nextCode: String?,
        formattedNextCode: String?,
        periodStart: Date,
        periodEnd: Date,
        remainingSeconds: TimeInterval,
        progress: Double
    ) {
        self.code = code
        self.formattedCode = formattedCode
        self.nextCode = nextCode
        self.formattedNextCode = formattedNextCode
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.remainingSeconds = remainingSeconds
        self.progress = progress
    }
}

public enum OTPGenerator {
    public static func generateHOTP(
        secret: Data,
        counter: UInt64,
        digits: Int = 6,
        algorithm: OTPAlgorithm = .sha1
    ) -> String {
        let normalizedDigits = (4...10).contains(digits) ? digits : 6
        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: MemoryLayout<UInt64>.size)

        let hmacBytes = computeHMAC(secret: secret, message: counterData, algorithm: algorithm)
        guard let lastByte = hmacBytes.last else {
            return String(repeating: "0", count: normalizedDigits)
        }

        let offset = Int(lastByte & 0x0F)
        guard offset + 3 < hmacBytes.count else {
            return String(repeating: "0", count: normalizedDigits)
        }

        let truncated =
            (UInt32(hmacBytes[offset] & 0x7F) << 24)
            | (UInt32(hmacBytes[offset + 1]) << 16)
            | (UInt32(hmacBytes[offset + 2]) << 8)
            | UInt32(hmacBytes[offset + 3])

        let modulus = pow10(normalizedDigits)
        let otp = truncated % modulus
        return String(format: "%0\(normalizedDigits)u", otp)
    }

    public static func generateTOTP(
        secret: Data,
        date: Date = Date(),
        period: Int = 30,
        digits: Int = 6,
        algorithm: OTPAlgorithm = .sha1
    ) -> String {
        let safePeriod = period > 0 ? period : 30
        let seconds = max(0, Int64(floor(date.timeIntervalSince1970)))
        let counter = UInt64(seconds / Int64(safePeriod))
        return generateHOTP(secret: secret, counter: counter, digits: digits, algorithm: algorithm)
    }

    public static func snapshot(for account: OTPAccount, at date: Date = Date()) -> OTPCodeSnapshot {
        let normalizedDigits = (4...10).contains(account.digits) ? account.digits : 6
        switch account.type {
        case .hotp:
            let code = generateHOTP(
                secret: account.secret,
                counter: account.counter,
                digits: normalizedDigits,
                algorithm: account.algorithm
            )
            let next = generateHOTP(
                secret: account.secret,
                counter: account.counter &+ 1,
                digits: normalizedDigits,
                algorithm: account.algorithm
            )
            return OTPCodeSnapshot(
                code: code,
                formattedCode: formatCode(code),
                nextCode: next,
                formattedNextCode: formatCode(next),
                periodStart: date,
                periodEnd: date,
                remainingSeconds: 0,
                progress: 1
            )

        case .totp:
            let safePeriod = account.period > 0 ? account.period : 30
            let periodDouble = TimeInterval(safePeriod)
            let timestamp = max(0, date.timeIntervalSince1970)
            let step = floor(timestamp / periodDouble)
            let startTimestamp = step * periodDouble
            let endTimestamp = startTimestamp + periodDouble
            let remaining = max(0, endTimestamp - timestamp)
            let progress = min(1, max(0, remaining / periodDouble))

            let counter = UInt64(step)
            let code = generateHOTP(
                secret: account.secret,
                counter: counter,
                digits: normalizedDigits,
                algorithm: account.algorithm
            )
            let nextCode = generateHOTP(
                secret: account.secret,
                counter: counter &+ 1,
                digits: normalizedDigits,
                algorithm: account.algorithm
            )

            return OTPCodeSnapshot(
                code: code,
                formattedCode: formatCode(code),
                nextCode: nextCode,
                formattedNextCode: formatCode(nextCode),
                periodStart: Date(timeIntervalSince1970: startTimestamp),
                periodEnd: Date(timeIntervalSince1970: endTimestamp),
                remainingSeconds: remaining,
                progress: progress
            )
        }
    }

    public static func formatCode(_ code: String) -> String {
        switch code.count {
        case 6:
            return "\(code.prefix(3)) \(code.suffix(3))"
        case 8:
            return "\(code.prefix(4)) \(code.suffix(4))"
        default:
            return code
        }
    }

    private static func computeHMAC(secret: Data, message: Data, algorithm: OTPAlgorithm) -> [UInt8] {
        let key = SymmetricKey(data: secret)
        switch algorithm {
        case .sha1:
            return Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            return Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            return Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        case .md5:
            return Array(HMAC<Insecure.MD5>.authenticationCode(for: message, using: key))
        }
    }

    private static func pow10(_ exponent: Int) -> UInt32 {
        var result: UInt32 = 1
        for _ in 0..<exponent {
            result &*= 10
        }
        return result
    }
}
