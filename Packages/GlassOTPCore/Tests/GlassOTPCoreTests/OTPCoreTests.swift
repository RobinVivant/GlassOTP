import Foundation
import Testing
@testable import GlassOTPCore

struct OTPCoreTests {
    @Test("RFC 4226 Appendix D HOTP test vectors (counters 0...9)")
    func rfc4226Vectors() {
        let secret = Data("12345678901234567890".utf8)
        let expected = [
            "755224", "287082", "359152", "969429", "338314",
            "254676", "287922", "162583", "399871", "520489",
        ]
        for (counter, expectedCode) in expected.enumerated() {
            let code = OTPGenerator.generateHOTP(
                secret: secret,
                counter: UInt64(counter),
                digits: 6,
                algorithm: .sha1
            )
            #expect(code == expectedCode)
        }
    }

    @Test("RFC 6238 Appendix B TOTP test vectors for SHA1, SHA256, and SHA512")
    func rfc6238Vectors() {
        let sha1Secret = Data("12345678901234567890".utf8)
        let sha256Secret = Data("12345678901234567890123456789012".utf8)
        let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

        let vectors: [(time: TimeInterval, algo: OTPAlgorithm, secret: Data, expected: String)] = [
            (59, .sha1, sha1Secret, "94287082"),
            (59, .sha256, sha256Secret, "46119246"),
            (59, .sha512, sha512Secret, "90693936"),
            (1_111_111_109, .sha1, sha1Secret, "07081804"),
            (1_111_111_109, .sha256, sha256Secret, "68084774"),
            (1_111_111_109, .sha512, sha512Secret, "25091201"),
            (1_234_567_890, .sha1, sha1Secret, "89005924"),
            (1_234_567_890, .sha256, sha256Secret, "91819424"),
            (1_234_567_890, .sha512, sha512Secret, "93441116"),
            (2_000_000_000, .sha1, sha1Secret, "69279037"),
            (2_000_000_000, .sha256, sha256Secret, "90698825"),
            (2_000_000_000, .sha512, sha512Secret, "38618901"),
        ]

        for vector in vectors {
            let code = OTPGenerator.generateTOTP(
                secret: vector.secret,
                date: Date(timeIntervalSince1970: vector.time),
                period: 30,
                digits: 8,
                algorithm: vector.algo
            )
            #expect(code == vector.expected)
        }
    }

    @Test("Base32 encode and decode RFC 4648 edge cases")
    func base32RoundTrip() throws {
        #expect(Base32.encode(Data("foobar".utf8), padded: true) == "MZXW6YTBOI======")
        #expect(Base32.encode(Data("foobar".utf8), padded: false) == "MZXW6YTBOI")
        #expect(try Base32.decode("mzxw 6ytb-oi==") == Data("foobar".utf8))
        #expect(try Base32.decode("MZXW6YTBOI") == Data("foobar".utf8))

        #expect(throws: Base32Error.invalidCharacter("1")) {
            try Base32.decode("ABC1DEF")
        }
    }

    @Test("otpauth:// URI round-trip preserves metadata and secret")
    func otpAuthURIRoundTrip() throws {
        let uri = "otpauth://totp/Cloudflare:ops@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Cloudflare&algorithm=SHA256&digits=8&period=60"
        let parsed = try OTPUriParser.parse(uri)
        #expect(parsed.count == 1)

        let account = parsed[0]
        #expect(account.issuer == "Cloudflare")
        #expect(account.label == "ops@example.com")
        #expect(account.algorithm == .sha256)
        #expect(account.digits == 8)
        #expect(account.period == 60)
        #expect(account.type == .totp)

        let reencoded = OTPUriParser.toURI(account)
        let reparsed = try OTPUriParser.parse(reencoded)
        #expect(reparsed.count == 1)
        #expect(reparsed[0].fingerprint == account.fingerprint)
    }

    @Test("Google Authenticator otpauth-migration:// protobuf payload decoding")
    func googleMigrationDecode() throws {
        // Hand-crafted protobuf MigrationPayload with 1 OtpParameters entry:
        // field 1 (OtpParameters, tag 0x0A):
        //   field 1 (secret = "12345", tag 0x0A, len 5): 31 32 33 34 35
        //   field 2 (name = "alice@work.io", tag 0x12, len 13)
        //   field 3 (issuer = "GitLab", tag 0x1A, len 6)
        //   field 4 (algorithm = SHA256(2), tag 0x20, val 2)
        //   field 5 (digits = SIX(1), tag 0x28, val 1)
        //   field 6 (type = TOTP(2), tag 0x30, val 2)
        var entry = Data()
        let secret = Data("12345".utf8)
        let name = Data("alice@work.io".utf8)
        let issuer = Data("GitLab".utf8)

        entry.append(contentsOf: [0x0A, UInt8(secret.count)])
        entry.append(secret)
        entry.append(contentsOf: [0x12, UInt8(name.count)])
        entry.append(name)
        entry.append(contentsOf: [0x1A, UInt8(issuer.count)])
        entry.append(issuer)
        entry.append(contentsOf: [0x20, 0x02, 0x28, 0x01, 0x30, 0x02])

        var payload = Data()
        payload.append(contentsOf: [0x0A, UInt8(entry.count)])
        payload.append(entry)

        let encoded = payload.base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let migrationURL = "otpauth-migration://offline?data=\(encoded)"

        let accounts = try OTPUriParser.parse(migrationURL)
        #expect(accounts.count == 1)
        #expect(accounts[0].issuer == "GitLab")
        #expect(accounts[0].label == "alice@work.io")
        #expect(accounts[0].secret == secret)
        #expect(accounts[0].algorithm == .sha256)
        #expect(accounts[0].digits == 6)
        #expect(accounts[0].type == .totp)
    }

    @Test("GlassOTPBackupCodec encrypt/decrypt round-trip, v2 cost header, minimum password, and wrong-password check")
    func glassOTPBackupRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = OTPFolder(name: "Engineering", symbolName: "server.rack", sortOrder: 0, updatedAt: fixedDate)
        let account = OTPAccount(
            issuer: "GitHub",
            label: "alex@example.com",
            secret: Data("supersecretkey".utf8),
            folderID: folder.id,
            isPinned: true,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let snapshot = OTPVaultSnapshot(folders: [folder], accounts: [account], updatedAt: fixedDate)

        #expect(throws: OTPImportError.passwordTooShort(8)) {
            try GlassOTPBackupCodec.encode(snapshot: snapshot, password: "short")
        }

        // Verify default GLOTP2 encode writes log2N = 16 (N = 65,536 / 64 MiB) and round-trips cleanly
        let encrypted = try GlassOTPBackupCodec.encode(snapshot: snapshot, password: "correct-horse-battery")
        #expect(GlassOTPBackupCodec.isGlassOTPBackup(encrypted))
        #expect(encrypted.starts(with: Data("GLOTP2".utf8)))
        #expect(encrypted.count > 6 && encrypted[6] == 16)

        let decoded = try GlassOTPBackupCodec.decode(data: encrypted, password: "correct-horse-battery")
        #expect(decoded.folders == snapshot.folders)
        #expect(decoded.accounts == snapshot.accounts)

        // Use fast N=4096 internal overload for negative wrong-password verification
        let fastEncrypted = try GlassOTPBackupCodec.encode(snapshot: snapshot, password: "correct-horse-battery", log2N: 12)
        #expect(throws: OTPImportError.wrongPassword) {
            try GlassOTPBackupCodec.decode(data: fastEncrypted, password: "wrong-password")
        }
    }

    @Test("Duplicate fingerprint detection ignores case/UUID differences while distinguishing parameters")
    func duplicateFingerprintDetection() {
        let secret = Data("sharedsecret".utf8)
        let a = OTPAccount(issuer: "GitHub", label: "Alex@Example.com", secret: secret)
        let b = OTPAccount(issuer: "github", label: "alex@example.com", secret: secret)
        let c = OTPAccount(issuer: "GitHub", label: "alex@example.com", secret: secret, digits: 8)

        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint != c.fingerprint)
    }

    @Test("RFC 7914 scrypt key derivation test vectors")
    func scryptRFC7914Vectors() throws {
        let vectors: [(password: String, salt: String, n: Int, r: Int, p: Int, expectedHex: String)] = [
            (
                "",
                "",
                16,
                1,
                1,
                "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"
            ),
            (
                "password",
                "NaCl",
                1024,
                8,
                16,
                "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"
            ),
            (
                "pleaseletmein",
                "SodiumChloride",
                16384,
                8,
                1,
                "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887"
            ),
        ]

        for vector in vectors {
            let derived = try CryptoPrimitives.scrypt(
                password: Data(vector.password.utf8),
                salt: Data(vector.salt.utf8),
                n: vector.n,
                r: vector.r,
                p: vector.p,
                keyLength: 64
            )
            let hex = derived.map { String(format: "%02x", $0) }.joined()
            #expect(hex == vector.expectedHex)
        }
    }

    @Test("PBKDF2-SHA256 and AES-256-GCM encrypt/decrypt round-trip and wrong-key error")
    func pbkdf2SHA256AndAESGCMRoundTrip() throws {
        let key = try CryptoPrimitives.pbkdf2SHA256(
            password: Data("correct-password".utf8),
            salt: Data("0123456789abcdef".utf8),
            iterations: 1000,
            keyLength: 32
        )
        #expect(key.count == 32)

        let nonce = Data(repeating: 0x2A, count: 12)
        let plaintext = Data("hello-glassotp-gcm".utf8)
        let sealed = try CryptoPrimitives.aes256GCMEncrypt(plaintext: plaintext, nonce: nonce, key: key)
        let decrypted = try CryptoPrimitives.aes256GCMDecrypt(
            ciphertext: sealed.ciphertext,
            nonce: nonce,
            tag: sealed.tag,
            key: key
        )
        #expect(decrypted == plaintext)

        let wrongKey = Data(repeating: 0xFF, count: 32)
        #expect(throws: OTPImportError.wrongPassword) {
            try CryptoPrimitives.aes256GCMDecrypt(
                ciphertext: sealed.ciphertext,
                nonce: nonce,
                tag: sealed.tag,
                key: wrongKey
            )
        }
    }

    @Test("Snapshot merge preserves concurrent edits, tombstones deletions, and keeps max HOTP counter")
    func snapshotMergeAndTombstones() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_050)
        let t3 = Date(timeIntervalSince1970: 1_700_000_100)

        let devFolder = OTPFolder(name: "Dev", sortOrder: 0, updatedAt: t1)
        let deletedFolder = OTPFolder(name: "Old", sortOrder: 1, updatedAt: t1)

        let hotpID = UUID()
        let toDeleteID = UUID()
        let addedOnMacID = UUID()

        let baseHotp = OTPAccount(id: hotpID, issuer: "NAS", label: "admin", secret: Data("123".utf8), type: .hotp, counter: 4, folderID: devFolder.id, createdAt: t1, updatedAt: t1)
        let toDelete = OTPAccount(id: toDeleteID, issuer: "OldApp", label: "x", secret: Data("456".utf8), folderID: deletedFolder.id, createdAt: t1, updatedAt: t1)

        // Device A incremented HOTP counter to 5 at t2, added Mac account, and deleted deletedFolder
        var macHotp = baseHotp
        macHotp.counter = 5
        macHotp.updatedAt = t2
        let macAdded = OTPAccount(id: addedOnMacID, issuer: "GitHub", label: "mac", secret: Data("789".utf8), createdAt: t2, updatedAt: t2)
        let macSnapshot = OTPVaultSnapshot(
            folders: [devFolder],
            accounts: [macHotp, toDelete, macAdded],
            updatedAt: t2,
            folderTombstones: [OTPTombstone(id: deletedFolder.id, deletedAt: t2)]
        )

        // Device B pinned baseHotp later at t3 (with stale counter 4) and deleted toDelete at t3
        var iosHotp = baseHotp
        iosHotp.isPinned = true
        iosHotp.updatedAt = t3
        let iosSnapshot = OTPVaultSnapshot(
            folders: [devFolder, deletedFolder],
            accounts: [iosHotp],
            updatedAt: t3,
            accountTombstones: [OTPTombstone(id: toDeleteID, deletedAt: t3)]
        )

        let merged = macSnapshot.merged(with: iosSnapshot)
        #expect(merged.folders.map(\.id) == [devFolder.id])
        #expect(merged.accounts.contains(where: { $0.id == addedOnMacID }))
        #expect(!merged.accounts.contains(where: { $0.id == toDeleteID }))

        let mergedHotp = merged.accounts.first { $0.id == hotpID }
        #expect(mergedHotp?.isPinned == true)
        #expect(mergedHotp?.counter == 5)
    }

    @Test("VaultImportReconciler prevents colliding UUIDs and avoids orphan folders")
    func importReconcilerSafety() {
        let existingFolder = OTPFolder(name: "Cloud", sortOrder: 0)
        let existingID = UUID()
        let existingAccount = OTPAccount(
            id: existingID,
            issuer: "AWS",
            label: "ops",
            secret: Data("SECRET1".utf8),
            folderID: existingFolder.id,
            sortOrder: 0
        )

        let usedFolder = OTPFolder(name: "Cloud", sortOrder: 0)
        let unusedFolder = OTPFolder(name: "Orphan", sortOrder: 1)
        let selectedAccount = OTPAccount(
            id: existingID, // intentionally collides with existingAccount ID!
            issuer: "GitHub",
            label: "dev",
            secret: Data("SECRET2".utf8),
            folderID: usedFolder.id
        )
        let unselectedAccount = OTPAccount(
            issuer: "Other",
            label: "user",
            secret: Data("SECRET3".utf8),
            folderID: unusedFolder.id
        )

        let plan = VaultImportReconciler.reconcile(
            importedAccounts: [existingAccount, selectedAccount, unselectedAccount],
            importedFolders: [usedFolder, unusedFolder],
            existingAccounts: [existingAccount],
            existingFolders: [existingFolder],
            selectedIDs: [existingID, selectedAccount.id],
            skipDuplicates: true
        )

        #expect(plan.addedCount == 1)
        #expect(plan.skippedDuplicateCount == 1)
        #expect(plan.accounts.count == 2)
        #expect(Set(plan.accounts.map(\.id)).count == 2)
        #expect(plan.folders.map(\.name) == ["Cloud"])
        #expect(plan.accounts.last?.folderID == existingFolder.id)
    }

    @Test("10-digit OTP generation avoids 32-bit modulus overflow")
    func tenDigitOTPNoOverflow() {
        let secret = Data("12345678901234567890".utf8)
        let code = OTPGenerator.generateHOTP(secret: secret, counter: 0, digits: 10, algorithm: .sha1)
        #expect(code == "1284755224")
    }

    @Test("OTPUriParser rejects crafted migration varint overflow, double percent-decoding, and MD5")
    func uriParserSecurityAndEdgeCases() throws {
        // Malformed varint overflow length (2^63 - 1)
        #expect(throws: OTPUriError.invalidMigrationPayload) {
            try OTPUriParser.parse("otpauth-migration://offline?data=Cv%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwE%3D")
        }

        // Single percent-decode: %2520 in path stays literal %20
        let singleDecoded = try OTPUriParser.parse(
            "otpauth://totp/Issuer%3Auser%2520name?secret=JBSWY3DPEHPK3PXP&issuer=Issuer"
        )
        #expect(singleDecoded[0].label == "user%20name")

        // MD5 rejection
        #expect(throws: OTPUriError.unsupportedAlgorithm("MD5")) {
            try OTPUriParser.parse("otpauth://totp/Legacy:user?secret=JBSWY3DPEHPK3PXP&algorithm=MD5")
        }
    }

    @Test("GlassOTPBackupCodec decodes legacy GLOTP1, validates RNCryptor options, caps scrypt, and caps archive depth")
    func codecCompatibilityAndLimits() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = OTPVaultSnapshot(
            folders: [OTPFolder(name: "Eng", sortOrder: 0, updatedAt: fixedDate)],
            accounts: [OTPAccount(issuer: "GitHub", label: "a", secret: Data("s".utf8), createdAt: fixedDate, updatedAt: fixedDate)],
            updatedAt: fixedDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshot)
        var legacyGLOTP1 = Data("GLOTP1".utf8)
        let rnEncrypted = try CryptoPrimitives.rncryptorV3Encrypt(plaintext: jsonData, password: "legacy-pass-1")
        legacyGLOTP1.append(rnEncrypted)

        let decodedLegacy = try GlassOTPBackupCodec.decode(data: legacyGLOTP1, password: "legacy-pass-1")
        #expect(decodedLegacy.accounts.count == 1)

        var badOptions = rnEncrypted
        badOptions[1] = 0x00
        #expect(throws: OTPImportError.self) {
            try CryptoPrimitives.rncryptorV3Decrypt(data: badOptions, password: "legacy-pass-1")
        }

        #expect(throws: OTPImportError.self) {
            try CryptoPrimitives.scrypt(password: Data("p".utf8), salt: Data("s".utf8), n: 1 << 20, r: 8, p: 1)
        }

        // Deeply nested NSKeyedArchiver plist > maxDepth (64)
        var objects: [Any] = ["$null"]
        let cfUidClass: [String: Any] = ["$classname": "NSArray", "$classes": ["NSArray", "NSObject"]]
        objects.append(cfUidClass)
        let uidType = { (i: Int) in ["CF$UID": i] }
        for i in 2...80 {
            objects.append(["$class": uidType(1), "NS.objects": [uidType(i + 1)]])
        }
        objects.append("leaf")
        let plistObj: [String: Any] = [
            "$version": 100_000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["root": uidType(2)],
            "$objects": objects,
        ]
        let xmlData = try PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0)
        // Binary plist conversion preserves native plist structure; test KeyedArchiveParser via XML-transformed plist
        #expect(throws: OTPImportError.self) {
            try KeyedArchiveParser.parseRoot(from: xmlData)
        }
    }

    @Test("Snapshot merge honors same-second tombstones, HOTP counterResetAt decrements, and tombstone limits")
    func snapshotMergeCounterResetAndTombstones() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_010)
        let hotpID = UUID()
        let sameSecondDeleteID = UUID()
        let extraDeletedA = UUID()
        let extraDeletedB = UUID()

        // Device A incremented counter to 10; Device B explicitly lowered counter to 2 with counterResetAt = t2
        let sideA = OTPVaultSnapshot(
            accounts: [
                OTPAccount(id: hotpID, issuer: "Yubi", label: "a", secret: Data("123".utf8), type: .hotp, counter: 10, createdAt: t1, updatedAt: t1),
                OTPAccount(id: sameSecondDeleteID, issuer: "Temp", label: "b", secret: Data("456".utf8), createdAt: t1, updatedAt: t1),
            ],
            updatedAt: t1
        )
        let sideB = OTPVaultSnapshot(
            accounts: [
                OTPAccount(id: hotpID, issuer: "Yubi", label: "a", secret: Data("123".utf8), type: .hotp, counter: 2, createdAt: t1, updatedAt: t2, counterResetAt: t2),
            ],
            updatedAt: t2,
            accountTombstones: [
                OTPTombstone(id: sameSecondDeleteID, deletedAt: t1), // exact same second as updatedAt
                OTPTombstone(id: extraDeletedA, deletedAt: t1),
                OTPTombstone(id: extraDeletedB, deletedAt: t2),
            ]
        )

        let mergedAB = sideA.merged(with: sideB, tombstoneLimit: 2)
        let mergedBA = sideB.merged(with: sideA, tombstoneLimit: 2)
        #expect(mergedAB.accounts.count == 1)
        #expect(mergedAB.accounts[0].counter == 2)
        #expect(mergedAB.accounts[0].counterResetAt == t2)
        #expect(mergedBA.accounts == mergedAB.accounts)
        #expect(!mergedAB.accounts.contains(where: { $0.id == sameSecondDeleteID }))
        #expect(mergedAB.accountTombstones.count == 2)
        #expect(mergedAB.accountTombstones.contains(where: { $0.id == extraDeletedB }))
    }

    @Test("VaultImportReconciler avoids tombstoned UUIDs and honors preserveEmptyFolders")
    func reconcilerTombstonesAndEmptyFolders() {
        let deletedAccountID = UUID()
        let deletedFolderID = UUID()
        let emptyFolder = OTPFolder(id: deletedFolderID, name: "Archive", sortOrder: 0)
        let importedAccount = OTPAccount(id: deletedAccountID, issuer: "GitHub", label: "u", secret: Data("SECRET".utf8))

        let planWithEmpty = VaultImportReconciler.reconcile(
            importedAccounts: [importedAccount],
            importedFolders: [emptyFolder],
            existingAccounts: [],
            existingFolders: [],
            existingAccountTombstones: [OTPTombstone(id: deletedAccountID, deletedAt: Date())],
            existingFolderTombstones: [OTPTombstone(id: deletedFolderID, deletedAt: Date())],
            preserveEmptyFolders: true
        )
        #expect(planWithEmpty.accounts.count == 1)
        #expect(planWithEmpty.accounts[0].id != deletedAccountID)
        #expect(planWithEmpty.folders.count == 1)
        #expect(planWithEmpty.folders[0].id != deletedFolderID)

        let planWithoutEmpty = VaultImportReconciler.reconcile(
            importedAccounts: [importedAccount],
            importedFolders: [emptyFolder],
            existingAccounts: [],
            existingFolders: [],
            preserveEmptyFolders: false
        )
        #expect(planWithoutEmpty.folders.isEmpty)
    }

    @Test("OTPAccount Codable clamps out-of-range digits/period and SharedWidgetStateStore expires strictly before 2.5s")
    func accountClampingAndCopyExpiryBoundary() throws {
        let json = Data("""
        {
          "id": "\(UUID().uuidString)",
          "issuer": "Legacy",
          "label": "u",
          "secret": "\(Data("12345".utf8).base64EncodedString())",
          "type": "totp",
          "algorithm": "md5",
          "digits": 12,
          "period": -5
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let account = try decoder.decode(OTPAccount.self, from: json)
        #expect(account.digits == 6)
        #expect(account.period == 30)
        #expect(!account.isSupportedAlgorithm)

        let testID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        SharedWidgetStateStore.recordCopy(accountID: testID, at: t0)
        #expect(SharedWidgetStateStore.copyExpiry(accountID: testID, now: t0.addingTimeInterval(2.49)) != nil)
        #expect(SharedWidgetStateStore.copyExpiry(accountID: testID, now: t0.addingTimeInterval(2.5)) == nil)
        #expect(!SharedWidgetStateStore.wasRecentlyCopied(accountID: testID, now: t0.addingTimeInterval(2.5)))
    }

    @Test("VaultSnapshotCoder preserves subsecond timestamps across repeated round-trips and decodes legacy ISO8601")
    func snapshotCoderSubsecondAndLegacy() throws {
        // Specifically verify .002Z (prone to binary-float truncation under naive DateComponents formatting) and .distantPast
        let exactDate = Date(timeIntervalSince1970: 1_795_600_000.002)
        let hotpID = UUID()
        var current = OTPVaultSnapshot(
            folders: [OTPFolder(name: "Sec", sortOrder: 0, updatedAt: exactDate)],
            accounts: [
                OTPAccount(
                    id: hotpID,
                    issuer: "GitHub",
                    label: "a",
                    secret: Data("s".utf8),
                    type: .hotp,
                    counter: 3,
                    createdAt: Date.distantPast,
                    updatedAt: exactDate,
                    counterResetAt: exactDate,
                    credentialGeneration: 2
                ),
            ],
            updatedAt: exactDate
        )
        for _ in 0..<10 {
            let encoded = try VaultSnapshotCoder.encode(current)
            let decoded = try VaultSnapshotCoder.decode(from: encoded)
            #expect(decoded.accounts[0].updatedAt.roundedEpochMillis == exactDate.roundedEpochMillis)
            #expect(decoded.accounts[0].counterResetAt?.roundedEpochMillis == exactDate.roundedEpochMillis)
            #expect(decoded.accounts[0].createdAt.roundedEpochMillis == Date.distantPast.roundedEpochMillis)
            current = decoded
        }

        let advancedHOTP = OTPVaultSnapshot(
            accounts: [
                OTPAccount(
                    id: hotpID,
                    issuer: "GitHub",
                    label: "a",
                    secret: Data("s".utf8),
                    type: .hotp,
                    counter: 5,
                    createdAt: Date.distantPast,
                    updatedAt: exactDate.addingTimeInterval(1),
                    counterResetAt: exactDate,
                    credentialGeneration: 2
                ),
            ],
            updatedAt: exactDate.addingTimeInterval(1)
        )
        let merged = current.merged(with: advancedHOTP)
        #expect(merged.accounts.first(where: { $0.id == hotpID })?.counter == 5)

        // Legacy whole-second JSON without fractional seconds
        let legacyJSON = Data("""
        {
          "schemaVersion": 1,
          "folders": [],
          "accounts": [
            {
              "id": "\(UUID().uuidString)",
              "issuer": "Legacy",
              "label": "u",
              "secret": "\(Data("12345".utf8).base64EncodedString())",
              "updatedAt": "2026-11-25T09:46:40Z"
            }
          ],
          "updatedAt": "2026-11-25T09:46:40Z"
        }
        """.utf8)
        let legacyDecoded = try VaultSnapshotCoder.decode(from: legacyJSON)
        #expect(legacyDecoded.accounts.count == 1)
        #expect(legacyDecoded.accounts[0].credentialGeneration == 0)
    }

    @Test("Merge handles HOTP secret rotation coherently, ties deterministically, and retains tombstones over >500 deletions")
    func mergeCoherentResetDeterministicTiesAndRetainedTombstones() throws {
        let id = UUID()
        let folderID = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000.100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_000.900) // subsecond later in same second

        // Offline increment vs secret rotation: credentialGeneration/reset tuple takes precedence cleanly
        let oldSecret = Data([1, 1, 1])
        let newSecret = Data([2, 2, 2])
        let offlineIncrement = OTPAccount(
            id: id,
            issuer: "NAS",
            label: "ops-renamed",
            secret: oldSecret,
            type: .hotp,
            counter: 42,
            createdAt: t1,
            updatedAt: t2,
            counterResetAt: nil,
            credentialGeneration: 0
        )
        let rotated = OTPAccount(
            id: id,
            issuer: "NAS",
            label: "ops",
            secret: newSecret,
            type: .hotp,
            counter: 0,
            createdAt: t1,
            updatedAt: t1.addingTimeInterval(0.3),
            counterResetAt: t1.addingTimeInterval(0.3),
            credentialGeneration: 1
        )
        let incSnap = OTPVaultSnapshot(accounts: [offlineIncrement], updatedAt: t2)
        let rotSnap = OTPVaultSnapshot(accounts: [rotated], updatedAt: t1.addingTimeInterval(0.3))

        let ab = incSnap.merged(with: rotSnap)
        let ba = rotSnap.merged(with: incSnap)
        #expect(ab.accounts[0] == ba.accounts[0])
        #expect(ab.accounts[0].secret == newSecret)
        #expect(ab.accounts[0].counter == 0)
        #expect(ab.accounts[0].credentialGeneration == 1)
        #expect(ab.accounts[0].label == "ops-renamed")

        // Deterministic tie-break on identical encoded timestamp
        let sameTime = Date(timeIntervalSince1970: 1_700_000_050)
        let tieFolderA = OTPFolder(id: folderID, name: "Alpha", sortOrder: 0, updatedAt: sameTime)
        let tieFolderB = OTPFolder(id: folderID, name: "Zeta", sortOrder: 0, updatedAt: sameTime)
        let snapA = OTPVaultSnapshot(folders: [tieFolderA], updatedAt: sameTime)
        let snapB = OTPVaultSnapshot(folders: [tieFolderB], updatedAt: sameTime)
        let m1 = try VaultSnapshotCoder.decode(from: VaultSnapshotCoder.encode(snapA.merged(with: snapB)))
        let m2 = try VaultSnapshotCoder.decode(from: VaultSnapshotCoder.encode(snapB.merged(with: snapA)))
        #expect(m1.folders == m2.folders)

        // >500 unrelated deletions retain all tombstones AND preserve unseen offline accounts/folders
        let deletedAccID = UUID()
        let unseenAccID = UUID()
        let unseenFolderID = UUID()
        let unseenFolder = OTPFolder(id: unseenFolderID, name: "OfflineFolder", sortOrder: 0, updatedAt: t1)
        let staleDeletedAcc = OTPAccount(id: deletedAccID, issuer: "Deleted", label: "x", secret: Data("abc".utf8), createdAt: t1, updatedAt: t1)
        let unseenOfflineAcc = OTPAccount(id: unseenAccID, issuer: "UnseenOffline", label: "y", secret: Data("def".utf8), folderID: unseenFolderID, createdAt: t1, updatedAt: t1)
        let staleDevice = OTPVaultSnapshot(
            folders: [unseenFolder],
            accounts: [staleDeletedAcc, unseenOfflineAcc],
            updatedAt: t1
        )

        var tombstones = [OTPTombstone(id: deletedAccID, deletedAt: t1.addingTimeInterval(1))]
        for idx in 1..<600 {
            tombstones.append(OTPTombstone(id: UUID(), deletedAt: t1.addingTimeInterval(TimeInterval(idx + 1))))
        }
        let pruningDevice = OTPVaultSnapshot(
            accounts: [],
            updatedAt: t1.addingTimeInterval(700),
            accountTombstones: tombstones
        ).merged(with: OTPVaultSnapshot())
        #expect(pruningDevice.accountTombstones.count == 600)

        let mergedAfterManyDeletes = pruningDevice.merged(with: staleDevice)
        #expect(!mergedAfterManyDeletes.accounts.contains(where: { $0.id == deletedAccID }))
        #expect(mergedAfterManyDeletes.accounts.contains(where: { $0.id == unseenAccID }))
        #expect(mergedAfterManyDeletes.folders.contains(where: { $0.id == unseenFolderID }))
    }

    @Test("Three-way merge of rotation, deletion, and stale rename is order-independent")
    func threeWayMergeRotationDeleteAndStaleRename() {
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_010)
        let t3 = Date(timeIntervalSince1970: 1_700_000_020)
        let t4 = Date(timeIntervalSince1970: 1_700_000_030)

        let rotated = OTPVaultSnapshot(
            accounts: [
                OTPAccount(
                    id: id,
                    issuer: "Service",
                    label: "a",
                    secret: Data("new-secret".utf8),
                    createdAt: t1,
                    updatedAt: t2,
                    counterResetAt: t2,
                    credentialGeneration: 1
                ),
            ],
            updatedAt: t2
        )
        let deleted = OTPVaultSnapshot(
            accounts: [],
            updatedAt: t3,
            accountTombstones: [OTPTombstone(id: id, deletedAt: t3)]
        )
        let staleRenamed = OTPVaultSnapshot(
            accounts: [
                OTPAccount(
                    id: id,
                    issuer: "Service-Renamed",
                    label: "a",
                    secret: Data("old-secret".utf8),
                    createdAt: t1,
                    updatedAt: t4,
                    counterResetAt: nil,
                    credentialGeneration: 0
                ),
            ],
            updatedAt: t4
        )

        let orders = [
            rotated.merged(with: deleted).merged(with: staleRenamed),
            rotated.merged(with: staleRenamed).merged(with: deleted),
            deleted.merged(with: rotated).merged(with: staleRenamed),
            deleted.merged(with: staleRenamed).merged(with: rotated),
            staleRenamed.merged(with: rotated).merged(with: deleted),
            staleRenamed.merged(with: deleted).merged(with: rotated),
        ]
        for result in orders {
            #expect(result.accounts.isEmpty)
            #expect(result.accountTombstones.map(\.id) == [id])
            #expect(result == orders[0])
        }
    }

    @Test("Equal-generation HOTP parameter conflicts and differing createdAt merge commutatively")
    func equalGenerationHOTPParameterConflictAndCreatedAt() {
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_050)
        let tEarlier = Date(timeIntervalSince1970: 1_699_000_000)
        let sharedSecret = Data("hotp-secret".utf8)

        let hotpSHA1 = OTPVaultSnapshot(
            accounts: [
                OTPAccount(
                    id: id,
                    issuer: "NAS",
                    label: "ops",
                    secret: sharedSecret,
                    type: .hotp,
                    algorithm: .sha1,
                    digits: 6,
                    period: 30,
                    counter: 5,
                    createdAt: .distantPast,
                    updatedAt: t1
                ),
            ],
            updatedAt: t1
        )
        let hotpSHA256 = OTPVaultSnapshot(
            accounts: [
                OTPAccount(
                    id: id,
                    issuer: "NAS",
                    label: "ops",
                    secret: sharedSecret,
                    type: .hotp,
                    algorithm: .sha256,
                    digits: 8,
                    period: 60,
                    counter: 9,
                    createdAt: tEarlier,
                    updatedAt: t1
                ),
            ],
            updatedAt: t1
        )

        let ab = hotpSHA1.merged(with: hotpSHA256)
        let ba = hotpSHA256.merged(with: hotpSHA1)
        #expect(ab == ba)
        #expect(ab.accounts[0].createdAt == tEarlier)
    }

    @Test("Clock-skewed accounts honor delete and Date.monotonicTimestamp stays ahead across round-trips")
    func clockSkewDeleteAndMonotonicTimestamp() throws {
        let id = UUID()
        let futureDate = Date(timeIntervalSince1970: 1_795_600_120.005)
        let pastDate = Date(timeIntervalSince1970: 1_795_600_000)

        let skewedAccount = OTPAccount(
            id: id,
            issuer: "Skewed",
            label: "u",
            secret: Data("abc".utf8),
            updatedAt: futureDate
        )
        let deletedWithOlderClock = OTPVaultSnapshot(
            accounts: [],
            updatedAt: pastDate,
            accountTombstones: [OTPTombstone(id: id, deletedAt: pastDate)]
        )
        let merged = OTPVaultSnapshot(accounts: [skewedAccount], updatedAt: futureDate)
            .merged(with: deletedWithOlderClock)
        #expect(merged.accounts.isEmpty)

        let bumped = Date.monotonicTimestamp(after: futureDate, now: pastDate)
        #expect(bumped > futureDate)
        let decoded = try VaultSnapshotCoder.decode(from: VaultSnapshotCoder.encode(
            OTPVaultSnapshot(accounts: [OTPAccount(issuer: "S", label: "u", secret: Data("1".utf8), updatedAt: bumped)])
        ))
        #expect(decoded.accounts[0].updatedAt.roundedEpochMillis > futureDate.roundedEpochMillis)
    }

    @Test("Equal-millisecond folder moves plus folder tombstone merge associatively and resolve uncategorized")
    func equalTimestampFolderMovesPlusTombstoneAssociativity() {
        let folderF = OTPFolder(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, name: "F", sortOrder: 0)
        let folderG = OTPFolder(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "G", sortOrder: 1)
        let tSame = Date(timeIntervalSince1970: 1_795_600_050.000)
        let accID = UUID()

        let baseAcc = OTPAccount(
            id: accID,
            issuer: "GitHub",
            label: "a",
            secret: Data("123".utf8),
            folderID: folderF.id,
            createdAt: tSame,
            updatedAt: tSame
        )
        let snapX = OTPVaultSnapshot(folders: [folderF, folderG], accounts: [baseAcc], updatedAt: tSame)

        var movedG = baseAcc
        movedG.folderID = folderG.id
        let snapY = OTPVaultSnapshot(folders: [folderF, folderG], accounts: [movedG], updatedAt: tSame)

        let snapZ = OTPVaultSnapshot(
            folders: [folderG],
            accounts: [],
            updatedAt: tSame,
            folderTombstones: [OTPTombstone(id: folderF.id, deletedAt: tSame)]
        )

        let left = snapX.merged(with: snapY).merged(with: snapZ)
        let right = snapX.merged(with: snapY.merged(with: snapZ))
        #expect(left == right)
        #expect(left.folders.map(\.id) == [folderG.id])
        #expect(left.accounts.first?.folderID == folderF.id)
        #expect(AccountCategorizer.hasUncategorizedOrDefaultOnly(accounts: [left.accounts[0], baseAcc], folders: left.folders))
    }

    @Test("Snapshot merge is commutative, associative, and idempotent across 1000 dense-tie randomized triples")
    func snapshotMergeSemilatticeProperties1000DenseTieTriples() {
        struct SplitMix64: RandomNumberGenerator {
            private var state: UInt64
            init(seed: UInt64) { self.state = seed }
            mutating func next() -> UInt64 {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
        }

        let folderPool = (0..<4).map { _ in UUID() }
        let accountPool = (0..<8).map { _ in UUID() }
        let baseMillis: Int64 = 1_795_600_000_000
        let secrets = [Data([1, 2, 3]), Data([4, 5, 6]), Data([7, 8, 9])]
        let algos: [OTPAlgorithm] = [.sha1, .sha256, .sha512]
        var rng = SplitMix64(seed: 0x474C4F54505F5236)

        func makeRandomDate(_ rng: inout SplitMix64) -> Date {
            // Dense 4-bucket timestamp pool to exercise equal-millisecond ties heavily
            let offsetMillis = Int64(rng.next() % 4) * 150
            return Date(timeIntervalSince1970: Double(baseMillis + offsetMillis) / 1000.0)
        }

        func makeRandomSnapshot(_ rng: inout SplitMix64) -> OTPVaultSnapshot {
            var folders: [OTPFolder] = []
            var folderTombstones: [OTPTombstone] = []
            for fid in folderPool {
                let pick = rng.next() % 4
                if pick < 2 {
                    folders.append(
                        OTPFolder(
                            id: fid,
                            name: "F-\(rng.next() % 3)",
                            sortOrder: Int(rng.next() % 5),
                            updatedAt: makeRandomDate(&rng)
                        )
                    )
                } else if pick == 2 {
                    folderTombstones.append(OTPTombstone(id: fid, deletedAt: makeRandomDate(&rng)))
                }
            }
            let activeFolderIDs = folders.map(\.id)

            var accounts: [OTPAccount] = []
            var accountTombstones: [OTPTombstone] = []
            for aid in accountPool {
                let pick = rng.next() % 4
                if pick < 2 {
                    let type: OTPType = (rng.next() % 2 == 0) ? .totp : .hotp
                    let hasReset = (rng.next() % 3 == 0)
                    let assignedFolder: UUID? = (activeFolderIDs.isEmpty || rng.next() % 3 == 0)
                        ? nil
                        : activeFolderIDs[Int(rng.next() % UInt64(activeFolderIDs.count))]
                    let createdAt: Date = (rng.next() % 4 == 0)
                        ? .distantPast
                        : Date(timeIntervalSince1970: Double(baseMillis - Int64((rng.next() % 5) + 1) * 1_000) / 1000.0)
                    accounts.append(
                        OTPAccount(
                            id: aid,
                            issuer: "Issuer-\(rng.next() % 2)",
                            label: "User-\(rng.next() % 2)",
                            secret: secrets[Int(rng.next() % UInt64(secrets.count))],
                            type: type,
                            algorithm: algos[Int(rng.next() % UInt64(algos.count))],
                            digits: (rng.next() % 2 == 0) ? 6 : 8,
                            period: (rng.next() % 2 == 0) ? 30 : 60,
                            counter: rng.next() % 20,
                            folderID: assignedFolder,
                            isPinned: rng.next() % 2 == 0,
                            sortOrder: Int(rng.next() % 3),
                            createdAt: createdAt,
                            updatedAt: makeRandomDate(&rng),
                            counterResetAt: hasReset ? makeRandomDate(&rng) : nil,
                            credentialGeneration: rng.next() % 3
                        )
                    )
                } else if pick == 2 {
                    accountTombstones.append(OTPTombstone(id: aid, deletedAt: makeRandomDate(&rng)))
                }
            }

            return OTPVaultSnapshot(
                schemaVersion: 1,
                folders: folders,
                accounts: accounts,
                updatedAt: makeRandomDate(&rng),
                accountTombstones: accountTombstones,
                folderTombstones: folderTombstones,
                cloudRetiredAtMillis: (rng.next() % 5 == 0) ? (baseMillis + Int64(rng.next() % 10)) : nil,
                cloudSyncGenerationMillis: (rng.next() % 5 == 0) ? (baseMillis + Int64(rng.next() % 10)) : nil
            )
        }

        for _ in 0..<1000 {
            let a = makeRandomSnapshot(&rng)
            let b = makeRandomSnapshot(&rng)
            let c = makeRandomSnapshot(&rng)
            let ab = a.merged(with: b)
            #expect(ab == b.merged(with: a))
            #expect(ab.merged(with: b) == ab)
            #expect(ab.merged(with: a) == ab)
            #expect(ab.merged(with: c) == a.merged(with: b.merged(with: c)))
        }
    }
}
