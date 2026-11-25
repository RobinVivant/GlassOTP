import GlassOTPCore
import SwiftUI
import UIKit

@MainActor
private final class PrivacyCoverController {
    private var coverWindow: UIWindow?
    private var lastLocked: Bool?
    private var lastBlurred: Bool?

    func update(isLocked: Bool, isBlurred: Bool, security: BiometricLockManager) {
        let shouldShow = isLocked || isBlurred
        if lastLocked == isLocked && lastBlurred == isBlurred && (coverWindow != nil) == shouldShow {
            return
        }

        guard shouldShow else {
            lastLocked = isLocked
            lastBlurred = isBlurred
            coverWindow?.isHidden = true
            coverWindow?.isUserInteractionEnabled = false
            return
        }

        let window: UIWindow
        if let existing = coverWindow {
            window = existing
        } else if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached }) {
            let created = UIWindow(windowScene: scene)
            created.windowLevel = UIWindow.Level(rawValue: 500)
            created.backgroundColor = .clear
            coverWindow = created
            window = created
        } else {
            return
        }

        lastLocked = isLocked
        lastBlurred = isBlurred

        let rootView: AnyView
        if isLocked {
            rootView = AnyView(BiometricLockOverlay().environment(security))
        } else {
            rootView = AnyView(
                ZStack {
                    AmbientGlassBackground().opacity(0.98)
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            )
        }

        if let host = window.rootViewController as? UIHostingController<AnyView> {
            host.rootView = rootView
        } else {
            let host = UIHostingController(rootView: rootView)
            host.view.backgroundColor = .clear
            window.rootViewController = host
        }

        window.isUserInteractionEnabled = isLocked
        window.isHidden = false
    }
}

@main
struct GlassOTPApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vault = VaultViewModel()
    @State private var security = BiometricLockManager()
    @State private var clock = OTPClock()
    @State private var privacyCover = PrivacyCoverController()

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environment(vault)
                    .environment(security)
                    .environment(clock)
                    .opacity(security.isLocked ? 0 : 1)
                    .allowsHitTesting(!security.isLocked)
                    .accessibilityHidden(security.isLocked)
                    .blur(radius: shouldBlurContent ? 18 : 0)

                if security.isLocked {
                    BiometricLockOverlay()
                        .environment(security)
                }
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-seed") {
                    vault.seedDemoDataIfNeeded()
                }
                if ProcessInfo.processInfo.arguments.contains("--open-auto-categorize") {
                    vault.showingAutoCategorizeSheet = true
                }
                #endif
                clock.setActive(scenePhase == .active && !security.isLocked)
                syncPrivacyCover()
                await security.unlockOnLaunchIfNeeded()
            }
            .onOpenURL { url in
                let lockedNow = security.isLocked || security.shouldLockOnActivation()
                vault.handleIncomingURL(url, isLocked: lockedNow)
            }
            .onChange(of: scenePhase) { _, newPhase in
                security.handleScenePhaseChange(newPhase)
                let isActive = newPhase == .active
                clock.setActive(isActive && !security.isLocked)
                syncPrivacyCover()

                if isActive {
                    vault.reloadFromStore()
                    if !security.isLocked {
                        vault.commitPendingForegroundCopyIfNeeded()
                        vault.processPendingIncomingURLIfUnlocked(isLocked: false)
                    }
                }
            }
            .onChange(of: security.isLocked) { _, isLocked in
                clock.setActive(scenePhase == .active && !isLocked)
                syncPrivacyCover()
                if isLocked {
                    vault.dismissSensitivePresentationsForLock()
                } else if scenePhase == .active {
                    vault.commitPendingForegroundCopyIfNeeded()
                    vault.processPendingIncomingURLIfUnlocked(isLocked: false)
                }
            }
        }
    }

    private var shouldBlurContent: Bool {
        security.isLocked
            || (scenePhase != .active
                && !security.isAuthenticating
                && (security.appSwitcherBlurEnabled || (security.biometricLockEnabled && security.autoLockDelaySeconds == 0)))
    }

    private func syncPrivacyCover() {
        let shouldBlur = scenePhase != .active
            && !security.isAuthenticating
            && (security.appSwitcherBlurEnabled || (security.biometricLockEnabled && security.autoLockDelaySeconds == 0))
        privacyCover.update(
            isLocked: security.isLocked,
            isBlurred: shouldBlur,
            security: security
        )
    }
}
