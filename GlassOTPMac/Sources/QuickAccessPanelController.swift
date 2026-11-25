import AppKit
import SwiftUI

private final class FloatingKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickAccessPanelController: NSObject, NSWindowDelegate {
    enum Anchor {
        case statusItem(NSStatusBarButton)
        case centerUpperThird
    }

    private var panel: FloatingKeyPanel?
    private weak var vault: MacVaultViewModel?
    private var previousFrontmostApp: NSRunningApplication?
    private var suppressNextResignDismiss = false

    private let panelSize = NSSize(width: 382, height: 486)

    func toggle(anchor: Anchor, vault: MacVaultViewModel) {
        if let panel, panel.isVisible {
            dismiss(restorePreviousApp: true)
            return
        }
        show(anchor: anchor, vault: vault)
    }

    func show(anchor: Anchor, vault: MacVaultViewModel) {
        self.vault = vault

        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousFrontmostApp = front
        }

        vault.reloadFromStore()
        vault.selectedAccountIndex = 0
        vault.clock.setActive(true, reason: "popover")
        vault.focusSearchToken &+= 1

        let hostPanel = ensurePanel(vault: vault)
        position(panel: hostPanel, anchor: anchor)

        suppressNextResignDismiss = true
        NSApp.activate(ignoringOtherApps: true)
        hostPanel.makeKeyAndOrderFront(nil)
        hostPanel.makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.suppressNextResignDismiss = false
        }
    }

    func runWithSuppressedResign<T>(_ action: () -> T) -> T {
        suppressNextResignDismiss = true
        let result = action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.suppressNextResignDismiss = false
        }
        return result
    }

    func dismiss(restorePreviousApp: Bool) {
        panel?.orderOut(nil)
        vault?.clock.setActive(false, reason: "popover")
        vault?.showingSettings = false
        if restorePreviousApp {
            let appToRestore = previousFrontmostApp
            previousFrontmostApp = nil
            appToRestore?.activate()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressNextResignDismiss,
              panel?.attachedSheet == nil,
              NSApp.modalWindow == nil else {
            return
        }
        dismiss(restorePreviousApp: false)
    }

    private func ensurePanel(vault: MacVaultViewModel) -> FloatingKeyPanel {
        if let existing = panel {
            return existing
        }
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let created = FloatingKeyPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .popUpMenu
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        created.delegate = self

        let rootView = MenuBarPopoverView(
            vault: vault,
            onDismiss: { [weak self] restoreFocus in
                self?.dismiss(restorePreviousApp: restoreFocus)
            },
            onPickImportURL: { [weak self] panel in
                self?.runWithSuppressedResign { panel.runModal() == .OK ? panel.url : nil }
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        created.contentView = hostingView
        self.panel = created
        return created
    }

    private func position(panel: NSPanel, anchor: Anchor) {
        switch anchor {
        case .statusItem(let button):
            guard let buttonWindow = button.window else {
                positionCenteredUpperThird(panel: panel)
                return
            }
            let buttonRectInWindow = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRectInWindow)
            let screen = buttonWindow.screen
                ?? NSScreen.screens.first { $0.frame.intersects(screenRect) }
                ?? NSScreen.main
            guard let visible = screen?.visibleFrame else {
                positionCenteredUpperThird(panel: panel)
                return
            }

            var originX = screenRect.midX - panelSize.width / 2.0
            originX = max(visible.minX + 8.0, min(originX, visible.maxX - panelSize.width - 8.0))
            let originY = max(visible.minY + 8.0, screenRect.minY - panelSize.height - 6.0)
            panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: panelSize), display: true)

        case .centerUpperThird:
            positionCenteredUpperThird(panel: panel)
        }
    }

    private func positionCenteredUpperThird(panel: NSPanel) {
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = mouseScreen?.visibleFrame else { return }
        let originX = visible.midX - panelSize.width / 2.0
        let topOffset = min(130.0, visible.height * 0.14)
        let originY = max(visible.minY + 16.0, visible.maxY - topOffset - panelSize.height)
        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: panelSize), display: true)
    }
}
