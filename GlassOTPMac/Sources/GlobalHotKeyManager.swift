import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeyManager {
    private enum Action {
        case quickPicker
        case account(UUID)
    }

    private static let signature: OSType = 0x474F_5450 // 'GOTP'
    private var eventHandlerRef: EventHandlerRef?
    private var registeredRefs: [UInt32: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: Action] = [:]

    var isPaused = false
    var onQuickPicker: (() -> Void)?
    var onAccountHotKey: ((UUID) -> Void)?

    init() {
        installHandler()
    }

    func register(quickPicker: HotKeyCombo?, accountHotKeys: [UUID: HotKeyCombo]) {
        unregisterAll()

        if let quickPicker {
            registerHotKey(id: 1, combo: quickPicker, action: .quickPicker)
        }

        let sortedAccounts = accountHotKeys.sorted { $0.key.uuidString < $1.key.uuidString }
        var nextID: UInt32 = 100
        for (accountID, combo) in sortedAccounts {
            registerHotKey(id: nextID, combo: combo, action: .account(accountID))
            nextID += 1
        }
    }

    func unregisterAll() {
        for (_, ref) in registeredRefs {
            UnregisterEventHotKey(ref)
        }
        registeredRefs.removeAll()
        idToAction.removeAll()
    }

    private func installHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard paramStatus == noErr, hotKeyID.signature == GlobalHotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let triggeredID = hotKeyID.id
                MainActor.assumeIsolated {
                    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.handleHotKey(id: triggeredID)
                }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &handlerRef
        )
        if status == noErr {
            self.eventHandlerRef = handlerRef
        }
    }

    private func registerHotKey(id: UInt32, combo: HotKeyCombo, action: Action) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            registeredRefs[id] = hotKeyRef
            idToAction[id] = action
        }
    }

    private func handleHotKey(id: UInt32) {
        guard !isPaused, let action = idToAction[id] else { return }
        switch action {
        case .quickPicker:
            onQuickPicker?()
        case .account(let accountID):
            onAccountHotKey?(accountID)
        }
    }
}
