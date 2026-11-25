import CoreImage.CIFilterBuiltins
import GlassOTPCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AccountQRDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: OTPAccount

    @State private var copiedKind: String?

    private var otpauthURI: String {
        OTPUriParser.toURI(account)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackground()

                VStack(spacing: 20) {
                    VStack(spacing: 14) {
                        BrandAvatarView(account: account, size: 52, logoRevision: 0)
                        Text(account.displayTitle)
                            .font(.title3.bold())
                        if !account.displaySubtitle.isEmpty {
                            Text(account.displaySubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if let qrImage = generateQRCode(from: otpauthURI) {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 220, height: 220)
                                .padding(14)
                                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button {
                                copySensitive(otpauthURI, label: "URI")
                            } label: {
                                Label(copiedKind == "URI" ? "Copied URI" : "Copy URI", systemImage: "link")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)

                            Button {
                                copySensitive(Base32.encode(account.secret), label: "Secret")
                            } label: {
                                Label(copiedKind == "Secret" ? "Copied Secret" : "Copy Secret", systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)
                        }
                    }

                    Text("Keep this QR code private — anyone with it can generate your 2FA codes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .navigationTitle("Export Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func copySensitive(_ value: String, label: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copiedKind = label
    }

    private func generateQRCode(from text: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = outputImage.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
