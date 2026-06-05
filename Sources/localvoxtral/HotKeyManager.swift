import Carbon.HIToolbox
import Foundation

@MainActor
final class HotKeyManager {
    enum RegistrationFailure {
        case handlerInstallFailed
        case shortcutUnavailable
    }

    enum RegistrationResult {
        case success
        case failure(RegistrationFailure)
    }

    static let handlerRegistrationErrorMessage = "Failed to register global hotkey handler."
    static let registrationErrorStatus = "Failed to register global hotkey."
    static let unavailableErrorMessage = "The selected keyboard shortcut is unavailable."

    var onPress: ((UInt32) -> Void)?
    var onRelease: ((UInt32) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyHandlerRef: EventHandlerRef?
    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private nonisolated(unsafe) static weak var hotKeyTarget: HotKeyManager?

    init() {
        Self.hotKeyTarget = self
    }

    /// Registers a global hotkey for the given shortcut.
    /// Returns `.success` when registration succeeds (including when shortcut is nil).
    @discardableResult
    func register(shortcut: DictationShortcut?) -> RegistrationResult {
        register(shortcuts: [1: shortcut])
    }

    /// Registers global hotkeys by identifier. Nil shortcuts are skipped.
    @discardableResult
    func register(shortcuts: [UInt32: DictationShortcut?]) -> RegistrationResult {
        unregister()

        let activeShortcuts = shortcuts.compactMapValues { $0 }
        guard !activeShortcuts.isEmpty else {
            return .success
        }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                guard let eventRef else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == HotKeyManager.hotKeySignature,
                      HotKeyManager.hotKeyTarget?.hotKeyRefs[hotKeyID.id] != nil
                else {
                    return noErr
                }

                let eventKind = GetEventKind(eventRef)
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    HotKeyManager.hotKeyTarget?.handleHotKeyEvent(kind: eventKind, id: id)
                }

                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &hotKeyHandlerRef
        )

        guard installStatus == noErr else {
            return .failure(.handlerInstallFailed)
        }

        for (id, shortcut) in activeShortcuts {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
            let registerStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifierFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if registerStatus != noErr {
                unregister()
                return .failure(.shortcutUnavailable)
            }

            if let hotKeyRef {
                hotKeyRefs[id] = hotKeyRef
            }
        }

        return .success
    }

    func unregister() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func handleHotKeyEvent(kind: UInt32, id: UInt32) {
        switch kind {
        case UInt32(kEventHotKeyPressed):
            onPress?(id)
        case UInt32(kEventHotKeyReleased):
            onRelease?(id)
        default:
            break
        }
    }
}
