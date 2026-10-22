import AppKit
import Carbon

/// Carbon hot-key registration keeps explicit shortcuts available while a
/// password field suppresses CGEventTap. It does not read password characters,
/// change Secure Input, or register unmodified printable keys.
final class SecureInputHotKeys {
    private let shortcuts: () -> Set<KeyboardShortcut>
    private let handle: (KeyboardShortcut, Bool) -> Void
    private let cancel: () -> Void
    private var timer: Timer?
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: (KeyboardShortcut, EventHotKeyRef)] = [:]
    private var requested = Set<KeyboardShortcut>()
    private var held = Set<UInt32>()
    private var frontPID: pid_t?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x414F4D53 // AOMS

    init(shortcuts: @escaping () -> Set<KeyboardShortcut>,
         handle: @escaping (KeyboardShortcut, Bool) -> Void,
         cancel: @escaping () -> Void) {
        self.shortcuts = shortcuts
        self.handle = handle
        self.cancel = cancel
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<SecureInputHotKeys>.fromOpaque(context).takeUnretainedValue()
            var hotKey = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey) == noErr,
                  hotKey.signature == SecureInputHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            return owner.receive(hotKey.id, isDown: GetEventKind(event) == UInt32(kEventHotKeyPressed))
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return }
        refresh()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid != frontPID {
            cancel()
            held.removeAll()
            frontPID = pid
        }
        // Retain registrations through key-up if the action changes secure state.
        guard held.isEmpty else { return }
        let wanted = IsSecureEventInputEnabled() ? Set(shortcuts().filter {
            !$0.modifiers.intersection([.command, .control, .option]).isEmpty && !$0.modifiers.contains(.function)
        }) : []
        guard wanted != requested else { return }
        unregister()
        requested = wanted
        for shortcut in wanted {
            var flags: UInt32 = 0
            if shortcut.modifiers.contains(.command) { flags |= UInt32(cmdKey) }
            if shortcut.modifiers.contains(.option) { flags |= UInt32(optionKey) }
            if shortcut.modifiers.contains(.control) { flags |= UInt32(controlKey) }
            if shortcut.modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
            let id = nextID
            nextID &+= 1
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), flags,
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { registrations[id] = (shortcut, reference) }
        }
    }

    private func receive(_ id: UInt32, isDown: Bool) -> OSStatus {
        guard let (shortcut, _) = registrations[id] else { return OSStatus(eventNotHandledErr) }
        if isDown {
            guard IsSecureEventInputEnabled(), ActionExecutor.activeTextTypingSessions == 0,
                  shortcuts().contains(shortcut), held.insert(id).inserted else { return noErr }
        } else {
            guard held.remove(id) != nil else { return noErr }
        }
        handle(shortcut, isDown)
        return noErr
    }

    func owns(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        registrations.contains { id, value in
            value.0.keyCode == keyCode && (held.contains(id) ||
                value.0.modifiers == flags.intersection([.command, .control, .option, .shift, .function]))
        }
    }

    private func unregister() {
        for (_, reference) in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        requested.removeAll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        unregister()
        held.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit { stop() }
}
