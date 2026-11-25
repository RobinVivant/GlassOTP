# Security Policy

## Architecture Overview

GlassOTP is built for on-device secret storage with zero third-party runtime dependencies and zero analytics or telemetry:

- **Vault Storage:** Accounts and seeds are stored inside Apple's Data Protection Keychain (`kSecUseDataProtectionKeychain`, `kSecAttrAccessibleAfterFirstUnlock`) scoped to the shared Keychain access group (`$(AppIdentifierPrefix)com.robinvivant.glassotp.shared`).
- **On-Device Imports & Backups:** All TOTP/HOTP generation, QR decoding, and backup encryption/decryption (Aegis, 2FAS, OTP Auth, Authenticator Pro legacy, and `.glassotp` RNCryptor v3) run locally on your device. OTP secrets never leave the device except via Apple iCloud Keychain when sync is enabled by the user.
- **Network Requests (Optional):** The only outbound network requests GlassOTP makes are optional service favicon/touch-icon lookups triggered when fetching logos for unmatched domains in `BrandLogoFetcher`.
- **Universal Clipboard Control:** Cross-device clipboard sharing (Handoff) can be toggled off in iOS Settings so widget copies stay local-only and expire after 60 seconds.

## Supported Versions

Security fixes are applied on the latest release branch (`main`):

| Version | Supported |
|---|---|
| `1.1.x` | Yes |
| `< 1.1.0` | No (upgrade to latest) |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities, cryptographic weaknesses, or Keychain/backup bypasses.

Instead, report vulnerabilities privately:

1. Use **GitHub Security Advisories** (`Security` -> `Advisories` -> `Report a vulnerability` on this repository).
2. Include a clear description of the affected component, steps to reproduce (without sharing personal OTP secrets), and potential impact.

I aim to acknowledge reports within 72 hours and coordinate a fix before public disclosure.
