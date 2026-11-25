# Security Policy

## Architecture Overview

GlassOTP is built for on-device secret storage with zero third-party runtime dependencies and zero analytics or telemetry:

- **Vault Storage:** Accounts and seeds are stored inside Apple's Data Protection Keychain (`kSecUseDataProtectionKeychain`) scoped to the shared Keychain access group (`$(AppIdentifierPrefix)com.robinvivant.glassotp.shared`) and coordinated via fail-closed POSIX `flock` across iOS app and widget processes. When iCloud Keychain sync is enabled, a `ThisDeviceOnly` local replica (`local-replica-v1`) reconciles concurrent multi-device writes alongside ID-retained deletion tombstones and integer-millisecond ISO-8601 timestamps; if an unreadable `local-replica-v1` is replaced while a readable cloud or local vault is available, its raw bytes are archived into content-addressed `ThisDeviceOnly` quarantine items (`local-replica-quarantine-v1.<hash>`, retaining up to the 3 most recent distinct payloads and deleting older slots) before rebuilding the replica. Advance a given HOTP counter on one device at a time when syncing across iPhone and Mac. Disabling iCloud sync with cloud deletion writes a logical-generation synchronizable empty retirement record (`cloudRetiredAtMillis` / `cloudSyncGenerationMillis`) to `primary-vault-v1` and deletes decodable `local-replica-v1` so devices running GlassOTP 1.2 or later switch to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` local storage with the vault they last loaded (update and open all peers before deleting the iCloud copy).
- **On-Device Imports & Backups:** All TOTP/HOTP generation, QR decoding, and backup encryption/decryption (Aegis, 2FAS, OTP Auth, Authenticator Pro legacy, and `.glassotp` `GLOTP2` using 64 MiB `scrypt` + AES-256-GCM with an 8-character passphrase minimum and backward-compatible `GLOTP1` `RNCryptor v3` decode) run locally on your device. OTP secrets never leave the device except via Apple iCloud Keychain when sync is enabled by the user.
- **Lock Screen & App Lock:** Biometric/passcode app lock fails closed, checks device authentication availability to enable and requires device-owner authentication to disable, shields modal sheets with a dedicated overlay window, and gates Home and Lock Screen widgets by keeping masked codes locked and opening GlassOTP for authentication instead of running background reveal/copy intents; when App Lock is off, interactive Lock Screen widget copy and reveal actions enforce device authentication (`IntentAuthenticationPolicy.requiresAuthentication`) and `.privacySensitive()` redaction.
- **Network Requests (Optional):** The only outbound network requests GlassOTP makes are explicit user-triggered favicon lookups (`BrandLogoFetcher`) via Google Favicons (`www.google.com/s2/favicons`) for explicit custom domains or public issuer hostnames (no email-domain or heuristic domain guessing), with HTTPS port-443 redirect validation limited to Google hosts, a 3-redirect cap, and a streaming 512 KiB size limit.
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
