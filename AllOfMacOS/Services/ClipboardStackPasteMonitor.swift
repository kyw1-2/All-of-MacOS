import AppKit

/// A stack owns Cmd-V only while its floating session is open. A consuming event
/// tap prevents the destination from reading the previous clipboard value before
/// the next stack item has been written. Our injected events bypass every AOM tap.
@MainActor
final class ClipboardStackPasteMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedV = false
    var onPaste: ((Bool) -> Bool)?

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ClipboardStackPasteMonitor>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.swallowedV = false
                        if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    guard event.getIntegerValueField(.eventSourceUserData) != 0x475454,
                          event.getIntegerValueField(.keyboardEventKeycode) == 9 else {
                        return Unmanaged.passUnretained(event)
                    }
                    if type == .keyUp, owner.swallowedV {
                        owner.swallowedV = false
                        return nil
                    }
                    let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection([.command, .option, .control, .shift])
                    let allowed = NSEvent.ModifierFlags.command.union(ClipboardPreferences.shared.plainModifier.flags)
                    guard type == .keyDown, !KeyboardMonitor.isRecordingShortcut,
                          modifiers.contains(.command), modifiers.subtracting(allowed).isEmpty else {
                        return Unmanaged.passUnretained(event)
                    }
                    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                        return owner.swallowedV ? nil : Unmanaged.passUnretained(event)
                    }
                    guard owner.onPaste?(ClipboardPreferences.shared.isPlain(modifiers)) == true else {
                        return Unmanaged.passUnretained(event)
                    }
                    owner.swallowedV = true
                    return nil
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else { CFMachPortInvalidate(tap); self.tap = nil; return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        swallowedV = false
    }

    /// Targeted injection preserves physical modifier state, including a held
    /// Command key, and cannot redirect a queued paste into another process.
    static func sendPaste(to target: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted(), !target.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: 0x475454)
            event.postToPid(target.processIdentifier)
        }
        return true
    }
}
