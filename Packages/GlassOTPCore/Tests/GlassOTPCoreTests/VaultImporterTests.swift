import Foundation
import Testing
@testable import GlassOTPCore

struct VaultImporterTests {
    @Test("Import 2FAS plaintext and encrypted backups with groups")
    func import2FASPlaintextAndEncrypted() throws {
        let plaintextJSON = """
        {
          "schemaVersion": 4,
          "groups": [
            { "id": "grp-1", "name": "Engineering" }
          ],
          "services": [
            {
              "name": "GitHub",
              "secret": "JBSWY3DPEHPK3PXP",
              "groupId": "grp-1",
              "otp": {
                "account": "alex@example.com",
                "issuer": "GitHub",
                "digits": 6,
                "period": 30,
                "algorithm": "SHA1",
                "tokenType": "TOTP"
              }
            },
            {
              "name": "Legacy Counter",
              "secret": "GEZDGNBVGY3TQOJQ",
              "otp": {
                "account": "token-1",
                "issuer": "Acme",
                "digits": 8,
                "counter": 7,
                "algorithm": "SHA256",
                "tokenType": "HOTP"
              }
            },
            {
              "name": "Steam Guard",
              "secret": "JBSWY3DPEHPK3PXP",
              "otp": {
                "tokenType": "STEAM"
              }
            }
          ]
        }
        """
        let plainData = Data(plaintextJSON.utf8)
        #expect(VaultImporter.inspect(data: plainData, filenameHint: "backup.2fas") == .plaintext(formatHint: "2FAS Backup"))

        let plainResult = try VaultImporter.importFile(data: plainData, filenameHint: "backup.2fas")
        #expect(plainResult.formatDescription == "2FAS Backup")
        #expect(plainResult.folders.map(\.name) == ["Engineering"])
        #expect(plainResult.accounts.count == 2)
        #expect(plainResult.accounts[0].issuer == "GitHub")
        #expect(plainResult.accounts[0].label == "alex@example.com")
        #expect(plainResult.accounts[0].folderID == plainResult.folders[0].id)
        #expect(plainResult.accounts[1].type == .hotp)
        #expect(plainResult.accounts[1].digits == 8)
        #expect(plainResult.accounts[1].counter == 7)
        #expect(plainResult.accounts[1].algorithm == .sha256)

        // Build encrypted 2FAS backup using PBKDF2-SHA256 (10,000 iterations) + AES-256-GCM
        let servicesArrayData = Data("""
        [
          {
            "name": "Cloudflare",
            "secret": "MZXW6YTBOI======",
            "groupId": "grp-1",
            "otp": {
              "account": "ops@example.com",
              "issuer": "Cloudflare",
              "digits": 6,
              "period": 30,
              "algorithm": "SHA1",
              "tokenType": "TOTP"
            }
          }
        ]
        """.utf8)
        let salt = Data("0123456789abcdef".utf8)
        let iv = Data("fedcba987654".utf8)
        let key = try CryptoPrimitives.pbkdf2SHA256(
            password: Data("2fas-secret".utf8),
            salt: salt,
            iterations: 10_000,
            keyLength: 32
        )
        let sealed = try CryptoPrimitives.aes256GCMEncrypt(plaintext: servicesArrayData, nonce: iv, key: key)
        let combined = sealed.ciphertext + sealed.tag
        let encryptedPayload = "\(combined.base64EncodedString()):\(salt.base64EncodedString()):\(iv.base64EncodedString())"
        let encryptedJSON = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 4,
            "groups": [["id": "grp-1", "name": "Infra"]],
            "servicesEncrypted": encryptedPayload,
        ])

        #expect(VaultImporter.inspect(data: encryptedJSON, filenameHint: "backup.2fas") == .encrypted(formatHint: "2FAS Encrypted Backup"))
        #expect(throws: OTPImportError.passwordRequired("2FAS Encrypted Backup")) {
            try VaultImporter.importFile(data: encryptedJSON)
        }
        #expect(throws: OTPImportError.wrongPassword) {
            try VaultImporter.importFile(data: encryptedJSON, password: "wrong-password")
        }

        let encryptedResult = try VaultImporter.importFile(data: encryptedJSON, password: "2fas-secret")
        #expect(encryptedResult.formatDescription == "2FAS Encrypted Backup")
        #expect(encryptedResult.folders.map(\.name) == ["Infra"])
        #expect(encryptedResult.accounts.count == 1)
        #expect(encryptedResult.accounts[0].issuer == "Cloudflare")
        #expect(encryptedResult.accounts[0].label == "ops@example.com")
    }

    @Test("Import Aegis plaintext and scrypt+GCM encrypted vaults")
    func importAegisPlaintextAndEncrypted() throws {
        let dbObject: [String: Any] = [
            "version": 3,
            "groups": [
                ["uuid": "g-dev", "name": "Dev"],
            ],
            "entries": [
                [
                    "type": "totp",
                    "issuer": "GitLab",
                    "name": "alex@example.com",
                    "favorite": true,
                    "groups": ["g-dev"],
                    "info": [
                        "secret": "JBSWY3DPEHPK3PXP",
                        "algo": "SHA1",
                        "digits": 6,
                        "period": 30,
                    ],
                ],
                [
                    "type": "steam",
                    "issuer": "Steam",
                    "name": "ignored",
                    "info": ["secret": "JBSWY3DPEHPK3PXP", "algo": "SHA1", "digits": 5, "period": 30],
                ],
            ],
        ]

        let plainEnvelope = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "header": ["slots": NSNull(), "params": NSNull()],
            "db": dbObject,
        ])
        #expect(VaultImporter.inspect(data: plainEnvelope) == .plaintext(formatHint: "Aegis Vault"))

        let plainResult = try VaultImporter.importFile(data: plainEnvelope)
        #expect(plainResult.formatDescription == "Aegis Vault")
        #expect(plainResult.folders.map(\.name) == ["Dev"])
        #expect(plainResult.accounts.count == 1)
        #expect(plainResult.accounts[0].isPinned == true)
        #expect(plainResult.accounts[0].issuer == "GitLab")

        // Build scrypt + AES-256-GCM encrypted Aegis vault
        let dbData = try JSONSerialization.data(withJSONObject: dbObject)
        let masterKey = Data((0..<32).map { UInt8($0) })
        let dbNonce = Data((100..<112).map { UInt8($0) })
        let dbSealed = try CryptoPrimitives.aes256GCMEncrypt(plaintext: dbData, nonce: dbNonce, key: masterKey)

        let slotSalt = Data("00112233445566778899aabbccddeeff".utf8).prefix(16)
        let slotKey = try CryptoPrimitives.scrypt(
            password: Data("aegis-pass".utf8),
            salt: Data(slotSalt),
            n: 1024,
            r: 8,
            p: 1,
            keyLength: 32
        )
        let keyNonce = Data((200..<212).map { UInt8($0) })
        let keySealed = try CryptoPrimitives.aes256GCMEncrypt(plaintext: masterKey, nonce: keyNonce, key: slotKey)

        func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        let encryptedEnvelope = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "header": [
                "slots": [
                    [
                        "type": 1,
                        "uuid": UUID().uuidString,
                        "key": hex(keySealed.ciphertext),
                        "key_params": ["nonce": hex(keyNonce), "tag": hex(keySealed.tag)],
                        "n": 1024,
                        "r": 8,
                        "p": 1,
                        "salt": hex(Data(slotSalt)),
                    ],
                ],
                "params": [
                    "nonce": hex(dbNonce),
                    "tag": hex(dbSealed.tag),
                ],
            ],
            "db": (dbSealed.ciphertext).base64EncodedString(),
        ])

        #expect(VaultImporter.inspect(data: encryptedEnvelope) == .encrypted(formatHint: "Aegis Encrypted Vault"))
        #expect(throws: OTPImportError.wrongPassword) {
            try VaultImporter.importFile(data: encryptedEnvelope, password: "bad-password")
        }

        let encResult = try VaultImporter.importFile(data: encryptedEnvelope, password: "aegis-pass")
        #expect(encResult.formatDescription == "Aegis Encrypted Vault")
        #expect(encResult.accounts.count == 1)
        #expect(encResult.accounts[0].issuer == "GitLab")
    }

    @Test("Import Bitwarden unencrypted JSON and surface guidance for encrypted JSON")
    func importBitwardenJSON() throws {
        let plainJSON = """
        {
          "encrypted": false,
          "folders": [
            { "id": "f1", "name": "Cloud" }
          ],
          "items": [
            {
              "name": "AWS Prod",
              "folderId": "f1",
              "favorite": true,
              "login": {
                "username": "ops@example.com",
                "totp": "otpauth://totp/AWS:ops@example.com?secret=JBSWY3DPEHPK3PXP&issuer=AWS"
              }
            },
            {
              "name": "Password Only",
              "login": { "username": "user@example.com", "totp": null }
            },
            {
              "name": "Fastmail",
              "login": {
                "username": "alex@fastmail.com",
                "totp": "MZXW 6YTB OI=="
              }
            }
          ]
        }
        """
        let data = Data(plainJSON.utf8)
        #expect(VaultImporter.inspect(data: data) == .plaintext(formatHint: "Bitwarden JSON"))

        let result = try VaultImporter.importFile(data: data)
        #expect(result.formatDescription == "Bitwarden JSON")
        #expect(result.folders.map(\.name) == ["Cloud"])
        #expect(result.accounts.count == 2)
        #expect(result.accounts[0].issuer == "AWS")
        #expect(result.accounts[0].isPinned == true)
        #expect(result.accounts[1].issuer == "Fastmail")
        #expect(result.accounts[1].label == "alex@fastmail.com")

        let encryptedJSON = Data("""
        { "encrypted": true, "encKeyValidation_DO_NOT_EDIT": "abc", "items": [] }
        """.utf8)
        if case .unsupportedEncrypted(let name, _) = VaultImporter.inspect(data: encryptedJSON) {
            #expect(name == "Bitwarden Encrypted Export")
        } else {
            Issue.record("Expected unsupportedEncrypted inspection for Bitwarden encrypted JSON")
        }
    }

    @Test("Import Apple Passwords, Bitwarden, and 1Password CSV exports")
    func importCSVExports() throws {
        let appleCSV = """
        \u{FEFF}Title,URL,Username,Password,Notes,OTPAuth
        "GitHub, Inc.",https://github.com/login,alex@example.com,pw,"line1
        line2","otpauth://totp/GitHub:alex@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        NoOTP Site,https://example.com,alex,pw,,
        """
        let appleData = Data(appleCSV.utf8)
        #expect(VaultImporter.inspect(data: appleData, filenameHint: "Passwords.csv") == .plaintext(formatHint: "Apple Passwords CSV"))

        let appleResult = try VaultImporter.importFile(data: appleData, filenameHint: "Passwords.csv")
        #expect(appleResult.formatDescription == "Apple Passwords CSV")
        #expect(appleResult.accounts.count == 1)
        #expect(appleResult.accounts[0].issuer == "GitHub")
        #expect(appleResult.accounts[0].label == "alex@example.com")

        let bwCSV = """
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Work,1,login,Cloudflare,,[],0,https://dash.cloudflare.com,ops@example.com,pw,MZXW6YTBOI======
        """
        let bwResult = try VaultImporter.importFile(data: Data(bwCSV.utf8), filenameHint: "bitwarden.csv")
        #expect(bwResult.formatDescription == "Bitwarden CSV")
        #expect(bwResult.folders.map(\.name) == ["Work"])
        #expect(bwResult.accounts[0].isPinned == true)
        #expect(bwResult.accounts[0].issuer == "Cloudflare")

        let opCSV = """
        Title,Website,Username,Password,One-Time Password
        Linear,https://linear.app,alex@example.com,pw,JBSWY3DPEHPK3PXP
        """
        let opResult = try VaultImporter.importFile(data: Data(opCSV.utf8), filenameHint: "1p.csv")
        #expect(opResult.formatDescription == "1Password CSV")
        #expect(opResult.accounts.count == 1)
        #expect(opResult.accounts[0].issuer == "Linear")
    }

    @Test("Import Raivo, Stratum/AuthPro JSON + legacy AES-CBC, andOTP, FreeOTP+, Proton, and URI list")
    func importOtherProviders() throws {
        // 1. Raivo OTP JSON
        let raivoData = Data("""
        [
          {
            "issuer": "GitHub",
            "account": "alex@example.com",
            "secret": "JBSWY3DPEHPK3PXP",
            "kind": "TOTP",
            "algorithm": "SHA1",
            "digits": "6",
            "timer": "30",
            "pinned": true
          }
        ]
        """.utf8)
        let raivoRes = try VaultImporter.importFile(data: raivoData)
        #expect(raivoRes.formatDescription == "Raivo OTP Export")
        #expect(raivoRes.accounts[0].isPinned == true)

        // 2. Authenticator Pro / Stratum JSON + Legacy encrypted .authpro
        let authProJSON = Data("""
        {
          "Authenticators": [
            {
              "Type": 2,
              "Issuer": "Tailscale",
              "Username": "home-net",
              "Secret": "JBSWY3DPEHPK3PXP",
              "Algorithm": 1,
              "Digits": 6,
              "Period": 30,
              "Counter": 0
            }
          ],
          "Categories": [
            { "Id": "cat-1", "Name": "Network" }
          ],
          "AuthenticatorCategories": [
            { "CategoryId": "cat-1", "AuthenticatorSecret": "JBSWY3DPEHPK3PXP" }
          ]
        }
        """.utf8)
        let apRes = try VaultImporter.importFile(data: authProJSON)
        #expect(apRes.formatDescription == "Authenticator Pro / Stratum")
        #expect(apRes.folders.map(\.name) == ["Network"])
        #expect(apRes.accounts[0].algorithm == .sha256)

        // Build legacy encrypted .authpro
        let apSalt = Data("01234567890123456789".utf8)
        let apIV = Data("abcdefabcdef0123".utf8)
        let apKey = try CryptoPrimitives.pbkdf2SHA1(password: Data("stratum-pw".utf8), salt: apSalt, iterations: 64_000, keyLength: 32)
        let apCipher = try CryptoPrimitives.aes256CBCEncrypt(plaintext: authProJSON, key: apKey, iv: apIV)
        let legacyAuthProData = Data("AuthenticatorPro".utf8) + apSalt + apIV + apCipher
        #expect(VaultImporter.inspect(data: legacyAuthProData) == .encrypted(formatHint: "Authenticator Pro Encrypted Backup"))
        let apEncRes = try VaultImporter.importFile(data: legacyAuthProData, password: "stratum-pw")
        #expect(apEncRes.formatDescription == "Authenticator Pro Encrypted Backup")
        #expect(apEncRes.accounts[0].issuer == "Tailscale")

        // Modern v2 Argon2id .authpro
        let v2AuthPro = Data("AUTHPRO".utf8) + Data(repeating: 0, count: 32)
        if case .unsupportedEncrypted = VaultImporter.inspect(data: v2AuthPro) {
            // Expected
        } else {
            Issue.record("Expected unsupportedEncrypted for v2 AUTHPRO")
        }

        // 3. FreeOTP+ JSON with signed Int8 array secret
        let secretBytes = Data("foobar".utf8)
        let signedArray = secretBytes.map { Int(Int8(bitPattern: $0)) }
        let freeOTPData = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                [
                    "issuerExt": "Red Hat",
                    "label": "alex",
                    "secret": signedArray,
                    "type": "TOTP",
                    "algo": "SHA1",
                    "digits": 6,
                    "period": 30,
                ],
            ],
        ])
        let freeOTPRes = try VaultImporter.importFile(data: freeOTPData)
        #expect(freeOTPRes.formatDescription == "FreeOTP+ Backup")
        #expect(freeOTPRes.accounts[0].secret == secretBytes)

        // 4. Proton Authenticator JSON
        let protonData = Data("""
        {
          "version": 1,
          "entries": [
            {
              "id": "entry-1",
              "content": {
                "uri": "otpauth://totp/Proton:alex@proton.me?secret=JBSWY3DPEHPK3PXP&issuer=Proton",
                "name": "Proton"
              }
            }
          ]
        }
        """.utf8)
        let protonRes = try VaultImporter.importFile(data: protonData)
        #expect(protonRes.formatDescription == "Proton Authenticator")
        #expect(protonRes.accounts[0].issuer == "Proton")

        // 5. andOTP JSON
        let andOTPData = Data("""
        [
          {
            "secret": "JBSWY3DPEHPK3PXP",
            "issuer": "Discord",
            "label": "alex#0001",
            "digits": 6,
            "type": "TOTP",
            "algorithm": "SHA1",
            "period": 30,
            "tags": ["Social"]
          }
        ]
        """.utf8)
        let andOTPRes = try VaultImporter.importFile(data: andOTPData)
        #expect(andOTPRes.formatDescription == "andOTP Export")
        #expect(andOTPRes.folders.map(\.name) == ["Social"])

        // 6. Ente Auth / Plaintext URI list
        let uriList = Data("""
        # Exported from Ente Auth
        otpauth://totp/GitHub:alex@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub

        otpauth://hotp/Counter:item?secret=GEZDGNBVGY3TQOJQ&counter=3
        """.utf8)
        #expect(VaultImporter.inspect(data: uriList, filenameHint: "ente_auth.txt") == .plaintext(formatHint: "OTP URI List"))
        let uriRes = try VaultImporter.importFile(data: uriList, filenameHint: "ente_auth.txt")
        #expect(uriRes.formatDescription == "OTP URI List")
        #expect(uriRes.accounts.count == 2)
        #expect(uriRes.accounts[1].counter == 3)
    }

    @Test("VaultImporter counts skipped entries, rejects oversized payloads, and caps Aegis slots")
    func importerSkippedCountsAndCaps() throws {
        let aegisWithSkipped = Data("""
        {
          "version": 1,
          "header": { "slots": null, "params": null },
          "db": {
            "entries": [
              { "type": "steam", "issuer": "Steam", "name": "user", "info": { "secret": "JBSWY3DPEHPK3PXP", "algo": "SHA1", "digits": 5, "period": 30 } },
              { "type": "totp", "issuer": "BadAlgo", "name": "md5", "info": { "secret": "JBSWY3DPEHPK3PXP", "algo": "MD5", "digits": 6, "period": 30 } },
              { "type": "totp", "issuer": "GitHub", "name": "valid", "info": { "secret": "JBSWY3DPEHPK3PXP", "algo": "SHA1", "digits": 6, "period": 30 } }
            ]
          }
        }
        """.utf8)
        let aegisRes = try VaultImporter.importFile(data: aegisWithSkipped)
        #expect(aegisRes.accounts.count == 1)
        #expect(aegisRes.skippedEntries == 2)

        let uriWithSkipped = Data("""
        otpauth://totp/Valid:alex?secret=JBSWY3DPEHPK3PXP&issuer=Valid
        otpauth://totp/Legacy:alex?secret=JBSWY3DPEHPK3PXP&algorithm=MD5
        not-a-valid-line
        """.utf8)
        let uriRes = try VaultImporter.importFile(data: uriWithSkipped)
        #expect(uriRes.accounts.count == 1)
        #expect(uriRes.skippedEntries == 2)

        let oversized = Data(repeating: 0x41, count: VaultImporter.maxImportFileBytes + 1)
        #expect(VaultImporter.inspect(data: oversized) == .fileTooLarge("Import files are limited to 20 MB."))
        #expect(throws: OTPImportError.self) {
            try VaultImporter.importFile(data: oversized)
        }
    }

    @Test("GlassOTP backup import skips MD5/empty entries and importer normalizes algorithms")
    func glassOTPBackupMD5FilterAndAlgorithmNormalization() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let md5Account = OTPAccount(
            issuer: "OldMD5",
            label: "md5",
            secret: Data("12345".utf8),
            algorithm: .md5,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let validAccount = OTPAccount(
            issuer: "GitHub",
            label: "valid",
            secret: Data("JBSWY3DPEHPK3PXP".utf8),
            algorithm: .sha256,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let snapshot = OTPVaultSnapshot(accounts: [md5Account, validAccount], updatedAt: fixedDate)
        let backupData = try GlassOTPBackupCodec.encode(snapshot: snapshot, password: "strong-password-1", log2N: 12)
        let imported = try VaultImporter.importFile(data: backupData, password: "strong-password-1", filenameHint: "test.glassotp")
        #expect(imported.accounts.count == 1)
        #expect(imported.accounts[0].issuer == "GitHub")
        #expect(imported.skippedEntries == 1)

        let aegisNormalized = Data("""
        {
          "version": 1,
          "header": { "slots": null, "params": null },
          "db": {
            "entries": [
              { "type": "totp", "issuer": "HyphenSHA", "name": "a", "info": { "secret": "JBSWY3DPEHPK3PXP", "algo": "HMAC-SHA512", "digits": 6, "period": 30 } },
              { "type": "totp", "issuer": "UnknownAlgo", "name": "b", "info": { "secret": "JBSWY3DPEHPK3PXP", "algo": "BLAKE2B", "digits": 6, "period": 30 } }
            ]
          }
        }
        """.utf8)
        let res = try VaultImporter.importFile(data: aegisNormalized)
        #expect(res.accounts.count == 1)
        #expect(res.accounts[0].algorithm == .sha512)
        #expect(res.skippedEntries == 1)

        // Stratum / Authenticator Pro unknown numeric algorithm is skipped instead of falling back to SHA-1
        let apUnknownAlgo = Data("""
        {
          "Authenticators": [
            { "Type": 2, "Issuer": "Valid", "Username": "a", "Secret": "JBSWY3DPEHPK3PXP", "Algorithm": 0, "Digits": 6, "Period": 30 },
            { "Type": 2, "Issuer": "UnknownNum", "Username": "b", "Secret": "JBSWY3DPEHPK3PXP", "Algorithm": 9, "Digits": 6, "Period": 30 }
          ]
        }
        """.utf8)
        let apRes = try VaultImporter.importFile(data: apUnknownAlgo)
        #expect(apRes.accounts.count == 1)
        #expect(apRes.accounts[0].issuer == "Valid")
        #expect(apRes.skippedEntries == 1)

        // Google migration unknown enum algorithm throws unsupportedAlgorithm
        var entry = Data()
        entry.append(contentsOf: [0x0A, 0x05])
        entry.append(Data("12345".utf8))
        entry.append(contentsOf: [0x20, 0x09]) // field 4 (algorithm) = 9
        var migration = Data()
        migration.append(contentsOf: [0x0A, UInt8(entry.count)])
        migration.append(entry)
        let encoded = migration.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        #expect(throws: OTPUriError.unsupportedAlgorithm("enum(9)")) {
            try OTPUriParser.parse("otpauth-migration://offline?data=\(encoded)")
        }
    }

    @Test("OTPAuthImporter maps numeric algorithms 0..3, skips unknown algorithms in backups, and throws corruptedArchive on unsupported single account")
    func otpAuthImporterNumericAlgorithmsAndSingleAccountError() throws {
        let password = "otpauth-test-password"

        // Backup database (.otpauthdb v1.1) with algorithms 0, 1, 2, 3 and unknown 9
        let folderAccounts: [[String: Any]] = [
            ["issuer": "ZeroSHA1", "label": "0", "secret": Data("11111".utf8), "type": 2, "algorithm": 0],
            ["issuer": "OneSHA1", "label": "1", "secret": Data("22222".utf8), "type": 2, "algorithm": 1],
            ["issuer": "TwoSHA256", "label": "2", "secret": Data("33333".utf8), "type": 2, "algorithm": 2],
            ["issuer": "ThreeSHA512", "label": "3", "secret": Data("44444".utf8), "type": 2, "algorithm": 3],
            ["issuer": "UnknownAlgo", "label": "9", "secret": Data("55555".utf8), "type": 2, "algorithm": 9],
        ]
        let dbInner: [String: Any] = ["Folders": [["name": "Work", "accounts": folderAccounts]]]
        let dbInnerPlist = try NSKeyedArchiver.archivedData(withRootObject: dbInner, requiringSecureCoding: false)
        let dbWrapped = try CryptoPrimitives.rncryptorV3Encrypt(plaintext: dbInnerPlist, password: password)
        let dbOuter: [String: Any] = ["Version": 1.1, "WrappedData": dbWrapped]
        let dbOuterPlist = try NSKeyedArchiver.archivedData(withRootObject: dbOuter, requiringSecureCoding: false)
        let dbBytes = try CryptoPrimitives.aes256CBCEncrypt(
            plaintext: dbOuterPlist,
            key: CryptoPrimitives.sha256(Data("Authenticator".utf8)),
            iv: Data(repeating: 0, count: 16)
        )

        let dbResult = try OTPAuthImporter.importFile(data: dbBytes, password: password, filenameHint: "backup.otpauthdb")
        #expect(dbResult.accounts.count == 4)
        #expect(dbResult.accounts.map(\.algorithm) == [.sha1, .sha1, .sha256, .sha512])
        #expect(dbResult.skippedEntries == 1)

        // Single-account (.otpauth v1.2) with unknown algorithm must throw corruptedArchive, NOT wrongPassword
        let singleInner: [String: Any] = ["issuer": "Legacy", "label": "u", "secret": Data("12345".utf8), "type": 2, "algorithm": 9]
        let singleInnerPlist = try NSKeyedArchiver.archivedData(withRootObject: singleInner, requiringSecureCoding: false)
        let singleEncrypted = try CryptoPrimitives.rncryptorV3Encrypt(plaintext: singleInnerPlist, password: password)
        let singleOuter: [String: Any] = ["Version": 1.2, "Data": singleEncrypted]
        let singleOuterPlist = try NSKeyedArchiver.archivedData(withRootObject: singleOuter, requiringSecureCoding: false)
        let singleBytes = try CryptoPrimitives.aes256CBCEncrypt(
            plaintext: singleOuterPlist,
            key: CryptoPrimitives.sha256(Data("OTPAuth".utf8)),
            iv: Data(repeating: 0, count: 16)
        )

        #expect(throws: OTPImportError.corruptedArchive("This OTP Auth account uses an unsupported algorithm or empty secret.")) {
            try OTPAuthImporter.importFile(data: singleBytes, password: password, filenameHint: "single.otpauth")
        }
    }
}
