import AppKit
import GlassOTPCore
import SwiftUI

@main
struct GlassOTPMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vault = MacVaultViewModel()
    let panelController = QuickAccessPanelController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupHotKeyCallbacks()
        startMenuBarObservation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        vault.hotKeyManager.unregisterAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            vault.handleIncomingURL(url)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "GlassOTP")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.target = self
            button.action = #selector(toggleFromStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func setupHotKeyCallbacks() {
        vault.hotKeyManager.onQuickPicker = { [weak self] in
            guard let self else { return }
            self.panelController.toggle(anchor: .centerUpperThird, vault: self.vault)
        }
        vault.hotKeyManager.onAccountHotKey = { [weak self] accountID in
            self?.vault.handleAccountHotKey(accountID)
        }
    }

    private func startMenuBarObservation() {
        withObservationTracking {
            updateStatusItemAppearance()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.startMenuBarObservation()
            }
        }
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        if let pinnedID = vault.menuBarAccountID,
           let account = vault.accounts.first(where: { $0.id == pinnedID }) {
            let snapshot = OTPGenerator.snapshot(for: account, at: vault.clock.now, includeNextCode: false)
            if account.type == .totp {
                let remaining = max(0, Int(ceil(snapshot.remainingSeconds)))
                button.title = " \(snapshot.formattedCode) • \(remaining)s"
            } else {
                button.title = " \(snapshot.formattedCode)"
            }
            button.toolTip = "\(account.displayTitle) • GlassOTP"
        } else {
            button.title = ""
            button.toolTip = "GlassOTP (\(vault.quickPickerHotKey?.displayString ?? "Menu Bar"))"
        }
    }

    @objc private func toggleFromStatusItem(_ sender: NSStatusBarButton) {
        panelController.toggle(anchor: .statusItem(sender), vault: vault)
    }
}
