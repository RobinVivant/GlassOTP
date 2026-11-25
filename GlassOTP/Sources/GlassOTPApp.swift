import GlassOTPCore
import SwiftUI

@main
struct GlassOTPApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vault = VaultViewModel()
    @State private var security = BiometricLockManager()
    @State private var clock = OTPClock()

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environment(vault)
                    .environment(security)
                    .environment(clock)
                    .blur(radius: shouldBlurContent ? 18 : 0)
                    .animation(.easeOut(duration: 0.2), value: shouldBlurContent)

                if security.isLocked {
                    BiometricLockOverlay()
                        .environment(security)
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
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
                await security.unlockOnLaunchIfNeeded()
            }
            .onOpenURL { url in
                vault.handleIncomingURL(url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                let isActive = newPhase == .active
                clock.setActive(isActive)
                if isActive {
                    vault.commitPendingForegroundCopyIfNeeded()
                }
                security.handleScenePhaseChange(newPhase)
            }
        }
    }

    private var shouldBlurContent: Bool {
        security.isLocked || (security.appSwitcherBlurEnabled && scenePhase != .active)
    }
}
