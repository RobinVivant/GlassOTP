import GlassOTPCore
import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (56, 189, 248)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }
}

struct AmbientGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(hex: "#060B16"),
                        Color(hex: "#0B1326"),
                        Color(hex: "#081C2B"),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [Color(hex: "#22D3EE").opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 420
                )

                RadialGradient(
                    colors: [Color(hex: "#6366F1").opacity(0.20), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 460
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(hex: "#EEF6FF"),
                        Color(hex: "#F4F7FB"),
                        Color(hex: "#E6F2F8"),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [Color(hex: "#38BDF8").opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 420
                )

                RadialGradient(
                    colors: [Color(hex: "#818CF8").opacity(0.16), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 440
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct BrandAvatarView: View {
    let style: OTPBrandStyle
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: style.accentHex), Color(hex: style.secondaryHex)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                )

            Image(systemName: style.symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .frame(width: size, height: size)
    }
}

struct CountdownRingView: View {
    let remainingSeconds: TimeInterval
    let progress: Double
    var size: CGFloat = 34

    private var ringColor: Color {
        if remainingSeconds <= 5 {
            return .red
        } else if remainingSeconds <= 8 {
            return .orange
        } else {
            return Color(hex: "#38BDF8")
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: 3.2)

            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)

            Text("\(max(0, Int(ceil(remainingSeconds))))")
                .font(.system(size: size * 0.33, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(remainingSeconds <= 5 ? ringColor : .secondary)
        }
        .frame(width: size, height: size)
    }
}

struct FloatingCopyToast: View {
    let toast: CopiedToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                Text("Copied \(toast.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(toast.formattedCode)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.green.opacity(0.14)), in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
