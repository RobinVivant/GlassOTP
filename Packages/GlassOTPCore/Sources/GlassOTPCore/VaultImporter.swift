import Foundation

public typealias VaultImportResult = OTPAuthImportResult

public enum VaultImportInspection: Sendable, Equatable {
    case encrypted(formatHint: String)
    case plaintext(formatHint: String)
    case unsupportedEncrypted(formatName: String, guidance: String)
    case unrecognized
}

public enum VaultImporter {
    private enum DetectedKind {
        case glassOTP
        case authProV2
        case authProLegacy
        case aegisEncrypted
        case aegisPlaintext
        case twoFASEncrypted
        case twoFASPlaintext
        case bitwardenEncrypted
        case bitwardenPlaintext
        case authenticatorProJSON
        case freeOTPPlusJSON
        case protonAuthenticatorJSON
        case raivoJSON
        case andOTPJSON
        case otpAuthEncrypted(String)
        case uriList
        case csv(String)
    }

    public static func inspect(data: Data, filenameHint: String? = nil) -> VaultImportInspection {
        guard let kind = detect(data: data, filenameHint: filenameHint) else {
            return .unrecognized
        }

        switch kind {
        case .glassOTP:
            return .encrypted(formatHint: "GlassOTP Encrypted Backup")
        case .authProV2:
            return .unsupportedEncrypted(
                formatName: "Authenticator Pro / Stratum v2",
                guidance: "Argon2id-encrypted .authpro backups aren't supported yet. Export an unencrypted JSON or URI list from Stratum / Authenticator Pro and import that file."
            )
        case .authProLegacy:
            return .encrypted(formatHint: "Authenticator Pro Encrypted Backup")
        case .aegisEncrypted:
            return .encrypted(formatHint: "Aegis Encrypted Vault")
        case .aegisPlaintext:
            return .plaintext(formatHint: "Aegis Vault")
        case .twoFASEncrypted:
            return .encrypted(formatHint: "2FAS Encrypted Backup")
        case .twoFASPlaintext:
            return .plaintext(formatHint: "2FAS Backup")
        case .bitwardenEncrypted:
            return .unsupportedEncrypted(
                formatName: "Bitwarden Encrypted Export",
                guidance: "Encrypted Bitwarden JSON exports aren't supported. Export as unencrypted JSON or CSV from Bitwarden, import it here, then delete the export file."
            )
        case .bitwardenPlaintext:
            return .plaintext(formatHint: "Bitwarden JSON")
        case .authenticatorProJSON:
            return .plaintext(formatHint: "Authenticator Pro / Stratum")
        case .freeOTPPlusJSON:
            return .plaintext(formatHint: "FreeOTP+ Backup")
        case .protonAuthenticatorJSON:
            return .plaintext(formatHint: "Proton Authenticator")
        case .raivoJSON:
            return .plaintext(formatHint: "Raivo OTP Export")
        case .andOTPJSON:
            return .plaintext(formatHint: "andOTP Export")
        case .otpAuthEncrypted(let label):
            return .encrypted(formatHint: label)
        case .uriList:
            return .plaintext(formatHint: "OTP URI List")
        case .csv(let label):
            return .plaintext(formatHint: label)
        }
    }

    public static func importFile(
        data: Data,
        password: String? = nil,
        filenameHint: String? = nil
    ) throws -> OTPAuthImportResult {
        guard let kind = detect(data: data, filenameHint: filenameHint) else {
            throw OTPImportError.invalidFileFormat
        }

        switch kind {
        case .glassOTP:
            let pwd = try requirePassword(password, format: "GlassOTP Encrypted Backup")
            let snapshot = try GlassOTPBackupCodec.decode(data: data, password: pwd)
            return OTPAuthImportResult(
                formatDescription: "GlassOTP Encrypted Backup",
                folders: snapshot.folders,
                accounts: snapshot.accounts
            )

        case .authProV2:
            throw OTPImportError.unsupportedEncryptedFormat(
                "Argon2id-encrypted .authpro backups aren't supported yet. Export an unencrypted JSON or URI list from Stratum / Authenticator Pro and import that file."
            )

        case .authProLegacy:
            let pwd = try requirePassword(password, format: "Authenticator Pro Encrypted Backup")
            return try decodeLegacyAuthPro(data: data, password: pwd)

        case .aegisEncrypted:
            let pwd = try requirePassword(password, format: "Aegis Encrypted Vault")
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decodeAegisEncrypted(root: rootDict ?? [:], password: pwd)

        case .aegisPlaintext:
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decodeAegisPlaintext(root: rootDict ?? [:])

        case .twoFASEncrypted:
            let pwd = try requirePassword(password, format: "2FAS Encrypted Backup")
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decode2FASEncrypted(root: rootDict ?? [:], password: pwd)

        case .twoFASPlaintext:
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decode2FASPlaintext(root: rootDict ?? [:])

        case .bitwardenEncrypted:
            throw OTPImportError.unsupportedEncryptedFormat(
                "Encrypted Bitwarden JSON exports aren't supported. Export as unencrypted JSON or CSV from Bitwarden, import it here, then delete the export file."
            )

        case .bitwardenPlaintext:
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decodeBitwarden(root: rootDict ?? [:])

        case .authenticatorProJSON:
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decodeAuthenticatorProJSON(root: rootDict ?? [:])

        case .freeOTPPlusJSON:
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decodeFreeOTPPlus(root: rootDict ?? [:])

        case .protonAuthenticatorJSON:
            let rootDict = try parseJSONObject(data) as? [String: Any]
            return try decodeProtonAuthenticator(root: rootDict ?? [:])

        case .raivoJSON:
            let items = try parseJSONObject(data) as? [[String: Any]] ?? []
            return try decodeRaivoJSON(items: items)

        case .andOTPJSON:
            let items = try parseJSONObject(data) as? [[String: Any]] ?? []
            return try decodeAndOTPJSON(items: items)

        case .otpAuthEncrypted(let label):
            let pwd = try requirePassword(password, format: label)
            return try OTPAuthImporter.importFile(data: data, password: pwd, filenameHint: filenameHint)

        case .uriList:
            guard let text = utf8StringStrippingBOM(from: data) else {
                throw OTPImportError.invalidFileFormat
            }
            return try decodeURIList(text: text)

        case .csv(let label):
            guard let text = utf8StringStrippingBOM(from: data) else {
                throw OTPImportError.invalidFileFormat
            }
            return try decodeCSV(text: text, label: label)
        }
    }

    private static func requirePassword(_ password: String?, format: String) throws -> String {
        guard let password, !password.isEmpty else {
            throw OTPImportError.passwordRequired(format)
        }
        return password
    }

    // MARK: - Format Detection

    private static func detect(data: Data, filenameHint: String?) -> DetectedKind? {
        if data.isEmpty {
            return nil
        }

        if GlassOTPBackupCodec.isGlassOTPBackup(data) {
            return .glassOTP
        }

        if data.starts(with: Data("AuthenticatorPro".utf8)) && data.count >= 16 + 20 + 16 + 16 {
            return .authProLegacy
        }

        if data.starts(with: Data("AUTHPRO".utf8)) {
            return .authProV2
        }

        if let jsonObj = try? parseJSONObject(data) {
            if let dict = jsonObj as? [String: Any] {
                if dict["header"] is [String: Any], let db = dict["db"] {
                    if db is String {
                        return .aegisEncrypted
                    }
                    if db is [String: Any] {
                        return .aegisPlaintext
                    }
                }

                if let encryptedPayload = dict["servicesEncrypted"] as? String,
                   !encryptedPayload.isEmpty,
                   (dict["services"] as? [[String: Any]])?.isEmpty ?? true {
                    return .twoFASEncrypted
                }

                if let services = dict["services"] as? [[String: Any]] {
                    if dict["schemaVersion"] != nil
                        || services.contains(where: { $0["otp"] != nil || $0["secret"] != nil }) {
                        return .twoFASPlaintext
                    }
                }

                if dict["items"] is [[String: Any]]
                    || ((dict["encrypted"] as? Bool) == true && (dict["encKeyValidation_DO_NOT_EDIT"] != nil || dict["items"] != nil)) {
                    if (dict["encrypted"] as? Bool) == true {
                        return .bitwardenEncrypted
                    }
                    return .bitwardenPlaintext
                }

                if dict["Authenticators"] is [[String: Any]] {
                    return .authenticatorProJSON
                }

                if dict["tokens"] is [[String: Any]] {
                    return .freeOTPPlusJSON
                }

                if let entries = dict["entries"] as? [[String: Any]],
                   entries.contains(where: { ($0["content"] as? [String: Any])?["uri"] != nil }) {
                    return .protonAuthenticatorJSON
                }
            } else if let array = jsonObj as? [[String: Any]] {
                let looksLikeRaivo = array.contains { item in
                    item["secret"] != nil && (item["kind"] != nil || item["timer"] != nil || item["account"] != nil)
                }
                if looksLikeRaivo {
                    return .raivoJSON
                }

                let looksLikeAndOTP = array.contains { item in
                    item["secret"] != nil && (item["type"] != nil || item["label"] != nil || item["period"] != nil || item["tags"] != nil)
                }
                if looksLikeAndOTP {
                    return .andOTPJSON
                }
            }
        }

        if let otpAuthFormat = OTPAuthImporter.detectOuterFormat(data: data, filenameHint: filenameHint) {
            return .otpAuthEncrypted(otpAuthFormat)
        }

        if let text = utf8StringStrippingBOM(from: data) {
            if containsOTPURI(in: text) {
                return .uriList
            }

            if let csvFormat = detectCSVFormat(in: text) {
                return .csv(csvFormat)
            }
        }

        return nil
    }

    // MARK: - Aegis Authenticator

    private static func decodeAegisEncrypted(root: [String: Any], password: String) throws -> OTPAuthImportResult {
        guard let header = root["header"] as? [String: Any],
              let slots = header["slots"] as? [[String: Any]],
              let params = header["params"] as? [String: Any],
              let dbNonceHex = params["nonce"] as? String,
              let dbTagHex = params["tag"] as? String,
              let dbNonce = CryptoPrimitives.hexDecode(dbNonceHex),
              let dbTag = CryptoPrimitives.hexDecode(dbTagHex),
              let dbBase64 = root["db"] as? String,
              let dbCiphertext = Data(base64Encoded: dbBase64, options: .ignoreUnknownCharacters),
              !dbCiphertext.isEmpty else {
            throw OTPImportError.corruptedArchive("Invalid Aegis encrypted vault header.")
        }

        let passwordSlots = slots.filter { intValue($0["type"]) == 1 }
        guard !passwordSlots.isEmpty else {
            throw OTPImportError.unsupportedEncryptedFormat("This Aegis vault has no password slot configured.")
        }

        let passwordData = Data(password.utf8)
        var masterKey: Data?

        for slot in passwordSlots {
            guard let saltHex = slot["salt"] as? String,
                  let salt = CryptoPrimitives.hexDecode(saltHex),
                  let n = intValue(slot["n"]),
                  let r = intValue(slot["r"]),
                  let p = intValue(slot["p"]),
                  let encryptedKeyHex = slot["key"] as? String,
                  let encryptedKey = CryptoPrimitives.hexDecode(encryptedKeyHex),
                  let keyParams = slot["key_params"] as? [String: Any],
                  let keyNonceHex = keyParams["nonce"] as? String,
                  let keyTagHex = keyParams["tag"] as? String,
                  let keyNonce = CryptoPrimitives.hexDecode(keyNonceHex),
                  let keyTag = CryptoPrimitives.hexDecode(keyTagHex) else {
                continue
            }

            guard let derived = try? CryptoPrimitives.scrypt(
                password: passwordData,
                salt: salt,
                n: n,
                r: r,
                p: p,
                keyLength: 32
            ),
                  let unlockedKey = try? CryptoPrimitives.aes256GCMDecrypt(
                    ciphertext: encryptedKey,
                    nonce: keyNonce,
                    tag: keyTag,
                    key: derived
                  ) else {
                continue
            }

            masterKey = unlockedKey
            break
        }

        guard let masterKey else {
            throw OTPImportError.wrongPassword
        }

        let dbPlaintext = try CryptoPrimitives.aes256GCMDecrypt(
            ciphertext: dbCiphertext,
            nonce: dbNonce,
            tag: dbTag,
            key: masterKey
        )

        guard let dbDict = try? parseJSONObject(dbPlaintext) as? [String: Any] else {
            throw OTPImportError.corruptedArchive("Decrypted Aegis vault is not valid JSON.")
        }

        return try parseAegisDatabase(dbDict, formatDescription: "Aegis Encrypted Vault")
    }

    private static func decodeAegisPlaintext(root: [String: Any]) throws -> OTPAuthImportResult {
        guard let dbDict = root["db"] as? [String: Any] else {
            throw OTPImportError.corruptedArchive("Missing Aegis db object.")
        }
        return try parseAegisDatabase(dbDict, formatDescription: "Aegis Vault")
    }

    private static func parseAegisDatabase(
        _ db: [String: Any],
        formatDescription: String
    ) throws -> OTPAuthImportResult {
        var folderBuilder = FolderBuilder()

        var groupNameByUUID: [String: String] = [:]
        if let groups = db["groups"] as? [[String: Any]] {
            for group in groups {
                if let uuid = trimmedNonEmpty(group["uuid"] as? String),
                   let name = trimmedNonEmpty(group["name"] as? String) {
                    groupNameByUUID[uuid] = name
                }
            }
        }

        let entries = db["entries"] as? [[String: Any]] ?? []
        var importedAccounts: [OTPAccount] = []

        for entry in entries {
            let rawType = (entry["type"] as? String ?? "totp").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let otpType: OTPType
            switch rawType {
            case "totp":
                otpType = .totp
            case "hotp":
                otpType = .hotp
            default:
                continue // Ignore Steam / Yandex / mOTP entries safely
            }

            let info = entry["info"] as? [String: Any] ?? [:]
            guard let secretStr = trimmedNonEmpty(info["secret"] as? String),
                  let secret = decodeBase32Flexible(secretStr) else {
                continue
            }

            let issuer = trimmed(entry["issuer"] as? String) ?? ""
            let label = trimmed(entry["name"] as? String) ?? ""
            let algorithm = parseAlgorithm(info["algo"] as? String)
            let digits = intValue(info["digits"]) ?? 6
            let period = intValue(info["period"]) ?? 30
            let counter = uint64Value(info["counter"]) ?? 0
            let isPinned = (entry["favorite"] as? Bool) ?? false

            var folderID: UUID?
            if let groupUUIDs = entry["groups"] as? [String],
               let firstName = groupUUIDs.compactMap({ groupNameByUUID[$0] }).first {
                folderID = folderBuilder.folderID(named: firstName)
            } else if let groupName = trimmedNonEmpty(entry["group"] as? String) {
                folderID = folderBuilder.folderID(named: groupName)
            }

            let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(issuer: issuer, label: label)
            importedAccounts.append(
                OTPAccount(
                    issuer: resolvedIssuer,
                    label: resolvedLabel,
                    secret: secret,
                    type: otpType,
                    algorithm: algorithm,
                    digits: digits,
                    period: period,
                    counter: counter,
                    folderID: folderID,
                    isPinned: isPinned,
                    sortOrder: importedAccounts.count
                )
            )
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No TOTP/HOTP accounts were found in this Aegis vault.")
        }

        return OTPAuthImportResult(
            formatDescription: formatDescription,
            folders: folderBuilder.folders,
            accounts: importedAccounts
        )
    }

    // MARK: - 2FAS Authenticator

    private static func decode2FASEncrypted(root: [String: Any], password: String) throws -> OTPAuthImportResult {
        guard let encryptedStr = trimmedNonEmpty(root["servicesEncrypted"] as? String) else {
            throw OTPImportError.corruptedArchive("Missing 2FAS servicesEncrypted payload.")
        }
        let parts = encryptedStr.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let combined = Data(base64Encoded: String(parts[0]), options: .ignoreUnknownCharacters),
              let salt = Data(base64Encoded: String(parts[1]), options: .ignoreUnknownCharacters),
              let iv = Data(base64Encoded: String(parts[2]), options: .ignoreUnknownCharacters),
              combined.count >= 16 else {
            throw OTPImportError.corruptedArchive("Malformed 2FAS encrypted payload.")
        }

        let ciphertext = Data(combined.dropLast(16))
        let tag = Data(combined.suffix(16))
        let key = try CryptoPrimitives.pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            iterations: 10_000,
            keyLength: 32
        )

        let decryptedData = try CryptoPrimitives.aes256GCMDecrypt(
            ciphertext: ciphertext,
            nonce: iv,
            tag: tag,
            key: key
        )

        guard let services = (try? parseJSONObject(decryptedData)) as? [[String: Any]] else {
            throw OTPImportError.corruptedArchive("Decrypted 2FAS services payload is invalid.")
        }

        return try parse2FASServices(
            services: services,
            groups: root["groups"] as? [[String: Any]] ?? [],
            formatDescription: "2FAS Encrypted Backup"
        )
    }

    private static func decode2FASPlaintext(root: [String: Any]) throws -> OTPAuthImportResult {
        let services = root["services"] as? [[String: Any]] ?? []
        let groups = root["groups"] as? [[String: Any]] ?? []
        return try parse2FASServices(
            services: services,
            groups: groups,
            formatDescription: "2FAS Backup"
        )
    }

    private static func parse2FASServices(
        services: [[String: Any]],
        groups: [[String: Any]],
        formatDescription: String
    ) throws -> OTPAuthImportResult {
        var folderBuilder = FolderBuilder()
        var groupNameByID: [String: String] = [:]
        for group in groups {
            if let id = trimmedNonEmpty(group["id"] as? String),
               let name = trimmedNonEmpty(group["name"] as? String) {
                groupNameByID[id] = name
            }
        }

        var importedAccounts: [OTPAccount] = []
        for service in services {
            let otp = service["otp"] as? [String: Any] ?? [:]
            let rawTokenType = (otp["tokenType"] as? String ?? "TOTP").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let otpType: OTPType
            switch rawTokenType {
            case "HOTP":
                otpType = .hotp
            case "TOTP", "":
                otpType = .totp
            default:
                continue // Skip STEAM
            }

            let rawSecret = trimmedNonEmpty(service["secret"] as? String) ?? trimmedNonEmpty(otp["secret"] as? String)
            guard let secretStr = rawSecret,
                  let secret = decodeBase32Flexible(secretStr) else {
                continue
            }

            let tileName = trimmed(service["name"] as? String) ?? ""
            let otpIssuer = trimmed(otp["issuer"] as? String) ?? ""
            let rawAccount = trimmed(otp["account"] as? String)
                ?? trimmed(otp["label"] as? String)
                ?? ""

            let chosenIssuer = otpIssuer.isEmpty ? tileName : otpIssuer
            let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(issuer: chosenIssuer, label: rawAccount)
            let finalIssuer = resolvedIssuer.isEmpty ? tileName : resolvedIssuer

            let algorithm = parseAlgorithm(otp["algorithm"] as? String)
            let digits = intValue(otp["digits"]) ?? 6
            let period = intValue(otp["period"]) ?? 30
            let counter = uint64Value(otp["counter"]) ?? 0

            let folderID: UUID?
            if let groupID = trimmedNonEmpty(service["groupId"] as? String),
               let groupName = groupNameByID[groupID] {
                folderID = folderBuilder.folderID(named: groupName)
            } else {
                folderID = nil
            }

            let isPinned = (service["isFavourite"] as? Bool) ?? (service["favorite"] as? Bool) ?? false

            importedAccounts.append(
                OTPAccount(
                    issuer: finalIssuer,
                    label: resolvedLabel,
                    secret: secret,
                    type: otpType,
                    algorithm: algorithm,
                    digits: digits,
                    period: period,
                    counter: counter,
                    folderID: folderID,
                    isPinned: isPinned,
                    sortOrder: importedAccounts.count
                )
            )
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No TOTP/HOTP accounts were found in this 2FAS backup.")
        }

        return OTPAuthImportResult(
            formatDescription: formatDescription,
            folders: folderBuilder.folders,
            accounts: importedAccounts
        )
    }

    // MARK: - Bitwarden JSON

    private static func decodeBitwarden(root: [String: Any]) throws -> OTPAuthImportResult {
        var folderBuilder = FolderBuilder()
        var folderNamesByID: [String: String] = [:]
        if let rawFolders = root["folders"] as? [[String: Any]] {
            for folder in rawFolders {
                if let id = trimmedNonEmpty(folder["id"] as? String),
                   let name = trimmedNonEmpty(folder["name"] as? String) {
                    folderNamesByID[id] = name
                }
            }
        }

        let items = root["items"] as? [[String: Any]] ?? []
        var importedAccounts: [OTPAccount] = []

        for item in items {
            guard let login = item["login"] as? [String: Any],
                  let totpValue = trimmedNonEmpty(login["totp"] as? String) else {
                continue
            }

            let itemName = trimmed(item["name"] as? String) ?? ""
            let username = trimmed(login["username"] as? String) ?? ""
            let uris = (login["uris"] as? [[String: Any]]) ?? []
            let firstHost = uris.compactMap { ($0["uri"] as? String).flatMap(hostLabel(from:)) }.first ?? ""
            let fallbackIssuer = itemName.isEmpty ? firstHost : itemName

            let folderID = (item["folderId"] as? String).flatMap { folderNamesByID[$0] }.map {
                folderBuilder.folderID(named: $0)
            }
            let isPinned = (item["favorite"] as? Bool) ?? false

            guard var account = parseOTPField(
                totpValue,
                fallbackIssuer: fallbackIssuer,
                fallbackLabel: username
            ) else {
                continue
            }

            account.folderID = folderID
            account.isPinned = isPinned
            account.sortOrder = importedAccounts.count
            importedAccounts.append(account)
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No Bitwarden items with TOTP keys were found.")
        }

        return OTPAuthImportResult(
            formatDescription: "Bitwarden JSON",
            folders: folderBuilder.folders,
            accounts: importedAccounts
        )
    }

    // MARK: - Authenticator Pro / Stratum

    private static func decodeLegacyAuthPro(data: Data, password: String) throws -> OTPAuthImportResult {
        // Header: "AuthenticatorPro" (16 bytes) + salt (20 bytes) + IV (16 bytes) + ciphertext
        let headerLength = 16
        let saltLength = 20
        let ivLength = 16
        let payloadOffset = headerLength + saltLength + ivLength
        guard data.count > payloadOffset else {
            throw OTPImportError.corruptedArchive("Truncated Authenticator Pro backup.")
        }

        let salt = Data(data[headerLength..<(headerLength + saltLength)])
        let iv = Data(data[(headerLength + saltLength)..<payloadOffset])
        let ciphertext = Data(data[payloadOffset..<data.endIndex])

        let key = try CryptoPrimitives.pbkdf2SHA1(
            password: Data(password.utf8),
            salt: salt,
            iterations: 64_000,
            keyLength: 32
        )
        let decrypted = try CryptoPrimitives.aes256CBCDecrypt(ciphertext: ciphertext, key: key, iv: iv)
        guard let root = (try? parseJSONObject(decrypted)) as? [String: Any],
              root["Authenticators"] is [[String: Any]] else {
            throw OTPImportError.wrongPassword
        }

        var result = try decodeAuthenticatorProJSON(root: root)
        result = OTPAuthImportResult(
            formatDescription: "Authenticator Pro Encrypted Backup",
            folders: result.folders,
            accounts: result.accounts
        )
        return result
    }

    private static func decodeAuthenticatorProJSON(root: [String: Any]) throws -> OTPAuthImportResult {
        var folderBuilder = FolderBuilder()

        var categoryNameByID: [String: String] = [:]
        if let categories = root["Categories"] as? [[String: Any]] {
            for category in categories {
                if let id = trimmedNonEmpty(category["Id"] as? String),
                   let name = trimmedNonEmpty(category["Name"] as? String) {
                    categoryNameByID[id] = name
                }
            }
        }

        var categoryBySecret: [String: String] = [:]
        if let mappings = root["AuthenticatorCategories"] as? [[String: Any]] {
            for mapping in mappings {
                if let secret = trimmedNonEmpty(mapping["AuthenticatorSecret"] as? String),
                   let catID = trimmedNonEmpty(mapping["CategoryId"] as? String),
                   let name = categoryNameByID[catID],
                   categoryBySecret[secret] == nil {
                    categoryBySecret[secret] = name
                }
            }
        }

        let rawAuthenticators = root["Authenticators"] as? [[String: Any]] ?? []
        var importedAccounts: [OTPAccount] = []

        for entry in rawAuthenticators {
            let otpType: OTPType
            if let typeInt = intValue(entry["Type"]) {
                switch typeInt {
                case 1: otpType = .hotp
                case 2: otpType = .totp
                default: continue // Ignore mOTP / Steam / Yandex
                }
            } else if let typeStr = entry["Type"] as? String {
                switch typeStr.lowercased() {
                case "hotp": otpType = .hotp
                case "totp": otpType = .totp
                default: continue
                }
            } else {
                otpType = .totp
            }

            guard let secretStr = trimmedNonEmpty(entry["Secret"] as? String),
                  let secret = decodeBase32Flexible(secretStr) else {
                continue
            }

            let algorithm: OTPAlgorithm
            if let algoInt = intValue(entry["Algorithm"]) {
                switch algoInt {
                case 1: algorithm = .sha256
                case 2: algorithm = .sha512
                default: algorithm = .sha1
                }
            } else {
                algorithm = parseAlgorithm(entry["Algorithm"] as? String)
            }

            let issuer = trimmed(entry["Issuer"] as? String) ?? ""
            let label = trimmed(entry["Username"] as? String) ?? ""
            let digits = intValue(entry["Digits"]) ?? 6
            let period = intValue(entry["Period"]) ?? 30
            let counter = uint64Value(entry["Counter"]) ?? 0
            let folderID = categoryBySecret[secretStr].map { folderBuilder.folderID(named: $0) }

            let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(issuer: issuer, label: label)
            importedAccounts.append(
                OTPAccount(
                    issuer: resolvedIssuer,
                    label: resolvedLabel,
                    secret: secret,
                    type: otpType,
                    algorithm: algorithm,
                    digits: digits,
                    period: period,
                    counter: counter,
                    folderID: folderID,
                    sortOrder: importedAccounts.count
                )
            )
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No TOTP/HOTP accounts were found in this Authenticator Pro backup.")
        }

        return OTPAuthImportResult(
            formatDescription: "Authenticator Pro / Stratum",
            folders: folderBuilder.folders,
            accounts: importedAccounts
        )
    }

    // MARK: - FreeOTP+ JSON

    private static func decodeFreeOTPPlus(root: [String: Any]) throws -> OTPAuthImportResult {
        let tokens = root["tokens"] as? [[String: Any]] ?? []
        var importedAccounts: [OTPAccount] = []

        for token in tokens {
            let rawType = (token["type"] as? String ?? "TOTP").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let otpType: OTPType
            switch rawType {
            case "HOTP": otpType = .hotp
            case "TOTP": otpType = .totp
            default: continue
            }

            let secret: Data?
            if let secretStr = trimmedNonEmpty(token["secret"] as? String) {
                secret = decodeBase32Flexible(secretStr)
            } else if let byteInts = token["secret"] as? [Int] {
                secret = Data(byteInts.map { UInt8(bitPattern: Int8(clamping: $0)) })
            } else if let numbers = token["secret"] as? [NSNumber] {
                secret = Data(numbers.map { UInt8(bitPattern: Int8(clamping: $0.intValue)) })
            } else {
                secret = nil
            }

            guard let secret, !secret.isEmpty else {
                continue
            }

            let issuerExt = trimmed(token["issuerExt"] as? String) ?? ""
            let issuerInt = trimmed(token["issuerInt"] as? String) ?? ""
            let issuer = issuerExt.isEmpty ? issuerInt : issuerExt
            let label = trimmed(token["label"] as? String) ?? ""
            let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(issuer: issuer, label: label)

            importedAccounts.append(
                OTPAccount(
                    issuer: resolvedIssuer,
                    label: resolvedLabel,
                    secret: secret,
                    type: otpType,
                    algorithm: parseAlgorithm(token["algo"] as? String),
                    digits: intValue(token["digits"]) ?? 6,
                    period: intValue(token["period"]) ?? 30,
                    counter: uint64Value(token["counter"]) ?? 0,
                    sortOrder: importedAccounts.count
                )
            )
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No TOTP/HOTP tokens were found in this FreeOTP+ backup.")
        }

        return OTPAuthImportResult(
            formatDescription: "FreeOTP+ Backup",
            folders: [],
            accounts: importedAccounts
        )
    }

    // MARK: - Proton Authenticator JSON

    private static func decodeProtonAuthenticator(root: [String: Any]) throws -> OTPAuthImportResult {
        let entries = root["entries"] as? [[String: Any]] ?? []
        var importedAccounts: [OTPAccount] = []

        for entry in entries {
            guard let content = entry["content"] as? [String: Any],
                  let uriStr = trimmedNonEmpty(content["uri"] as? String),
                  let url = URL(string: uriStr),
                  var account = try? OTPUriParser.parseOTPAuthURL(url) else {
                continue
            }

            if let entryName = trimmedNonEmpty(content["name"] as? String), account.issuer.isEmpty {
                let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(issuer: entryName, label: account.label)
                account.issuer = resolvedIssuer
                account.label = resolvedLabel
            }
            account.sortOrder = importedAccounts.count
            importedAccounts.append(account)
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No valid otpauth entries were found in this Proton Authenticator export.")
        }

        return OTPAuthImportResult(
            formatDescription: "Proton Authenticator",
            folders: [],
            accounts: importedAccounts
        )
    }

    // MARK: - Raivo OTP JSON

    private static func decodeRaivoJSON(items: [[String: Any]]) throws -> OTPAuthImportResult {
        var importedAccounts: [OTPAccount] = []

        for item in items {
            let kindRaw = (item["kind"] as? String ?? "TOTP").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let otpType: OTPType
            switch kindRaw {
            case "HOTP": otpType = .hotp
            case "TOTP", "": otpType = .totp
            default: continue
            }

            guard let secretStr = trimmedNonEmpty(item["secret"] as? String),
                  let secret = decodeBase32Flexible(secretStr) else {
                continue
            }

            let issuer = trimmed(item["issuer"] as? String) ?? ""
            let label = trimmed(item["account"] as? String) ?? ""
            let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(issuer: issuer, label: label)

            importedAccounts.append(
                OTPAccount(
                    issuer: resolvedIssuer,
                    label: resolvedLabel,
                    secret: secret,
                    type: otpType,
                    algorithm: parseAlgorithm(item["algorithm"] as? String),
                    digits: intValue(item["digits"]) ?? 6,
                    period: intValue(item["timer"]) ?? 30,
                    counter: uint64Value(item["counter"]) ?? 0,
                    isPinned: boolValue(item["pinned"]) ?? false,
                    sortOrder: importedAccounts.count
                )
            )
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No TOTP/HOTP accounts were found in this Raivo export.")
        }

        return OTPAuthImportResult(
            formatDescription: "Raivo OTP Export",
            folders: [],
            accounts: importedAccounts
        )
    }

    // MARK: - andOTP JSON

    private static func decodeAndOTPJSON(items: [[String: Any]]) throws -> OTPAuthImportResult {
        var folderBuilder = FolderBuilder()
        var importedAccounts: [OTPAccount] = []

        for item in items {
            let rawType = (item["type"] as? String ?? "TOTP").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let otpType: OTPType
            switch rawType {
            case "HOTP": otpType = .hotp
            case "TOTP", "": otpType = .totp
            default: continue // Skip STEAM / MOTP
            }

            guard let secretStr = trimmedNonEmpty(item["secret"] as? String),
                  let secret = decodeBase32Flexible(secretStr) else {
                continue
            }

            let issuer = trimmed(item["issuer"] as? String) ?? ""
            let label = trimmed(item["label"] as? String) ?? ""
            let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(issuer: issuer, label: label)

            let folderID: UUID?
            if let tags = item["tags"] as? [String],
               let firstTag = tags.compactMap(trimmedNonEmpty).first {
                folderID = folderBuilder.folderID(named: firstTag)
            } else {
                folderID = nil
            }

            importedAccounts.append(
                OTPAccount(
                    issuer: resolvedIssuer,
                    label: resolvedLabel,
                    secret: secret,
                    type: otpType,
                    algorithm: parseAlgorithm(item["algorithm"] as? String),
                    digits: intValue(item["digits"]) ?? 6,
                    period: intValue(item["period"]) ?? 30,
                    counter: uint64Value(item["counter"]) ?? 0,
                    folderID: folderID,
                    sortOrder: importedAccounts.count
                )
            )
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No TOTP/HOTP accounts were found in this andOTP export.")
        }

        return OTPAuthImportResult(
            formatDescription: "andOTP Export",
            folders: folderBuilder.folders,
            accounts: importedAccounts
        )
    }

    // MARK: - Plaintext URI List (.txt — Ente Auth / Migration / URI Export)

    private static func containsOTPURI(in text: String) -> Bool {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let lower = line.lowercased()
            if lower.hasPrefix("otpauth://") || lower.hasPrefix("otpauth-migration://") {
                return true
            }
        }
        return false
    }

    private static func decodeURIList(text: String) throws -> OTPAuthImportResult {
        var importedAccounts: [OTPAccount] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let lower = line.lowercased()
            guard lower.hasPrefix("otpauth://") || lower.hasPrefix("otpauth-migration://") else { continue }
            if let parsed = try? OTPUriParser.parse(line) {
                for var account in parsed {
                    account.sortOrder = importedAccounts.count
                    importedAccounts.append(account)
                }
            }
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No valid otpauth:// URIs were found in this file.")
        }

        return OTPAuthImportResult(
            formatDescription: "OTP URI List",
            folders: [],
            accounts: importedAccounts
        )
    }

    // MARK: - RFC 4180 CSV (Apple Passwords, Bitwarden, 1Password, Generic)

    private static func normalizedHeaderKey(_ raw: String) -> String {
        String(raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static let otpColumnKeys = [
        "otpauth",
        "logintotp",
        "totp",
        "onetimepassword",
        "otp",
        "totpsecret",
        "2fasecret",
        "twofactor",
        "secret",
    ]

    private static func detectCSVFormat(in text: String) -> String? {
        let rows = parseCSV(text)
        guard rows.count >= 2, let headerRow = rows.first else {
            return nil
        }

        let normalizedHeaders = headerRow.map(normalizedHeaderKey)
        guard normalizedHeaders.contains(where: { otpColumnKeys.contains($0) }) else {
            return nil
        }

        let headerSet = Set(normalizedHeaders)
        if headerSet.contains("title") && headerSet.contains("url") && headerSet.contains("username") && headerSet.contains("otpauth") {
            return "Apple Passwords CSV"
        }
        if headerSet.contains("logintotp") {
            return "Bitwarden CSV"
        }
        if headerSet.contains("onetimepassword") || (headerSet.contains("website") && headerSet.contains("otpauth")) {
            return "1Password CSV"
        }
        return "CSV Export"
    }

    private static func decodeCSV(text: String, label formatLabel: String) throws -> OTPAuthImportResult {
        let rows = parseCSV(text)
        guard rows.count >= 2, let headerRow = rows.first else {
            throw OTPImportError.invalidFileFormat
        }

        var colByKey: [String: Int] = [:]
        for (idx, header) in headerRow.enumerated() {
            let norm = normalizedHeaderKey(header)
            if !norm.isEmpty, colByKey[norm] == nil {
                colByKey[norm] = idx
            }
        }

        guard let otpCol = otpColumnKeys.compactMap({ colByKey[$0] }).first else {
            throw OTPImportError.invalidFileFormat
        }

        func firstCell(_ row: [String], keys: [String]) -> String? {
            for key in keys {
                if let idx = colByKey[key], idx < row.count,
                   let val = trimmedNonEmpty(row[idx]) {
                    return val
                }
            }
            return nil
        }

        var folderBuilder = FolderBuilder()
        var importedAccounts: [OTPAccount] = []

        for row in rows.dropFirst() {
            guard otpCol < row.count,
                  let otpValue = trimmedNonEmpty(row[otpCol]),
                  otpValue.lowercased() != "null",
                  otpValue != "-" else {
                continue
            }

            let rawTitle = firstCell(row, keys: ["issuer", "title", "name", "service", "accountname"])
            let rawURL = firstCell(row, keys: ["url", "website", "loginuri"])
            let urlHost = rawURL.flatMap(hostLabel(from:)) ?? ""
            let fallbackIssuer = rawTitle ?? urlHost
            let fallbackLabel = firstCell(row, keys: ["username", "account", "loginusername", "email", "label"]) ?? ""

            guard var account = parseOTPField(
                otpValue,
                fallbackIssuer: fallbackIssuer,
                fallbackLabel: fallbackLabel
            ) else {
                continue
            }

            if !otpValue.lowercased().hasPrefix("otpauth") {
                if let rawType = firstCell(row, keys: ["type", "otptype"])?.uppercased(), rawType == "HOTP" {
                    account.type = .hotp
                }
                if let algoStr = firstCell(row, keys: ["algorithm", "algo"]) {
                    account.algorithm = parseAlgorithm(algoStr)
                }
                if let digitsStr = firstCell(row, keys: ["digits"]), let d = Int(digitsStr) {
                    account.digits = (4...10).contains(d) ? d : account.digits
                }
                if let periodStr = firstCell(row, keys: ["period", "timer"]), let p = Int(periodStr), p > 0 {
                    account.period = p
                }
                if let counterStr = firstCell(row, keys: ["counter"]), let c = UInt64(counterStr) {
                    account.counter = c
                }
            }

            if let folderName = firstCell(row, keys: ["folder", "group", "category"]) {
                account.folderID = folderBuilder.folderID(named: folderName)
            }
            if let favStr = firstCell(row, keys: ["favorite", "pinned", "starred"]),
               let isFav = boolValue(favStr) {
                account.isPinned = isFav
            }

            account.sortOrder = importedAccounts.count
            importedAccounts.append(account)
        }

        guard !importedAccounts.isEmpty else {
            throw OTPImportError.corruptedArchive("No OTP keys were found in this CSV export.")
        }

        return OTPAuthImportResult(
            formatDescription: formatLabel,
            folders: folderBuilder.folders,
            accounts: importedAccounts
        )
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        currentField.unicodeScalars.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                }
                currentField.unicodeScalars.append(ch)
                i += 1
            } else {
                if ch == "\"" && currentField.isEmpty {
                    inQuotes = true
                    i += 1
                } else if ch == "," {
                    currentRow.append(currentField)
                    currentField = ""
                    i += 1
                } else if ch == "\r" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\n" {
                        i += 2
                    } else {
                        i += 1
                    }
                    currentRow.append(currentField)
                    currentField = ""
                    if currentRow.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                } else if ch == "\n" {
                    currentRow.append(currentField)
                    currentField = ""
                    if currentRow.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    i += 1
                } else {
                    currentField.unicodeScalars.append(ch)
                    i += 1
                }
            }
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            if currentRow.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(currentRow)
            }
        }

        return rows
    }

    // MARK: - Shared Helpers

    private static func parseOTPField(
        _ value: String,
        fallbackIssuer: String,
        fallbackLabel: String
    ) -> OTPAccount? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmedValue.lowercased()
        if lower.hasPrefix("steam://") {
            return nil
        }

        if lower.hasPrefix("otpauth://") || lower.hasPrefix("otpauth-migration://") {
            guard let parsed = try? OTPUriParser.parse(trimmedValue), var account = parsed.first else {
                return nil
            }
            if account.issuer.isEmpty && !fallbackIssuer.isEmpty {
                account.issuer = fallbackIssuer
            }
            if account.label.isEmpty && !fallbackLabel.isEmpty {
                account.label = fallbackLabel
            }
            return account
        }

        guard let secret = decodeBase32Flexible(trimmedValue) else {
            return nil
        }

        let (resolvedIssuer, resolvedLabel) = normalizeIssuerAndLabel(
            issuer: fallbackIssuer,
            label: fallbackLabel
        )
        return OTPAccount(
            issuer: resolvedIssuer,
            label: resolvedLabel,
            secret: secret
        )
    }

    private static func parseJSONObject(_ data: Data) throws -> Any {
        let normalizedData: Data
        if data.starts(with: Data([0xEF, 0xBB, 0xBF])) {
            normalizedData = Data(data.dropFirst(3))
        } else {
            normalizedData = data
        }
        return try JSONSerialization.jsonObject(with: normalizedData, options: [.fragmentsAllowed])
    }

    private static func utf8StringStrippingBOM(from data: Data) -> String? {
        guard var str = String(data: data, encoding: .utf8) else {
            return nil
        }
        if str.hasPrefix("\u{FEFF}") {
            str.removeFirst()
        }
        return str
    }

    private static func decodeBase32Flexible(_ raw: String) -> Data? {
        let stripped = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty,
              let decoded = try? Base32.decode(stripped),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    private static func parseAlgorithm(_ raw: String?) -> OTPAlgorithm {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sha256", "hmacsha256":
            return .sha256
        case "sha512", "hmacsha512":
            return .sha512
        case "md5", "hmacmd5":
            return .md5
        default:
            return .sha1
        }
    }

    private static func normalizeIssuerAndLabel(issuer: String, label: String) -> (String, String) {
        let cleanIssuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanIssuer.isEmpty, let colon = cleanLabel.firstIndex(of: ":") {
            let prefix = String(cleanLabel[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(cleanLabel[cleanLabel.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty && !suffix.isEmpty {
                return (prefix, suffix)
            }
        }
        return (cleanIssuer, cleanLabel)
    }

    private static func hostLabel(from rawURL: String) -> String? {
        let candidate = rawURL.contains("://") ? rawURL : "https://\(rawURL)"
        guard var host = URL(string: candidate)?.host?.lowercased() else {
            return nil
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }

    private static func trimmed(_ str: String?) -> String? {
        str?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedNonEmpty(_ str: String?) -> String? {
        guard let cleaned = str?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let num = value as? NSNumber { return num.intValue }
        if let str = value as? String { return Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let uintVal = value as? UInt64 { return uintVal }
        if let intVal = value as? Int { return intVal >= 0 ? UInt64(intVal) : nil }
        if let num = value as? NSNumber { return num.uint64Value }
        if let str = value as? String { return UInt64(str.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let boolVal = value as? Bool { return boolVal }
        if let intVal = value as? Int { return intVal != 0 }
        if let num = value as? NSNumber { return num.boolValue }
        if let str = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch str {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

private struct FolderBuilder {
    private(set) var folders: [OTPFolder] = []
    private var idByLowerName: [String: UUID] = [:]

    mutating func folderID(named rawName: String) -> UUID {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = name.lowercased()
        if let existing = idByLowerName[key] {
            return existing
        }
        let folder = OTPFolder(
            name: name,
            symbolName: Self.symbolForFolder(name: name),
            sortOrder: folders.count
        )
        folders.append(folder)
        idByLowerName[key] = folder.id
        return folder.id
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
        if lower.contains("gam") || lower.contains("play") {
            return "gamecontroller.fill"
        }
        if lower.contains("shop") || lower.contains("travel") {
            return "bag.fill"
        }
        if lower.contains("social") || lower.contains("media") {
            return "bubble.left.and.bubble.right.fill"
        }
        if lower.contains("sec") || lower.contains("vault") {
            return "lock.shield.fill"
        }
        return "folder.fill"
    }
}
