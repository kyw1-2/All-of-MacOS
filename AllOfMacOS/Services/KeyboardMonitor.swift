import Foundation
import AppKit
import Carbon

/// Tracks physical key downs without consuming the original keystrokes.
/// Gaps and app changes reset the stream. Each candidate is bounded to 6 strokes.
final class KeySequenceDetector {
    struct Press {
        let stroke: KeySequenceStroke
        let timestamp: TimeInterval
    }
    private(set) var history: [Press] = []
    private(set) var heldKeys = Set<UInt16>()
    private var activeBundleID: String?

    func reset() { history.removeAll(); heldKeys.removeAll(); activeBundleID = nil }
    func release(_ keyCode: UInt16) { heldKeys.remove(keyCode) }
    func isHeld(_ keyCode: UInt16) -> Bool { heldKeys.contains(keyCode) }
    /// Returns false for native autorepeat and duplicate flag-change-down events.
    @discardableResult
    func press(_ stroke: KeySequenceStroke, at time: TimeInterval, in app: String?) -> Bool {
        if activeBundleID != app { reset(); activeBundleID = app }
        guard heldKeys.insert(stroke.keyCode).inserted else { return false }
        history.append(Press(stroke: stroke, timestamp: time))
        if history.count > 6 { history.removeFirst(history.count - 6) }
        return true
    }
    /// A stroke matches when the physical key agrees and, for printable keys,
    /// so do the modifiers. Modifier-only key downs already identify the
    /// physical key, so their modifier set is not compared.
    private static func stroke(_ wanted: KeySequenceStroke, matches actual: KeySequenceStroke) -> Bool {
        guard wanted.keyCode == actual.keyCode else { return false }
        if [54,55,56,58,59,60,61,62,63].contains(wanted.keyCode) { return true }
        return wanted.modifiers == actual.modifiers
    }

    func matches(_ pattern: [KeySequenceStroke], maxGapMs: Int, orderRelevant: Bool = true) -> Bool {
        guard !pattern.isEmpty, pattern.count <= 6 else { return false }
        // Optional strokes do not have to appear, so what has to be present is
        // the required subset; an all-optional pattern pins nothing and can
        // never be judged, so it never matches.
        let required = pattern.filter(\.isRequired)
        guard !required.isEmpty, history.count >= required.count else { return false }
        // A short history is still usable when the pattern has optional
        // strokes: the tail only has to cover what is actually required.
        let span = min(history.count, max(pattern.count, required.count))
        let tail = Array(history.suffix(span))
        let ok: Bool
        if orderRelevant {
            ok = Self.orderedMatch(pattern, tail: tail)
        } else {
            ok = Self.unorderedMatch(pattern, tail: tail)
        }
        guard ok else { return false }
        for index in 1..<tail.count {
            if tail[index].timestamp - tail[index - 1].timestamp > Double(maxGapMs) / 1000 { return false }
        }
        return true
    }

    /// The required strokes must appear as an in-order subsequence. Optional
    /// strokes are not constraints at all: they neither have to appear nor
    /// consume an event that a later required stroke needs.
    private static func orderedMatch(_ pattern: [KeySequenceStroke], tail: [Press]) -> Bool {
        var cursor = 0
        for wanted in pattern where wanted.isRequired {
            var found = false
            while cursor < tail.count {
                let candidate = tail[cursor]
                cursor += 1
                if stroke(wanted, matches: candidate.stroke) { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Required strokes are claimed regardless of order; optional strokes are
    /// ignored, which is the reading BTT gives an unordered pattern.
    private static func unorderedMatch(_ pattern: [KeySequenceStroke], tail: [Press]) -> Bool {
        var remaining = tail.map(\.stroke)
        for wanted in pattern where wanted.isRequired {
            guard let index = remaining.firstIndex(where: { stroke(wanted, matches: $0) }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }
}

class KeyboardMonitor: ObservableObject {
    private static var shortcutRecordingCount = 0
    static var isRecordingShortcut: Bool { shortcutRecordingCount > 0 }
    static func beginShortcutRecording() { shortcutRecordingCount += 1; activeMonitor?.releaseKeys() }
    static func endShortcutRecording() { shortcutRecordingCount = max(0, shortcutRecordingCount - 1) }
    @Published var isMonitoring = false
    private var localKeyMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var completionHandler: ((KeyboardShortcut) -> Void)?
    private var hasTap = false // tracks if we created a tap with a retained self

    func startRecording(completion: @escaping (KeyboardShortcut) -> Void) {
        stopRecording()
        releaseKeys()
        completionHandler = completion
        isMonitoring = true

        // Local monitor for key events within our app
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isMonitoring else { return event }

            // Escape cancels recording without setting a shortcut
            if event.keyCode == 53 {
                DispatchQueue.main.async { self.stopRecording() }
                return nil
            }

            let shortcut = KeyboardShortcut(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            )
            self.finishRecording(with: shortcut)
            return nil
        }

        // CGEventTap for system-intercepted keys (fn keys, media keys etc.)
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let retainedSelf = Unmanaged.passRetained(self)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()

            guard monitor.isMonitoring else { return Unmanaged.passUnretained(event) }

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown {
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                var modifiers: NSEvent.ModifierFlags = []
                if flags.contains(.maskCommand) { modifiers.insert(.command) }
                if flags.contains(.maskAlternate) { modifiers.insert(.option) }
                if flags.contains(.maskShift) { modifiers.insert(.shift) }
                if flags.contains(.maskControl) { modifiers.insert(.control) }
                if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }

                let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
                DispatchQueue.main.async {
                    monitor.finishRecording(with: shortcut)
                }
                return nil // swallow
            }

            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: retainedSelf.toOpaque()
        )

        if let tap = eventTap {
            hasTap = true
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        } else {
            retainedSelf.release()
            hasTap = false
        }
    }

    private func finishRecording(with shortcut: KeyboardShortcut) {
        guard isMonitoring else { return }
        let handler = completionHandler
        stopRecording()
        handler?(shortcut)
    }

    func stopRecording() {
        completionHandler = nil

        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if hasTap {
            Unmanaged<KeyboardMonitor>.passUnretained(self).release()
            hasTap = false
        }

        // Ensure UI update happens on main thread
        if Thread.isMainThread {
            isMonitoring = false
        } else {
            DispatchQueue.main.async { self.isMonitoring = false }
        }
    }

    // MARK: - Global shortcut monitoring for trigger execution

    private let systemMonitoringEnabled: Bool
    private let builtinHandler: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
    init(systemMonitoringEnabled: Bool = true, builtinHandler: ((UInt16, NSEvent.ModifierFlags) -> Bool)? = nil) {
        self.systemMonitoringEnabled = systemMonitoringEnabled; self.builtinHandler = builtinHandler
    }
    private var pressApps: [UInt16: String] = [:]
    private var registrationGeneration = UUID()
    private var globalMonitors: [Any] = []
    private var triggerEventTap: CFMachPort?
    private var triggerRunLoopSource: CFRunLoopSource?
    private var registeredTriggers: [Trigger] = []
    private var activationGroups: [ActivationGroup] = []
    private var sequenceDetector = KeySequenceDetector()
    private var pressed: [UInt16: [Trigger]] = [:]
    private static var activeMonitor: KeyboardMonitor?

    func registerTriggers(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        unregisterAll()
        activationGroups = groups
        registeredTriggers = triggers.filter {
            guard $0.isEnabled else { return false }
            switch $0.input { case .keyboardShortcut, .keySequence: return true; default: return false }
        }
        let hasCaptureShortcuts = MainActor.assumeIsolated { CaptureShortcuts.shared.hasActiveShortcuts || ClipboardShortcuts.shared.hasActiveShortcuts }
        guard (!registeredTriggers.isEmpty || hasCaptureShortcuts), systemMonitoringEnabled else { return }
        KeyboardMonitor.activeMonitor = self
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        triggerEventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, _ in
                guard let monitor = KeyboardMonitor.activeMonitor else { return Unmanaged.passUnretained(event) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.releaseKeys()
                    if let tap = monitor.triggerEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard event.getIntegerValueField(.eventSourceUserData) != 0x475454, !monitor.isMonitoring, !KeyboardMonitor.isRecordingShortcut else { return Unmanaged.passUnretained(event) }
                if type == .flagsChanged {
                    monitor.handleSequenceModifierEvent(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                        flags: event.flags)
                    return Unmanaged.passUnretained(event)
                }
                let swallowed = monitor.handleInput(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                    modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)), isDown: type == .keyDown,
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                return swallowed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: nil)
        if let tap = triggerEventTap {
            triggerRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = triggerRunLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // Listen-only fallback cannot consume the original shortcut.
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x475454 else { return }
                if event.type == .flagsChanged {
                    self?.handleSequenceModifierEvent(keyCode: event.keyCode, flags: event.cgEvent?.flags ?? [])
                } else {
                    _ = self?.handleInput(keyCode: event.keyCode, modifiers: event.modifierFlags, isDown: event.type == .keyDown, isRepeat: event.isARepeat)
                }
            } { globalMonitors.append(monitor) }
            GestureLog.shared.logFromAnyThread("Keyboard uses listen-only fallback; check Accessibility permission", level: .error)
        }
    }
    private static let modifierOnlyKeys: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    /// These events are observed but never swallowed, so normal typing continues.
    func handleSequenceModifierEvent(keyCode: UInt16, flags: CGEventFlags) {
        guard Self.modifierOnlyKeys.contains(keyCode) else { return }
        let flag: CGEventFlags
        switch keyCode {
        case 54, 55: flag = .maskCommand
        case 56, 60: flag = .maskShift
        case 58, 61: flag = .maskAlternate
        case 59, 62: flag = .maskControl
        default: flag = .maskSecondaryFn
        }
        if flags.contains(flag) {
            observeSequence(keyCode: keyCode, modifiers: [], isDown: true, isRepeat: false)
        } else {
            observeSequence(keyCode: keyCode, modifiers: [], isDown: false, isRepeat: false)
        }
    }

    private func observeSequence(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                                 isDown: Bool, isRepeat: Bool) {
        if !isDown { sequenceDetector.release(keyCode); return }
        guard !isRepeat, !isMonitoring, !Self.isRecordingShortcut,
              (UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true),
              registeredTriggers.contains(where: { if case .keySequence = $0.input { return true }; return false }) else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let flags = Self.modifierOnlyKeys.contains(keyCode) ? UInt(0) :
            KeyboardShortcut(keyCode: keyCode, modifiers: modifiers.intersection(Self.relevantModifiers)).modifiers.rawValue
        let stroke = KeySequenceStroke(keyCode: keyCode, modifiers: flags)
        guard sequenceDetector.press(stroke, at: ProcessInfo.processInfo.systemUptime, in: front) else { return }
        let candidates = registeredTriggers.filter { trigger in
            guard case .keySequence(let pattern) = trigger.input,
                  sequenceDetector.matches(pattern, maxGapMs: trigger.sequenceMaxGapMs,
                                              orderRelevant: trigger.sequenceOrderRelevant) else { return false }
            return true
        }
        let winners = TriggerResolver.resolve(candidates, payload: true, frontBundleID: front,
            payloadOf: { _ in true }, appBundleIDOf: { $0.appBundleID },
            groups: activationGroups, activationGroupIDOf: { $0.activationGroupID })
        for winner in winners {
            if winner.sequenceHoldMs > 0 {
                // A hold only applies to a one-stroke pattern (enforced on import).
                let generation = registrationGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(winner.sequenceHoldMs) / 1000) { [weak self] in
                    guard let self, self.registrationGeneration == generation,
                          self.sequenceDetector.isHeld(keyCode),
                          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == front,
                          (UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true) else { return }
                    self.fire(winner, keyCode: keyCode)
                }
            } else { fire(winner, keyCode: keyCode) }
        }
    }

    @discardableResult
    func handleInput(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isDown: Bool, isRepeat: Bool = false) -> Bool {
        guard !Self.isRecordingShortcut, !isMonitoring else { return false }

        // ESC (keyCode 53) dismisses active overlays immediately, even when another app is focused
        if keyCode == 53 && isDown {
            let handledOverlay = MainActor.assumeIsolated { () -> Bool in
                if SelectionOverlayController.isActive {
                    SelectionOverlayController.cancelActive()
                    return true
                }
                if MediaHistoryOverlayController.shared.isPresented {
                    if MediaHistoryOverlayController.shared.isShowingSheet { return false }
                    MediaHistoryOverlayController.shared.handleEscape()
                    return true
                }
                if ClipboardPanelController.shared.isVisible {
                    return ClipboardPanelController.shared.handleEscape()
                }
                return false
            }
            if handledOverlay {
                pressed[keyCode] = []
                return true
            }
        }

        observeSequence(keyCode: keyCode, modifiers: modifiers, isDown: isDown, isRepeat: isRepeat)
        if !isDown {
            guard let bindings = pressed.removeValue(forKey: keyCode) else { return false }
            let sameApp = pressApps.removeValue(forKey: keyCode) == (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            for trigger in bindings {
                ActionExecutor.releaseHold(trigger.id)
                if trigger.keyboardPhase == .keyUp, sameApp,
                   trigger.appBundleID == nil || trigger.appBundleID == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                   UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true { fire(trigger, keyCode: keyCode) }
            }
            return true
        }
        if pressed[keyCode] != nil { return true } // Native autorepeat must not create additional macros.
        guard !isRepeat, UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true else { return false }

        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers.intersection([.command, .option, .control, .shift, .function]))
        let matches = TriggerResolver.resolve(registeredTriggers, payload: shortcut,
            frontBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            payloadOf: { if case .keyboardShortcut(let shortcut) = $0.input { return KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.intersection([.command, .option, .control, .shift, .function])) }; return nil }, appBundleIDOf: { $0.appBundleID }, groups: activationGroups, activationGroupIDOf: { $0.activationGroupID })
        if matches.isEmpty {
            // Explicit user bindings win; consume the entire physical key pair
            // for built-ins too, even when their panel changes focus on key down.
            let handled = builtinHandler?(keyCode, modifiers) ?? (systemMonitoringEnabled && MainActor.assumeIsolated {
                ClipboardShortcuts.shared.handleKeyEvent(keyCode: keyCode, modifiers: modifiers) ||
                    CaptureShortcuts.shared.handleKeyEvent(keyCode: keyCode, modifiers: modifiers)
            })
            if handled { pressed[keyCode] = [] }
            return handled
        }
        pressed[keyCode] = matches
        pressApps[keyCode] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        for trigger in matches where trigger.keyboardPhase == .keyDown { fire(trigger, keyCode: keyCode) }
        return true
    }
    private func fire(_ trigger: Trigger, keyCode: UInt16) {
        // Keep event tap callbacks short: launch the workflow after returning to the run loop.
        let generation = registrationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.registrationGeneration == generation, self.registeredTriggers.contains(where: { $0.id == trigger.id }),
                  UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true else { return }
            ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions,
                isHeld: trigger.keyboardPhase == .keyDown ? { [weak self] in
                    self?.pressed[keyCode] != nil && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
                } : nil)
            LiveTouchState.shared.flashTrigger(trigger.id)
            NotificationCenter.default.post(name: .gestureDidFire, object: nil, userInfo: ["name": trigger.input.displayName, "actions": trigger.actions.filter(\.isEnabled).map { $0.actionType.rawValue }.joined(separator: " → ")])
        }
    }
    private func releaseKeys() {
        let bindings = pressed.values.flatMap { $0 }; pressed.removeAll(); pressApps.removeAll()
        for trigger in bindings { ActionExecutor.releaseHold(trigger.id) }
    }
    func unregisterAll() {
        registrationGeneration = UUID()
        releaseKeys()
        sequenceDetector.reset()
        for monitor in globalMonitors { NSEvent.removeMonitor(monitor) }; globalMonitors.removeAll()
        if let tap = triggerEventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap); triggerEventTap = nil }
        if let source = triggerRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); triggerRunLoopSource = nil }
        if KeyboardMonitor.activeMonitor === self { KeyboardMonitor.activeMonitor = nil }
        registeredTriggers.removeAll()
    }
    deinit {
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
        unregisterAll()
    }
}
