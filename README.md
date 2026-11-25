# GlassOTP

![GlassOTP](assets/github-social-preview.png)

GlassOTP is a native iOS 26+ and macOS 26+ two-factor authenticator (TOTP/HOTP) with Liquid Glass UI, interactive Home and Lock Screen widgets, 1-keystroke macOS menu bar shortcuts, iCloud Keychain sync, and on-device OTP Auth backup import.

## Quickstart

**Prerequisites:** macOS 26+ with Xcode 26+ (tested on Xcode 27.2), an Apple Developer Team for device signing and iCloud Keychain sync, and `xcodegen` (only needed if editing `project.yml`).

Run the core Swift package unit tests:

```bash
cd Packages/GlassOTPCore && swift test
```

Build the iOS app and widget extension for the iOS Simulator:

```bash
xcodebuild -project GlassOTP.xcodeproj \
  -scheme GlassOTP \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  CODE_SIGNING_ALLOWED=NO build
```

Build and install the macOS menu bar companion (`GlassOTPMac`) to `/Applications/GlassOTP.app`:

```bash
xcodebuild -project GlassOTP.xcodeproj \
  -scheme GlassOTPMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/glassotp-mac-dd \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build
ditto /tmp/glassotp-mac-dd/Build/Products/Release/GlassOTP.app /Applications/GlassOTP.app
open /Applications/GlassOTP.app
```

## Key Capabilities

- **iOS App (`GlassOTP`, iOS 26+):** Compact two-column OTP rows with live countdown rings and next-code preview on expiration, pinned favorites, folder filtering using native Liquid Glass controls (`GlassEffectContainer`, `.glassEffect`, `.buttonStyle(.glassProminent)`, `.tabBarMinimizeBehavior(.onScrollDown)`), and optional Face ID / Touch ID lock with auto-lock delay and app-switcher blur.
- **Service Logos & Auto-Categorization:** Offline brand catalog covering 266 services (245 bundled SVG vector paths in `brand_logos.json`), optional web favicon/touch-icon lookup for unmatched domains, manual brand picker, and one-tap auto-categorization into 9 folders (`Dev & Code`, `Cloud & Infra`, `Work`, `Finance & Crypto`, `Security`, `Social & Media`, `Gaming`, `Shopping & Travel`, `Personal`).
- **Interactive Home & Lock Screen Widgets (`GlassOTPWidgetExtension`):** Small, Medium, Large, and Lock Screen (`accessoryRectangular`, `accessoryCircular`, `accessoryInline`) widgets with per-widget account selection, live countdowns, one-tap copy with haptic feedback, optional Tap-to-Reveal (15s) privacy mode, and Universal Clipboard cross-device handoff (with an optional local-only 60s clipboard toggle in Settings).
- **macOS Menu Bar Companion (`GlassOTPMac`, macOS 26+):** Menu bar popover (`LSUIElement`), global quick-search panel, per-account 1-keystroke global shortcuts, optional auto-type into the active field, optional live code pinned in the menu bar, Launch at Login (`SMAppService`), direct encrypted backup import, and macOS Shortcuts support (`CopyMacOTPIntent`).
- **Storage, Sync & Backups (`GlassOTPCore`):** Zero third-party runtime dependencies. Stores accounts in the Apple Data Protection Keychain (`kSecUseDataProtectionKeychain`, `kSecAttrAccessibleAfterFirstUnlock`) with optional iCloud Keychain sync across iPhone and Mac, plus encrypted `.glassotp` backup export and import (RNCryptor v3).

## Importing from OTP Auth (`de.cooperrs.Authenticator`)

iOS isolates each app's private iCloud container by Team ID, so GlassOTP imports OTP Auth's encrypted backup formats directly on-device:

1. **On iPhone:** Open **OTP Auth** -> **Settings** -> **Backups** -> **Export Encrypted Backup** (`.otpauthdb`), tap **Share**, and choose **GlassOTP** (or save to **Files** and open it in GlassOTP's Importer).
2. **From Mac iCloud Drive:** Copy `~/Library/Mobile Documents/iCloud~de~cooperrs~Authenticator/Accounts.otpauthdb` to iCloud Drive / Files (or import it directly in `GlassOTPMac`), and enter your backup password.
3. **QR & Migration Links:** Scan `otpauth://` QR codes from the camera or a photo, or import Google Authenticator `otpauth-migration://` payloads.

Supported formats:

- `.otpauthdb` Backup v1.0 (salted SHA-256 / AES-256-CBC)
- `.otpauthdb` Backup v1.1+ (RNCryptor v3 / PBKDF2-HMAC-SHA1 + HMAC-SHA256 + AES-256-CBC)
- `.otpauth` Single Account v1.1 and v1.2 (RNCryptor v3)
- `.glassotp` portable backups (RNCryptor v3)

## macOS Menu Bar Shortcuts & Sync

| Shortcut / Feature | Behavior |
|---|---|
| `Ctrl+Option+Space` (`⌃⌥Space`) | Opens the floating quick-search panel from any app. Press `Return` to copy the top match or `Cmd+1` through `Cmd+9` (`⌘1`-`⌘9`) for rows 1-9. |
| `Ctrl+Option+1`..`9` (`⌃⌥1`-`⌃⌥9`) or custom shortcut | Copies a bound account's current OTP in one keystroke from any app and displays a brief confirmation HUD. |
| Auto-Type on Direct Shortcut (optional) | Types the OTP digits into the focused input field once modifier keys are released (requires macOS Accessibility permission). |
| Live Menu Bar Code (optional) | Displays one pinned account's current OTP and countdown directly in the macOS menu bar. |

`GlassOTP` and `GlassOTPMac` share the Keychain access group `$(AppIdentifierPrefix)com.robinvivant.glassotp.shared`, so accounts sync automatically between iPhone and Mac when signed with the same Apple Developer Team and Apple Account (with iCloud Keychain enabled).

## Building & Signing

1. Open `GlassOTP.xcodeproj` in Xcode 26+ (or run `xcodegen generate` after changing `project.yml`).
2. Under **Signing & Capabilities**, select your **Apple Developer Team** on **GlassOTP**, **GlassOTPWidgetExtension**, and **GlassOTPMac**.
3. Keep the shared entitlements aligned with your team:
    - App Group (iOS app + widget): `group.com.robinvivant.glassotp`
    - Keychain Access Group (iOS app + widget + macOS app): `$(AppIdentifierPrefix)com.robinvivant.glassotp.shared`
4. Build and run the `GlassOTP` scheme on iPhone or the `GlassOTPMac` scheme on Mac.

## Repository Layout

| Path | Contents |
|---|---|
| `GlassOTP/` | iOS SwiftUI app sources, Liquid Glass views, view models, assets, and entitlements |
| `GlassOTPWidget/` | WidgetKit Home Screen and Lock Screen widgets |
| `Shared/` | Shared AppIntents (`CopyOTPWidgetIntent`, `RevealOTPWidgetIntent`) compiled into both iOS app and widget targets |
| `GlassOTPMac/` | macOS menu bar app (`GlassOTP.app`), Carbon global hotkeys, quick-search panel, confirmation HUD, and `CopyMacOTPIntent` |
| `Packages/GlassOTPCore/` | Shared Swift 6.2 package: Base32, RFC 4226/6238 OTP generation, URI/migration parser, crypto primitives, OTP Auth and `.glassotp` codecs, Data Protection Keychain store, brand catalog (`brand_logos.json`), SVG path parser, categorizer, and unit tests |
| `scripts/generate_brand_catalog.py` | Script to regenerate `brand_logos.json` vector paths and service mappings |
| `project.yml` | XcodeGen project definition for all targets and schemes |
