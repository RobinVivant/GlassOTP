import GlassOTPCore
import SwiftUI

@main
struct GlassOTPApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vault = VaultViewModel()
    @State private var security = BiometricLockManager()

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environment(vault)
                    .environment(security)
                    .blur(radius: shouldBlurContent ? 18 : 0)
                    .animation(.easeOut(duration: 0.2), value: shouldBlurContent)

                if security.isLocked {
                    BiometricLockOverlay()
                        .environment(security)
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                }
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--demo-seed") {
                    vault.seedDemoDataIfNeeded()
                }
                await security.unlockOnLaunchIfNeeded()
            }
            .onOpenURL { url in
                vault.handleIncomingURL(url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                security.handleScenePhaseChange(newPhase)
            }
        }
    }

    private var shouldBlurContent: Bool {
        security.isLocked || (security.appSwitcherBlurEnabled && scenePhase != .active)
    }
}
