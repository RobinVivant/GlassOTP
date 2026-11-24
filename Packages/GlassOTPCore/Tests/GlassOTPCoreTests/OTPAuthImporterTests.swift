import Foundation
import Testing
@testable import GlassOTPCore

struct OTPAuthImporterTests {
    private func loadFixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test("Decrypt backup-1.0.otpauthdb with exact folders, accounts, secrets, and defaults")
    func decryptBackup10() throws {
        let data = try loadFixture("backup-1.0.otpauthdb")
        let result = try OTPAuthImporter.importFile(data: data, password: "abc123", filenameHint: "backup-1.0.otpauthdb")

        #expect(result.formatDescription == "OTP Auth Backup v1.0")
        #expect(result.folders.count == 1)
        #expect(result.folders[0].name == "Accounts")
        #expect(result.accounts.count == 6)

        let expected: [(issuer: String, label: String, secret: String, type: OTPType)] = [
            ("Facebook", "max@facebook.com", "abc123", .totp),
            ("Google", "max@mustermann.de", "def456", .totp),
            ("Dropbox", "max@mustermann.de", "ghi789", .totp),
            ("Evernote", "max@mustermann.de", "ksdjgfs", .totp),
            ("GitHub", "max@mustermann.de", "arti7ozouirhbc123", .totp),
            ("Heim-NAS", "max@mustermann.de", "dhfv87ds", .hotp),
        ]

        for (index, item) in expected.enumerated() {
            let account = result.accounts[index]
            #expect(account.issuer == item.issuer)
            #expect(account.label == item.label)
            #expect(account.secret == Data(item.secret.utf8))
            #expect(account.type == item.type)
            #expect(account.digits == 6)
            #expect(account.period == 30)
            #expect(account.algorithm == .sha1)
            #expect(account.folderID == result.folders[0].id)
        }
    }

    @Test("Decrypt backup-1.1.otpauthdb (RNCryptor v3) with exact accounts and secrets")
    func decryptBackup11() throws {
        let data = try loadFixture("backup-1.1.otpauthdb")
        let result = try OTPAuthImporter.importFile(data: data, password: "abc123", filenameHint: "backup-1.1.otpauthdb")

        #expect(result.formatDescription == "OTP Auth Backup v1.1")
        #expect(result.folders.count == 1)
        #expect(result.folders[0].name == "Accounts")
        #expect(result.accounts.count == 6)
        #expect(result.accounts.map(\.issuer) == ["Facebook", "Google", "Dropbox", "Evernote", "GitHub", "Heim-NAS"])
        #expect(result.accounts[4].secret == Data("arti7ozouirhbc123".utf8))
        #expect(result.accounts[5].type == .hotp)
    }

    @Test("Decrypt account-1.1.otpauth single account export")
    func decryptAccount11() throws {
        let data = try loadFixture("account-1.1.otpauth")
        let result = try OTPAuthImporter.importFile(data: data, password: "abc123", filenameHint: "account-1.1.otpauth")

        #expect(result.formatDescription == "OTP Auth Account v1.1")
        #expect(result.folders.isEmpty)
        #expect(result.accounts.count == 1)

        let account = result.accounts[0]
        #expect(account.issuer == "GitHub")
        #expect(account.label == "max@mustermann.de")
        #expect(account.secret == Data("arti7ozouirhbc123".utf8))
        #expect(account.type == .totp)
        #expect(account.digits == 6)
        #expect(account.period == 30)
        #expect(account.algorithm == .sha1)
    }

    @Test("Decrypt account-1.2.otpauth single account export (RNCryptor v3)")
    func decryptAccount12() throws {
        let data = try loadFixture("account-1.2.otpauth")
        let result = try OTPAuthImporter.importFile(data: data, password: "abc123", filenameHint: "account-1.2.otpauth")

        #expect(result.formatDescription == "OTP Auth Account v1.2")
        #expect(result.folders.isEmpty)
        #expect(result.accounts.count == 1)

        let account = result.accounts[0]
        #expect(account.issuer == "Facebook")
        #expect(account.label == "max@facebook.com")
        #expect(account.secret == Data("abc123".utf8))
        #expect(account.type == .totp)
        #expect(account.digits == 6)
        #expect(account.period == 30)
        #expect(account.algorithm == .sha1)
    }

    @Test("Auto-detect format even without filename hint")
    func autoDetectWithoutHint() throws {
        let data = try loadFixture("account-1.2.otpauth")
        let result = try OTPAuthImporter.importFile(data: data, password: "abc123", filenameHint: nil)
        #expect(result.accounts.count == 1)
        #expect(result.accounts[0].issuer == "Facebook")
    }

    @Test("Wrong password throws OTPImportError.wrongPassword across v1.0 and RNCryptor v1.1/v1.2")
    func wrongPasswordThrows() throws {
        for fixture in ["backup-1.0.otpauthdb", "backup-1.1.otpauthdb", "account-1.1.otpauth", "account-1.2.otpauth"] {
            let data = try loadFixture(fixture)
            #expect(throws: OTPImportError.wrongPassword) {
                try OTPAuthImporter.importFile(data: data, password: "definitely-wrong-password", filenameHint: fixture)
            }
        }
    }

    @Test("Invalid bytes throw OTPImportError.invalidFileFormat")
    func invalidBytesThrows() throws {
        let garbage = Data("not-an-otpauth-file-at-all-12345".utf8)
        #expect(throws: OTPImportError.invalidFileFormat) {
            try OTPAuthImporter.importFile(data: garbage, password: "abc123")
        }
    }
}
