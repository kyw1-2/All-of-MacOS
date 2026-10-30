import AppKit
import AudioToolbox
import CoreAudio

// MARK: - Force Touch pressure stages

/// Force Touch stages with hysteresis.
///
/// AppKit reports a pressure stage (0 none, 1 click, 2 deep press) and the
/// pressure within that stage (0…1). They are combined into one level 0…1:
/// stage 1 spans 1/3…2/3 and stage 2 spans 2/3…1, so a stage is entered
/// exactly where macOS changes stage. Each stage fires once when it is
/// entered and re-arms only after the level falls `hysteresis` below that
/// stage's boundary, so pressure wobbling around the deep-press point cannot
/// fire stage 2 again and again. Stage 1 therefore re-arms only on release.
struct PressureStageTracker {
    static let boundaries: [Double] = [1.0 / 3, 2.0 / 3]
    static let hysteresisKey = "AOMForceTouchStageHysteresis"
    static let defaultHysteresis = 0.1
    static let hysteresisRange: ClosedRange<Double> = 0.02...0.3

    let hysteresis: Double
    private(set) var level: Double = 0
    private var armed = [true, true]

    init(hysteresis: Double = PressureStageTracker.storedHysteresis()) {
        let value = hysteresis.isFinite ? hysteresis : Self.defaultHysteresis
        self.hysteresis = min(max(value, Self.hysteresisRange.lowerBound), Self.hysteresisRange.upperBound)
    }

    static func storedHysteresis(_ defaults: UserDefaults = .standard) -> Double {
        (defaults.object(forKey: hysteresisKey) as? NSNumber)?.doubleValue ?? defaultHysteresis
    }

    static func level(stage: Int, pressure: Double) -> Double {
        guard stage > 0 else { return 0 }
        let within = pressure.isFinite ? min(max(pressure, 0), 1) : 0
        return min(1, (Double(min(stage, 2)) + within) / 3)
    }

    /// Feeds one reading; returns the stages it entered (1, 2, or both after a
    /// fast deep press).
    mutating func feed(stage: Int, pressure: Double) -> [Int] {
        level = Self.level(stage: stage, pressure: pressure)
        var entered: [Int] = []
        for index in 0..<2 {
            let boundary = Self.boundaries[index]
            if armed[index], level >= boundary {
                armed[index] = false
                entered.append(index + 1)
            } else if !armed[index], level < boundary - hysteresis {
                armed[index] = true
            }
        }
        return entered
    }

    /// Stage `stage` has been entered and not yet released past its band.
    func isHeld(_ stage: Int) -> Bool { (1...2).contains(stage) && !armed[stage - 1] }

    /// The AOM value of a binding on stage `stage`: 0 at the stage boundary,
    /// 1 at full deep-press pressure.
    func progress(from stage: Int) -> Double {
        let boundary = Self.boundaries[min(max(stage, 1), 2) - 1]
        return min(1, max(0, (level - boundary) / (1 - boundary)))
    }

    mutating func reset() { level = 0; armed = [true, true] }
}

// MARK: - Targets

/// Where a binding's value lands, resolved on the main thread when the value
/// arrives (frontmost app, display under the pointer).
enum ContinuousTargetRef: Hashable {
    case systemVolume
    case appVolume(bundleID: String)
    case displayBrightness(displayID: CGDirectDisplayID)

    var title: String {
        switch self {
        case .systemVolume: return "System volume"
        case .appVolume(let id): return "App volume (\(id))"
        case .displayBrightness: return "Display brightness"
        }
    }
}

// MARK: - Rate-limited delivery

/// Delivers continuous values to their targets on one serial utility queue,
/// never on CoreMIDI's realtime thread or the multitouch callback thread.
///
/// Per target the newest value wins: a burst of MIDI or pressure readings is
/// coalesced to at most one write per `minimumInterval`, and the last value of
/// the burst is always written (trailing edge). A value equal to the last one
/// written to the same device is skipped.
///
/// Only a write that succeeded counts as written (N333-04). A failed write, or
/// one during which the device changed, leaves the level unknown, so the same
/// value is written again. A failed value is retried once after `retryDelay`,
/// together with anything submitted meanwhile; a retry that fails waits for
/// the next value, so a target that cannot be set is never polled.
final class ContinuousValueSink {
    static let queueLabel = "com.kyw.allofmacos.continuous-values"
    static let defaultInterval: TimeInterval = 1.0 / 30
    static let retryDelay: TimeInterval = 0.25

    let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var pending: [ContinuousTargetRef: Double] = [:]
    /// When each target was last tried, successful or not: the rate limit.
    private var lastAttempt: [ContinuousTargetRef: TimeInterval] = [:]
    /// The level each target is known to hold, and the device that holds it.
    private var lastWritten: [ContinuousTargetRef: (value: Double, device: AnyHashable?)] = [:]
    private var scheduled = Set<ContinuousTargetRef>()
    /// Targets whose scheduled flush is the automatic retry of a failed write.
    private var retrying = Set<ContinuousTargetRef>()
    private let clock: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let device: (ContinuousTargetRef) -> AnyHashable?
    private let apply: (ContinuousTargetRef, Double) -> Bool

    /// `device` names what a target lands on when the target itself does not
    /// (the default output for system volume); nil when the target is enough.
    init(minimumInterval: TimeInterval = ContinuousValueSink.defaultInterval,
         queue: DispatchQueue = DispatchQueue(label: ContinuousValueSink.queueLabel, qos: .userInitiated),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
         device: @escaping (ContinuousTargetRef) -> AnyHashable? = { _ in nil },
         apply: @escaping (ContinuousTargetRef, Double) -> Bool) {
        self.minimumInterval = max(0, minimumInterval)
        self.clock = clock
        self.device = device
        self.apply = apply
        self.schedule = schedule ?? { delay, work in
            if delay <= 0 { queue.async(execute: work) } else { queue.asyncAfter(deadline: .now() + delay, execute: work) }
        }
    }

    /// Thread-safe. Returns immediately; the write happens on the sink queue.
    func submit(_ value: Double, to target: ContinuousTargetRef) {
        guard value.isFinite else { return }
        lock.lock()
        pending[target] = ContinuousValueBinding.unit(value)
        retrying.remove(target) // a new value earns its own retry
        guard scheduled.insert(target).inserted else { lock.unlock(); return }
        let delay = lastAttempt[target].map { max(0, $0 + minimumInterval - clock()) } ?? 0
        lock.unlock()
        schedule(delay) { [weak self] in self?.flush(target) }
    }

    private func flush(_ target: ContinuousTargetRef) {
        let output = device(target)
        lock.lock()
        scheduled.remove(target)
        let isRetry = retrying.remove(target) != nil
        guard let value = pending.removeValue(forKey: target) else { lock.unlock(); return }
        if let last = lastWritten[target], last.device == output, abs(last.value - value) < 0.0005 { lock.unlock(); return }
        lastAttempt[target] = clock()
        // Held while the write runs, so a forget during it is not undone.
        lastWritten[target] = (value, output)
        lock.unlock()
        let ok = apply(target, value)
        if ok, device(target) == output { return }
        // Failed, or the device changed under the write: the level is unknown.
        lock.lock()
        lastWritten[target] = nil
        // One more try, unless a newer value is waiting or this was the retry.
        let retry = !ok && !isRetry && pending[target] == nil && scheduled.insert(target).inserted
        if retry { pending[target] = value; retrying.insert(target) }
        lock.unlock()
        if retry { schedule(max(minimumInterval, Self.retryDelay)) { [weak self] in self?.flush(target) } }
    }

    /// Forgets what was written, so the next value is written even if equal.
    func forgetLastWritten() { lock.lock(); lastWritten.removeAll(); lock.unlock() }
}

// MARK: - Engine

/// Turns source values into target levels. Runs on the main thread, where
/// every source already arrives (MIDI is hopped there by `MIDIInputMonitor`,
/// trackpad scroll and pressure come from AppKit monitors).
final class ContinuousValueEngine {
    static let shared = ContinuousValueEngine()

    /// A scroll that pauses longer than this re-reads the target first, so a
    /// change made elsewhere (keys, menu bar) is not overwritten.
    static let relativeResync: TimeInterval = 1.5

    let sink: ContinuousValueSink
    private let resolve: (ContinuousValueBinding) -> ContinuousTargetRef?
    private let currentLevel: (ContinuousTargetRef) -> Double?
    private let clock: () -> TimeInterval
    private var positions: [UUID: (position: Double, time: TimeInterval, target: ContinuousTargetRef)] = [:]
    private var peaks: [UUID: Double] = [:]

    init(sink: ContinuousValueSink = ContinuousValueSink(device: ContinuousTargetIO.device, apply: ContinuousTargetIO.apply),
         resolve: @escaping (ContinuousValueBinding) -> ContinuousTargetRef? = ContinuousTargetIO.resolve,
         currentLevel: @escaping (ContinuousTargetRef) -> Double? = ContinuousTargetIO.currentLevel,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink; self.resolve = resolve; self.currentLevel = currentLevel; self.clock = clock
    }

    /// Absolute sources (MIDI CC, pitch bend, pressure; Force Touch pressure).
    /// Returns the level submitted, or nil when nothing was submitted.
    @discardableResult
    func drive(_ binding: ContinuousValueBinding, input: Double, from id: UUID) -> Double? {
        guard input.isFinite else { return nil }
        var value = ContinuousValueBinding.unit(input)
        if binding.holdPeak {
            // At or below the input minimum the press is over: the target
            // keeps the peak, and the next press starts from scratch.
            guard value > binding.inputMinimum else { peaks[id] = nil; return nil }
            value = max(peaks[id] ?? value, value)
            peaks[id] = value
        }
        guard let target = resolve(binding) else { return nil }
        let level = binding.output(forInput: value)
        positions[id] = nil
        sink.submit(level, to: target)
        return level
    }

    /// A pressure press ended (its Force Touch stage was released).
    func release(_ id: UUID) { peaks[id] = nil }

    /// Relative sources (scroll). `delta` is a fraction of the full range,
    /// positive in the trigger's own direction.
    @discardableResult
    func nudge(_ binding: ContinuousValueBinding, by delta: Double, from id: UUID) -> Double? {
        guard delta.isFinite, delta != 0, let target = resolve(binding) else { return nil }
        let now = clock()
        let start: Double
        if let state = positions[id], state.target == target, now - state.time < Self.relativeResync {
            start = state.position
        } else {
            start = binding.position(forOutput: currentLevel(target) ?? binding.outputMinimum)
        }
        let next = ContinuousValueBinding.unit(start + (binding.inverted ? -delta : delta))
        positions[id] = (next, now, target)
        let level = binding.output(forPosition: next)
        sink.submit(level, to: target)
        return level
    }

    func reset() { positions.removeAll(); peaks.removeAll() }
}

// MARK: - Live target I/O

/// The real outputs. `resolve` and `currentLevel` run on the main thread;
/// `apply` and `device` run on the sink queue. Under XCTest `apply` refuses
/// everything, so no test can change the real volume or brightness.
enum ContinuousTargetIO {
    private static let lock = NSLock()
    private static var failing = Set<ContinuousTargetRef>()

    static func resolve(_ binding: ContinuousValueBinding) -> ContinuousTargetRef? {
        switch binding.target {
        case .systemVolume: return .systemVolume
        case .appVolume:
            let wanted = binding.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = wanted.isEmpty ? (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") : wanted
            guard !id.isEmpty, id != Bundle.main.bundleIdentifier else { return nil }
            return .appVolume(bundleID: id)
        case .displayBrightness:
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return .displayBrightness(displayID: CGDirectDisplayID(number.uint32Value))
        }
    }

    static func currentLevel(_ target: ContinuousTargetRef) -> Double? {
        switch target {
        case .systemVolume: return AudioOutputService.currentVolume().map(Double.init)
        case .appVolume(let id):
            guard #available(macOS 14.2, *) else { return nil }
            return Double(min(1, AppAudioEngine.storedGain(bundleID: id)))
        case .displayBrightness(let display): return DisplayControlService.brightness(display).map(Double.init)
        }
    }

    /// The device a target lands on when the target does not name it: system
    /// volume follows the default output, so a level written to one output is
    /// not taken for another's. Nil under XCTest, where `apply` writes nothing.
    static func device(_ target: ContinuousTargetRef) -> AnyHashable? {
        guard case .systemVolume = target, !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return nil }
        return AudioOutputService.currentDeviceID().map { AnyHashable($0) }
    }

    static func apply(_ target: ContinuousTargetRef, _ level: Double) -> Bool {
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return false }
        let ok: Bool
        switch target {
        case .systemVolume:
            ok = setSystemVolume(level)
        case .appVolume(let id):
            if #available(macOS 14.2, *) {
                // The mixer's sessions live on the main thread; the write is
                // still rate-limited by the sink.
                DispatchQueue.main.async {
                    guard AppAudioPreferences.setGain(Float(level), bundleID: id) else { return }
                    AppAudioEngine.shared.refreshGainAndMute(bundleID: id)
                }
                ok = true
            } else { ok = false }
        case .displayBrightness(let display):
            let hardware = DisplayControlService.supportsHardwareBrightness(display)
            ok = DisplayControlService.setBrightness(display, ExtendedActions.brightnessValue(percent: level * 100, hardware: hardware))
        }
        report(target, ok)
        return ok
    }

    /// Writes the output's volume scalar directly (no read-back loop, no log
    /// line per write). Outputs without a writable volume, such as AirPlay or
    /// outputs that only have AOM's software volume, are refused.
    static func setSystemVolume(_ level: Double) -> Bool {
        guard let device = AudioOutputService.currentDeviceID() else { return false }
        var value = Float32(ContinuousValueBinding.unit(level))
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var writable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else { continue }
            // Like the volume keys, raising the volume clears mute.
            if value > 0 { unmute(device) }
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        }
        return false
    }

    private static func unmute(_ device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var writable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else { return }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr, muted != 0 else { return }
        muted = 0
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &muted)
    }

    /// One log line when a target starts failing, one when it recovers.
    private static func report(_ target: ContinuousTargetRef, _ ok: Bool) {
        lock.lock()
        let changed = ok ? failing.remove(target) != nil : failing.insert(target).inserted
        lock.unlock()
        guard changed else { return }
        GestureLog.shared.logFromAnyThread(ok ? "Value binding: \(target.title) responds again"
                                              : "Value binding: \(target.title) could not be set", level: ok ? .action : .error)
    }
}
