import AVFoundation
import CoreImage
import GlassOTPCore
import PhotosUI
import SwiftUI
import UIKit

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onParsed: ([OTPAccount]) -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var torchOn = false
    @State private var hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientGlassBackground()

                VStack(spacing: 18) {
                    if hasCamera {
                        cameraViewfinder
                    } else {
                        noCameraFallback
                    }

                    if let errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.footnote)
                            Spacer()
                        }
                        .padding(12)
                        .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Label("Scan from Photo", systemImage: "photo.on.rectangle")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)

                            Button {
                                pasteFromClipboard()
                            } label: {
                                Label("Paste URI", systemImage: "doc.on.clipboard")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if hasCamera {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            torchOn.toggle()
                        } label: {
                            Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task { await decodePhoto(newItem) }
            }
        }
    }

    private var cameraViewfinder: some View {
        ZStack {
            QRCameraPreview(torchOn: torchOn) { code in
                handleScannedString(code)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2.5, dash: [18, 12]))
                .frame(width: 220, height: 220)

            VStack {
                Spacer()
                Text("Point camera at an otpauth:// or Google Authenticator migration QR")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: 440)
    }

    private var noCameraFallback: some View {
        VStack(spacing: 14) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)
            Text("Camera Unavailable")
                .font(.headline)
            Text("Choose a QR screenshot from Photos or copy an otpauth:// link to the clipboard and tap Paste URI below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func handleScannedString(_ code: String) {
        do {
            let accounts = try OTPUriParser.parse(code)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onParsed(accounts)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        guard let str = UIPasteboard.general.string, !str.isEmpty else {
            errorMessage = "Clipboard doesn't contain text."
            return
        }
        handleScannedString(str)
    }

    private func decodePhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data),
                  let ciImage = CIImage(image: uiImage) else {
                errorMessage = "Unable to load selected image."
                return
            }

            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
            let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] ?? []
            guard let payload = features.compactMap(\.messageString).first else {
                errorMessage = "No QR code found in the selected photo."
                return
            }
            handleScannedString(payload)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

private struct QRCameraPreview: UIViewControllerRepresentable {
    let torchOn: Bool
    let onDetected: (String) -> Void

    func makeUIViewController(context: Context) -> CameraScannerController {
        let controller = CameraScannerController()
        controller.onDetected = onDetected
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraScannerController, context: Context) {
        uiViewController.setTorch(torchOn)
    }
}

@MainActor
private final class CameraScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onDetected: ((String) -> Void)?
    private let sessionBox = CaptureSessionBox()
    private let sessionQueue = DispatchQueue(label: "com.robinvivant.glassotp.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmitCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: sessionBox.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let box = sessionBox
        sessionQueue.async {
            if box.session.isRunning {
                box.session.stopRunning()
            }
        }
    }

    func setTorch(_ enabled: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
    }

    private func configureSession() {
        let box = sessionBox
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  box.session.canAddInput(input) else {
                return
            }

            box.session.beginConfiguration()
            box.session.addInput(input)

            let output = AVCaptureMetadataOutput()
            if box.session.canAddOutput(output) {
                box.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                output.metadataObjectTypes = [.qr]
            }
            box.session.commitConfiguration()
            box.session.startRunning()
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        guard let value, !value.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.didEmitCode else { return }
            self.didEmitCode = true
            self.onDetected?(value)
        }
    }
}
