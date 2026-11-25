# Changelog

All notable changes to GlassOTP are documented in this file.

## [1.2.0] - 2026-11-25

### Added
- Interprocess POSIX file locking (`flock`) and a local `ThisDeviceOnly` replica (`local-replica-v1`) in `KeychainVaultStore` so simultaneous iPhone, Widget, and Mac saves reconcile safely with bounded (`500`) tombstones and `counterResetAt` HOTP tracking.
- Shared App Lock preference (`SharedSecurityPreferences.isAppLockEnabled`) forcing Tap-to-Reveal masking on widgets when Face ID / Touch ID lock is enabled, plus passcode/biometry availability gating on app lock toggle.
- Explicit Google Favicons disclosure in settings, `README.md`, and `SECURITY.md`, plus `"Unsupported"` status handling across iOS, widgets, and macOS for legacy MD5 accounts from older exports.
- Actionable `"Retry Deleting iCloud Copy"` control when turning off iCloud Keychain sync leaves a cloud cleanup error.

### Fixed
- Fixed an infinite Face ID re-lock loop when Auto-Lock is set to "Immediately" by ignoring `isAuthenticating` `.inactive` transitions and clearing `backgroundedAt` on unlock.
- Fixed iOS camera scanner authorization timing, app-switcher scene-phase recovery, off-MainActor QR photo decoding, torch toolbar gating, and temporary `/Documents/Inbox/` file cleanup after import.
- Fixed `BrandLogoFetcher` to restrict remote lookups strictly to Google Favicons (`s2/favicons`) over HTTPS port 443 with streaming 512 KiB size enforcement and verified redirect targets.
- Fixed HOTP counter reservation races in `CopyOTPWidgetIntent`, `CopyMacOTPIntent`, `glassotp://` deep links, and macOS copy actions, plus target-process verification (`postToPid`) for macOS auto-type, hotkey collision prevention, async background sync polling, modal sheet resign guarding, and chronological mixed-period widget timelines.
- Bumped `GLOTP2` default `scrypt` work factor to `N = 65536` (`log2N = 16`, 64 MiB), enforced the 8-character minimum password check inside `GlassOTPBackupCodec.encode`, normalized hyphenated algorithms in `VaultImporter`, preserved empty folders on full `.glassotp` restore, and bumped bundle versions (`1.2.0`, build `3`).

## [1.1.0] - 2026-11-25

### Added
- Universal multi-provider OTP importer (`VaultImporter`) supporting 2FAS (`.2fas`, plaintext & PBKDF2-SHA256 / AES-256-GCM encrypted), Aegis (`.json`, plaintext & RFC 7914 `scrypt` / AES-256-GCM encrypted), Bitwarden JSON, Apple Passwords CSV, Bitwarden CSV, 1Password CSV, generic OTP CSV, Ente Auth / URI lists (`.txt`), Raivo OTP JSON, Authenticator Pro / Stratum (JSON & legacy AES-CBC `.authpro`), andOTP JSON, FreeOTP+ JSON, Proton Authenticator JSON, OTP Auth (`.otpauthdb` / `.otpauth`), and GlassOTP (`.glassotp`).
- Automatic plaintext vs encrypted detection in iOS (`OTPAuthImportSheet`) and macOS (`MenuBarPopoverView`) so unencrypted exports skip unnecessary password prompts and unsupported encrypted formats (Bitwarden encrypted JSON, Stratum v2 Argon2id `.authpro`) show actionable export guidance.
- Pure-Swift RFC 7914 `scrypt`, `CryptoPrimitives.pbkdf2SHA256`, and `CryptoPrimitives.aes256GCMDecrypt` / `aes256GCMEncrypt` implementations in `GlassOTPCore`.
- Open-source scaffolding: MIT `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `Config/Signing.xcconfig` + `Config/Signing.local.xcconfig.example`, `.github/workflows/ci.yml`, issue/PR templates, and `LSApplicationCategoryType` for macOS.

### Changed
- Scrubbed repository code, widget previews, demo seeds, tests, brand catalog, and Xcode project files of hardcoded Apple Developer Team IDs and personal/employer identifiers.
- Bumped bundle versions (`CFBundleShortVersionString` `1.1.0`, `CFBundleVersion` `2`) across iOS, WidgetKit extension, and macOS targets.

## [1.0.0] - 2026-11-25

### Added
- Initial release of GlassOTP for iOS 26+ (Liquid Glass UI, compact two-column OTP rows, interactive Home & Lock Screen widgets, haptic widget feedback, Universal Clipboard Handoff toggle, Face ID / Touch ID vault lock, 260+ offline service vector logos, smart auto-categorization, OTP Auth importer, and `.glassotp` RNCryptor v3 backups).
- Initial release of `GlassOTPMac` menu bar companion for macOS 26+ with Data Protection Keychain iCloud sync, `⌃⌥Space` quick-search popover, per-account global shortcuts (`⌃⌥1`–`⌃⌥9` or custom), optional auto-type, live menu bar code, Launch at Login, and `CopyMacOTPIntent`.
