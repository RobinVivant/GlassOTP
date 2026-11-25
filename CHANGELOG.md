# Changelog

All notable changes to GlassOTP are documented in this file.

## [1.2.0] - 2026-11-25

### Added
- Interprocess POSIX file locking (`flock`, fail-closed on iOS mutations), `ThisDeviceOnly` local replica (`local-replica-v1`), single-record synchronizable empty retirement records (`cloudRetiredAtMillis` / `cloudSyncGenerationMillis`), integer-millisecond ISO-8601 serialization (`VaultSnapshotCoder`), canonical tie-breakers, ID-retained deletion tombstones (without horizon pruning), explicit-group legacy migration, and injectable `KeychainBackend` unit tests in `KeychainVaultStore`.
- True App Lock gating on widgets (`SharedSecurityPreferences.effectiveAppLockEnabled` + `isDiscoverable = false` + widget deep-link routing into locked GlassOTP), checks device authentication availability to enable App Lock, and requires device-owner authentication before disabling App Lock.
- Google Favicons disclosures across `SettingsView`, `AutoCategorizeSheet`, `README.md`, and `SECURITY.md`, inline modal error banners, folder-only `.glassotp` restore support, local-only `BrandPickerSheet` grid selection, and `"Unsupported"` status handling for legacy MD5 accounts.
- Actionable `"Retry Deleting iCloud Copy"` control (reactive on `VaultViewModel.hasPendingICloudCleanup`) when turning off iCloud Keychain sync encounters a cloud cleanup error.

### Fixed
- Fixed Face ID auto-lock & cancel loops by ignoring `isAuthenticating` `.inactive` transitions and pausing automatic re-prompts after cancel/error until backgrounding or tapping Unlock.
- Fixed HOTP credential-generation merging (`secret` + `counter` + parameters carried together), `Store` normalized return values eliminating subsecond `counterResetAt` rollbacks, `loadSnapshotUnlocked` read resilience, and `local-replica-v1` cleanup on iCloud opt-out.
- Fixed iOS camera scanner authorization timing, `scenePhase` recovery, detached `CIDetector`, torch gating, `RootTabView` staged sheet transitions, duplicate import/export task races, in-app HOTP tap reservation consistency, and `Documents/Inbox` cleanup.
- Fixed `BrandLogoFetcher` to restrict remote lookups strictly to Google Favicons (`www.google.com/s2/favicons`) over HTTPS port 443 with streaming 512 KiB size enforcement and verified redirect targets.
- Fixed HOTP counter reservation races in `CopyOTPWidgetIntent`, `CopyMacOTPIntent`, `glassotp://` deep links, and macOS copy actions, plus `postToPid` per-digit auto-type verification, hotkey collision checks, generation-checked async 20s Keychain polling, idle menu-bar clock suppression for HOTP/MD5, and modal-sheet resign guarding.
- Bumped `GLOTP2` `scrypt` work factor to `N = 65536` (64 MiB), enforced 8-char backup passwords in `encode`, rejected unknown numeric/migration algorithms instead of defaulting to SHA-1, hardened CI secret/identifier checks to cover `[:=]` and `GlassOTP.xcodeproj`, and bumped bundle versions (`1.2.0`, build `3`).

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
