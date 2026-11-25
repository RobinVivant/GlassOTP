import Foundation

public struct OTPAuthImportResult: Sendable {
    public let formatDescription: String
    public let folders: [OTPFolder]
    public let accounts: [OTPAccount]
    public let skippedEntries: Int

    public init(
        formatDescription: String,
        folders: [OTPFolder],
        accounts: [OTPAccount],
        skippedEntries: Int = 0
    ) {
        self.formatDescription = formatDescription
        self.folders = folders
        self.accounts = accounts
        self.skippedEntries = skippedEntries
    }
}

public enum OTPAuthImporter {
    private enum OuterFormat {
        case backupDatabase
        case singleAccount

        var keyPhrase: String {
            switch self {
            case .backupDatabase: "Authenticator"
            case .singleAccount: "OTPAuth"
            }
        }
    }

    public static func importFile(
        data: Data,
        password: String,
        filenameHint: String? = nil
    ) throws -> OTPAuthImportResult {
        guard data.count <= VaultImporter.maxImportFileBytes else {
            throw OTPImportError.corruptedArchive("Import files are limited to 20 MB.")
        }
        guard let (format, outer) = unwrapOuterArchive(data: data, filenameHint: filenameHint) else {
            throw OTPImportError.invalidFileFormat
        }

        switch format {
        case .backupDatabase:
            return try decodeBackupDatabase(outer: outer, password: password)
        case .singleAccount:
            return try decodeSingleAccount(outer: outer, password: password)
        }
    }

    internal static func detectOuterFormat(data: Data, filenameHint: String? = nil) -> String? {
        guard let (format, _) = unwrapOuterArchive(data: data, filenameHint: filenameHint) else {
            return nil
        }
        switch format {
        case .backupDatabase:
            return "OTP Auth Encrypted Backup"
        case .singleAccount:
            return "OTP Auth Encrypted Account"
        }
    }

    private static func unwrapOuterArchive(
        data: Data,
        filenameHint: String?
    ) -> (OuterFormat, [String: Any])? {
        guard !data.isEmpty, data.count % 16 == 0 else {
            return nil
        }

        let preferSingle = filenameHint?.lowercased().hasSuffix(".otpauth") == true
        let candidateFormats: [OuterFormat] = preferSingle
            ? [.singleAccount, .backupDatabase]
            : [.backupDatabase, .singleAccount]

        for format in candidateFormats {
            let outerKey = CryptoPrimitives.sha256(Data(format.keyPhrase.utf8))
            let zeroIV = Data(repeating: 0, count: 16)
            guard let outerDecrypted = try? CryptoPrimitives.aes256CBCDecrypt(
                ciphertext: data,
                key: outerKey,
                iv: zeroIV
            ),
                  let rootDict = try? KeyedArchiveParser.parseRoot(from: outerDecrypted) as? [String: Any],
                  rootDict["Version"] != nil else {
                continue
            }
            return (format, rootDict)
        }

        return nil
    }

    private static func decodeBackupDatabase(outer: [String: Any], password: String) throws -> OTPAuthImportResult {
        let version = numberValue(outer["Version"]) ?? 0
        guard let wrappedData = outer["WrappedData"] as? Data else {
            throw OTPImportError.corruptedArchive("Missing WrappedData in backup archive.")
        }

        let innerData: Data
        if version == 1.0 {
            guard let salt = outer["Salt"] as? String,
                  let ivData = extractIVBytes(outer["IV"]) else {
                throw OTPImportError.corruptedArchive("Missing v1.0 Salt or IV.")
            }
            let iv = CryptoPrimitives.sha1(ivData).prefix(16)
            let key = CryptoPrimitives.sha256(Data("\(salt)-\(password)".utf8))
            innerData = try CryptoPrimitives.aes256CBCDecrypt(
                ciphertext: wrappedData,
                key: key,
                iv: Data(iv)
            )
        } else if version >= 1.1 {
            innerData = try CryptoPrimitives.rncryptorV3Decrypt(data: wrappedData, password: password)
        } else {
            throw OTPImportError.unsupportedVersion(version)
        }

        guard startsWithBinaryPlistHeader(innerData),
              let innerRoot = (try? KeyedArchiveParser.parseRoot(from: innerData)) as? [String: Any] else {
            throw OTPImportError.wrongPassword
        }

        let rawFolders = innerRoot["Folders"] as? [[String: Any]] ?? []
        var importedFolders: [OTPFolder] = []
        var importedAccounts: [OTPAccount] = []
        var skippedEntries = 0

        for (folderIdx, rawFolder) in rawFolders.enumerated() {
            let folderName = (rawFolder["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedFolderName = (folderName?.isEmpty == false) ? folderName! : "Accounts"
            let folder = OTPFolder(
                name: resolvedFolderName,
                symbolName: symbolForFolder(name: resolvedFolderName),
                sortOrder: folderIdx
            )
            importedFolders.append(folder)

            let rawAccounts = rawFolder["accounts"] as? [[String: Any]] ?? []
            for (accountIdx, rawAccount) in rawAccounts.enumerated() {
                if let account = parseAccountDict(
                    rawAccount,
                    folderID: folder.id,
                    sortOrder: accountIdx
                ) {
                    importedAccounts.append(account)
                } else {
                    skippedEntries += 1
                }
            }
        }

        return OTPAuthImportResult(
            formatDescription: "OTP Auth Backup v\(formatVersionString(version))",
            folders: importedFolders,
            accounts: importedAccounts,
            skippedEntries: skippedEntries
        )
    }

    private static func decodeSingleAccount(outer: [String: Any], password: String) throws -> OTPAuthImportResult {
        let version = numberValue(outer["Version"]) ?? 0
        guard let payloadData = outer["Data"] as? Data else {
            throw OTPImportError.corruptedArchive("Missing Data in account archive.")
        }

        let innerData: Data
        if version == 1.1 {
            guard let salt = outer["Salt"] as? String,
                  let ivData = extractIVBytes(outer["IV"]) else {
                throw OTPImportError.corruptedArchive("Missing v1.1 Salt or IV.")
            }
            let iv = CryptoPrimitives.sha1(ivData).prefix(16)
            let key = CryptoPrimitives.sha256(Data("\(salt)-\(password)".utf8))
            innerData = try CryptoPrimitives.aes256CBCDecrypt(
                ciphertext: payloadData,
                key: key,
                iv: Data(iv)
            )
        } else if version >= 1.2 {
            innerData = try CryptoPrimitives.rncryptorV3Decrypt(data: payloadData, password: password)
        } else {
            throw OTPImportError.unsupportedVersion(version)
        }

        guard startsWithBinaryPlistHeader(innerData),
              let innerRoot = (try? KeyedArchiveParser.parseRoot(from: innerData)) as? [String: Any] else {
            throw OTPImportError.wrongPassword
        }
        guard let account = parseAccountDict(innerRoot, folderID: nil, sortOrder: 0) else {
            throw OTPImportError.corruptedArchive("This OTP Auth account uses an unsupported algorithm or empty secret.")
        }

        return OTPAuthImportResult(
            formatDescription: "OTP Auth Account v\(formatVersionString(version))",
            folders: [],
            accounts: [account]
        )
    }

    private static func parseAccountDict(
        _ dict: [String: Any],
        folderID: UUID?,
        sortOrder: Int
    ) -> OTPAccount? {
        guard let secret = dict["secret"] as? Data, !secret.isEmpty else {
            return nil
        }

        let label = (dict["label"] as? String) ?? ""
        let issuer = (dict["issuer"] as? String) ?? ""

        let rawType = intValue(dict["type"]) ?? 2
        let type: OTPType = (rawType == 1) ? .hotp : .totp

        let rawAlgo = intValue(dict["algorithm"]) ?? 1
        let algorithm: OTPAlgorithm
        switch rawAlgo {
        case 0, 1: algorithm = .sha1
        case 2: algorithm = .sha256
        case 3: algorithm = .sha512
        default: return nil
        }

        let rawDigits = intValue(dict["digits"]) ?? 0
        let digits = rawDigits > 0 ? rawDigits : 6

        let rawPeriod = intValue(dict["period"]) ?? 0
        let period = rawPeriod > 0 ? rawPeriod : 30

        let rawCounter = intValue(dict["counter"]) ?? 0
        let counter = rawCounter >= 0 ? UInt64(rawCounter) : 0

        let hideInWidget = (dict["hideInWidget"] as? Bool) ?? true
        let widgetIndex = intValue(dict["widgetIndex"]) ?? -1
        let isPinned = !hideInWidget && widgetIndex >= 0 && widgetIndex < 4

        return OTPAccount(
            issuer: issuer,
            label: label,
            secret: secret,
            type: type,
            algorithm: algorithm,
            digits: digits,
            period: period,
            counter: counter,
            folderID: folderID,
            isPinned: isPinned,
            sortOrder: sortOrder
        )
    }

    private static func startsWithBinaryPlistHeader(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        return data.prefix(6) == Data("bplist".utf8)
    }

    private static func extractIVBytes(_ value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let str = value as? String { return Data(str.utf8) }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let dbl = value as? Double { return dbl }
        if let num = value as? NSNumber { return num.doubleValue }
        if let intVal = value as? Int { return Double(intVal) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let num = value as? NSNumber { return num.intValue }
        return nil
    }

    private static func formatVersionString(_ version: Double) -> String {
        String(format: "%.1f", version)
    }

    private static func symbolForFolder(name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("work") || lower.contains("corp") || lower.contains("office") {
            return "briefcase.fill"
        }
        if lower.contains("bank") || lower.contains("finance") || lower.contains("crypto") {
            return "building.columns.fill"
        }
        if lower.contains("dev") || lower.contains("cloud") || lower.contains("infra") {
            return "server.rack"
        }
        if lower.contains("personal") || lower.contains("home") {
            return "house.fill"
        }
        return "folder.fill"
    }
}
