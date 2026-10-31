import AppKit
import Carbon.HIToolbox

/// ⌘⌥1–9 for the first nine favourites, registered as system hot keys only
/// while a dialog is attached (so the dialog never sees the keys and nothing
/// listens to the keyboard the rest of the time). A combination another app
/// already holds is skipped.
@MainActor
final class FilesDialogHotKeys {
    static let shared = FilesDialogHotKeys()

    /// Digit row key codes for 1…9.
    static let digitKeyCodes: [UInt32] = [UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
                                          UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
                                          UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)]
    private static let signature: OSType = 0x414F_4D46 // "AOMF"

    var onPress: ((Int) -> Void)?
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []

    var isRegistered: Bool { !references.isEmpty }

    /// Registers ⌘⌥1…⌘⌥`count` (at most nine).
    func register(count: Int) {
        unregister()
        guard count > 0 else { return }
        installHandlerIfNeeded()
        guard handler != nil else { return }
        let modifiers = UInt32(cmdKey | optionKey)
        for index in 0..<min(9, count) {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            if RegisterEventHotKey(Self.digitKeyCodes[index], modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr,
               let reference {
                references.append(reference)
            }
        }
    }

    func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey) == noErr,
                  hotKey.signature == 0x414F_4D46 else { return OSStatus(eventNotHandledErr) }
            let index = Int(hotKey.id) - 1
            DispatchQueue.main.async { MainActor.assumeIsolated { FilesDialogHotKeys.shared.onPress?(index) } }
            return OSStatus(noErr)
        }, 1, &type, nil, &handler)
        if status != noErr { handler = nil }
    }
}
