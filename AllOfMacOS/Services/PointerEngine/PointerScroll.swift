import AppKit

/// Reverses a wheel mouse's scrolling and leaves trackpads (continuous
/// scrolling) alone, so each device keeps its own natural direction.
final class ScrollWheelReverser {
    static let shared = ScrollWheelReverser()
    fileprivate var reverseEnabled = false
    fileprivate var smoothEnabled = false
    private var smoothing = WheelSmoothing()
    private var animation: Timer?
    private var template: CGEvent?
    private var remainderX = 0.0
    private var remainderY = 0.0
    private var observing = false
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap != nil }

    func setEnabled(_ enabled: Bool) {
        stop()
        reverseEnabled = enabled
        smoothEnabled = InputRemapSettings.smoothMouseWheel
        if !observing {
            observing = true
            for name in [PermissionWatchdog.accessibilityRecovered, NSApplication.didBecomeActiveNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self, self.reverseEnabled || self.smoothEnabled else { return }
                    self.start()
                }
            }
            NotificationCenter.default.addObserver(forName: PermissionWatchdog.accessibilityLost, object: nil, queue: .main) { [weak self] _ in
                self?.stop()
            }
        }
        if reverseEnabled || smoothEnabled { start() }
    }

    func stopAll() {
        reverseEnabled = false
        smoothEnabled = false
        stop()
    }

    fileprivate func cancelAnimation() {
        animation?.invalidate()
        animation = nil
        template = nil
        smoothing = WheelSmoothing()
        remainderX = 0
        remainderY = 0
    }

    fileprivate func smooth(_ event: CGEvent) -> Bool {
        // Modified wheel events often zoom or navigate horizontally.
        guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
            cancelAnimation()
            return false
        }
        let x = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let y = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = x != 0 ? Double(x) : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
        let dy = y != 0 ? Double(y) : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
        guard dx != 0 || dy != 0, let copied = event.copy() else { return false }
        if dx * smoothing.remainingX < 0 { remainderX = 0 }
        if dy * smoothing.remainingY < 0 { remainderY = 0 }
        smoothing.add(x: dx, y: dy, at: ProcessInfo.processInfo.systemUptime)
        template = copied
        if animation == nil {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.animate() }
            animation = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }

    private func animate() {
        guard AutomationGate.allows(.mouse), let template else { cancelAnimation(); return }
        let delta = smoothing.step(at: ProcessInfo.processInfo.systemUptime)
        remainderX += delta.x
        remainderY += delta.y
        let rounding: FloatingPointRoundingRule = smoothing.active ? .towardZero : .toNearestOrAwayFromZero
        let x = Int32(remainderX.rounded(rounding))
        let y = Int32(remainderY.rounded(rounding))
        remainderX -= Double(x)
        remainderY -= Double(y)
        if x != 0 || y != 0, let output = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                wheel1: y, wheel2: x, wheel3: 0) {
            output.location = template.location
            output.flags = template.flags
            output.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
            output.post(tap: .cgSessionEventTap)
        }
        if !smoothing.active { cancelAnimation() }
    }

    private func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: scrollReverseCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            GestureLog.shared.logFromAnyThread("Reversing the mouse wheel needs Accessibility permission", level: .error)
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func stop() {
        cancelAnimation()
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    /// Reverse only discrete physical wheel ticks. Phase/momentum scrolls
    /// belong to touch surfaces even on drivers that omit isContinuous.
    static func shouldReverse(isContinuous: Int64, isSynthetic: Bool,
                              scrollPhase: Int64 = 0, momentumPhase: Int64 = 0) -> Bool {
        isContinuous == 0 && !isSynthetic && scrollPhase == 0 && momentumPhase == 0
    }

    static func reverse(_ event: CGEvent) {
        for (line, point, fixed) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1),
                                     (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)] {
            let lines = event.getIntegerValueField(line)
            let points = event.getIntegerValueField(point)
            let fraction = event.getDoubleValueField(fixed)
            event.setIntegerValueField(line, value: -lines)
            event.setIntegerValueField(point, value: -points)
            event.setDoubleValueField(fixed, value: -fraction)
        }
    }
}

private func scrollReverseCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let refcon {
        let engine = Unmanaged<ScrollWheelReverser>.fromOpaque(refcon).takeUnretainedValue()
        engine.cancelAnimation()
        if let port = engine.tap { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel, let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<ScrollWheelReverser>.fromOpaque(refcon).takeUnretainedValue()
    guard event.getIntegerValueField(.eventSourceUserData) != SyntheticInput.selfTag else { return Unmanaged.passUnretained(event) }
    guard AutomationGate.allows(.mouse), ScrollWheelReverser.shouldReverse(
        isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous), isSynthetic: false,
        scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
        momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)) else {
        engine.cancelAnimation()
        return Unmanaged.passUnretained(event)
    }
    if engine.reverseEnabled { ScrollWheelReverser.reverse(event) }
    if engine.smoothEnabled, engine.smooth(event) { return nil }
    return Unmanaged.passUnretained(event)
}
