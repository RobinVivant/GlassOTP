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

    @Test("GlassOTPBackupCodec encrypt/decrypt round-trip and wrong-password check")
    func glassOTPBackupRoundTrip() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = OTPFolder(name: "Engineering", symbolName: "server.rack", sortOrder: 0)
        let account = OTPAccount(
            issuer: "GitHub",
            label: "robin@example.com",
            secret: Data("supersecretkey".utf8),
            folderID: folder.id,
            isPinned: true,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let snapshot = OTPVaultSnapshot(folders: [folder], accounts: [account], updatedAt: fixedDate)

        let encrypted = try GlassOTPBackupCodec.encode(snapshot: snapshot, password: "correct-horse-battery")
        #expect(GlassOTPBackupCodec.isGlassOTPBackup(encrypted))

        let decoded = try GlassOTPBackupCodec.decode(data: encrypted, password: "correct-horse-battery")
        #expect(decoded.folders == snapshot.folders)
        #expect(decoded.accounts == snapshot.accounts)

        #expect(throws: OTPImportError.wrongPassword) {
            try GlassOTPBackupCodec.decode(data: encrypted, password: "wrong-password")
        }
    }

    @Test("Duplicate fingerprint detection ignores case/UUID differences while distinguishing parameters")
    func duplicateFingerprintDetection() {
        let secret = Data("sharedsecret".utf8)
        let a = OTPAccount(issuer: "GitHub", label: "Robin@Example.com", secret: secret)
        let b = OTPAccount(issuer: "github", label: "robin@example.com", secret: secret)
        let c = OTPAccount(issuer: "GitHub", label: "robin@example.com", secret: secret, digits: 8)

        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint != c.fingerprint)
    }
}
