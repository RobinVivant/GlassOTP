import SwiftUI

struct BiometricLockOverlay: View {
    @Environment(BiometricLockManager.self) private var security

    var body: some View {
        ZStack {
            AmbientGlassBackground()
                .opacity(0.96)

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 88, height: 88)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .circle)

                VStack(spacing: 6) {
                    Text("GlassOTP Locked")
                        .font(.title2.bold())
                    Text("Authenticate with \(security.biometryDisplayName) to view your codes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let error = security.authErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await security.authenticate(userInitiated: true) }
                } label: {
                    Label("Unlock with \(security.biometryDisplayName)", systemImage: security.biometrySymbolName)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .disabled(security.isAuthenticating)
            }
            .padding(32)
        }
        .accessibilityAddTraits(.isModal)
    }
}
