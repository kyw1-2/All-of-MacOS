import AppKit
import Carbon

/// Carbon hot-key registration keeps explicit shortcuts available while a
/// password field suppresses CGEventTap. It does not read password characters,
/// change Secure Input, or register unmodified printable keys.
///
/// macOS withholds hot keys whose only modifiers are Option or Option-Shift
/// while Secure Event Input is on, because those chords type characters
/// (⌥P is "π") and a password field must keep them. Verified on macOS 27.2
/// against the SecurityAgent authorization dialog: ⌥ and ⌥⇧ chords never
/// arrive, while ⌃, ⌃⌥, ⌃⇧, ⌘⌥, ⌘⇧ and ⌃⌥⌘ do. Such a shortcut therefore
/// also answers to a *secure alias* — the same key with Control added
/// (⌥P → ⌃⌥P) — but only while Secure Input is active, and never when the
/// alias is itself bound to another trigger.
final class SecureInputHotKeys {
    private struct Registration {
        let physical: KeyboardShortcut
        let target: KeyboardShortcut
        let reference: EventHotKeyRef
    }

    private let shortcuts: () -> Set<KeyboardShortcut>
    private let handle: (KeyboardShortcut, Bool) -> Void
    private let cancel: () -> Void
    private var timer: Timer?
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var requested = Set<KeyboardShortcut>()
    private var held = Set<UInt32>()
    private var frontPID: pid_t?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x414F4D53 // AOMS

    // MARK: Pure rules (unit-tested)

    /// True for chords macOS withholds from hot keys during Secure Event Input.
    static func isWithheldDuringSecureInput(_ shortcut: KeyboardShortcut) -> Bool {
        let modifiers = shortcut.modifiers.intersection([.command, .control, .option, .shift, .function])
        return modifiers == [.option] || modifiers == [.option, .shift]
    }

    /// The chord that stands in for a withheld shortcut inside password fields.
    static func secureAlias(for shortcut: KeyboardShortcut) -> KeyboardShortcut? {
        guard isWithheldDuringSecureInput(shortcut) else { return nil }
        return KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.union(.control))
    }

    /// Physical chord → trigger shortcut. Every requested shortcut keeps its own
    /// chord; withheld ones add an alias unless an explicit binding owns it.
    static func registrationPlan(for shortcuts: Set<KeyboardShortcut>) -> [KeyboardShortcut: KeyboardShortcut] {
        var plan: [KeyboardShortcut: KeyboardShortcut] = [:]
        for shortcut in shortcuts { plan[shortcut] = shortcut }
        for shortcut in shortcuts.sorted(by: { ($0.keyCode, $0.modifiers.rawValue) < ($1.keyCode, $1.modifiers.rawValue) }) {
            guard let alias = secureAlias(for: shortcut), plan[alias] == nil else { continue }
            plan[alias] = shortcut
        }
        return plan
    }

    // MARK: Lifecycle

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
        for (physical, target) in Self.registrationPlan(for: wanted) {
            var flags: UInt32 = 0
            if physical.modifiers.contains(.command) { flags |= UInt32(cmdKey) }
            if physical.modifiers.contains(.option) { flags |= UInt32(optionKey) }
            if physical.modifiers.contains(.control) { flags |= UInt32(controlKey) }
            if physical.modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
            let id = nextID
            nextID &+= 1
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(physical.keyCode), flags,
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registrations[id] = Registration(physical: physical, target: target, reference: reference)
            }
        }
    }

    private func receive(_ id: UInt32, isDown: Bool) -> OSStatus {
        guard let registration = registrations[id] else { return OSStatus(eventNotHandledErr) }
        if isDown {
            guard IsSecureEventInputEnabled(), ActionExecutor.activeTextTypingSessions == 0,
                  shortcuts().contains(registration.target), held.insert(id).inserted else { return noErr }
        } else {
            guard held.remove(id) != nil else { return noErr }
        }
        handle(registration.target, isDown)
        return noErr
    }

    func owns(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        registrations.contains { id, registration in
            registration.physical.keyCode == keyCode && (held.contains(id) ||
                registration.physical.modifiers == flags.intersection([.command, .control, .option, .shift, .function]))
        }
    }

    private func unregister() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
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
