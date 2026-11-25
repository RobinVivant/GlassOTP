# Security Policy

## Architecture Overview

GlassOTP is built for on-device secret storage with zero third-party runtime dependencies and zero analytics or telemetry:

- **Vault Storage:** Accounts and seeds are stored inside Apple's Data Protection Keychain (`kSecUseDataProtectionKeychain`) scoped to the shared Keychain access group (`$(AppIdentifierPrefix)com.robinvivant.glassotp.shared`). Local-only storage uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and iCloud-synced storage uses `kSecAttrAccessibleAfterFirstUnlock`.
- **On-Device Imports & Backups:** All TOTP/HOTP generation, QR decoding, and backup encryption/decryption (Aegis, 2FAS, OTP Auth, Authenticator Pro legacy, and `.glassotp` `GLOTP2` using `scrypt` + AES-256-GCM with backward-compatible `GLOTP1` `RNCryptor v3` decode) run locally on your device. OTP secrets never leave the device except via Apple iCloud Keychain when sync is enabled by the user.
- **Lock Screen & App Lock:** Biometric/passcode app lock fails closed and shields modal sheets with a dedicated overlay window; interactive Lock Screen widget copy and reveal actions enforce device authentication (`IntentAuthenticationPolicy.requiresAuthentication`) and `.privacySensitive()` redaction.
- **Network Requests (Optional):** The only outbound network requests GlassOTP makes are explicit user-triggered website icon/favicon lookups (`BrandLogoFetcher`) for public DNS hostnames, with HTTPS-only redirect validation and no email-domain or heuristic domain guessing.
- **Clipboard Hygiene:** Universal Clipboard handoff expires after 2 minutes when enabled, local widget/app copies expire after 60 seconds, and macOS copies tag `ConcealedType` / `TransientType` and auto-clear after 60 seconds.

## Supported Versions

Security fixes are applied on the latest release branch (`main`):

| Version | Supported |
|---|---|
| `1.2.x` | Yes |
| `< 1.2.0` | No (upgrade to latest) |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities, cryptographic weaknesses, or Keychain/backup bypasses.

Instead, report vulnerabilities privately:

1. Use **GitHub Security Advisories** (`Security` -> `Advisories` -> `Report a vulnerability` on this repository).
2. Include a clear description of the affected component, steps to reproduce (without sharing personal OTP secrets), and potential impact.

I aim to acknowledge reports within 72 hours and coordinate a fix before public disclosure.
