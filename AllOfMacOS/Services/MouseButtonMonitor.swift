import Foundation
import AppKit

/// One normalized mouse event, decoupled from CGEvent so the whole pipeline
/// (recognizer → resolver → suppression verdict) can be driven by tests.
struct MouseInputEvent {
    enum Kind { case down, up, dragged, scroll }
    var kind: Kind
    /// 0 left, 1 right, 2 middle, 3+ extra buttons. Ignored for scroll.
    var button: Int = 0
    var x: Double = 0
    var y: Double = 0
    var modifiers: UInt = 0
    var time: TimeInterval = 0
    var scrollDX: Double = 0
    var scrollDY: Double = 0
}

class MouseButtonMonitor {
    /// A registered Normal Mouse trigger. Legacy `.mouseButton` triggers keep
    /// their original "fire immediately on press" behavior (`isLegacy`).
    struct Entry {
        let id: UUID
        let spec: MouseTriggerSpec
        let isLegacy: Bool
        let actions: [TriggerAction]
        let appBundleID: String?
        let suppressClick: Bool
        let requiredModifiers: UInt?
        let activationGroupID: UUID?
        let repeatWhileHeld: Bool
    }

    private let sideHID = MouseSideButtonHID()
    private var sideDeduplicator = MouseSideButtonDeduplicator()
    private var hidGeneration = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var entries: [Entry] = []
    private var recognizer = MouseGestureRecognizer(config: .init(), wanted: [])
    private var activationGroups: [ActivationGroup] = []
    /// Buttons whose press was swallowed; their drag and release are swallowed too.
    private var suppressedButtons = Set<Int>()
    private var wake: DispatchWorkItem?
    private var wakeDeadline: TimeInterval?
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private static var activeMonitor: MouseButtonMonitor?

    // Test seams.
    var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var timingDefaults: UserDefaults = TriggerTimingSettings.store
    /// When set, replaces the real fire path (ActionExecutor + HUD).
    var onFire: ((Entry) -> Void)?
    var globalEnabled: () -> Bool = { AutomationGate.isOn }
    var needsSideButtonHID: Bool {
        entries.contains { !$0.spec.kind.isScroll && (3...4).contains($0.spec.button) }
    }

    func registerTriggers(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        registerEntries(triggers, groups: groups)
        guard !entries.isEmpty || !suppressedButtons.isEmpty else { return }
        observeRecovery()
        installTap()
        sideHID.onEvent = { [weak self] button, down in
            guard let self else { return }
            let time = self.clock(), generation = self.hidGeneration
            let point = CGEvent(source: nil)?.location ?? .zero
            let flags = UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                guard let self, self.hidGeneration == generation else { return }
                let edge = MouseSideButtonDeduplicator.Edge(button: button, down: down)
                guard self.sideDeduplicator.shouldDeliverHID(edge, time: time) else { return }
                let swallowed = self.handle(MouseInputEvent(kind: down ? .down : .up, button: button,
                    x: point.x, y: point.y, modifiers: flags, time: time))
                self.sideDeduplicator.noteHID(edge, time: time, swallow: swallowed)
            }
        }
        if needsSideButtonHID { sideHID.start() }
    }

    /// Builds the registration tables without touching the event system.
    func registerEntries(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        let pendingReleases = suppressedButtons
        unregisterAll()
        suppressedButtons = pendingReleases
        activationGroups = groups
        for trigger in triggers where trigger.isEnabled {
            let spec: MouseTriggerSpec
            let legacy: Bool
            switch trigger.input {
            case .mouseButton(let button): spec = MouseTriggerSpec(legacy: button); legacy = true
            case .mouse(let value):
                if let problem = TriggerValidation.problem(for: trigger) {
                    // A left/right/scroll trigger without a modifier would capture the whole system's input.
                    NSLog("[MouseButtonMonitor] Ignoring '%@': %@", trigger.displayName, problem)
                    continue
                }
                spec = value; legacy = false
            default: continue
            }
            entries.append(Entry(id: trigger.id, spec: spec, isLegacy: legacy, actions: trigger.actions,
                                 appBundleID: trigger.appBundleID, suppressClick: trigger.suppressClick,
                                 requiredModifiers: trigger.requiredModifiers, activationGroupID: trigger.activationGroupID,
                                 repeatWhileHeld: trigger.repeatWhileHeld))
        }
        rebuildRecognizer()
    }

    private func rebuildRecognizer() {
        let d = timingDefaults
        let config = MouseGestureRecognizer.Config(
            multiClickInterval: Double(TriggerTimingSettings.mouseMultiClickMs(d)) / 1000,
            longPressDuration: Double(TriggerTimingSettings.mouseLongPressMs(d)) / 1000,
            dragThreshold: Double(TriggerTimingSettings.mouseDragThresholdPx(d)))
        recognizer = MouseGestureRecognizer(config: config, wanted: Set(entries.filter { !$0.isLegacy }.map(\.spec)))
    }

    // MARK: Event handling (pure of CGEvent)

    /// Processes one event and returns true when the original event must be swallowed.
    @discardableResult
    func handle(_ event: MouseInputEvent) -> Bool {
        let front = frontmostBundleID()
        var outputs: [MouseGestureRecognizer.Output] = []
        var swallow = false

        switch event.kind {
        case .down:
            // A fresh down supersedes any lost release for this button.
            suppressedButtons.remove(event.button)
            // Pause and per-app suppression pass the click through untouched.
            guard TriggerSuppression.shared.allows(kind: .mouse), globalEnabled() else { return false }
            if entries.contains(where: { $0.isLegacy && $0.spec.button == event.button }) {
                let legacy = TriggerResolver.resolve(
                    entries.filter(\.isLegacy), payload: event.button, frontBundleID: front,
                    payloadOf: { $0.spec.button }, appBundleIDOf: { $0.appBundleID }, modifiers: event.modifiers,
                    requiredModifiersOf: { $0.requiredModifiers }, groups: activationGroups,
                    activationGroupIDOf: { $0.activationGroupID })
                for entry in legacy { fire(entry) }
                if legacy.contains(where: \.suppressClick) { swallow = true }
            }
            if suppresses(button: event.button, modifiers: event.modifiers, front: front) { swallow = true }
            if swallow { suppressedButtons.insert(event.button) }
            outputs = recognizer.buttonDown(event.button, x: event.x, y: event.y, time: event.time, modifiers: event.modifiers)
        case .up:
            outputs = recognizer.buttonUp(event.button, time: event.time)
            swallow = suppressedButtons.remove(event.button) != nil
        case .dragged:
            outputs = recognizer.moved(x: event.x, y: event.y, time: event.time)
            swallow = suppressedButtons.contains(event.button)
        case .scroll:
            guard TriggerSuppression.shared.allows(kind: .mouse), globalEnabled() else { return false }
            outputs = recognizer.scroll(dx: event.scrollDX, dy: event.scrollDY, time: event.time, modifiers: event.modifiers)
            swallow = suppressesScroll(modifiers: event.modifiers, front: front)
        }
        dispatch(outputs, front: front)
        scheduleWake()
        return swallow
    }

    /// Fires recognizer-completed triggers through the shared resolver so they
    /// honor the same app-scope / activation-group / modifier rules as every
    /// other trigger family.
    private func dispatch(_ outputs: [MouseGestureRecognizer.Output], front: String?) {
        guard !outputs.isEmpty else { return }
        for output in outputs {
            let winners = TriggerResolver.resolve(
                entries.filter { !$0.isLegacy }, payload: output.spec, frontBundleID: front,
                payloadOf: { $0.spec }, appBundleIDOf: { $0.appBundleID }, modifiers: output.modifiers,
                requiredModifiersOf: { $0.requiredModifiers }, groups: activationGroups,
                activationGroupIDOf: { $0.activationGroupID })
            for entry in winners { fire(entry) }
        }
    }

    /// Whether a press of `button` should be swallowed: only when a matching
    /// trigger asked for it (suppressClick) and its modifier/app scope applies.
    private func suppresses(button: Int, modifiers: UInt, front: String?) -> Bool {
        let candidates = entries.filter { !$0.isLegacy && !$0.spec.kind.isScroll && $0.spec.button == button && $0.suppressClick }
        guard !candidates.isEmpty else { return false }
        return !TriggerResolver.resolve(candidates, payload: true, frontBundleID: front, payloadOf: { _ in true },
            appBundleIDOf: { $0.appBundleID }, modifiers: modifiers, requiredModifiersOf: { $0.requiredModifiers },
            groups: activationGroups, activationGroupIDOf: { $0.activationGroupID }).isEmpty
    }

    private func suppressesScroll(modifiers: UInt, front: String?) -> Bool {
        let candidates = entries.filter { $0.spec.kind.isScroll && $0.suppressClick }
        guard !candidates.isEmpty else { return false }
        return !TriggerResolver.resolve(candidates, payload: true, frontBundleID: front, payloadOf: { _ in true },
            appBundleIDOf: { $0.appBundleID }, modifiers: modifiers, requiredModifiersOf: { $0.requiredModifiers },
            groups: activationGroups, activationGroupIDOf: { $0.activationGroupID }).isEmpty
    }

    /// Wakes the recognizer exactly when a long press or deferred click is due.
    private func scheduleWake() {
        let deadline = recognizer.nextDeadline
        if wake != nil, wakeDeadline == deadline { return }
        wake?.cancel(); wake = nil
        wakeDeadline = deadline
        guard let deadline else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wake = nil
            self.wakeDeadline = nil
            self.pollNow()
        }
        wake = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - clock()) + 0.005, execute: item)
    }

    /// Drives time-based output (long press, deferred click). Public for tests.
    func pollNow() {
        guard TriggerSuppression.shared.allows(kind: .mouse), globalEnabled() else { recognizer.reset(); return }
        dispatch(recognizer.poll(now: clock()), front: frontmostBundleID())
        scheduleWake()
    }

    /// Whether a button is physically down now; replaced in tests.
    var buttonIsDown: (Int) -> Bool = { button in
        (0...31).contains(button)
            && CGMouseButton(rawValue: UInt32(button)).map { CGEventSource.buttonState(.combinedSessionState, button: $0) } == true
    }

    /// macOS turned the tap off (a slow callback): the releases of that gap
    /// went around it. 3.4.0 audit: the recognizer kept those presses and the
    /// wake set for them, so a long press (or a drag) fired for a button
    /// already let go. Presses and pending clicks go; a swallowed press whose
    /// button is still down keeps its release swallowed.
    func tapWasDisabled() {
        wake?.cancel(); wake = nil
        wakeDeadline = nil
        recognizer.reset()
        suppressedButtons = suppressedButtons.filter(buttonIsDown)
    }

    private func fire(_ entry: Entry) {
        if let onFire { onFire(entry); return }
        let button = entry.spec.button
        let held: (() -> Bool)? = (entry.repeatWhileHeld && entry.spec.kind == .click && (0...31).contains(button))
            ? { [weak self] in self.map { $0.sideHID.held.contains(button) || $0.buttonIsDown(button) } ?? false }
            : nil
        DispatchQueue.main.async {
            ActionExecutor.fire(triggerID: entry.id, fallbackActions: entry.actions, isHeld: held)
            LiveTouchState.shared.flashTrigger(entry.id)
            NotificationCenter.default.post(name: .gestureDidFire, object: nil, userInfo: [
                "name": entry.spec.displayName,
                "actions": entry.actions.filter(\.isEnabled).map { $0.actionType.rawValue }.joined(separator: " → ")])
        }
    }

    // MARK: Event tap

    private func observeRecovery() {
        guard lifecycleObservers.isEmpty, !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        func observe(_ center: NotificationCenter, _ name: Notification.Name, suspend: Bool) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if suspend {
                    self.hidGeneration += 1
                    self.sideHID.stop()
                    self.sideDeduplicator = MouseSideButtonDeduplicator()
                    self.tapWasDisabled()
                    self.removeTap()
                } else {
                    guard !self.entries.isEmpty || !self.suppressedButtons.isEmpty else { return }
                    if let tap = self.eventTap, !CFMachPortIsValid(tap) { self.removeTap() }
                    if self.eventTap == nil { self.installTap() }
                    if let tap = self.eventTap, !CGEvent.tapIsEnabled(tap: tap) {
                        self.tapWasDisabled()
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    if self.needsSideButtonHID { self.sideHID.start() }
                }
            }
            lifecycleObservers.append((center, token))
        }
        observe(.default, PermissionWatchdog.accessibilityLost, suspend: true)
        observe(.default, PermissionWatchdog.accessibilityRecovered, suspend: false)
        observe(.default, NSApplication.didBecomeActiveNotification, suspend: false)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, suspend: true)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, suspend: false)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification, suspend: false)
    }

    private func removeTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func installTap() {
        MouseButtonMonitor.activeMonitor = self
        let specs = entries.filter { !$0.isLegacy }.map(\.spec)
        var mask: CGEventMask = 0
        func add(_ type: CGEventType) { mask |= (1 << type.rawValue) }
        // Legacy triggers are the extra buttons 3…7 only.
        if entries.contains(where: \.isLegacy) { add(.otherMouseDown); add(.otherMouseUp) }
        for button in Set(specs.filter { !$0.kind.isScroll }.map(\.button)).union(suppressedButtons) {
            switch button {
            case 0: add(.leftMouseDown); add(.leftMouseUp); add(.leftMouseDragged)
            case 1: add(.rightMouseDown); add(.rightMouseUp); add(.rightMouseDragged)
            default: add(.otherMouseDown); add(.otherMouseUp); add(.otherMouseDragged)
            }
        }
        if specs.contains(where: { $0.kind.isScroll }) { add(.scrollWheel) }

        let callback: CGEventTapCallBack = { _, type, event, _ -> Unmanaged<CGEvent>? in
            guard let monitor = MouseButtonMonitor.activeMonitor else { return Unmanaged.passUnretained(event) }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.tapWasDisabled()
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // Skip events posted by our own ActionExecutor
            if event.getIntegerValueField(.eventSourceUserData) == 0x475454 { return Unmanaged.passUnretained(event) }
            guard let input = MouseButtonMonitor.normalize(type: type, event: event, time: monitor.clock()) else {
                return Unmanaged.passUnretained(event)
            }
            if (3...4).contains(input.button), input.kind == .down || input.kind == .up,
               let swallow = monitor.sideDeduplicator.noteCG(.init(button: input.button, down: input.kind == .down), time: input.time) {
                return swallow ? nil : Unmanaged.passUnretained(event)
            }
            return monitor.handle(input) ? nil : Unmanaged.passUnretained(event)
        }

        // A tap that never suppresses anything only needs to observe. A
        // listen-only tap is handed a copy it cannot modify, so it stays off
        // the input hot path and out of the tapDisabledByTimeout failure mode
        // where a slow callback makes macOS disable the tap and delay events
        // system-wide. Escalate to an active tap only when a trigger actually
        // needs to swallow the click.
        let needsSuppression = !suppressedButtons.isEmpty || entries.contains { $0.suppressClick }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: needsSuppression ? .defaultTap : .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: nil)

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            NSLog("[MouseButtonMonitor] Registered %d triggers with a %@ event tap",
                  entries.count, needsSuppression ? "active" : "listen-only")
        } else {
            NSLog("[MouseButtonMonitor] Failed to create CGEventTap — check Accessibility permissions")
        }
    }

    static func normalize(type: CGEventType, event: CGEvent, time: TimeInterval) -> MouseInputEvent? {
        let flags = UInt(event.flags.rawValue)
        let point = event.location
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        switch type {
        case .leftMouseDown: return MouseInputEvent(kind: .down, button: 0, x: point.x, y: point.y, modifiers: flags, time: time)
        case .leftMouseUp: return MouseInputEvent(kind: .up, button: 0, x: point.x, y: point.y, modifiers: flags, time: time)
        case .leftMouseDragged: return MouseInputEvent(kind: .dragged, button: 0, x: point.x, y: point.y, modifiers: flags, time: time)
        case .rightMouseDown: return MouseInputEvent(kind: .down, button: 1, x: point.x, y: point.y, modifiers: flags, time: time)
        case .rightMouseUp: return MouseInputEvent(kind: .up, button: 1, x: point.x, y: point.y, modifiers: flags, time: time)
        case .rightMouseDragged: return MouseInputEvent(kind: .dragged, button: 1, x: point.x, y: point.y, modifiers: flags, time: time)
        case .otherMouseDown: return MouseInputEvent(kind: .down, button: number, x: point.x, y: point.y, modifiers: flags, time: time)
        case .otherMouseUp: return MouseInputEvent(kind: .up, button: number, x: point.x, y: point.y, modifiers: flags, time: time)
        case .otherMouseDragged: return MouseInputEvent(kind: .dragged, button: number, x: point.x, y: point.y, modifiers: flags, time: time)
        case .scrollWheel:
            return MouseInputEvent(kind: .scroll, modifiers: flags, time: time,
                                   scrollDX: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                                   scrollDY: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)))
        default: return nil
        }
    }

    func unregisterAll() {
        for (center, token) in lifecycleObservers { center.removeObserver(token) }
        lifecycleObservers.removeAll()
        hidGeneration += 1
        sideHID.stop()
        sideHID.onEvent = nil
        sideDeduplicator = MouseSideButtonDeduplicator()
        wake?.cancel(); wake = nil
        wakeDeadline = nil
        removeTap()
        if MouseButtonMonitor.activeMonitor === self {
            MouseButtonMonitor.activeMonitor = nil
        }
        entries.removeAll()
        suppressedButtons.removeAll()
        recognizer.reset()
    }

    deinit {
        unregisterAll()
    }
}
