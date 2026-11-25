# GlassOTP

![GlassOTP](assets/github-social-preview.png)

A modern iOS 26 / iOS 27 two-factor authentication (TOTP/HOTP) app featuring native **Liquid Glass** UI, interactive Home & Lock Screen widgets, Face ID / Touch ID vault protection, iCloud Keychain sync, and seamless **100% on-device migration from OTP Auth** (`.otpauthdb` & `.otpauth`).

## Importing from OTP Auth (`de.cooperrs.Authenticator`)

iOS isolates each app's private iCloud container by Team ID, so GlassOTP imports your OTP Auth vault securely using OTP Auth's documented encrypted backup format:

1. **On iPhone (recommended):** Open **OTP Auth** → **Settings** → **Backups** → **Export Encrypted Backup** (`.otpauthdb`), tap **Share**, and choose **GlassOTP** (or save to **Files** and open it inside GlassOTP's Importer).
2. **From Mac iCloud Drive:** Copy `~/Library/Mobile Documents/iCloud~de~cooperrs~Authenticator/Accounts.otpauthdb` into iCloud Drive / Files, pick it in GlassOTP, and enter your backup password.
3. **QR / Migration Links:** Scan `otpauth://` QR codes with the camera or from a photo screenshot, or import Google Authenticator `otpauth-migration://` payloads.

### Supported OTP Auth Formats
- `.otpauthdb` Backup v1.0 (salted SHA-256 / AES-256-CBC)
- `.otpauthdb` Backup v1.1+ (RNCryptor v3 / PBKDF2-HMAC-SHA1 + HMAC-SHA256 + AES-256-CBC)
- `.otpauth` Single Account v1.1 and v1.2 (RNCryptor v3)

## Features
- **Native Liquid Glass UI (`iOS 26+`)**: Morphing `GlassEffectContainer` folder filters, `.glassEffect` capsules, `.buttonStyle(.glassProminent)` actions, and `.tabBarMinimizeBehavior(.onScrollDown)`.
- **Interactive Widgets (`WidgetKit` + `AppIntents`)**: Small, Medium, Large, and Lock Screen (`accessoryRectangular`, `accessoryCircular`, `accessoryInline`) widgets with live countdowns, one-tap **Copy** button, per-widget account selection, and optional **Tap-to-Reveal (15s)** privacy mode.
- **Security**: Universal Clipboard cross-device OTP copy (with optional local-only 60s mode), optional Face ID / Touch ID lock with auto-lock delay, app-switcher blur, and Keychain storage (`kSecAttrAccessibleAfterFirstUnlock` + optional `iCloud Keychain` sync).
- **Encrypted Export**: Export portable `.glassotp` backups protected with RNCryptor v3.
- **macOS Menu Bar Companion (`GlassOTPMac`)**: Syncs automatically with iPhone via iCloud Data Protection Keychain (`kSecUseDataProtectionKeychain`), adds 1-keystroke global shortcuts per OTP account, `⌃⌥Space` Spotlight-style search popover, optional auto-type, live menu bar countdown/code display, and macOS Shortcuts (`CopyMacOTPIntent`).

## Building & Running on Your iPhone & Mac

1. Open `GlassOTP.xcodeproj` in Xcode 26+ (or Xcode 27.2).
2. Select your **Apple Developer Team** under **Signing & Capabilities** on both **GlassOTP** and **GlassOTPWidgetExtension** targets so iOS provisions the shared App Group (`group.com.robinvivant.glassotp`) and shared Keychain Access Group (`$(AppIdentifierPrefix)com.robinvivant.glassotp.shared`).
3. Build and run on your iPhone.

### CLI Build & Unit Tests
```bash
# Run core cryptographic & importer tests
cd Packages/GlassOTPCore && swift test

# Regenerate Xcode project from project.yml (if edited)
xcodegen generate

# Build app + widget extension for iOS Simulator
xcodebuild -project GlassOTP.xcodeproj \
  -scheme GlassOTP \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  CODE_SIGNING_ALLOWED=NO build
```
