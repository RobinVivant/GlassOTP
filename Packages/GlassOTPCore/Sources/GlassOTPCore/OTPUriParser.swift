import Foundation

public enum OTPUriError: Error, LocalizedError, Equatable, Sendable {
    case invalidURI
    case unsupportedScheme(String)
    case unsupportedOTPType(String)
    case missingSecret
    case invalidBase32Secret
    case invalidMigrationPayload
    case unsupportedAlgorithm(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURI:
            "That doesn't look like a valid otpauth:// URL."
        case .unsupportedScheme(let scheme):
            "Unsupported URI scheme: \(scheme)."
        case .unsupportedOTPType(let type):
            "Unsupported OTP type: \(type)."
        case .missingSecret:
            "The OTP URI does not include a secret key."
        case .invalidBase32Secret:
            "The secret key is not valid Base32."
        case .invalidMigrationPayload:
            "Unable to decode Google Authenticator migration payload."
        case .unsupportedAlgorithm(let algorithm):
            "Unsupported OTP algorithm: \(algorithm). Use SHA1, SHA256, or SHA512."
        }
    }
}

public enum OTPUriParser {
    public static func parse(_ rawString: String) throws -> [OTPAccount] {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw OTPUriError.invalidURI
        }

        switch scheme {
        case "otpauth":
            return [try parseOTPAuthURL(url)]
        case "otpauth-migration":
            return try parseGoogleMigrationURL(url)
        default:
            throw OTPUriError.unsupportedScheme(scheme)
        }
    }

    public static func parseOTPAuthURL(_ url: URL) throws -> OTPAccount {
        guard let scheme = url.scheme?.lowercased(), scheme == "otpauth" else {
            throw OTPUriError.invalidURI
        }
        guard let host = url.host?.lowercased() else {
            throw OTPUriError.invalidURI
        }

        let otpType: OTPType
        switch host {
        case "totp":
            otpType = .totp
        case "hotp":
            otpType = .hotp
        default:
            throw OTPUriError.unsupportedOTPType(host)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var decodedPath = components?.path ?? url.path
        if decodedPath.hasPrefix("/") {
            decodedPath.removeFirst()
        }

        var pathIssuer = ""
        var label = decodedPath
        if let colonIndex = decodedPath.firstIndex(of: ":") {
            pathIssuer = String(decodedPath[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            label = String(decodedPath[decodedPath.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var queryMap: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                queryMap[item.name.lowercased()] = value
            }
        }

        guard let secretString = queryMap["secret"], !secretString.isEmpty else {
            throw OTPUriError.missingSecret
        }
        let secretData: Data
        do {
            secretData = try Base32.decode(secretString)
        } catch {
            throw OTPUriError.invalidBase32Secret
        }
        guard !secretData.isEmpty else {
            throw OTPUriError.invalidBase32Secret
        }

        let queryIssuer = queryMap["issuer"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let issuer = (queryIssuer?.isEmpty == false ? queryIssuer : nil) ?? pathIssuer

        let algorithm: OTPAlgorithm
        switch queryMap["algorithm"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sha256":
            algorithm = .sha256
        case "sha512":
            algorithm = .sha512
        case "md5":
            throw OTPUriError.unsupportedAlgorithm("MD5")
        case "sha1", "", nil:
            algorithm = .sha1
        case let other?:
            throw OTPUriError.unsupportedAlgorithm(other.uppercased())
        }

        let digits = Int(queryMap["digits"] ?? "") ?? 6
        let period = Int(queryMap["period"] ?? "") ?? 30
        let counter = UInt64(queryMap["counter"] ?? "") ?? 0

        return OTPAccount(
            issuer: issuer,
            label: label,
            secret: secretData,
            type: otpType,
            algorithm: algorithm,
            digits: digits,
            period: period,
            counter: counter
        )
    }

    public static func toURI(_ account: OTPAccount) -> String {
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = account.type.rawValue

        let escapedLabel: String
        if account.issuer.isEmpty {
            escapedLabel = account.label
        } else if account.label.isEmpty {
            escapedLabel = account.issuer
        } else {
            escapedLabel = "\(account.issuer):\(account.label)"
        }
        components.path = "/" + escapedLabel

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "secret", value: Base32.encode(account.secret, padded: false)),
        ]
        if !account.issuer.isEmpty {
            queryItems.append(URLQueryItem(name: "issuer", value: account.issuer))
        }
        queryItems.append(URLQueryItem(name: "algorithm", value: account.algorithm.rawValue.uppercased()))
        queryItems.append(URLQueryItem(name: "digits", value: String(account.digits)))
        if account.type == .totp {
            queryItems.append(URLQueryItem(name: "period", value: String(account.period)))
        } else {
            queryItems.append(URLQueryItem(name: "counter", value: String(account.counter)))
        }
        components.queryItems = queryItems
        return components.string ?? ""
    }

    public static func parseGoogleMigrationURL(_ url: URL) throws -> [OTPAccount] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw OTPUriError.invalidMigrationPayload
        }

        let normalizedBase64 = dataParam
            .replacingOccurrences(of: " ", with: "+")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddedBase64: String
        let rem = normalizedBase64.count % 4
        if rem == 0 {
            paddedBase64 = normalizedBase64
        } else {
            paddedBase64 = normalizedBase64 + String(repeating: "=", count: 4 - rem)
        }

        guard let payload = Data(base64Encoded: paddedBase64), !payload.isEmpty else {
            throw OTPUriError.invalidMigrationPayload
        }

        return try decodeMigrationPayload(payload)
    }

    private static func decodeMigrationPayload(_ data: Data) throws -> [OTPAccount] {
        var reader = ProtobufReader(data: data)
        var accounts: [OTPAccount] = []

        while !reader.isAtEnd {
            let (fieldNumber, wireType) = try reader.readTag()
            if fieldNumber == 1 && wireType == 2 {
                let entryData = try reader.readLengthDelimited()
                if let account = try decodeOtpParameters(entryData) {
                    accounts.append(account)
                }
            } else {
                try reader.skipField(wireType: wireType)
            }
        }

        if accounts.isEmpty {
            throw OTPUriError.invalidMigrationPayload
        }
        return accounts
    }

    private static func decodeOtpParameters(_ data: Data) throws -> OTPAccount? {
        var reader = ProtobufReader(data: data)
        var secret = Data()
        var name = ""
        var issuer = ""
        var algorithm: OTPAlgorithm = .sha1
        var digits = 6
        var type: OTPType = .totp
        var counter: UInt64 = 0

        while !reader.isAtEnd {
            let (fieldNumber, wireType) = try reader.readTag()
            switch (fieldNumber, wireType) {
            case (1, 2):
                secret = try reader.readLengthDelimited()
            case (2, 2):
                let strData = try reader.readLengthDelimited()
                name = String(data: strData, encoding: .utf8) ?? ""
            case (3, 2):
                let strData = try reader.readLengthDelimited()
                issuer = String(data: strData, encoding: .utf8) ?? ""
            case (4, 0):
                let val = try reader.readVarint()
                switch val {
                case 0, 1: algorithm = .sha1
                case 2: algorithm = .sha256
                case 3: algorithm = .sha512
                case 4: throw OTPUriError.unsupportedAlgorithm("MD5")
                default: throw OTPUriError.unsupportedAlgorithm("enum(\(val))")
                }
            case (5, 0):
                let val = try reader.readVarint()
                digits = (val == 2) ? 8 : 6
            case (6, 0):
                let val = try reader.readVarint()
                type = (val == 1) ? .hotp : .totp
            case (7, 0):
                counter = try reader.readVarint()
            default:
                try reader.skipField(wireType: wireType)
            }
        }

        guard !secret.isEmpty else { return nil }

        var resolvedIssuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedLabel = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedIssuer.isEmpty, let colonIndex = resolvedLabel.firstIndex(of: ":") {
            resolvedIssuer = String(resolvedLabel[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedLabel = String(resolvedLabel[resolvedLabel.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return OTPAccount(
            issuer: resolvedIssuer,
            label: resolvedLabel,
            secret: secret,
            type: type,
            algorithm: algorithm,
            digits: digits,
            period: 30,
            counter: counter
        )
    }
}

private struct ProtobufReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    var isAtEnd: Bool {
        offset >= bytes.count
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw OTPUriError.invalidMigrationPayload
            }
        }
        throw OTPUriError.invalidMigrationPayload
    }

    mutating func readTag() throws -> (fieldNumber: Int, wireType: Int) {
        let tag = try readVarint()
        guard let fieldNumber = Int(exactly: tag >> 3) else {
            throw OTPUriError.invalidMigrationPayload
        }
        return (fieldNumber, Int(tag & 0x07))
    }

    mutating func readLengthDelimited() throws -> Data {
        let rawLength = try readVarint()
        guard let length = Int(exactly: rawLength),
              length >= 0,
              length <= bytes.count - offset else {
            throw OTPUriError.invalidMigrationPayload
        }
        let slice = Data(bytes[offset..<(offset + length)])
        offset += length
        return slice
    }

    mutating func skipField(wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            guard bytes.count - offset >= 8 else { throw OTPUriError.invalidMigrationPayload }
            offset += 8
        case 2:
            _ = try readLengthDelimited()
        case 5:
            guard bytes.count - offset >= 4 else { throw OTPUriError.invalidMigrationPayload }
            offset += 4
        default:
            throw OTPUriError.invalidMigrationPayload
        }
    }
}
