import Foundation
import AppKit

class TrackpadMonitor {
    typealias Binding = (id: UUID, gesture: TrackpadGesture, actions: [TriggerAction], appBundleID: String?, suppressClick: Bool, hapticFeedback: Bool, requiredModifiers: UInt?, activationGroupID: UUID?)
    private let source = MultitouchSource()
    private var sessions: [UInt64: ContactGestureSession] = [:]
    private var activeDevice: UInt64?
    private var lastContactDevice: UInt64 = 0
    private var rawOwnedUntil: TimeInterval = 0
    private var lifecycleObservers: [Any] = []
    private var healthTimer: Timer?
    private var suspended = false
    private var lastRecovery: TimeInterval = 0
    private var lastDeviceScan: TimeInterval = 0
    private var diagnosticSignals: [DispatchSourceSignal] = []
    private var diagnosticTarget: String?
    private var hardwareFourFingerFrames = 0
    private var hardwareDetections: [String] = []
    private var recoveries = 0
    private var hardwareFrames = 0
    private var lastHardwareFrame: TimeInterval?
    private var latestRawStates: [Int] = []
    private var recentDetections: [String] = []
    private struct TapKey: Hashable {
        let device: UInt64
        let single: TrackpadGesture
        let app: String?
    }
    private var pendingTaps: [TapKey: (time: Double, item: DispatchWorkItem, targets: [Binding])] = [:]

    private let systemMonitoringEnabled: Bool
    private let customFrontmostBundleID: (() -> String?)?
    private var cachedFrontmostBundleID: String?
    private var appActivationObserver: Any?

    init(systemMonitoringEnabled: Bool = true,
         frontmostBundleID: (() -> String?)? = nil) {
        self.systemMonitoringEnabled = systemMonitoringEnabled
        self.customFrontmostBundleID = frontmostBundleID
        if frontmostBundleID == nil {
            self.cachedFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            self.appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notif in
                let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.cachedFrontmostBundleID = app?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        }
    }

    private func frontmostBundleID() -> String? {
        if let custom = customFrontmostBundleID {
            return custom()
        }
        return cachedFrontmostBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private let frameLock = NSLock()
    private var registrationGeneration = UUID()
    private var monitors: [Any] = []
    private var registeredTriggers: [Binding] = []
    /// Long Touch hold time (seconds) per registered trigger id.
    private var longTouchDurations: [UUID: Double] = [:]
    /// Held modifiers; injectable so scroll+modifier triggers are testable.
    var modifierFlagsProvider: () -> UInt = { NSEvent.modifierFlags.rawValue }
    private var trackpadScroll = ScrollStepper(step: 40, minInterval: 0.15)
    private var activationGroups: [ActivationGroup] = []
    // Click suppression via CGEventTap
    private var clickSuppressEventTap: CFMachPort?
    private var clickSuppressRunLoopSource: CFRunLoopSource?
    private var suppressedButtons = Set<Int>()
    private var tipTapShield = TipTapClickShield()
    /// Peak normalized pressure seen on the current contact, reset when the
    /// fingers lift. Force Click is judged against this because the pressure
    /// arrives on the frame stream while the click arrives from the mouse tap.
    private var peakPressure: Float = 0
    /// Highest force value ever seen from real hardware, for calibration.
    private var lastHardwarePressure: Float = 0
    /// Most recent frame's force reading, and how often each tenth was seen.
    private var livePressure: Float = 0
    private var pressureHistogram: [String: Int] = [:]
    /// Threshold above which a contact counts as a force press.
    ///
    /// Force Click is opt-in and off by default: this trackpad reports 1.0 for
    /// ordinary presses, so judging every click by pressure would turn existing
    /// corner and middle clicks into force clicks. A user enables it when they
    /// actually configure a Force Click trigger, and can tune the threshold.
    private static var forcePressThreshold: Float {
        let stored = UserDefaults.standard.object(forKey: "AOMForcePressThreshold") as? Double
        return Float(stored ?? 0.95)
    }
    private static var forcePressEnabled: Bool {
        UserDefaults.standard.bool(forKey: "AOMForcePressEnabled")
    }
    private var suppressedTipTapClicks = 0
    private static var activeTrackpadMonitor: TrackpadMonitor?

    // Swipe tracking
    private var scrollDeltaX: CGFloat = 0
    private var scrollDeltaY: CGFloat = 0
    private var scrollFingerCount: Int = 0
    private var scrollStartTime: Date?
    private let swipeThreshold: CGFloat = 50
    // Minimum velocity (points/sec) for a swipe to fire — per-gesture, fast flick vs slow scroll
    private func swipeMinVelocity(for gesture: TrackpadGesture) -> CGFloat {
        CGFloat(GestureSensitivity.velocity(for: gesture))
    }

    // Press-drag tracking
    private var pressDragDeltaX: CGFloat = 0
    private var pressDragActive = false

    // Pinch/rotate tracking
    private var magnification: CGFloat = 0
    private var rotation: CGFloat = 0

    private var currentFingers = 0
    private var gestureConsumed = false
    private let doubleTapWindow: TimeInterval = 0.4
    private var tipTapMinRestTime: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "AOMTipTapMinRestTime")
        return stored > 0 ? stored : 0.12
    }

    // Circle gesture detection (1-finger circular motion)
    private var circlePoints: [(x: Float, y: Float)] = []  // recent path points
    private var circleCumulativeAngle: Float = 0            // accumulated angle (radians)
    private var circleLastAngle: Float?                     // last angle to center
    private var circleCenterX: Float = 0                    // running centroid X
    private var circleCenterY: Float = 0                    // running centroid Y
    private let circleMinPoints: Int = 12                   // min points before checking
    private static let circleMaxPoints: Int = 96            // hard cap on the tracked path
    private var circleLastFiredAngle: Float = 0             // cumulative angle at last fire
    private var circleStartTime: Date?                      // when circling started
    private var circleFireCount: Int = 0                    // how many times we've fired this session
    private var trackpadIsPressed = false                   // true when trackpad is clicked down
    private var suppressedDrawingGesture: TrackpadGesture?
    private var circleDrawingActive = false                 // true while circle gesture is being drawn
    private var suppressionDeadline: TimeInterval = 0
    private static weak var mouseSuppressionOwner: TrackpadMonitor?
    private var mouseEventTap: CFMachPort?                  // CGEvent tap for suppressing mouse during circle
    private var mouseEventTapRunLoopSource: CFRunLoopSource?

    // Triangle gesture detection (1-finger pressing down and drawing)
    private var trianglePoints: [(x: Float, y: Float)] = []
    private var triangleFired = false

    // Edge slider detection (1-finger press + slide along edge, fires repeatedly)
    private var edgeSlideLastY: Float?
    private var edgeSlideEdge: EdgeSide?
    /// One-finger edge swipe: the origin and whether it has already fired, so a
    /// single drag along an edge produces one gesture rather than a stream.
    private var edgeSwipeOrigin: (x: Float, y: Float)?
    private var edgeSwipeFired = false
    private let edgeSlideZoneWidth: Float = 0.15   // leftmost/rightmost 15%
    private let edgeSlideStep: Float = 0.04        // fire every ~4% of trackpad height

    private enum EdgeSide { case left, right }

    // Position click detection (1-finger click at specific zone)
    private var lastSingleFingerPos: (x: Float, y: Float)?  // last known 1-finger position
    private var positionClickFired = false                   // prevent re-firing on same press
    private var positionClickGeneration = UUID()
    private var pendingPositionClickChecks = 0               // frames left to wait for the touch position

    func registerTriggers(_ triggers: [Trigger], groups: [ActivationGroup] = []) {
        activationGroups = groups
        invalidateRecognition()
        longTouchDurations.removeAll()
        registeredTriggers = triggers.compactMap { trigger in
            guard trigger.isEnabled, case .trackpadGesture(let gesture) = trigger.input else { return nil }
            // Scroll triggers without a modifier would fire on every scroll.
            if TriggerValidation.problem(for: trigger) != nil { return nil }
            if gesture.isLongTouch { longTouchDurations[trigger.id] = Double(trigger.longTouchDurationMs) / 1000 }
            return (trigger.id, gesture, trigger.actions, trigger.appBundleID, trigger.suppressClick, trigger.hapticFeedback, trigger.requiredModifiers, trigger.activationGroupID)
        }
        guard systemMonitoringEnabled else { return }
        // The Swish-style gesture layers read the same hardware stream; with
        // no trackpad trigger configured they were the only consumer, and the
        // stream used to shut down — every ported gesture went dead.
        let layersNeedHardware = MainActor.assumeIsolated {
            WindowGestureController.shared.anyLayerEnabled || TrackpadUtilityGestures.shared.anyLayerEnabled
        }
        if registeredTriggers.isEmpty && !layersNeedHardware { stopHardware(); return }
        if monitors.isEmpty { setupNSEventMonitors() }
        if healthTimer == nil { setupLifecycle() }
        if !source.running { startHardware(reason: "registration") }
        tearDownClickSuppressionTap()
        setupClickSuppressionTap()
    }

    private func startHardware(reason: String) {
        let layersNeedHardware = MainActor.assumeIsolated {
            WindowGestureController.shared.anyLayerEnabled || TrackpadUtilityGestures.shared.anyLayerEnabled
        }
        guard !suspended, !registeredTriggers.isEmpty || layersNeedHardware else { return }
        invalidateRecognition()
        source.onFrame = { [weak self] device, frame, timestamp in
            guard let self else { return }
            self.hardwareFrames += 1
            self.lastHardwareFrame = ProcessInfo.processInfo.systemUptime
            self.latestRawStates = frame.states
            if frame.contacts.count == 4 { self.hardwareFourFingerFrames += 1 }
            self.processTouchFrame(frame.contacts, count: frame.contacts.count, timestamp: timestamp,
                pressedButtons: NSEvent.pressedMouseButtons, deviceID: device)
        }
        source.start()
        lastRecovery = ProcessInfo.processInfo.systemUptime
        recoveries += 1
        GestureLog.shared.logFromAnyThread("Trackpad connected: \(source.deviceIDs.count) device(s), \(reason)" , level: .detect)
        writeDiagnostics()
    }

    private func setupLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspended = true; self.source.stop(); self.invalidateRecognition()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspended = false
                self.startHardware(reason: "wake/session active")
            })
        }
        if ProcessInfo.processInfo.arguments.contains("--aom-diagnostics") {
            for number in [SIGUSR1, SIGUSR2] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    if number == SIGUSR1 { self?.startHardware(reason: "diagnostic recovery") }
                    else { self?.replayDiagnosticContacts() }
                }
                source.resume(); diagnosticSignals.append(source)
            }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkHardwareHealth() }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func checkHardwareHealth() {
        let layersNeedHardware = MainActor.assumeIsolated {
            WindowGestureController.shared.anyLayerEnabled || TrackpadUtilityGestures.shared.anyLayerEnabled
        }
        guard systemMonitoringEnabled, !suspended, !registeredTriggers.isEmpty || layersNeedHardware else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if circleDrawingActive && now >= suppressionDeadline { stopSuppressingMouse() }
        if now - lastRecovery >= 5 {
            if !source.running { startHardware(reason: "device recovery") }
            else if now - lastDeviceScan >= 10 {
                lastDeviceScan = now
                if source.availableDeviceIDs() != Set(source.deviceIDs) { startHardware(reason: "device change") }
            }
        }
        writeDiagnostics()
    }

    func diagnosticSnapshot() -> [String: Any] {
        ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "test",
         "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test",
         "pid": ProcessInfo.processInfo.processIdentifier,
         "executable": Bundle.main.executablePath ?? "unknown",
         "accessibility": AXIsProcessTrusted(), "running": source.running,
         "deviceIDs": source.deviceIDs.map(String.init), "suspended": suspended,
         "frames": hardwareFrames, "rejectedFrames": source.rejectedFrames,
         "hardwareFourFingerFrames": hardwareFourFingerFrames, "hardwareDetections": hardwareDetections,
         "rawStates": latestRawStates, "activeContacts": currentFingers,
         "frameAgeSeconds": lastHardwareFrame.map { ProcessInfo.processInfo.systemUptime - $0 } ?? -1,
         "recoveries": recoveries, "registeredTriggers": registeredTriggers.count,
         "globalEnabled": UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true,
         "lastDetections": recentDetections, "suppressedTipTapClicks": suppressedTipTapClicks,
         // Exposed so the force threshold can be calibrated against real
         // hardware instead of guessed: a trackpad that never reports force
         // shows peak 0 here.
         "peakPressure": Double(peakPressure), "forceThreshold": Double(Self.forcePressThreshold),
         "forceReported": lastHardwarePressure > 0,
         // Live reading plus a coarse histogram, so the threshold can be set
         // from what this trackpad actually reports rather than guessed.
         "livePressure": Double(livePressure), "pressureHistogram": pressureHistogram,
         "error": source.error ?? ""]
    }

    /// Opt-in installation check. Actions are guarded again on the main queue;
    /// only the disposable receiver may receive them, never the user's active app.
    private func replayDiagnosticContacts() {
        let receiver = "com.kyw.allofmacos.gesture-test"
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == receiver else { return }
        diagnosticTarget = receiver
        defer { diagnosticTarget = nil }
        let start = ProcessInfo.processInfo.systemUptime
        func frame(_ y: Float, _ time: Double, state: Int32 = 4) {
            let points = (0..<4).map { TouchPoint(id: $0, x: 0.2 + Float($0) * 0.15, y: y, size: 0.4) }
            let bytes = GestureReplaySuite.rawFrame(points, state: state)
            guard let decoded = bytes.withUnsafeBytes({ TouchFrameDecoder.decode($0, count: 4) }) else { return }
            processTouchFrame(decoded.contacts, count: decoded.contacts.count, timestamp: time,
                              pressedButtons: 0, deviceID: UInt64.max)
        }
        frame(0.7, start); frame(0.7, start + 0.1, state: 7)
        frame(0.7, start + 0.2); frame(0.58, start + 0.3)
        frame(0.58, start + 0.4, state: 7)
        sessions.removeValue(forKey: UInt64.max)
    }

    private func writeDiagnostics() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--aom-diagnostics"), args.indices.contains(index + 1),
              let data = try? JSONSerialization.data(withJSONObject: diagnosticSnapshot(), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
    }

    /// Raw-buffer entry point shared by replay tests and the hardware decoder.
    func handleMultitouchFrame(rawTouches: UnsafeMutableRawPointer?, numTouches: Int, timestamp: Double) {
        guard (0...32).contains(numTouches) else { return }
        let frame: TouchFrameDecoder.Frame?
        if let rawTouches {
            frame = TouchFrameDecoder.decode(UnsafeRawBufferPointer(start: rawTouches, count: numTouches * TouchFrameDecoder.stride), count: numTouches)
        } else if numTouches == 0 {
            frame = TouchFrameDecoder.Frame(contacts: [], rawCount: 0, states: [])
        } else if !systemMonitoringEnabled {
            // Legacy count-only tests; production never fabricates contacts.
            frame = TouchFrameDecoder.Frame(contacts: (0..<numTouches).map {
                TouchPoint(id: $0, x: 0.2 + Float($0) * 0.1, y: 0.5, size: 0.1)
            }, rawCount: numTouches, states: Array(repeating: 4, count: numTouches))
        } else { frame = nil }
        guard let frame else { return }
        frameLock.lock(); let generation = registrationGeneration; frameLock.unlock()
        let apply = { [weak self] in
            guard let self, self.registrationGeneration == generation else { return }
            self.processTouchFrame(frame.contacts, count: frame.contacts.count, timestamp: timestamp, pressedButtons: 0)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func processTouchFrame(_ points: [TouchPoint], count: Int, timestamp: Double,
                           pressedButtons: Int, deviceID: UInt64 = 0) {
        // Gesture layers first: nothing below this line may skip them — an
        // early return for another device or an inactive secondary trackpad
        // used to swallow the window/utility gesture frames entirely.
        MainActor.assumeIsolated {
            // Every frame reaches the window gesture layer: the release frame
            // (count 0-2) is what commits a snap — routing it only to the
            // utility layer stranded every gesture mid-air.
            WindowGestureController.shared.observe(points: points, timestamp: timestamp)
            if points.count <= 2 {
                TrackpadUtilityGestures.shared.observe(points: points, timestamp: timestamp)
            }
        }
        tipTapShield.observe(device: deviceID, count: points.count, now: ProcessInfo.processInfo.systemUptime)
        // Track the peak so a click arriving from the mouse tap can tell a
        // force press from an ordinary one; the fingers lifting resets it.
        if points.isEmpty {
            peakPressure = 0
            livePressure = 0
        } else {
            let framePressure = points.map(\.pressure).max() ?? 0
            livePressure = framePressure
            peakPressure = max(peakPressure, framePressure)
            lastHardwarePressure = max(lastHardwarePressure, framePressure)
            // Bucketed to a tenth so a run of real touches shows the spread.
            let bucket = "0.\(Int((framePressure * 10).rounded(.down)))"
            pressureHistogram[bucket, default: 0] += 1
        }
        let enabled = Set(applicableTriggers.map(\.gesture))
        var session = sessions[deviceID] ?? ContactGestureSession()
        let applicable = applicableTriggers
        let gestures = session.update(points, timestamp: timestamp, pressed: pressedButtons != 0,
            enabled: enabled, restTime: tipTapMinRestTime, minVelocity: { [self] in swipeMinVelocity(for: $0) },
            longTouchDurations: { [self] gesture in
                let durations = applicable.filter { $0.gesture == gesture }.compactMap { longTouchDurations[$0.id] }
                return durations.isEmpty ? [0.5] : Array(Set(durations))
            })
        let longTouchDuration = session.lastLongTouchDuration
        sessions[deviceID] = session
        if session.peak >= 2 { rawOwnedUntil = ProcessInfo.processInfo.systemUptime + 0.3 }
        if systemMonitoringEnabled && deviceID != UInt64.max {
            hardwareDetections.append(contentsOf: gestures.map(\.rawValue))
            hardwareDetections = Array(hardwareDetections.suffix(20))
        }
        for gesture in gestures {
            switch gesture {
            case .twoFingerTap:
                handleTap(.twoFingerTap, double: .twoFingerDoubleTap, at: timestamp, device: deviceID)
            case .threeFingerTap:
                handleTap(.threeFingerTap, double: .threeFingerDoubleTap, at: timestamp, device: deviceID)
            case .oneFingerTap:
                handleTap(.oneFingerTap, double: .oneFingerDoubleTap, at: timestamp, device: deviceID)
            case .fourFingerTap:
                handleTap(.fourFingerTap, double: .fourFingerDoubleTap, at: timestamp, device: deviceID)
            case .oneFingerLongTouch, .twoFingerLongTouch, .threeFingerLongTouch, .fourFingerLongTouch, .fiveFingerLongTouch:
                queueGesture(gesture, deviceID: deviceID, longTouchDuration: longTouchDuration)
            default: queueGesture(gesture, deviceID: deviceID)
            }
        }
        // An idle secondary trackpad must not release the active trackpad's
        // click/drawing state or blank its live contacts.
        if activeDevice == nil, !points.isEmpty { activeDevice = deviceID }
        guard activeDevice == nil || activeDevice == deviceID else { return }
        lastContactDevice = deviceID
        currentFingers = points.count
        lastSingleFingerPos = points.count == 1 ? points.first.map { (x: $0.x, y: $0.y) } : nil
        MainActor.assumeIsolated {
            let display = LiveTouchState.shared
            display.present(points, pressed: pressedButtons != 0 && !points.isEmpty,
                            visible: display.visualizerCount > 0 && NSApp?.isActive == true)
        }
        if points.count >= 2 && pressedButtons != 0 && !pressDragActive {
            pressDragActive = true; pressDragDeltaX = 0
        }
        if pendingPositionClickChecks > 0, trackpadIsPressed { checkPendingPositionClick() }
        if let gesture = suppressedDrawingGesture,
           !enabled.contains(gesture) { stopSuppressingMouse() }
        if points.count == 1, let point = points.first {
            // Circle and triangle are drawn with the finger held down; an edge
            // swipe is not, so it is tracked for any single-finger contact.
            if pressedButtons & 1 != 0 {
                trackCirclePoint(x: point.x, y: point.y)
                trackTrianglePoint(x: point.x, y: point.y)
            }
            trackEdgeDrag(x: point.x, y: point.y)
        } else {
            resetCircleState(); resetTriangleState(); resetEdgeDragState(); stopSuppressingMouse()
        }
        if points.isEmpty { activeDevice = nil }
    }

    private func handleTap(_ single: TrackpadGesture, double: TrackpadGesture,
                           at timestamp: Double, device: UInt64) {
        // Single taps stay immediate unless this app has a double-tap binding.
        guard !matchingTriggers(for: double).isEmpty else { queueGesture(single); return }
        let key = TapKey(device: device, single: single, app: frontmostBundleID())
        if let pending = pendingTaps.removeValue(forKey: key) {
            pending.item.cancel()
            if timestamp - pending.time >= 0 && timestamp - pending.time < doubleTapWindow {
                queueGesture(double); return
            }
            fireGesture(single, targets: pending.targets)
        }
        let generation = registrationGeneration
        let targets = matchingTriggers(for: single)
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.registrationGeneration == generation else { return }
            self.pendingTaps.removeValue(forKey: key)
            guard self.frontmostBundleID() == key.app else { return }
            self.fireGesture(single, targets: targets)
        }
        pendingTaps[key] = (timestamp, timer, targets)
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: timer)
    }

    // MARK: - Circle gesture helpers

    private func trackCirclePoint(x: Float, y: Float) {
        guard hasCircleTrigger, !triangleFired else { return }
        if let last = circlePoints.last, hypot(x - last.x, y - last.y) < 0.003 { return }
        circlePoints.append((x, y))
        if circlePoints.count > Self.circleMaxPoints { circlePoints.removeFirst() }
        if circleFireCount == 0 {
            guard circlePoints.count >= 16 else { return }
            let xs = circlePoints.map(\.x), ys = circlePoints.map(\.y)
            let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
            guard min(width, height) > 0.035, max(width, height) < 0.25,
                  min(width, height) / max(width, height) > 0.5 else { return }
            circleCenterX = (xs.min()! + xs.max()!) / 2
            circleCenterY = (ys.min()! + ys.max()!) / 2
            guard isPathCircular(), let first = circlePoints.first,
                  hypot(x - first.x, y - first.y) < max(width, height) * 0.35 else { return }
            var signedTurn: Float = 0, absoluteTurn: Float = 0
            for (a, b) in zip(circlePoints, circlePoints.dropFirst()) {
                var delta = atan2(b.y - circleCenterY, b.x - circleCenterX) - atan2(a.y - circleCenterY, a.x - circleCenterX)
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                signedTurn += delta; absoluteTurn += abs(delta)
            }
            guard abs(signedTurn) > 5.2, abs(signedTurn) > absoluteTurn * 0.85 else { return }
            circleFireCount = 1
            circleLastAngle = atan2(y - circleCenterY, x - circleCenterX)
            circleCumulativeAngle = 0; circleLastFiredAngle = 0
            let gesture: TrackpadGesture = signedTurn > 0 ? .circleCounterClockwise : .circleClockwise
            startSuppressingMouse(for: gesture); queueGesture(gesture)
            resetTriangleState()
            return
        }
        let radius = hypot(x - circleCenterX, y - circleCenterY)
        guard radius > 0.01, radius < 0.16 else {
            resetCircleState(); stopSuppressingMouse(); return
        }
        let angle = atan2(y - circleCenterY, x - circleCenterX)
        if let last = circleLastAngle {
            var delta = angle - last
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            circleCumulativeAngle += delta
        }
        circleLastAngle = angle
        let progress = circleCumulativeAngle - circleLastFiredAngle
        if abs(progress) >= .pi / 2 {
            circleLastFiredAngle = circleCumulativeAngle
            circleFireCount += 1
            let gesture: TrackpadGesture = progress > 0 ? .circleCounterClockwise : .circleClockwise
            startSuppressingMouse(for: gesture); queueGesture(gesture)
        }
    }

    /// Check if the tracked path is roughly circular (not a line or zigzag)
    private func isPathCircular() -> Bool {
        guard circlePoints.count >= circleMinPoints else { return false }

        // Calculate distances from each point to the centroid
        let distances = circlePoints.map { p -> Float in
            let dx = p.x - circleCenterX
            let dy = p.y - circleCenterY
            return sqrt(dx * dx + dy * dy)
        }

        let meanDist = distances.reduce(0, +) / Float(distances.count)

        // Path must have a minimum radius (not just jitter in place)
        // but also a maximum — only small coin-sized circles should trigger
        guard meanDist > 0.02 && meanDist < 0.09 else { return false }

        // Check coefficient of variation (std dev / mean)
        // A circle has low variation, a line has high variation
        let variance = distances.map { ($0 - meanDist) * ($0 - meanDist) }.reduce(0, +) / Float(distances.count)
        let stdDev = sqrt(variance)
        let cv = stdDev / meanDist

        // A perfect circle has cv ≈ 0. Allow up to 0.45 for imperfect human circles.
        // Lines typically have cv > 0.5
        return cv < 0.45
    }

    private func resetCircleState() {
        circlePoints.removeAll()
        circleCumulativeAngle = 0
        circleLastAngle = nil
        circleCenterX = 0
        circleCenterY = 0
        circleLastFiredAngle = 0
        circleStartTime = nil
        circleFireCount = 0
    }

    /// Whether anything is actually bound to a gesture that needs the pointer
    /// frozen while it is drawn. Suppressing input when no such trigger exists
    /// freezes ordinary drags for no reason at all.
    private var applicableTriggers: [(id: UUID, gesture: TrackpadGesture, actions: [TriggerAction], appBundleID: String?, suppressClick: Bool, hapticFeedback: Bool, requiredModifiers: UInt?, activationGroupID: UUID?)] {
        guard UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true else { return [] }
        let front = frontmostBundleID()
        return registeredTriggers.filter { binding in
            guard TriggerResolver.modifiersMatch(binding.requiredModifiers, modifierFlagsProvider()) else { return false }
            if let id = binding.activationGroupID { return activationGroups.contains { $0.id == id && $0.matches(front) } }
            if let bundleID = binding.appBundleID { return bundleID == front }
            return !activationGroups.contains { $0.matches(front) && $0.disableGlobalTriggers }
        }
    }

    /// Whether any registered trigger is a circle gesture.
    private var hasCircleTrigger: Bool {
        applicableTriggers.contains {
            $0.gesture == .circleClockwise || $0.gesture == .circleCounterClockwise
        }
    }

    /// Whether any registered trigger is the triangle drawing gesture.
    private var hasTriangleTrigger: Bool {
        applicableTriggers.contains { $0.gesture == .drawTriangle }
    }

    /// Whether any registered trigger is an edge-slide gesture.
    private var hasEdgeSlideTrigger: Bool {
        applicableTriggers.contains { entry in
            switch entry.gesture {
            case .leftEdgeSlideUp, .leftEdgeSlideDown,
                 .rightEdgeSlideUp, .rightEdgeSlideDown:
                return true
            default:
                return false
            }
        }
    }

    /// Whether any registered trigger is a one-finger edge swipe.
    private var hasEdgeSwipeTrigger: Bool {
        applicableTriggers.contains { entry in
            switch entry.gesture {
            case .oneFingerSwipeUpOnLeftEdge, .oneFingerSwipeDownOnLeftEdge,
                 .oneFingerSwipeUpOnRightEdge, .oneFingerSwipeDownOnRightEdge,
                 .oneFingerSwipeLeftOnTopEdge, .oneFingerSwipeRightOnTopEdge,
                 .oneFingerSwipeLeftOnBottomEdge, .oneFingerSwipeRightOnBottomEdge:
                return true
            default:
                return false
            }
        }
    }

    /// How far a finger must travel along an edge before the swipe fires.
    private let edgeSwipeStep: Float = 0.12

    private func startSuppressingMouse(for gesture: TrackpadGesture) {
        let suppress = UserDefaults.standard.object(forKey: "AOMSuppressMouseDuringDrawing") as? Bool ?? true

        // Only freeze the pointer when a drawing gesture is actually bound —
        // otherwise a plain drag gets swallowed by a tap nobody asked for.
        guard suppress, UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true,
              TriggerSuppression.shared.allows(kind: .trackpad), !matchingTriggers(for: gesture).isEmpty else {
            stopSuppressingMouse()
            return
        }
        suppressionDeadline = ProcessInfo.processInfo.systemUptime + 0.15
        suppressedDrawingGesture = gesture
        guard !circleDrawingActive else { return }
        // Tests exercise ownership without creating a system-wide event tap.
        if !systemMonitoringEnabled {
            circleDrawingActive = true
            suppressedDrawingGesture = gesture
            return
        }
        NSLog("[TrackpadMonitor] mouse suppression ON")

        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, _ in
                guard let owner = TrackpadMonitor.mouseSuppressionOwner else { return .passUnretained(event) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async { [weak owner] in owner?.stopSuppressingMouse() }
                    return .passUnretained(event)
                }
                if !TriggerSuppression.shared.allows(kind: .trackpad) ||
                   event.getIntegerValueField(.eventSourceUserData) == 0x475454 ||
                   ProcessInfo.processInfo.systemUptime >= owner.suppressionDeadline || NSEvent.pressedMouseButtons & 1 == 0 {
                    return .passUnretained(event)
                }
                return nil
            },
            userInfo: nil
        ) else { return }

        circleDrawingActive = true
        TrackpadMonitor.mouseSuppressionOwner = self
        suppressedDrawingGesture = gesture
        mouseEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mouseEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)


    }

    private func stopSuppressingMouse() {
        guard circleDrawingActive else { return }
        circleDrawingActive = false
        if TrackpadMonitor.mouseSuppressionOwner === self { TrackpadMonitor.mouseSuppressionOwner = nil }
        suppressionDeadline = 0
        suppressedDrawingGesture = nil
        NSLog("[TrackpadMonitor] mouse suppression OFF")
        if let tap = mouseEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = mouseEventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            mouseEventTap = nil
            mouseEventTapRunLoopSource = nil
        }
    }

    // MARK: - Triangle gesture helpers

    private func trackTrianglePoint(x: Float, y: Float) {
        // Same reasoning as the circle detector: skip entirely when no triangle
        // trigger is bound.
        guard hasTriangleTrigger else { return }

        if let last = trianglePoints.last, hypot(x - last.x, y - last.y) < 0.004 { return }
        trianglePoints.append((x: x, y: y))
        if trianglePoints.count > 128 {
            trianglePoints = rdpSimplify(trianglePoints, epsilon: 0.004)
            if trianglePoints.count > 128 { triangleFired = true; return }
        }
        // Don't check triangle if circle already fired this session, or triangle already fired
        guard !triangleFired, circleFireCount == 0, trianglePoints.count >= 12 else { return }
        if isTriangle() {
            // Suppress only once the path is actually a triangle. Suppressing at
            // the 20-point mark swallowed every ordinary drag that lasted longer
            // than about a third of a second, freezing the pointer.
            triangleFired = true
            startSuppressingMouse(for: .drawTriangle)
            resetCircleState()  // suppress circle since triangle won
            queueGesture(.drawTriangle)
        }
    }

    /// Detect if the drawn path forms a triangle:
    /// 1. Simplify the path using Ramer-Douglas-Peucker
    /// 2. Check if simplified path has ~3 corners
    /// 3. Verify the path is roughly closed
    private func isTriangle() -> Bool {
        let pts = trianglePoints
        guard pts.count >= 12 else { return false }

        // Path must span a minimum area (not just jitter)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let span = max(maxX - minX, maxY - minY)
        guard span > 0.08 else { return false }

        // Reject if path looks circular (let circle detector handle it)
        if isPathCircular() { return false }

        // Check path is roughly closed (end near start)
        let startX = pts.first!.x, startY = pts.first!.y
        let endX = pts.last!.x, endY = pts.last!.y
        let closeDist = sqrt((endX - startX) * (endX - startX) + (endY - startY) * (endY - startY))
        guard closeDist < span * 0.4 else { return false }

        // Simplify path with RDP algorithm
        let simplified = rdpSimplify(pts, epsilon: span * 0.08)
        // A triangle simplifies to 3-5 points (3 corners + closure)
        // Remove last point if it's close to first (closure duplicate)
        var corners = simplified
        if corners.count >= 3 {
            let last = corners.last!, first = corners.first!
            let d = sqrt((last.x - first.x) * (last.x - first.x) + (last.y - first.y) * (last.y - first.y))
            if d < span * 0.15 {
                corners.removeLast()
            }
        }

        // Should have exactly 3 corners
        guard corners.count == 3 else { return false }

        // Verify angles at each corner are reasonable for a triangle (30°–150°)
        for i in 0..<3 {
            let a = corners[i]
            let b = corners[(i + 1) % 3]
            let c = corners[(i + 2) % 3]
            let angle = angleBetween(a: a, vertex: b, c: c)
            if angle < 0.5 || angle > 2.6 { return false } // ~30° to ~150°
        }

        return true
    }

    /// Ramer-Douglas-Peucker line simplification
    private func rdpSimplify(_ points: [(x: Float, y: Float)], epsilon: Float) -> [(x: Float, y: Float)] {
        guard points.count > 2 else { return points }

        // Find the point with maximum distance from the line between first and last
        let first = points.first!, last = points.last!
        var maxDist: Float = 0
        var maxIdx = 0
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(point: points[i], lineStart: first, lineEnd: last)
            if d > maxDist {
                maxDist = d
                maxIdx = i
            }
        }

        if maxDist > epsilon {
            let left = rdpSimplify(Array(points[0...maxIdx]), epsilon: epsilon)
            let right = rdpSimplify(Array(points[maxIdx...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        } else {
            return [first, last]
        }
    }

    private func perpendicularDistance(point: (x: Float, y: Float), lineStart: (x: Float, y: Float), lineEnd: (x: Float, y: Float)) -> Float {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.0001 else {
            return sqrt((point.x - lineStart.x) * (point.x - lineStart.x) + (point.y - lineStart.y) * (point.y - lineStart.y))
        }
        return abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x) / len
    }

    private func angleBetween(a: (x: Float, y: Float), vertex: (x: Float, y: Float), c: (x: Float, y: Float)) -> Float {
        let v1x = a.x - vertex.x, v1y = a.y - vertex.y
        let v2x = c.x - vertex.x, v2y = c.y - vertex.y
        let dot = v1x * v2x + v1y * v2y
        let cross = v1x * v2y - v1y * v2x
        return abs(atan2(cross, dot))
    }

    private func resetTriangleState() {
        trianglePoints.removeAll()
        triangleFired = false
    }

    // MARK: - Edge drag detection

    private func trackEdgeDrag(x: Float, y: Float) {
        // Skip when no edge-slide trigger is bound — otherwise a plain drag that
        // happens to start near an edge is inspected every frame for nothing.
        guard hasEdgeSlideTrigger || hasEdgeSwipeTrigger else { return }

        // Determine if finger is on an edge. The swipe uses a wider band so the
        // top and bottom edges are reachable too, not just the sides.
        let onLeft = x < edgeSlideZoneWidth
        let onRight = x > (1.0 - edgeSlideZoneWidth)
        let onEdge = onLeft || onRight || y < edgeSlideZoneWidth || y > (1.0 - edgeSlideZoneWidth)

        guard onEdge else {
            resetEdgeDragState()
            return
        }

        // A one-finger swipe along any edge is a separate gesture from the
        // vertical slide. It fires once per drag, on the axis the edge implies,
        // so it does not compete with the stepping slide below.
        if hasEdgeSwipeTrigger {
            if edgeSwipeOrigin == nil { edgeSwipeOrigin = (x, y); edgeSwipeFired = false }
            if let origin = edgeSwipeOrigin, !edgeSwipeFired {
                let dx = x - origin.x, dy = y - origin.y
                if hypot(dx, dy) >= edgeSwipeStep,
                   let gesture = ContactGestureSession.edgeSwipe(origin: TouchPoint(id: 0, x: origin.x, y: origin.y, size: 0), dx: dx, dy: dy),
                   matchingTriggers(for: gesture).isEmpty == false {
                    edgeSwipeFired = true
                    queueGesture(gesture)
                }
            }
        }

        guard onLeft || onRight else {
            // Top and bottom edges carry the swipe only; the stepping slide is
            // a left/right-edge gesture.
            edgeSlideLastY = nil; edgeSlideEdge = nil
            return
        }
        let side: EdgeSide = onLeft ? .left : .right

        guard let lastY = edgeSlideLastY, edgeSlideEdge == side else {
            // Start tracking. Suppression begins only once the finger actually
            // slides along the edge: starting it here froze any plain drag that
            // happened to begin within the outer 15% of the trackpad, such as a
            // scrollbar or a window edge.
            edgeSlideLastY = y
            edgeSlideEdge = side
            return
        }

        let deltaY = y - lastY
        if abs(deltaY) >= edgeSlideStep {
            // Fire once per step, then advance the anchor
            let gesture: TrackpadGesture
            switch (side, deltaY > 0) {
            case (.left, true):   gesture = .leftEdgeSlideUp
            case (.left, false):  gesture = .leftEdgeSlideDown
            case (.right, true):  gesture = .rightEdgeSlideUp
            case (.right, false): gesture = .rightEdgeSlideDown
            }
            let steps = min(5, Int(abs(deltaY) / edgeSlideStep))
            edgeSlideLastY = lastY + Float(steps) * edgeSlideStep * (deltaY > 0 ? 1 : -1)
            startSuppressingMouse(for: gesture)
            for _ in 0..<steps { queueGesture(gesture) }
        }
    }

    private func resetEdgeDragState() {
        if let gesture = suppressedDrawingGesture,
           [.leftEdgeSlideUp, .leftEdgeSlideDown, .rightEdgeSlideUp, .rightEdgeSlideDown].contains(gesture) {
            stopSuppressingMouse()
        }
        edgeSlideLastY = nil
        edgeSlideEdge = nil
        edgeSwipeOrigin = nil
        edgeSwipeFired = false
    }

    // MARK: - Position click detection

    /// Corner zones as a fraction of the trackpad. Generous on purpose: the
    /// user has to land inside one while clicking, and a 12% square is a small
    /// target to hit blind.
    private static let cornerZoneW: Float = 0.18
    private static let cornerZoneH: Float = 0.18

    private func positionClickGesture(at pos: (x: Float, y: Float)) -> TrackpadGesture? {
        let x = pos.x
        let y = pos.y

        // Zone layout (normalized 0-1, origin bottom-left):
        // Corners: at the tips of the trackpad
        // Middle top/bottom: wider strip spanning more of the center edge
        let middleH: Float = 0.20   // middle strips extend further in than corners

        if x < Self.cornerZoneW && y > (1 - Self.cornerZoneH) {
            return .cornerClickTopLeft
        } else if x > (1 - Self.cornerZoneW) && y > (1 - Self.cornerZoneH) {
            return .cornerClickTopRight
        } else if x < Self.cornerZoneW && y < Self.cornerZoneH {
            return .cornerClickBottomLeft
        } else if x > (1 - Self.cornerZoneW) && y < Self.cornerZoneH {
            return .cornerClickBottomRight
        } else if y > (1 - middleH) {
            return .middleClickTop
        } else if y < middleH {
            return .middleClickBottom
        }
        return nil
    }

    /// Force-press corners reuse the corner zone map, so a force press and a
    /// plain click in the same spot resolve to the matching pair of gestures.
    private func forceCornerGesture(at pos: (x: Float, y: Float)) -> TrackpadGesture? {
        switch positionClickGesture(at: pos) {
        case .cornerClickTopLeft: return .cornerForceClickTopLeft
        case .cornerClickTopRight: return .cornerForceClickTopRight
        case .cornerClickBottomLeft: return .cornerForceClickBottomLeft
        case .cornerClickBottomRight: return .cornerForceClickBottomRight
        default: return nil
        }
    }

    /// Called on mouse-down. The touch position for the click may not have
    /// arrived yet — touches and the click come from different sources and the
    /// click can win the race — so if the position is not known yet, look for
    /// it over the next few frames instead of dropping the gesture.
    private func handlePositionClick() {
        guard !positionClickFired else { return }

        if let pos = lastSingleFingerPos, currentFingers == 1 {
            firePositionClickIfAny(pos)
            return
        }

        // Position not available yet. Give the multitouch callback a moment to
        // report it, then decide.
        positionClickGeneration = UUID()
        pendingPositionClickChecks = 3
        checkPendingPositionClick()
    }

    private func checkPendingPositionClick() {
        guard pendingPositionClickChecks > 0, !positionClickFired else {
            pendingPositionClickChecks = 0
            return
        }
        pendingPositionClickChecks -= 1
        if trackpadIsPressed, currentFingers == 2 || currentFingers == 3 {
            positionClickFired = true; pendingPositionClickChecks = 0
            sessions[lastContactDevice]?.consume()
            queueGesture(ContactGestureSession.clickGesture(fingers: currentFingers) ?? .twoFingerClick)
            return
        }
        if let pos = lastSingleFingerPos, currentFingers == 1 {
            firePositionClickIfAny(pos)
            return
        }
        if pendingPositionClickChecks > 0 {
            let generation = positionClickGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.positionClickGeneration == generation else { return }
                self.checkPendingPositionClick()
            }
        }
    }

    private func firePositionClickIfAny(_ pos: (x: Float, y: Float)) {
        guard let gesture = clickGesture(at: pos) else { return }
        positionClickFired = true
        pendingPositionClickChecks = 0
        queueGesture(gesture)
    }

    /// Test seam: the same judgement the click paths use.
    func clickGestureForTesting(x: Float, y: Float) -> TrackpadGesture? {
        clickGesture(at: (x: x, y: y))
    }

    /// The one place that decides which gesture a click is, so the fire path
    /// and the suppression path can never disagree. A force press outranks the
    /// plain click it is built on, which is why pressure is checked first.
    private func clickGesture(at pos: (x: Float, y: Float)) -> TrackpadGesture? {
        if Self.forcePressEnabled, peakPressure >= Self.forcePressThreshold {
            return forceCornerGesture(at: pos) ?? .forceClick
        }
        return positionClickGesture(at: pos)
    }

    // MARK: - NSEvent monitors for scroll/pinch/rotate

    private func setupNSEventMonitors() {
        let scrollHandler: (NSEvent) -> Void = { [weak self] e in self?.handleScroll(e) }
        let magnifyHandler: (NSEvent) -> Void = { [weak self] e in self?.handleMagnify(e) }
        let rotateHandler: (NSEvent) -> Void = { [weak self] e in self?.handleRotate(e) }
        let dragHandler: (NSEvent) -> Void = { [weak self] e in self?.handleDrag(e) }
        // Left-click press: used for gesture logic (circle, position click)
        // Visual press state is handled in the multitouch callback via NSEvent.pressedMouseButtons
        let leftPressHandler: (NSEvent) -> Void = { [weak self] event in self?.handleMousePress(event) }
        let leftReleaseHandler: (NSEvent) -> Void = { [weak self] event in self?.handleMouseRelease(event) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: scrollHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { e in scrollHandler(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .magnify, handler: magnifyHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { e in magnifyHandler(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .rotate, handler: rotateHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .rotate, handler: { e in rotateHandler(e); return e }) {
            monitors.append(m)
        }
        // Left mouse — gesture logic + visual
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: leftPressHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { e in leftPressHandler(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: leftReleaseHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { e in leftReleaseHandler(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: dragHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged, handler: { e in dragHandler(e); return e }) {
            monitors.append(m)
        }
        // Right mouse — 2-finger click on trackpad is a right-click by default
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: leftPressHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { e in leftPressHandler(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseUp, handler: leftReleaseHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp, handler: { e in leftReleaseHandler(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDragged, handler: dragHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDragged, handler: { e in dragHandler(e); return e }) {
            monitors.append(m)
        }
    }

    func handleMousePress(_ event: NSEvent? = nil) {
        // Mouse actions generated by AOM must not recursively trigger clicks.
        guard event?.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x475454 else { return }
        if event?.type == .rightMouseDown {
            // Keep native context menus independent of primary-click zones.
            if currentFingers == 2 || currentFingers == 3 {
                let gesture: TrackpadGesture = ContactGestureSession.clickGesture(fingers: currentFingers) ?? .twoFingerClick
                if !matchingTriggers(for: gesture).isEmpty { sessions[lastContactDevice]?.consume(); queueGesture(gesture) }
            }
            return
        }
        trackpadIsPressed = true
        gestureConsumed = true
        sessions[lastContactDevice]?.consume()
        if currentFingers >= 2 {
            pressDragDeltaX = 0
            pressDragActive = true
        }
        let forced = Self.forcePressEnabled && peakPressure >= Self.forcePressThreshold
        switch currentFingers {
        case 2: queueGesture(forced ? .forceClickTwoFinger : .twoFingerClick)
        case 3: queueGesture(forced ? .forceClickThreeFinger : .threeFingerClick)
        case 4: queueGesture(.fourFingerClick)
        case 5: queueGesture(.fiveFingerClick)
        default: handlePositionClick()
        }
    }

    func handleMouseRelease(_ event: NSEvent? = nil) {
        guard event?.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x475454 else { return }
        handlePressDragEnd()
        trackpadIsPressed = false
        positionClickFired = false
        positionClickGeneration = UUID()
        pendingPositionClickChecks = 0
        resetCircleState()
        resetTriangleState()
        resetEdgeDragState()
        stopSuppressingMouse()
    }

    // MARK: - Press-drag handling

    private func handleDrag(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x475454 else { return }
        // Accumulate while the drag is armed rather than while exactly two
        // fingers are down: the finger count dips as fingers lift mid-gesture,
        // and dropping those deltas loses most of the travel.
        processMouseDrag(deltaX: event.deltaX)
    }

    func processMouseDrag(deltaX: CGFloat) {
        guard pressDragActive else { return }
        pressDragDeltaX += deltaX
    }

    private func handlePressDragEnd() {
        // Do not require currentFingers == 2 here. The natural way to finish a
        // press-drag is to lift the fingers before releasing the click, which
        // drives the finger count to 0 and used to discard the whole gesture.
        guard pressDragActive else {
            pressDragDeltaX = 0; pressDragActive = false; return
        }
        let stored = UserDefaults.standard.double(forKey: "AOMPressDragThreshold")
        let threshold: CGFloat = stored > 0 ? CGFloat(stored) : 300
        if abs(pressDragDeltaX) > threshold {
            let gesture: TrackpadGesture = pressDragDeltaX > 0 ? .twoFingerPressDragRight : .twoFingerPressDragLeft
            fireGesture(gesture)
        }
        pressDragDeltaX = 0; pressDragActive = false
    }

    // MARK: - Scroll / Swipe handling

    private func handleScroll(_ event: NSEvent) {
        processScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            phase: event.phase, momentumPhase: event.momentumPhase,
            precise: event.hasPreciseScrollingDeltas, timestamp: event.timestamp)
    }

    /// "Scroll Up/Down (modifier key needed)": discrete steps from two-finger
    /// scrolling while the trigger's modifiers are held. Runs even when the raw
    /// multitouch source is active, because scrolling is not part of that stream.
    /// Direction follows the delivered delta: positive Y = Up.
    private func processScrollTrigger(deltaX: CGFloat, deltaY: CGFloat, momentumPhase: NSEvent.Phase, timestamp: TimeInterval) {
        guard momentumPhase.isEmpty else { return }
        var wanted = Set<MouseTriggerKind>()
        for entry in applicableTriggers {
            if entry.gesture == .scrollUp { wanted.insert(.scrollUp) }
            if entry.gesture == .scrollDown { wanted.insert(.scrollDown) }
        }
        guard !wanted.isEmpty,
              let kind = trackpadScroll.feed(dx: Double(deltaX), dy: Double(deltaY), time: timestamp, wanted: wanted) else { return }
        queueGesture(kind == .scrollUp ? .scrollUp : .scrollDown)
    }

    func processScroll(deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
                       momentumPhase: NSEvent.Phase = [], precise: Bool = true, timestamp: TimeInterval) {
        processScrollTrigger(deltaX: deltaX, deltaY: deltaY, momentumPhase: momentumPhase, timestamp: timestamp)
        guard !source.running, ProcessInfo.processInfo.systemUptime >= rawOwnedUntil else { return }
        let now = Date(timeIntervalSince1970: timestamp)
        guard precise, momentumPhase.isEmpty else { return }
        if phase.contains(.cancelled) {
            scrollDeltaX = 0; scrollDeltaY = 0; scrollFingerCount = 0; scrollStartTime = nil
            return
        }

        if phase == .began || phase == .mayBegin {
            scrollDeltaX = 0; scrollDeltaY = 0
            scrollStartTime = now
            // Use multitouch finger count (reliable) instead of event.touches() (empty for global monitors)
            scrollFingerCount = max(currentFingers, 2)
        }

        // Update finger count from multitouch if more fingers landed or we missed .began
        if currentFingers > scrollFingerCount {
            scrollFingerCount = currentFingers
        } else if scrollFingerCount == 0 {
            scrollFingerCount = max(currentFingers, 2)
        }
        if scrollStartTime == nil {
            scrollStartTime = now
        }

        scrollDeltaX += deltaX
        scrollDeltaY += deltaY

        // Only consume gesture after meaningful scroll movement (preserves taps)
        let scrollConsumeThreshold: CGFloat = currentFingers >= 4 ? 50 : 25
        if abs(scrollDeltaX) > scrollConsumeThreshold || abs(scrollDeltaY) > scrollConsumeThreshold {
            gestureConsumed = true
        }

        if phase.contains(.ended) {
            let duration = now.timeIntervalSince(scrollStartTime ?? now)
            // Decide before clearing the accumulators — the decision needs them.
            let decision = SwipeResolver.decide(
                deltaX: scrollDeltaX,
                deltaY: scrollDeltaY,
                fingerCount: scrollFingerCount,
                duration: duration,
                distanceThreshold: swipeThreshold,
                minVelocityFor: { [self] gesture in swipeMinVelocity(for: gesture) }
            )
            scrollDeltaX = 0; scrollDeltaY = 0; scrollFingerCount = 0; scrollStartTime = nil

            // Four-finger motion is owned by the raw recognizer. A scroll
            // event for the same hand movement must not also fire a swipe.
            guard let decision, ![TrackpadGesture.fourFingerSwipeUp, .fourFingerSwipeDown,
                                  .fourFingerSwipeLeft, .fourFingerSwipeRight].contains(decision.gesture) else { return }
            GestureLog.shared.logFromAnyThread(
                "Swipe velocity: \(Int(decision.velocity)) pts/sec (min: \(Int(decision.minVelocity)))",
                level: .detect
            )
            fireGesture(decision.gesture)
        }
    }

    // MARK: - Magnify

    private func handleMagnify(_ event: NSEvent) {
        processMagnify(delta: event.magnification, phase: event.phase)
    }

    func processMagnify(delta: CGFloat, phase: NSEvent.Phase) {
        guard !source.running, ProcessInfo.processInfo.systemUptime >= rawOwnedUntil else { return }
        if phase.contains(.cancelled) { magnification = 0; return }
        if phase == .began { magnification = 0 }
        magnification += delta
        if abs(magnification) > 0.02 { gestureConsumed = true }
        if phase.contains(.ended) {
            if magnification > 0.1 { fireGesture(.twoFingerPinchOut) }
            else if magnification < -0.1 { fireGesture(.twoFingerPinchIn) }
            magnification = 0
        }
    }

    // MARK: - Rotate

    private func handleRotate(_ event: NSEvent) {
        processRotate(delta: CGFloat(event.rotation), phase: event.phase)
    }

    func processRotate(delta: CGFloat, phase: NSEvent.Phase) {
        guard !source.running, ProcessInfo.processInfo.systemUptime >= rawOwnedUntil else { return }
        if phase.contains(.cancelled) { rotation = 0; return }
        if phase == .began { rotation = 0 }
        rotation += delta
        if abs(rotation) > 1 { gestureConsumed = true }
        if phase.contains(.ended) {
            if rotation > 5 { fireGesture(.twoFingerRotateRight) }
            else if rotation < -5 { fireGesture(.twoFingerRotateLeft) }
            rotation = 0
        }
    }

    // MARK: - Click Suppression CGEventTap

    private func setupClickSuppressionTap() {
        guard registeredTriggers.contains(where: { $0.suppressClick }) else { return }
        TrackpadMonitor.activeTrackpadMonitor = self
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        clickSuppressEventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
                guard let monitor = TrackpadMonitor.activeTrackpadMonitor else { return .passUnretained(event) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.suppressedButtons.removeAll()
                    if let tap = monitor.clickSuppressEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return .passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == 0x475454 { return .passUnretained(event) }
                return monitor.shouldSuppressMouseEvent(type) ? nil : .passUnretained(event)
            }, userInfo: nil)
        if let tap = clickSuppressEventTap {
            clickSuppressRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), clickSuppressRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func shouldSuppressMouseEvent(_ type: CGEventType,
                                  at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let button = (type == .rightMouseDown || type == .rightMouseUp) ? 1 : 0
        if type == .leftMouseUp || type == .rightMouseUp {
            guard suppressedButtons.remove(button) != nil else { return false }
            handleMouseRelease(); return true
        }
        guard type == .leftMouseDown || type == .rightMouseDown else { return false }
        suppressedButtons.remove(button) // Resynchronize on a fresh down after a lost up.
        guard TriggerSuppression.shared.allows(kind: .trackpad) else { return false }
        let enabled = UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true
        if enabled, type == .leftMouseDown, tipTapShield.contains(now) {
            // Pair every residual click, including a delayed second click,
            // without turning the residual movement into another gesture.
            suppressedButtons.insert(button)
            suppressedTipTapClicks += 1
            return true
        }
        if type == .rightMouseDown {
            // A native secondary tap may arrive after a contact has lifted.
            // Never let a stale corner position or TipTap shield eat it.
            guard currentFingers == 2 || currentFingers == 3 else { return false }
        }
        guard let gesture = clickGestureToSuppress() else { return false }
        suppressedButtons.insert(button)
        sessions[lastContactDevice]?.consume()
        trackpadIsPressed = true
        positionClickFired = true
        queueGesture(gesture)
        return true
    }

    /// Returns the click gesture to suppress if the current trackpad state matches a registered
    /// click gesture that has suppressClick enabled, or nil if no suppression should happen.
    func clickGestureToSuppress() -> TrackpadGesture? {
        let globalEnabled = UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true
        guard globalEnabled, TriggerSuppression.shared.allows(kind: .trackpad) else { return nil }

        // Determine which gesture would fire based on finger count and position
        let gesture: TrackpadGesture?
        if currentFingers == 1, let pos = lastSingleFingerPos {
            // Same judgement the fire path uses, so a click cannot be
            // suppressed for one gesture and then fire a different one.
            gesture = clickGesture(at: pos)
        } else if let clicked = ContactGestureSession.clickGesture(fingers: currentFingers) {
            // Four and five fingers are plain clicks; the force variants only
            // exist for two and three.
            if Self.forcePressEnabled && peakPressure >= Self.forcePressThreshold {
                gesture = currentFingers == 2 ? .forceClickTwoFinger
                    : currentFingers == 3 ? .forceClickThreeFinger : clicked
            } else {
                gesture = clicked
            }
        } else {
            gesture = nil
        }

        guard let gesture = gesture else { return nil }

        return matchingTriggers(for: gesture).contains { $0.suppressClick && $0.actions.contains(where: \.isEnabled) } ? gesture : nil
    }

    private func tearDownClickSuppressionTap() {
        if let tap = clickSuppressEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            clickSuppressEventTap = nil
        }
        if let source = clickSuppressRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            clickSuppressRunLoopSource = nil
        }
        if TrackpadMonitor.activeTrackpadMonitor === self {
            TrackpadMonitor.activeTrackpadMonitor = nil
        }
        suppressedButtons.removeAll()
    }

    private func matchingTriggers(for gesture: TrackpadGesture) -> [(id: UUID, gesture: TrackpadGesture, actions: [TriggerAction], appBundleID: String?, suppressClick: Bool, hapticFeedback: Bool, requiredModifiers: UInt?, activationGroupID: UUID?)] {
        TriggerResolver.resolve(registeredTriggers, payload: gesture,
            frontBundleID: frontmostBundleID(), payloadOf: { $0.gesture }, appBundleIDOf: { $0.appBundleID }, modifiers: modifierFlagsProvider(), requiredModifiersOf: { $0.requiredModifiers }, groups: activationGroups, activationGroupIDOf: { $0.activationGroupID })
    }

    private func queueGesture(_ gesture: TrackpadGesture, deviceID: UInt64? = nil, longTouchDuration: Double? = nil) {
        guard TriggerSuppression.shared.allows(kind: .trackpad) else { return }
        let generation = registrationGeneration
        var targets = matchingTriggers(for: gesture)
        if let longTouchDuration {
            // Only the triggers that configured exactly this hold time fire now;
            // longer ones fire when their own time elapses.
            targets = targets.filter { abs((longTouchDurations[$0.id] ?? 0.5) - longTouchDuration) < 0.001 }
        }
        if [.tipTapLeft, .tipTapRight, .tipTapMiddle].contains(gesture),
           UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true,
           targets.contains(where: { $0.suppressClick && $0.actions.contains(where: \.isEnabled) }) {
            // Arm synchronously, before the queued navigation action changes
            // the page. App-specific overrides and the suppression switch apply.
            tipTapShield.arm(device: deviceID ?? lastContactDevice, now: ProcessInfo.processInfo.systemUptime)
        }
        let requiredReceiver = diagnosticTarget
        DispatchQueue.main.async { [weak self] in
            guard let self, self.registrationGeneration == generation else { return }
            if let requiredReceiver,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier != requiredReceiver { return }
            self.fireGesture(gesture, targets: targets)
        }
    }

    // MARK: - Fire

    private func fireGesture(_ gesture: TrackpadGesture, targets: [Binding]? = nil) {
        recentDetections.append(gesture.rawValue)
        if recentDetections.count > 20 { recentDetections.removeFirst() }
        NSLog("[TrackpadMonitor] Detected gesture: %@", gesture.rawValue)

        // Record every detected gesture for statistics (always, even when paused)
        if systemMonitoringEnabled { GestureStatistics.shared.recordDetectionFromAnyThread(gesture.rawValue) }

        // Check global toggle — detect but don't fire when disabled
        let globalEnabled = UserDefaults.standard.object(forKey: "AOMGlobalEnabled") as? Bool ?? true
        guard globalEnabled, TriggerSuppression.shared.allows(kind: .trackpad) else {
            GestureLog.shared.logFromAnyThread("Gesture \(gesture.rawValue) — paused", level: .noMatch)
            return
        }

        let toFire = targets ?? matchingTriggers(for: gesture)
        if systemMonitoringEnabled { GestureHaptics.shared.feedback(enabled: toFire.contains { $0.hapticFeedback && $0.actions.contains(where: \.isEnabled) }) }

        if toFire.isEmpty {
            GestureLog.shared.logFromAnyThread("Gesture \(gesture.rawValue) — no matching trigger", level: .noMatch)
        } else {
            for trigger in toFire {
                let actionNames = trigger.actions.map { $0.actionType.rawValue }.joined(separator: ", ")
                let scope = trigger.activationGroupID != nil ? "activation group" : (trigger.appBundleID != nil ? "app-specific" : "global")
                GestureLog.shared.logFromAnyThread("Fired: \(gesture.rawValue) → \(actionNames) (\(scope))", level: .fire)
                if systemMonitoringEnabled { GestureStatistics.shared.recordFireFromAnyThread(gesture.rawValue) }
                ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions, fromTrackpad: true,
                    isHeld: { NSEvent.pressedMouseButtons & 1 != 0 })
                LiveTouchState.shared.flashTrigger(trigger.id)
                NotificationCenter.default.post(name: .gestureDidFire, object: nil, userInfo: ["name": gesture.rawValue, "actions": trigger.actions.filter(\.isEnabled).map { $0.actionType.rawValue }.joined(separator: " → ")])
            }
        }
    }

    /// Test-only: directly fire a gesture through the normal pipeline
    func fireGestureForTest(_ gesture: TrackpadGesture) {
        fireGesture(gesture)
    }

    /// Test-only: the shared corner/middle zone map.
    func positionClickGestureForTest(x: Float, y: Float) -> TrackpadGesture? {
        positionClickGesture(at: (x: x, y: y))
    }

    /// Test-only: which detector families have a bound trigger.
    var isSuppressingMouseForTest: Bool { circleDrawingActive }
    var hasCircleTriggerForTest: Bool { hasCircleTrigger }
    var hasTriangleTriggerForTest: Bool { hasTriangleTrigger }
    var hasEdgeSlideTriggerForTest: Bool { hasEdgeSlideTrigger }

    private func invalidateRecognition() {
        source.invalidatePendingFrames()
        tipTapShield.reset()
        frameLock.lock(); registrationGeneration = UUID(); frameLock.unlock()
        pendingTaps.values.forEach { $0.item.cancel() }; pendingTaps.removeAll()
        sessions.removeAll(); activeDevice = nil; rawOwnedUntil = 0
        currentFingers = 0; lastSingleFingerPos = nil; gestureConsumed = false
        positionClickGeneration = UUID(); pendingPositionClickChecks = 0; positionClickFired = false
        trackpadIsPressed = false; pressDragActive = false; pressDragDeltaX = 0
        scrollDeltaX = 0; scrollDeltaY = 0; scrollFingerCount = 0; scrollStartTime = nil
        magnification = 0; rotation = 0
        stopSuppressingMouse(); resetCircleState(); resetTriangleState(); resetEdgeDragState()
    }
    private func stopHardware() {
        source.stop(); source.onFrame = nil
        tearDownClickSuppressionTap()
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        healthTimer?.invalidate(); healthTimer = nil
        diagnosticSignals.forEach { $0.cancel() }; diagnosticSignals.removeAll()
        lifecycleObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        lifecycleObservers.removeAll()
    }
    func unregisterAll() {
        invalidateRecognition(); stopHardware(); registeredTriggers.removeAll()
    }
    deinit {
        unregisterAll()
        if let observer = appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
