import CoreAudio
import Darwin
import Foundation

/// What `status(pid:)`, the activity watchdog, diagnostics and the event log
/// read from a session's audio path, whichever kind it is: the queued
/// `AppAudioTransport` or an AirPlay direct stream.
protocol AppAudioActivitySource: AnyObject {
    var activity: (captured: UInt64, rendered: UInt64, peak: Float, recent: Bool, rendering: Bool) { get }
    var statistics: [String: Any] { get }
    var eventCounters: [String: UInt64] { get }
}

extension AppAudioTransport: AppAudioActivitySource {}

/// Output sample-time discontinuities of an IOProc: the frames the HAL
/// skipped between two cycles. The first cycle, an invalid timestamp and a
/// clock that moved backwards re-anchor without counting a gap; sub-frame
/// jitter is not a gap. Pure; render thread state.
struct AudioIOGapDetector: Equatable {
    private(set) var expected: Double?

    /// Missing frames before this cycle (0: continuous).
    mutating func observe(sampleTime: Double, valid: Bool, frames: Int) -> Int {
        guard valid, sampleTime.isFinite, frames > 0 else { expected = nil; return 0 }
        defer { expected = sampleTime + Double(frames) }
        guard let expected else { return 0 }
        let delta = sampleTime - expected
        guard delta >= 1 else { return 0 }
        return Int(min(delta, 1_000_000_000).rounded())
    }
}

/// The direct path's 5 ms linear fades: in at start and after an IO gap, out
/// when the session is stopped deliberately (a mute is a gain change, not a
/// stop). Sample k of a fade-in has gain (k + 1) / length; a fade-out from
/// full reaches 0 on its `length`th sample. Pure; render thread state.
struct AudioDirectFade: Equatable {
    static func frames(sampleRate: Double) -> Int {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        return max(1, Int((rate * 0.005).rounded()))
    }

    let length: Int
    /// 0: silent … `length`: full level.
    private(set) var position = 0
    private(set) var stopping = false

    init(sampleRate: Double) { length = Self.frames(sampleRate: sampleRate) }

    /// Fade in from silence (start, or the cycle after an IO gap).
    mutating func restart() { if !stopping { position = 0 } }
    /// Fade out from the current level; there is no way back in.
    mutating func stop() { stopping = true }
    /// Faded out completely after a stop.
    var finished: Bool { stopping && position == 0 }
    var isSteady: Bool { !stopping && position == length }

    mutating func nextGain() -> Float {
        if stopping { if position > 0 { position -= 1 } }
        else if position < length { position += 1 }
        return Float(position) / Float(length)
    }

    mutating func apply(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard !isSteady else { return }
        for index in 0..<frames {
            let gain = nextGain()
            left[index] *= gain
            right[index] *= gain
        }
    }
}

/// Which sessions the AirPlay direct path keeps: each one is a 128-frame IO
/// thread on the receiver's clock, so only apps that play (or that the user
/// muted, which must never leak sound) hold one. Pure.
enum AirPlayDirectPolicy {
    enum Kind: Equatable { case direct, queued }
    enum Decision: Equatable {
        /// No session: eligible to attach (a queued destination: the
        /// existing `needsProcessing` / retry rules still decide).
        case attach
        /// No session and nothing to attach for yet.
        case wait
        case keep
        /// Release a direct session that has been idle too long.
        case detach
        /// The session's kind or device no longer matches its destination.
        case recreate
    }

    /// 300 s since 6.3.3 (30 s before). Each reattach builds a new aggregate
    /// on the receiver, and its first half second overloaded (three ~6 ms
    /// gaps at 20:26:23 on 2026-11-18): the crackle heard when pressing play
    /// again after a short pause. A paused app now keeps its stream for five
    /// minutes; a silent one costs one idle IO thread meanwhile.
    static let idleDetachSeconds: TimeInterval = 300

    /// `wantsDirect`: the destination is AirPlay and the direct path is on.
    /// `sameDevice`: a direct session still targets that device's UID and ID.
    static func decide(session: Kind?, wantsDirect: Bool, sameDevice: Bool, playing: Bool, muted: Bool,
                       hasProcessObjects: Bool, idleSeconds: TimeInterval) -> Decision {
        if let session {
            if (session == .direct) != wantsDirect || (session == .direct && !sameDevice) { return .recreate }
            guard session == .direct else { return .keep }
            if playing || muted { return .keep }
            return idleSeconds >= idleDetachSeconds ? .detach : .keep
        }
        guard wantsDirect else { return .attach }
        return hasProcessObjects && (playing || muted) ? .attach : .wait
    }
}

/// One-time: the HAL safety fuse (not the user) switched HomePod effects off
/// because of the bridge path's deadline faults. The direct path has no
/// bridge, so those effects come back once; a user's own choice is kept.
enum AirPlayDirectMigration {
    static let doneKey = "AOMAudioAirPlayDirectMigrated"
    static let safetyReasonKey = "AOMAudioAirPlaySafetyReason"
    static let processingKey = "AOMAudioAirPlayProcessingEnabled"

    /// True when it re-enabled HomePod effects.
    @discardableResult
    static func run(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        defaults.set(true, forKey: doneKey)
        guard defaults.object(forKey: safetyReasonKey) != nil else { return false }
        defaults.removeObject(forKey: safetyReasonKey)
        defaults.set(true, forKey: processingKey)
        return true
    }
}

/// A direct stream's counters as read once by the control path, and their
/// diagnostics JSON (`captures.<pid>` in audio-health.json). Pure.
struct AirPlayDirectCounters: Equatable {
    var callbacks: UInt64 = 0
    var frames: UInt64 = 0
    var capturedFrames: UInt64 = 0
    var ioGaps: UInt64 = 0
    var ioGapFrames: UInt64 = 0
    var overloads: UInt64 = 0
    var costTicks: UInt64 = 0
    var costCycles: UInt64 = 0
    var costMaxTicks: UInt64 = 0
    var secondsPerTick: Double = 1e-9
    var bufferFrames: UInt64 = 0
    var configuredIOFrames = 0
    var oversizedCycles: UInt64 = 0
    var sampleRate: Double = 48000
    var peak: Float = 0
    var wired = false

    private func micros(_ ticks: Double) -> Double { (ticks * secondsPerTick * 10_000_000).rounded() / 10 }

    var json: [String: Any] {
        ["direct": true,
         "callbacks": callbacks,
         "frames": frames,
         "capturedFrames": capturedFrames,
         "ioGaps": ioGaps,
         "ioGapFrames": ioGapFrames,
         "overloads": overloads,
         "renderCostMeanMicros": costCycles == 0 ? 0.0 : micros(Double(costTicks) / Double(costCycles)),
         "renderCostMaxMicros": micros(Double(costMaxTicks)),
         "bufferFrames": bufferFrames,
         "configuredIOFrames": configuredIOFrames,
         "oversizedCycles": oversizedCycles,
         "sampleRate": sampleRate,
         "peak": peak.isFinite ? Double(peak) : 0,
         "wired": wired]
    }
}

/// One app on an AirPlay receiver through a single clock: its muted process
/// tap and the AirPlay device in one private aggregate (the device is the
/// clock, the tap is drift-compensated to it), and one IOProc that runs the
/// app's chain from the tap's input straight into the device's output, then
/// the network bus's −1 dBTP limiter. No queue, resampler, mix thread or
/// shared sender. The aggregate and the tap belong to the engine's session;
/// this object owns the IOProc, its buffers and its counters.
final class AirPlayDirectStream: AppAudioActivitySource {
    static let enabledKey = "AOMAudioAirPlayDirect"
    /// Absent: on. False keeps the queued bridge path (A/B measurement).
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Frames one cycle may carry (the AirPlay device runs 128).
    static let capacity = 16384
    /// How long a deliberate stop waits for the fade-out before stopping IO.
    static let stopFadeTimeout: TimeInterval = 0.03

    enum SetupError: Error { case format, start(OSStatus) }

    let aggregateID: AudioObjectID
    let deviceID: AudioDeviceID
    let deviceUID: String
    let sampleRate: Double
    let ioFrames: Int
    /// The tap's first buffer in the aggregate's input buffer list.
    let inputBufferOffset: Int
    let eventName: String
    /// The IOProc's ring (producer: the IO thread only).
    let events = AudioEventRing(capacity: 64)

    private let mixer: MixerBox
    private let limiter: AudioLookaheadLimiter
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let wired: (left: Bool, right: Bool)
    private let scratch: UnsafeMutableAudioBufferListPointer
    // IO thread only.
    private var gapDetector = AudioIOGapDetector()
    private var fade: AudioDirectFade

    private let callbacks = AudioAtomicCounter()
    private let framesRendered = AudioAtomicCounter()
    private let framesCaptured = AudioAtomicCounter()
    private let lastCallbackTick = AudioAtomicCounter()
    private let ioGaps = AudioAtomicCounter()
    private let ioGapFrames = AudioAtomicCounter()
    private let overloads = AudioAtomicCounter()
    private let costTicks = AudioAtomicCounter()
    private let costMaxTicks = AudioAtomicCounter()
    private let costCycles = AudioAtomicCounter()
    private let bufferFrames = AudioAtomicCounter()
    private let oversizedCycles = AudioAtomicCounter()
    private let peakBits = AudioAtomicCounter()
    private let stopRequested = AudioAtomicCounter()
    private let fadedOut = AudioAtomicCounter()
    private let reconfigured = AudioAtomicCounter()
    private let secondsPerTick: Double

    private var procID: AudioDeviceIOProcID?
    private let queue: DispatchQueue
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// The nominal rate or stream layout changed: the engine rebuilds the session.
    var needsRebuild: Bool { reconfigured.load() != 0 }

    /// Validates the aggregate's streams and creates (does not start) the
    /// IOProc. `onReconfigure` runs on a private queue.
    init(aggregateID: AudioObjectID, device: AudioOutputDevice, mixer: MixerBox, eventName: String,
         onReconfigure: @escaping () -> Void) throws {
        self.aggregateID = aggregateID
        deviceID = device.id
        deviceUID = device.uid
        self.eventName = eventName
        self.mixer = mixer
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let rate = Self.float64(aggregateID, kAudioDevicePropertyNominalSampleRate) ?? 0
        let inputs = Self.channelsPerBuffer(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let deviceInputs = Self.channelsPerBuffer(device.id, scope: kAudioObjectPropertyScopeInput)
        let outputs = Self.channelsPerBuffer(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        // The aggregate lists its sub-device's input streams first, then the
        // tap's. A stereo mixdown tap is one interleaved buffer or two mono.
        let offset = deviceInputs.count
        guard rate.isFinite, (8000...384000).contains(rate), inputs.count > offset,
              (1...2).contains(inputs[offset]), outputs.reduce(0, +) > 0,
              Self.outputsAreFloat32(aggregateID) else { throw SetupError.format }
        sampleRate = rate
        inputBufferOffset = offset
        ioFrames = Int(Self.uint32(aggregateID, kAudioDevicePropertyBufferFrameSize) ?? 0)
        fade = AudioDirectFade(sampleRate: rate)
        limiter = AudioLookaheadLimiter(sampleRate: rate, ceiling: AppAudioRenderBus.networkCeiling, truePeak: true,
                                        releaseSeconds: AppAudioRenderBus.networkRelease)
        left = .allocate(capacity: Self.capacity); left.initialize(repeating: 0, count: Self.capacity)
        right = .allocate(capacity: Self.capacity); right.initialize(repeating: 0, count: Self.capacity)
        wired = (AudioRealtimeMemory.wire(left, count: Self.capacity), AudioRealtimeMemory.wire(right, count: Self.capacity))
        scratch = AudioBufferList.allocate(maximumBuffers: 2)
        scratch[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: UnsafeMutableRawPointer(left))
        scratch[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: UnsafeMutableRawPointer(right))
        queue = DispatchQueue(label: "com.kyw.allofmacos.audio.direct.\(aggregateID)", qos: .userInitiated)
        mixer.inputBufferOffset = offset
        mixer.leftOutputChannel = 0
        mixer.rightOutputChannel = 1
        mixer.usesNetworkDynamics = true
        var created: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&created, aggregateID, nil) { [self] _, input, _, output, outputTime in
            render(input: input, output: output, outputTime: outputTime)
        }
        // A throw from here on still runs deinit, which frees the buffers.
        guard status == noErr, let created else { throw SetupError.start(status) }
        procID = created
        addListeners(onReconfigure: onReconfigure)
    }

    deinit { releaseBuffers() }

    private func releaseBuffers() {
        AudioRealtimeMemory.unwire(left, count: Self.capacity, wired: wired.left)
        AudioRealtimeMemory.unwire(right, count: Self.capacity, wired: wired.right)
        left.deallocate(); right.deallocate()
        free(scratch.unsafeMutablePointer)
    }

    func start() -> OSStatus {
        guard let procID else { return kAudioHardwareNotRunningError }
        return AudioDeviceStart(aggregateID, procID)
    }

    /// Deliberate stop (any thread but main): fade out over 5 ms, wait for it
    /// up to `stopFadeTimeout`, then stop IO and destroy the IOProc. The
    /// caller destroys the aggregate and the tap afterwards.
    func stop() {
        guard let procID else { return }
        stopRequested.store(1)
        let deadline = Date().addingTimeInterval(Self.stopFadeTimeout)
        while fadedOut.load() == 0 && Date() < deadline { usleep(1000) }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        self.procID = nil
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address, queue, block)
        }
        listeners.removeAll()
    }

    private func addListeners(onReconfigure: @escaping () -> Void) {
        let changes: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)]
        for (selector, scope) in changes {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.stopRequested.load() == 0 else { return }
                self.reconfigured.store(1)
                onReconfigure()
            }
            if AudioObjectAddPropertyListenerBlock(aggregateID, &address, queue, block) == noErr {
                listeners.append((address, block))
            }
        }
        // The HAL's report of an IO cycle that missed its deadline. Logged
        // and counted; an isolated overload is left alone (no fuse here).
        var overload = AudioObjectPropertyAddress(mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let name = eventName
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.stopRequested.load() == 0 else { return }
            self.overloads.add()
            AudioEventLog.shared.record(.overload, source: name, detail: "kAudioDeviceProcessorOverload")
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &overload, queue, block) == noErr {
            listeners.append((overload, block))
        }
    }

    // MARK: IO thread

    /// One cycle. No allocation, no lock it waits for (the mixer only
    /// try-locks), no logging: atomics and preallocated buffers.
    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                        outputTime: UnsafePointer<AudioTimeStamp>) {
        let start = mach_absolute_time()
        callbacks.add()
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var outputChannels = 0
        var frames = Int.max
        for buffer in outputs {
            let width = Int(buffer.mNumberChannels)
            guard width > 0, buffer.mData != nil else { continue }
            outputChannels += width
            frames = min(frames, Int(buffer.mDataByteSize) / (4 * width))
        }
        guard outputChannels > 0, frames != .max, frames > 0 else { return }
        bufferFrames.store(UInt64(frames))
        let stamp = outputTime.pointee
        let missing = gapDetector.observe(sampleTime: stamp.mSampleTime,
                                          valid: stamp.mFlags.contains(.sampleTimeValid), frames: frames)
        if missing > 0 {
            ioGaps.add()
            ioGapFrames.add(UInt64(missing))
            events.push(.cycleGap, value: UInt64(missing), host: start)
            fade.restart()
        }
        if stopRequested.load() != 0 { fade.stop() }
        guard frames <= Self.capacity, !fade.finished else {
            if frames > Self.capacity { oversizedCycles.add() }
            if fade.finished { fadedOut.store(1) }
            Self.silence(outputs)
            finishCycle(start: start, frames: 0)
            return
        }
        scratch[0].mDataByteSize = UInt32(frames * 4)
        scratch[1].mDataByteSize = UInt32(frames * 4)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if inputBufferOffset < inputs.count {
            let tap = inputs[inputBufferOffset]
            if tap.mNumberChannels > 0, tap.mData != nil, tap.mDataByteSize > 0 {
                framesCaptured.add(UInt64(Int(tap.mDataByteSize) / (4 * Int(tap.mNumberChannels))))
            }
        }
        // The app's chain: EQ, Magic Boost, volume, balance, Overdrive.
        Mixer.mix(input: input, output: scratch.unsafeMutablePointer, box: mixer)
        limiter.process(left: left, right: right, frames: frames)
        fade.apply(left: left, right: right, frames: frames)
        if fade.finished { fadedOut.store(1) }
        var peak: Float = 0
        var channel = 0
        for buffer in outputs {
            let width = Int(buffer.mNumberChannels)
            guard width > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / (4 * width))
            for frame in 0..<count {
                let l = left[frame].isFinite ? left[frame] : 0
                let r = right[frame].isFinite ? right[frame] : 0
                if channel == 0 { peak = max(peak, max(abs(l), abs(r))) }
                for slot in 0..<width {
                    let target = channel + slot
                    data[frame * width + slot] = outputChannels == 1 ? (l + r) * 0.5 : (target == 0 ? l : (target == 1 ? r : 0))
                }
            }
            channel += width
        }
        peakBits.store(UInt64(peak.bitPattern))
        finishCycle(start: start, frames: frames)
    }

    @inline(__always)
    private func finishCycle(start: UInt64, frames: Int) {
        if frames > 0 { framesRendered.add(UInt64(frames)) }
        let end = mach_absolute_time()
        lastCallbackTick.store(end)
        let cost = end &- start
        costTicks.add(cost)
        costCycles.add()
        costMaxTicks.raise(to: cost)
    }

    private static func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
    }

    // MARK: Control side

    /// A callback in the last 0.25 s; the device clock is the capture clock,
    /// so capturing and rendering are the same fact.
    var activity: (captured: UInt64, rendered: UInt64, peak: Float, recent: Bool, rendering: Bool) {
        let last = lastCallbackTick.load()
        let now = mach_absolute_time()
        let recent = last > 0 && Double(now &- last) * secondsPerTick < 0.25
        return (framesCaptured.load(), framesRendered.load(),
                Float(bitPattern: UInt32(truncatingIfNeeded: peakBits.load())), recent, recent)
    }

    var statistics: [String: Any] {
        AirPlayDirectCounters(
            callbacks: callbacks.load(), frames: framesRendered.load(), capturedFrames: framesCaptured.load(),
            ioGaps: ioGaps.load(), ioGapFrames: ioGapFrames.load(), overloads: overloads.load(),
            costTicks: costTicks.load(), costCycles: costCycles.load(), costMaxTicks: costMaxTicks.load(),
            secondsPerTick: secondsPerTick, bufferFrames: bufferFrames.load(), configuredIOFrames: ioFrames,
            oversizedCycles: oversizedCycles.load(), sampleRate: sampleRate,
            peak: Float(bitPattern: UInt32(truncatingIfNeeded: peakBits.load())), wired: wired.left && wired.right).json
    }

    var eventCounters: [String: UInt64] {
        ["app.direct.callbacks": callbacks.load(), "app.direct.ioGaps": ioGaps.load(),
         "app.direct.ioGapFrames": ioGapFrames.load(), "app.direct.overloads": overloads.load()]
    }

    // MARK: HAL reads (control thread, at setup)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var property = address(selector); var value: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector); var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Channels of each buffer in an object's stream configuration (empty:
    /// none, or the read failed).
    static func channelsPerBuffer(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Every output stream's virtual format is native-endian Float32 PCM,
    /// what the IOProc writes.
    private static func outputsAreFloat32(_ object: AudioObjectID) -> Bool {
        var property = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &streams) == noErr, !streams.isEmpty else { return false }
        return streams.allSatisfy { stream in
            var formatAddress = address(kAudioStreamPropertyVirtualFormat)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr else { return false }
            return format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
                format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && format.mBitsPerChannel == 32
        }
    }

    /// Engine diagnostics for a direct session (the stream's counters plus
    /// the session's identity).
    static func diagnostics(statistics: [String: Any], bundleID: String, tapRewrites: Int) -> [String: Any] {
        var stats = statistics
        stats["direct"] = true
        stats["bundleID"] = bundleID
        stats["airPlay"] = true
        stats["tapRewrites"] = tapRewrites
        return stats
    }
}
