import Foundation
import GlassOTPCore
import LocalAuthentication
import Observation
import SwiftUI
import WidgetKit

@MainActor
@Observable
final class BiometricLockManager {
    var isLocked = false
    var isAuthenticating = false
    var authErrorMessage: String?

    var biometricLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(biometricLockEnabled, forKey: Self.lockEnabledKey)
            SharedSecurityPreferences.isAppLockEnabled = biometricLockEnabled
            if !biometricLockEnabled {
                isLocked = false
                backgroundedAt = nil
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    var appSwitcherBlurEnabled: Bool {
        didSet {
            UserDefaults.standard.set(appSwitcherBlurEnabled, forKey: Self.blurEnabledKey)
        }
    }

    var autoLockDelaySeconds: Int {
        didSet {
            UserDefaults.standard.set(autoLockDelaySeconds, forKey: Self.autoLockDelayKey)
        }
    }

    private var backgroundedAt: Date?
    private var suppressAutoAuthUntilBackground = false
    private static let lockEnabledKey = "glassotp.biometric.lockEnabled"
    private static let blurEnabledKey = "glassotp.privacy.appSwitcherBlur"
    private static let autoLockDelayKey = "glassotp.biometric.autoLockDelay"

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.blurEnabledKey) == nil {
            defaults.set(true, forKey: Self.blurEnabledKey)
        }
        if defaults.object(forKey: Self.autoLockDelayKey) == nil {
            defaults.set(30, forKey: Self.autoLockDelayKey)
        }
        let lockEnabled = defaults.bool(forKey: Self.lockEnabledKey)
        self.biometricLockEnabled = lockEnabled
        self.appSwitcherBlurEnabled = defaults.bool(forKey: Self.blurEnabledKey)
        self.autoLockDelaySeconds = defaults.integer(forKey: Self.autoLockDelayKey)
        let wasInitialized = SharedSecurityPreferences.isAppLockPreferenceInitialized
        let previousSharedLock = SharedSecurityPreferences.isAppLockEnabled
        SharedSecurityPreferences.isAppLockEnabled = lockEnabled
        if !wasInitialized || previousSharedLock != lockEnabled {
            WidgetCenter.shared.reloadAllTimelines()
        }
        if lockEnabled {
            isLocked = true
        }
    }

    var biometryDisplayName: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        switch context.biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        default:
            return "Passcode"
        }
    }

    var biometrySymbolName: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        switch context.biometryType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .opticID:
            return "opticid"
        default:
            return "lock.fill"
        }
    }

    func canEvaluateDeviceAuthentication() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func shouldLockOnActivation(now: Date = Date()) -> Bool {
        guard biometricLockEnabled else { return false }
        if isLocked { return true }
        guard let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= TimeInterval(autoLockDelaySeconds)
    }

    func unlockOnLaunchIfNeeded() async {
        guard isLocked else { return }
        await authenticate()
    }

    func authenticate(userInitiated: Bool = false) async {
        guard biometricLockEnabled else {
            isLocked = false
            backgroundedAt = nil
            suppressAutoAuthUntilBackground = false
            return
        }
        if userInitiated {
            suppressAutoAuthUntilBackground = false
        }
        guard isLocked, !isAuthenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = true
            suppressAutoAuthUntilBackground = true
            authErrorMessage = error?.localizedDescription
                ?? "Set a device passcode or enable \(biometryDisplayName) in iOS Settings to unlock."
            return
        }

        isAuthenticating = true
        authErrorMessage = nil
        defer { isAuthenticating = false }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your GlassOTP authenticator vault"
            )
            if success {
                suppressAutoAuthUntilBackground = false
                backgroundedAt = nil
                authErrorMessage = nil
                withAnimation(.easeOut(duration: 0.2)) {
                    isLocked = false
                }
            } else {
                suppressAutoAuthUntilBackground = true
            }
        } catch let laError as LAError where laError.code == .userCancel || laError.code == .systemCancel {
            suppressAutoAuthUntilBackground = true
            authErrorMessage = "Authentication canceled."
        } catch {
            suppressAutoAuthUntilBackground = true
            authErrorMessage = error.localizedDescription
        }
    }

    func verifyDeviceOwner(reason: String) async -> (succeeded: Bool, errorMessage: String?) {
        guard !isAuthenticating else { return (false, nil) }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (
                false,
                error?.localizedDescription
                    ?? "Set a device passcode or enable \(biometryDisplayName) in iOS Settings."
            )
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return (ok, ok ? nil : "Authentication failed.")
        } catch let laError as LAError where laError.code == .userCancel || laError.code == .systemCancel {
            return (false, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            guard biometricLockEnabled, !isAuthenticating else { return }
            if let backgroundedAt,
               Date().timeIntervalSince(backgroundedAt) >= TimeInterval(autoLockDelaySeconds) {
                isLocked = true
            }
        case .background:
            guard biometricLockEnabled else { return }
            suppressAutoAuthUntilBackground = false
            backgroundedAt = Date()
            if autoLockDelaySeconds == 0 {
                isLocked = true
            }
        case .active:
            guard biometricLockEnabled else {
                isLocked = false
                backgroundedAt = nil
                suppressAutoAuthUntilBackground = false
                return
            }
            if !isAuthenticating, let backgroundedAt {
                let elapsed = Date().timeIntervalSince(backgroundedAt)
                if elapsed >= TimeInterval(autoLockDelaySeconds) {
                    isLocked = true
                }
                self.backgroundedAt = nil
            }
            if isLocked && !isAuthenticating && !suppressAutoAuthUntilBackground {
                Task { await authenticate() }
            }
        @unknown default:
            break
        }
    }
}
