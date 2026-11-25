import AppKit
import GlassOTPCore
import SwiftUI

@MainActor
final class CopyHUDController {
    static let shared = CopyHUDController()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var presentationToken = UUID()

    private init() {}

    func show(account: OTPAccount, formattedCode: String, remainingSeconds: Int?, didAutoType: Bool) {
        dismissTask?.cancel()
        let token = UUID()
        presentationToken = token

        let hudView = CopyHUDCardView(
            account: account,
            formattedCode: formattedCode,
            remainingSeconds: remainingSeconds,
            didAutoType: didAutoType
        )
        let hostingView = NSHostingView(rootView: hudView)
        let fittingSize = hostingView.fittingSize
        let width = max(250, fittingSize.width)
        let height = max(54, fittingSize.height)

        let hudPanel = ensurePanel()
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        hudPanel.contentView = hostingView
        hudPanel.setContentSize(NSSize(width: width, height: height))

        let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let visible = screen.visibleFrame
            let originX = visible.midX - width / 2.0
            let originY = visible.maxY - height - 28.0
            hudPanel.setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        hudPanel.alphaValue = 0
        hudPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            hudPanel.animator().alphaValue = 1
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled,
                  let self,
                  self.presentationToken == token,
                  let panel = self.panel else {
                return
            }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.22
                    panel.animator().alphaValue = 0
                },
                completionHandler: { [weak self, weak panel] in
                    Task { @MainActor in
                        guard let self, self.presentationToken == token else { return }
                        panel?.orderOut(nil)
                    }
                }
            )
        }
    }

    private func ensurePanel() -> NSPanel {
        if let existing = panel {
            return existing
        }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = newPanel
        return newPanel
    }
}

private struct CopyHUDCardView: View {
    let account: OTPAccount
    let formattedCode: String
    let remainingSeconds: Int?
    let didAutoType: Bool

    var body: some View {
        HStack(spacing: 10) {
            MacBrandBadgeView(account: account, size: 30)
                .equatable()

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: didAutoType ? "keyboard.fill" : "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                    Text(didAutoType ? "Typed & Copied \(account.displayTitle)" : "Copied \(account.displayTitle)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(formattedCode)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            if let remainingSeconds {
                Text("\(remainingSeconds)s")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(remainingSeconds <= 5 ? Color.red : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.75), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
    }
}
