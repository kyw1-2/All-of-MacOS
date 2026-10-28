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
    private var pressTimes: [UInt16: TimeInterval] = [:]
    private var pressSerial: [UInt16: UUID] = [:]
    /// Injectable so hold-time behavior is testable without real waiting or input.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var scheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var timingDefaults: UserDefaults = TriggerTimingSettings.store
    private var registrationGeneration = UUID()
    private var globalMonitors: [Any] = []
    private var triggerEventTap: CFMachPort?
    private var triggerRunLoopSource: CFRunLoopSource?
    /// Internal for the registration integration test (@testable).
    var registeredTriggers: [Trigger] = []
    private var activationGroups: [ActivationGroup] = []
    private var sequenceDetector = KeySequenceDetector()
    private var pressed: [UInt16: [Trigger]] = [:]
    private static var activeMonitor: KeyboardMonitor?
    private var secureHotKeys: SecureInputHotKeys?

    func registerTriggers(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        unregisterAll()
        activationGroups = groups
        registeredTriggers = triggers.filter {
            guard $0.isEnabled else { return false }
            // .typedString feeds processTypedString from the same tap; without
            // it here a saved expansion rule never reaches the engine.
            switch $0.input { case .keyboardShortcut, .keySequence, .typedString: return true; default: return false }
        }
        let hasCaptureShortcuts = MainActor.assumeIsolated {
            CaptureShortcuts.shared.hasActiveShortcuts || ClipboardShortcuts.shared.hasActiveShortcuts
                // The title-bar snap's ⌃⌥ hotkeys (Swish's Advanced tab) answer from this tap too.
                || TitleBarWindowSnap.hotkeysWanted()
        }
        guard (!registeredTriggers.isEmpty || hasCaptureShortcuts), systemMonitoringEnabled else { return }
        KeyboardMonitor.activeMonitor = self
        secureHotKeys = SecureInputHotKeys(shortcuts: { [weak self] in
            guard let self, !self.isMonitoring, !Self.isRecordingShortcut,
                  AutomationGate.isOn,
                  TriggerSuppression.shared.allows(kind: .keyboard) else { return [] }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let candidates = Set(self.registeredTriggers.compactMap { trigger -> KeyboardShortcut? in
                if case .keyboardShortcut(let shortcut) = trigger.input { return shortcut }
                return nil
            })
            return candidates.filter { shortcut in
                !TriggerResolver.resolve(self.registeredTriggers, payload: shortcut, frontBundleID: front,
                    payloadOf: { if case .keyboardShortcut(let value) = $0.input { return value }; return nil },
                    appBundleIDOf: { $0.appBundleID }, groups: self.activationGroups,
                    activationGroupIDOf: { $0.activationGroupID }).isEmpty
            }
        }, handle: { [weak self] shortcut, isDown in
            guard let self else { return }
            if isDown && ActionExecutor.activeTextTypingSessions > 0 { return }
            _ = self.handleInput(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, isDown: isDown)
        }, cancel: { [weak self] in self?.releaseKeys() })
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
                let eventCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if monitor.secureHotKeys?.owns(keyCode: eventCode, flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))) == true {
                    return Unmanaged.passUnretained(event)
                }
                // Text expansion needs the real character, not a keycode.
                var text: String?
                if type == .keyDown {
                    var chars = [UniChar](repeating: 0, count: 8)
                    var length = 0
                    event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
                    if length > 0 { text = String(decoding: chars.prefix(length), as: UTF16.self) }
                }
                let swallowed = monitor.handleInput(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                    modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)), isDown: type == .keyDown,
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, text: text)
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
                    _ = self?.handleInput(keyCode: event.keyCode, modifiers: event.modifierFlags, isDown: event.type == .keyDown, isRepeat: event.isARepeat, text: event.type == .keyDown ? event.characters : nil)
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
              (AutomationGate.isOn),
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
                          (AutomationGate.isOn) else { return }
                    self.fire(winner, keyCode: keyCode)
                }
            } else { fire(winner, keyCode: keyCode) }
        }
    }

    @discardableResult
    func handleInput(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isDown: Bool, isRepeat: Bool = false, text: String? = nil) -> Bool {
        guard !Self.isRecordingShortcut, !isMonitoring else { return false }

        // Mission Control hotkeys (W/⇧W/M/H) only while MC is open — the Dock
        // owns focus then, so this global tap is the only place they exist.
        if isDown, MainActor.assumeIsolated({
            MissionControlOverlayService.shared.isMissionControlActive &&
            MissionControlHotKeyHandler.shared.handleGlobalKey(keyCode: keyCode, modifiers: modifiers)
        }) { return true }

        // While the window switcher is up it owns the keyboard: the bound
        // shortcut (⌃Tab re-pressed) cycles instead of re-opening.
        if isDown, MainActor.assumeIsolated({ WindowSwitcherController.shared.handleSwitcherKey(
            keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat) }) { return true }

        // Text expansion runs before everything else: it only ever sees plain
        // printable typing, and a match swallows its final key.
        if isDown, let text, !text.isEmpty,
           processTypedString(text: text, modifiers: modifiers) { return true }

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
            // Invalidate any pending hold timers for this physical press.
            pressSerial[keyCode] = nil
            let heldMs = pressTimes.removeValue(forKey: keyCode).map { Int(max(0, clock() - $0) * 1000) } ?? 0
            for trigger in bindings {
                ActionExecutor.releaseHold(trigger.id)
                let plan = TriggerKeyHold.plan(phase: trigger.keyboardPhase, minHoldMs: trigger.minHoldMs,
                                               longPressMs: TriggerTimingSettings.keyboardLongPressMs(timingDefaults))
                if plan == .onRelease, sameApp,
                   TriggerKeyHold.acceptsRelease(phase: trigger.keyboardPhase, heldMs: heldMs, minHoldMs: trigger.minHoldMs,
                                                 maxHoldMs: trigger.maxHoldMs,
                                                 quickReleaseMaxMs: TriggerTimingSettings.keyboardQuickReleaseMs(timingDefaults)),
                   trigger.appBundleID == nil || trigger.appBundleID == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                   AutomationGate.isOn { fire(trigger, keyCode: keyCode) }
            }
            return true
        }
        if pressed[keyCode] != nil { return true } // Native autorepeat must not create additional macros.
        guard !isRepeat, AutomationGate.isOn else { return false }

        let shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers.intersection([.command, .option, .control, .shift, .function]))
        // A paused/suppressed keyboard never swallows keys or runs user
        // bindings; AOM's own built-in shortcuts below are unaffected.
        let suppressed = !TriggerSuppression.shared.allows(kind: .keyboard)
        let matches = suppressed ? [] : TriggerResolver.resolve(registeredTriggers, payload: shortcut,
            frontBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            payloadOf: { if case .keyboardShortcut(let shortcut) = $0.input { return KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers.intersection([.command, .option, .control, .shift, .function])) }; return nil }, appBundleIDOf: { $0.appBundleID }, groups: activationGroups, activationGroupIDOf: { $0.activationGroupID })
        if matches.isEmpty {
            // Explicit user bindings win; consume the entire physical key pair
            // for built-ins too, even when their panel changes focus on key down.
            let handled = builtinHandler?(keyCode, modifiers) ?? (systemMonitoringEnabled && MainActor.assumeIsolated {
                ClipboardShortcuts.shared.handleKeyEvent(keyCode: keyCode, modifiers: modifiers) ||
                    CaptureShortcuts.shared.handleKeyEvent(keyCode: keyCode, modifiers: modifiers) ||
                    // Swish's ⌃⌥ snap hotkeys; the defaults check keeps the
                    // service unbuilt while they are off.
                    (TitleBarWindowSnap.hotkeysWanted()
                        && TitleBarWindowSnap.shared.handleHotKey(keyCode: keyCode, modifiers: modifiers))
            })
            if handled { pressed[keyCode] = [] }
            return handled
        }
        pressed[keyCode] = matches
        let pressApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        pressApps[keyCode] = pressApp
        pressTimes[keyCode] = clock()
        let serial = UUID()
        pressSerial[keyCode] = serial
        let longPressMs = TriggerTimingSettings.keyboardLongPressMs(timingDefaults)
        for trigger in matches {
            switch TriggerKeyHold.plan(phase: trigger.keyboardPhase, minHoldMs: trigger.minHoldMs, longPressMs: longPressMs) {
            case .immediately: fire(trigger, keyCode: keyCode)
            case .onRelease: break
            case .afterHold(let ms):
                scheduler(Double(ms) / 1000) { [weak self] in
                    // Still the same physical press, still held, same app.
                    guard let self, self.pressSerial[keyCode] == serial,
                          self.pressed[keyCode]?.contains(where: { $0.id == trigger.id }) == true,
                          NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" == pressApp else { return }
                    self.fire(trigger, keyCode: keyCode)
                }
            }
        }
        return true
    }

    /// Typed-string matching (espanso / BTT Typed Strings parity). Returns
    /// true when this key was the final character of an abbreviation and was
    /// swallowed; the erasure and expansion then run off the tap callback.
    private func processTypedString(text: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard (AutomationGate.isOn),
              registeredTriggers.contains(where: { if case .typedString = $0.input { return true }; return false }),
              ActionExecutor.activeTextTypingSessions == 0,
              !ScreenLock.isLocked,
              NSApp.keyWindow == nil, // never expand into AOM's own fields
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            MainActor.assumeIsolated { TypedStringEngine.shared.reset() }
            return false
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option, .function]) else {
            MainActor.assumeIsolated { TypedStringEngine.shared.reset() }
            return false
        }
        // Secure Event Input owns the focused field (passwords, the lock
        // screen): typed text must never expand or erase there.
        guard !IsSecureEventInputEnabled() else {
            MainActor.assumeIsolated { TypedStringEngine.shared.reset() }
            return false
        }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let match = MainActor.assumeIsolated {
            TypedStringEngine.shared.observe(text: text, bundleID: bundleID,
                                             registered: registeredTriggers, activationGroups: activationGroups)
        }
        guard let match, case .typedString(let spec) = match.trigger.input else { return false }
        let engine = TypedStringEngine.shared
        let trigger = match.trigger
        DispatchQueue.global(qos: .userInitiated).async {
            engine.erase(match.backspaces)
            Task { @MainActor in engine.reset() }
            if !spec.replacement.isEmpty {
                ActionExecutor.typeReplacementText(spec.replacement, completion: nil)
            } else {
                self.fire(trigger, keyCode: 0)
            }
        }
        return true
    }

    private func fire(_ trigger: Trigger, keyCode: UInt16) {
        // Keep event tap callbacks short: launch the workflow after returning to the run loop.
        let generation = registrationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.registrationGeneration == generation, self.registeredTriggers.contains(where: { $0.id == trigger.id }),
                  AutomationGate.isOn else { return }
            ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions,
                isHeld: trigger.keyboardPhase == .keyDown ? { [weak self] in
                    self?.pressed[keyCode] != nil && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
                } : nil)
            LiveTouchState.shared.flashTrigger(trigger.id)
            // Rapid-fire actions (window switching, pin toggles) must not flash
            // a HUD on every press — the overlay itself is the feedback.
            let quiet = trigger.actions.filter(\.isEnabled).map(\.actionType).allSatisfy {
                [.showWindowSwitcher, .togglePinFrontWindow, .togglePinWindowUnderCursor].contains($0)
            }
            NotificationCenter.default.post(name: .gestureDidFire, object: nil, userInfo: ["name": trigger.input.displayName, "actions": trigger.actions.filter(\.isEnabled).map { $0.actionType.rawValue }.joined(separator: " → "), "quiet": quiet])
        }
    }
    private func releaseKeys() {
        let bindings = pressed.values.flatMap { $0 }; pressed.removeAll(); pressApps.removeAll()
        pressTimes.removeAll(); pressSerial.removeAll()
        for trigger in bindings { ActionExecutor.releaseHold(trigger.id) }
    }
    func unregisterAll() {
        secureHotKeys?.stop()
        secureHotKeys = nil
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
