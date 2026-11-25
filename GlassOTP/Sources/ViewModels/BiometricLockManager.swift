import Foundation
import LocalAuthentication
import Observation
import SwiftUI

@MainActor
@Observable
final class BiometricLockManager {
    var isLocked = false
    var isAuthenticating = false
    var authErrorMessage: String?

    var biometricLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(biometricLockEnabled, forKey: Self.lockEnabledKey)
            if !biometricLockEnabled {
                isLocked = false
            }
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
        self.biometricLockEnabled = defaults.bool(forKey: Self.lockEnabledKey)
        self.appSwitcherBlurEnabled = defaults.bool(forKey: Self.blurEnabledKey)
        self.autoLockDelaySeconds = defaults.integer(forKey: Self.autoLockDelayKey)
        if biometricLockEnabled {
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

    func authenticate() async {
        guard biometricLockEnabled else {
            isLocked = false
            return
        }
        guard !isAuthenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = true
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
                withAnimation(.easeOut(duration: 0.2)) {
                    isLocked = false
                }
            }
        } catch let laError as LAError where laError.code == .userCancel || laError.code == .systemCancel {
            authErrorMessage = "Authentication canceled."
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            guard biometricLockEnabled else { return }
            if backgroundedAt == nil {
                backgroundedAt = Date()
            }
            if autoLockDelaySeconds == 0 {
                isLocked = true
            }
        case .background:
            guard biometricLockEnabled else { return }
            if backgroundedAt == nil {
                backgroundedAt = Date()
            }
            if autoLockDelaySeconds == 0 {
                isLocked = true
            }
        case .active:
            guard biometricLockEnabled else {
                isLocked = false
                backgroundedAt = nil
                return
            }
            if let backgroundedAt {
                let elapsed = Date().timeIntervalSince(backgroundedAt)
                if elapsed >= TimeInterval(autoLockDelaySeconds) {
                    isLocked = true
                }
                self.backgroundedAt = nil
            }
            if isLocked {
                Task { await authenticate() }
            }
        @unknown default:
            break
        }
    }
}
