# Contributing to GlassOTP

Contributions are welcome for bug fixes, new OTP import formats, brand logo mappings, accessibility improvements, and tests.

## Local Development Setup

### Prerequisites

- macOS 26+ with Xcode 27.2+ (tested with Xcode 27.2)
- Swift 6.2+ toolchain (bundled with Xcode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) if you modify `project.yml`
- An Apple Developer Team ID if building for physical iOS devices or signed macOS/iCloud Keychain sync

### Configure Local Signing (Optional for Device Builds)

To run on a physical iPhone or enable iCloud Keychain sync on your own Apple Account without dirtying tracked config files:

1. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` (gitignored):

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

2. Set `DEVELOPMENT_TEAM = YOUR_TEAM_ID` in `Config/Signing.local.xcconfig`.
3. If using your own App Group or bundle identifiers, update `project.yml`, the `.entitlements` files, and `GlassOTPConstants` in `Packages/GlassOTPCore/Sources/GlassOTPCore/KeychainVaultStore.swift`, then run `xcodegen generate`.

### Running Tests & Builds

```bash
# Core package unit tests
cd Packages/GlassOTPCore && swift test

# Unsigned iOS Simulator build
xcodebuild -project GlassOTP.xcodeproj \
  -scheme GlassOTP \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  CODE_SIGNING_ALLOWED=NO build

# Unsigned macOS build
xcodebuild -project GlassOTP.xcodeproj \
  -scheme GlassOTPMac \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
```

## Adding Importers or Brand Logos

- **New Importers:** Implement format detection (`VaultImporter.inspect`) and parsing (`VaultImporter.importFile`) in `Packages/GlassOTPCore/Sources/GlassOTPCore/VaultImporter.swift`, add fixture-free synthetic test cases in `Packages/GlassOTPCore/Tests/GlassOTPCoreTests/VaultImporterTests.swift`, and verify unsupported or encrypted formats return clear, actionable errors.
- **New Brands:** Update `SERVICES` in `scripts/generate_brand_catalog.py`, regenerate `brand_logos.json` (`python3 scripts/generate_brand_catalog.py`), and run `swift test` so `BrandAndCategorizerTests` validates every SVG path.

## Pull Request Guidelines

- Keep `Swift 6` strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`) warning-free.
- Never commit personal OTP backups, Apple Developer Team IDs, device UDIDs, provisioning profiles, or signing certificates.
- Add or update unit tests in `Packages/GlassOTPCore/Tests/GlassOTPCoreTests/` for every core logic or importer change.
- Run `swift test` and confirm both `GlassOTP` and `GlassOTPMac` compile before opening a PR.
