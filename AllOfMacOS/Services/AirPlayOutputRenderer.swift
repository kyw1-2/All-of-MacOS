import Foundation
import AudioToolbox
import CoreAudio
import Darwin

/// Weak entries retain ordering while a renderer or its queued teardown lives,
/// without retaining a queue forever for every transient CoreAudio device ID.
enum AirPlayDeviceQueues {
    private final class Entry {
        weak var queue: DispatchQueue?
        init(_ queue: DispatchQueue) { self.queue = queue }
    }
    private static let lock = NSLock()
    private static var entries: [AudioDeviceID: Entry] = [:]
    static func queue(for deviceID: AudioDeviceID) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let queue = entries[deviceID]?.queue { return queue }
        entries = entries.filter { $0.value.queue != nil }
        let queue = DispatchQueue(label: "com.kyw.aom.airplay.\(deviceID)", qos: .userInteractive)
        entries[deviceID] = Entry(queue)
        return queue
    }
}

/// One output-only HAL client per connected AirPlay device. The local 48 kHz
/// DSP clock is independent of the HAL callback and of the main/UI run loop.
/// macOS owns discovery, pairing, network transport and HomePod remote control.
final class AirPlayOutputRenderer {
    enum State {
        case preparing
        case ready
        case failed(String)
    }
    let deviceID: AudioDeviceID
    let bus = AppAudioRenderBus()
    // Replacements of one device share a disposal/start barrier; unrelated
    // receivers must never wait behind its potentially blocking HAL lifecycle.
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var phase: State = .preparing
    private let bridge = AirPlayPCMBridge()
    // Everything below is confined to queue; callback only touches bridge.
    private var unit: AudioUnit?
    /// Health checks only; mixing runs on a dedicated realtime thread.
    private var timer: DispatchSourceTimer?
    private var mixerStorage: AirPlayMixThread?
    /// Read by diagnostics on main while the device queue owns its lifetime.
    private var mixer: AirPlayMixThread? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return mixerStorage }
        set { stateLock.lock(); mixerStorage = newValue; stateLock.unlock() }
    }
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var startedAt: TimeInterval = 0
    private var configuredRate: Double = 0
    private var configuredFrames: UInt32 = 0
    private var configuredChannels: UInt32 = 0
    private var stopped = false
    private var failureDelivered = false
    private let changed: () -> Void
    /// Seconds without a HAL render request (or without rendered audio)
    /// before native playback is restored. HomePods can pause a few seconds
    /// on Wi-Fi hiccups; the PCM bridge rides those out.
    static let stallLimit: TimeInterval = 6

    init(deviceID: AudioDeviceID, changed: @escaping () -> Void) {
        self.deviceID = deviceID
        self.queue = AirPlayDeviceQueues.queue(for: deviceID)
        self.changed = changed
        queue.async { [self] in start() }
    }

    var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return phase
    }

    private func publish(_ value: State) {
        stateLock.lock(); phase = value; stateLock.unlock()
        DispatchQueue.main.async(execute: changed)
    }

    /// Source removal is the DSP lifetime barrier. HAL teardown can block on
    /// a remote device, so it never runs on the menu / main thread.
    func stop() {
        bus.removeAll()
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            tearDown()
        }
    }

    private func check(_ status: OSStatus, _ operation: String) -> Bool {
        guard status == noErr else {
            fail("AirPlay \(operation) failed (\(status)). Native playback restored; use Reconnect to retry.")
            return false
        }
        return true
    }

    private func start() {
        guard !stopped else { return }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            fail("AirPlay output component unavailable. Native playback restored."); return
        }
        var instance: AudioUnit?
        guard check(AudioComponentInstanceNew(component, &instance), "create") else { return }
        guard let instance else { fail("AirPlay output instance unavailable. Native playback restored."); return }
        unit = instance
        var off: UInt32 = 0
        var on: UInt32 = 1
        var id = deviceID
        guard check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input, 1, &off, 4), "disable input"),
              check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output, 0, &on, 4), "enable output"),
              check(AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &id, 4), "select device") else { return }
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: hardware))
        guard check(AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output, 0, &hardware, &size), "read format"),
              hardware.mSampleRate.isFinite, (8000...192000).contains(hardware.mSampleRate),
              hardware.mChannelsPerFrame >= 2 else {
            fail("AirPlay stereo output format unavailable. Native playback restored."); return
        }
        // AUHAL does not provide arbitrary sample rate conversion. Match the
        // device clock here; bridge converts from the fixed local mixing rate.
        var format = AudioStreamBasicDescription(mSampleRate: hardware.mSampleRate,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var maximum: UInt32 = 16384
        guard check(AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout.size(ofValue: format))), "set format"),
              check(AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global, 0, &maximum, 4), "set buffer limit") else { return }
        var frameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceFrames: UInt32 = 0
        size = 4
        guard check(AudioObjectGetPropertyData(deviceID, &frameAddress, 0, nil, &size, &deviceFrames),
                    "read buffer size"), deviceFrames > 0, deviceFrames <= maximum,
              Double(deviceFrames) * 48000 / format.mSampleRate <= 32000 else {
            fail("AirPlay buffer size unsupported. Native playback restored."); return
        }
        configuredRate = format.mSampleRate
        configuredFrames = deviceFrames
        configuredChannels = hardware.mChannelsPerFrame
        bridge.configure(outputRate: format.mSampleRate, deviceFrames: Int(deviceFrames))
        var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, buffers in
            guard let buffers else { return noErr }
            Unmanaged<AirPlayPCMBridge>.fromOpaque(context).takeUnretainedValue()
                .render(frames: Int(frames), output: buffers)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(bridge).toOpaque())
        guard check(AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))), "set callback"),
              check(AudioUnitInitialize(instance), "initialize") else { return }
        // Silence is prebuffered before any muting process tap is attached.
        bridge.prime()
        startedAt = ProcessInfo.processInfo.systemUptime
        guard check(AudioOutputUnitStart(instance), "start") else { return }
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
                         kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyStreamConfiguration] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: selector == kAudioDevicePropertyStreamConfiguration ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.configurationChanged()
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener) == noErr {
                listeners.append((address, listener))
            }
        }
        let thread = AirPlayMixThread(bus: bus, bridge: bridge)
        thread.start()
        mixer = thread
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(250), leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.checkHealth() }
        timer = source
        source.resume()
    }

    private func configurationChanged() {
        guard !stopped, !failureDelivered, let unit else { return }
        // HAL sends redundant notifications during route settlement. A
        // notification alone must never tear down a playing connection.
        var alive: UInt32 = 0
        var frames: UInt32 = 0
        var rate: Double = 0
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 4
        let aliveStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        address.mSelector = kAudioDevicePropertyBufferFrameSize; size = 4
        let bufferStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
        address.mSelector = kAudioDevicePropertyNominalSampleRate; size = 8
        let rateStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        size = UInt32(MemoryLayout.size(ofValue: format))
        let formatStatus = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &format, &size)
        if aliveStatus != noErr || alive == 0 || bufferStatus != noErr || rateStatus != noErr ||
            formatStatus != noErr || frames != configuredFrames || rate != configuredRate ||
            format.mSampleRate != configuredRate || format.mChannelsPerFrame != configuredChannels {
            fail("AirPlay device configuration changed. Native playback restored; use Reconnect to retry.")
        }
    }

    var statistics: [String: Any] {
        var result = bridge.statistics
        let mixer = mixer
        result["delayedMixResets"] = mixer?.delayedMixResets.load() ?? 0
        result["maximumMixDelayMS"] = Double(mixer?.maximumMixDelay.load() ?? 0) / 1_000_000
        result["catchUpBlocks"] = mixer?.catchUpBlocks.load() ?? 0
        result["realtimeMixer"] = mixer?.isRealtime ?? false
        if let report = mixer?.timeline.report() {
            // Start-up and sustained supply, separately (audit F12).
            result["mixThreadStartMS"] = report.threadStart.map { Double($0) / 1_000_000 } ?? -1
            result["mixFirstBlockMS"] = report.firstMix.map { Double($0) / 1_000_000 } ?? -1
            result["mixRealtimeEffective"] = report.scheduling?.realtime ?? false
            result["mixSchedulingPriority"] = Int(report.scheduling?.priority ?? -1)
            result["mixLateWakes"] = report.lateWakes
            result["mixBudgetLimitedWakes"] = report.budgetLimitedWakes
            if let rate = report.sustainedRate(warmUp: 250_000_000) {
                result["mixSustainedFramesPerSecond"] = rate.framesPerSecond.rounded()
                result["mixWorstLagAfterWakeMS"] = Double(rate.worstLagAfterWake) / 1_000_000
            }
        }
        return result
    }

    /// Queue-confined: the scheduling state last written to the log.
    private var loggedRealtime: Bool?

    /// Says when macOS runs the mix clock outside the realtime band (or
    /// refused the promotion), and when it is realtime again; the mix thread
    /// itself never logs.
    private func logSchedulingChange() {
        guard let mixer, let reading = mixer.timeline.scheduling, reading.realtime != loggedRealtime else { return }
        let previous = loggedRealtime
        loggedRealtime = reading.realtime
        if !reading.realtime {
            let request = mixer.isRealtime ? "realtime accepted but not applied" : "realtime promotion refused"
            GestureLog.shared.logFromAnyThread(
                "AirPlay mix clock runs timeshare at priority \(reading.priority) (\(request)); catching up without a time budget",
                level: .error)
        } else if previous == false {
            GestureLog.shared.logFromAnyThread("AirPlay mix clock runs realtime again (priority \(reading.priority))",
                                               level: .noMatch)
        }
    }

    private func checkHealth() {
        guard !stopped, !failureDelivered else { return }
        logSchedulingChange()
        let health = bridge.health
        let uptime = ProcessInfo.processInfo.systemUptime
        if health.invalidFormat {
            fail("AirPlay supplied an unsupported render buffer. Native playback restored.")
        } else if health.lastCallback > 0 && uptime - health.lastCallback > Self.stallLimit {
            fail("AirPlay output stopped requesting audio. Native playback restored; AOM will reconnect.")
        } else if health.lastCallback == 0 && uptime - startedAt > 15 {
            fail("AirPlay output did not start. Native playback restored; AOM will reconnect.")
        } else if health.lastAudio > 0 && uptime - health.lastAudio > Self.stallLimit {
            fail("AirPlay audio buffer could not recover. Native playback restored; AOM will reconnect.")
        } else if case .preparing = state, health.lastAudio > 0 {
            // AudioOutputUnitStart success alone does not prove a live clock.
            publish(.ready)
        }
    }

    private func fail(_ message: String) {
        guard !stopped, !failureDelivered else { return }
        failureDelivered = true
        // Notify main before potentially slow HAL teardown, allowing the owner
        // to release muting taps promptly. No automatic reconnect loop.
        publish(.failed(message))
        tearDown()
    }

    private func tearDown() {
        // The mixer thread exits before the bus or bridge can be released.
        let running = mixer
        mixer = nil
        running?.stop()
        timer?.cancel(); timer = nil
        for entry in listeners {
            var address = entry.0
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, entry.1)
        }
        listeners.removeAll()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
    }
}

/// A bounded, preallocated PCM queue between the local mix clock and AirPlay's
/// device clock. The HAL callback never runs DSP, dispatches work, or waits.
final class AirPlayPCMBridge {
    private let queue = StereoPCMQueue(capacity: 96000)
    private var target = 7200
    private var outputRate: Double = 48000
    private let outputRateBits = AudioAtomicCounter(Double(48000).bitPattern)
    private let targetValue = AudioAtomicCounter(7200)
    private let callbackTick = AudioAtomicCounter()
    private let audioTick = AudioAtomicCounter()
    private let invalid = AudioAtomicCounter()
    private let secondsPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    // Setup only, before the producer and HAL callback start.
    func configure(outputRate: Double, deviceFrames: Int) {
        self.outputRate = outputRate
        outputRateBits.store(outputRate.bitPattern)
        target = min(48000, max(7200, Int(ceil(Double(deviceFrames) * 48000 / outputRate)) * 3))
        targetValue.store(UInt64(target))
    }
    func prime() { queue.prime(frames: target) }
    var health: (lastCallback: TimeInterval, lastAudio: TimeInterval, invalidFormat: Bool) {
        (Double(callbackTick.load()) * secondsPerTick, Double(audioTick.load()) * secondsPerTick, invalid.load() != 0)
    }
    var statistics: [String: Any] {
        var result = queue.statistics.mapValues { $0 as Any }
        result["outputRate"] = Double(bitPattern: outputRateBits.load()); result["targetFrames"] = targetValue.load()
        return result
    }
    func discard() { queue.requestClear() }
    func push(_ input: UnsafePointer<Float>, frames: Int) {
        queue.write(frames: frames) { (input[$0 * 2], input[$0 * 2 + 1]) }
    }
    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>) {
        callbackTick.store(mach_absolute_time())
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames > 0, frames <= 16384, buffers.count == 1,
              buffers[0].mNumberChannels == 2, Int(buffers[0].mDataByteSize) >= frames * 8,
              let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            invalid.store(1); return
        }
        let produced = queue.render(into: data, frames: frames, ratio: 48000 / outputRate,
            targetFrames: target, driftLimit: 0.005, smoothing: 0.02, fadeFrames: Int(outputRate * 0.02))
        if produced > 0 { audioTick.store(mach_absolute_time()) }
    }
}

/// The mix clock's scheduling rule, kept pure so a virtual clock can drive it
/// in tests. Times are host ticks (mach_absolute_time units in the app, plain
/// nanoseconds in tests).
///
/// Catch-up is bounded by time, not by wake-ups. Until 3.3.0 a late wake
/// rendered at most four blocks (40 ms of audio) and then slept 1 ms, so once
/// wake-ups were delayed by more than 40 ms the clock fell behind however idle
/// the CPU was (audit F12: a release build made 15,840 of 24,000 frames in
/// 0.5 s when every wait overshot by ~190 ms). Now one wake renders every
/// overdue block — at least `minimumBurst`, then, while the thread really
/// runs realtime, as many more as fit in `burstBudget`; a demoted thread is
/// not time-budgeted — up to `maximumBurst`, and never a block ahead of real
/// time.
struct AirPlayMixSchedule: Equatable {
    let period: UInt64
    /// Beyond this lateness (sleep, debugger) the backlog is stale: realign.
    let realign: UInt64
    /// Overdue blocks always rendered per wake (the pre-3.3.1 burst).
    let minimumBurst: Int
    /// Wall time a wake may keep rendering beyond `minimumBurst`.
    let burstBudget: UInt64
    /// Hard cap on blocks per wake.
    let maximumBurst: Int
    private(set) var next: UInt64

    init(start: UInt64, period: UInt64, realign: UInt64, minimumBurst: Int, burstBudget: UInt64, maximumBurst: Int) {
        self.period = max(1, period)
        self.realign = realign
        self.minimumBurst = max(1, minimumBurst)
        self.burstBudget = burstBudget
        self.maximumBurst = max(self.minimumBurst, maximumBurst)
        next = start
    }

    /// The thread woke at `now` (at or after `next`): how late it is, and
    /// whether the schedule had to realign.
    mutating func wake(at now: UInt64) -> (late: UInt64, realigned: Bool) {
        guard now >= next else { return (0, false) }
        let late = now - next
        guard late > realign else { return (late, false) }
        next = now
        return (late, true)
    }

    /// Whether this wake renders another block.
    ///
    /// `realtime` is how the scheduler really runs the mix thread, read back
    /// after the promotion (`AirPlayMixScheduling`), not the promotion's
    /// return value. A time-constraint thread keeps each burst inside
    /// `burstBudget`, so it never overruns the realtime constraint it asked
    /// for. A thread the host demoted to timeshare (a background-throttled
    /// process: audit F12 measured priority 4 and every wake-up ~120–200 ms
    /// late) has no constraint to honour and is preempted like any other
    /// thread, so it renders every overdue block up to `maximumBurst`; with a
    /// time budget it would starve the bridge whenever a block costs more
    /// than the budget allows per wake-up (a debug build: ~5 ms per block).
    func shouldRender(now: UInt64, burstStart: UInt64, rendered: Int, realtime: Bool = true) -> Bool {
        guard next <= now, rendered < maximumBurst else { return false }
        return rendered < minimumBurst || !realtime || now &- burstStart < burstBudget
    }

    /// How far the clock is behind real time at `now` (0 when caught up).
    func lag(at now: UInt64) -> UInt64 { now > next ? now - next : 0 }

    mutating func didRender() { next += period }

    /// When to wake again: the next block's deadline, or after `pause` if
    /// the burst ended while still behind.
    func resume(after now: UInt64, pause: UInt64) -> UInt64 { next > now ? next : now + pause }
}

/// How the scheduler really runs the calling thread. `thread_policy_set`
/// accepts a time-constraint request even when the host clamps the whole
/// process (a tool started by a background agent or launchd job, App Nap):
/// the request is stored, but the thread runs timeshare at the clamp's
/// priority and its timers are coalesced.
///
/// Audit F12, measured on the build Mac (work/audit-20261028/s3/
/// RealtimeStateProbe.out): under the agent's policy the promotion returned
/// success, yet the scheduler ran the thread timeshare at priority 4 and 2 ms
/// waits woke ~120 ms late; neither a latency-critical NSProcessInfo activity
/// nor leaving darwin-background changed that. Under the application policy
/// the same thread runs round-robin at priority 97 and wakes within 0.05 ms,
/// and the installed app's mix thread shows as 97R in `ps -M`.
enum AirPlayMixScheduling {
    struct Reading: Equatable {
        /// The realtime band: fixed priority at or above BASEPRI_RTQUEUES.
        var realtime: Bool
        /// The thread's current scheduling priority (-1 when unknown).
        var priority: Int32
        /// The highest priority the host allows this thread (-1 when
        /// unknown): 4 (MAXPRI_THROTTLE) in a background-clamped process,
        /// 63 for an application. Read on an ordinary thread, it says whether
        /// the host clamps the process at all, independently of the mix code.
        var maximumPriority: Int32 = -1

        /// The host clamps the process to the throttled band.
        var hostClamped: Bool { maximumPriority >= 0 && maximumPriority <= 4 }
    }

    /// The scheduler's view of the calling thread; nil if the kernel does not
    /// answer. Two Mach calls, nothing allocated: safe on the mix thread.
    static func current() -> Reading? {
        let port = pthread_mach_thread_np(pthread_self())
        var basic = thread_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let basicStatus = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicStatus == KERN_SUCCESS else { return nil }
        var extended = thread_extended_info_data_t()
        var extendedCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size)
        let extendedStatus = withUnsafeMutablePointer(to: &extended) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
            }
        }
        let priority: Int32 = extendedStatus == KERN_SUCCESS ? extended.pth_curpri : -1
        let maximum: Int32 = extendedStatus == KERN_SUCCESS ? extended.pth_maxpriority : -1
        // THREAD_BASIC_INFO reports every non-timeshare mode as round-robin;
        // the priority tells the realtime band (97 and up) apart.
        return Reading(realtime: basic.policy != POLICY_TIMESHARE && (priority < 0 || priority >= 97),
                       priority: priority, maximumPriority: maximum)
    }

    /// One word, so a reader never pairs one reading's state with another's
    /// priority: bits 0–7 state (1 realtime, 2 timeshare; 0 none), 8–15 and
    /// 16–23 the priorities plus one.
    static func pack(_ reading: Reading?) -> UInt64 {
        guard let reading else { return 0 }
        func byte(_ value: Int32) -> UInt64 { UInt64(min(max(value + 1, 0), 255)) }
        return (reading.realtime ? 1 : 2) | byte(reading.priority) << 8 | byte(reading.maximumPriority) << 16
    }

    static func unpack(_ word: UInt64) -> Reading? {
        let state = word & 0xFF
        guard state == 1 || state == 2 else { return nil }
        return Reading(realtime: state == 1, priority: Int32(word >> 8 & 0xFF) - 1,
                       maximumPriority: Int32(word >> 16 & 0xFF) - 1)
    }
}

/// What one mix thread measured about itself (audit F12): when it was asked
/// to start, when it first ran and first mixed, and every wake-up's lateness
/// and output, so start-up cost and sustained supply are read separately.
/// Only the mix thread writes, through atomics allocated before it starts;
/// diagnostics and tests read at any time.
final class AirPlayMixTimeline {
    struct Wake: Equatable {
        /// Host time of the wake-up (CLOCK_UPTIME_RAW nanoseconds).
        var at: UInt64
        /// How far behind its schedule the thread woke.
        var late: UInt64
        /// Blocks this wake-up rendered, and blocks rendered since start.
        var rendered: Int
        var totalBlocks: UInt64
        /// Time spent rendering, and how far behind real time the clock
        /// still was when the burst ended (0: caught up). Microsecond
        /// resolution.
        var burst: UInt64
        var lagAfter: UInt64
        /// How the scheduler ran the thread at this wake-up.
        var realtime: Bool
        var realigned: Bool
        var end: UInt64 { at + burst }
    }

    struct SustainedRate: Equatable {
        var framesPerSecond: Double
        /// Host time covered, nanoseconds, and wake-ups in that span.
        var span: UInt64
        var wakes: Int
        /// The largest lag any of those wake-ups left behind.
        var worstLagAfterWake: UInt64
    }

    struct Report {
        /// `start()` to the thread running, and to its first block, ns.
        var threadStart: UInt64?
        var firstMix: UInt64?
        /// Host times of `start()` and of the first block.
        var startRequestedAt: UInt64?
        var firstMixAt: UInt64?
        var wakes: [Wake]
        var lateWakes: UInt64
        var budgetLimitedWakes: UInt64
        var scheduling: AirPlayMixScheduling.Reading?

        /// Supply after the warm-up: from the first wake-up that ends at least
        /// `warmUp` after the first block to the last one recorded.
        func sustainedRate(warmUp: UInt64, blockFrames: Int = AirPlayMixThread.blockFrames) -> SustainedRate? {
            guard let firstMixAt else { return nil }
            return AirPlayMixTimeline.sustainedRate(of: wakes, after: firstMixAt + warmUp, blockFrames: blockFrames)
        }
    }

    /// Wake-ups kept: 2.56 s at one per period, much longer when throttled.
    static let capacity = 256
    /// A wake-up this late is counted as throttled.
    static let lateWakeNanoseconds: UInt64 = 20_000_000

    let startRequested = AudioAtomicCounter()
    let threadRunning = AudioAtomicCounter()
    let firstMix = AudioAtomicCounter()
    let lateWakes = AudioAtomicCounter()
    /// Wake-ups whose burst ended still behind (time budget or block cap).
    let budgetLimitedWakes = AudioAtomicCounter()
    /// The latest scheduler reading, packed (`AirPlayMixScheduling.pack`).
    private let schedulingWord = AudioAtomicCounter()
    private let slotAt: [AudioAtomicCounter]
    private let slotLate: [AudioAtomicCounter]
    private let slotCounts: [AudioAtomicCounter]
    private let slotTiming: [AudioAtomicCounter]
    private let written = AudioAtomicCounter()
    private static let blockMask: UInt64 = (1 << 40) - 1

    init() {
        slotAt = (0..<Self.capacity).map { _ in AudioAtomicCounter() }
        slotLate = (0..<Self.capacity).map { _ in AudioAtomicCounter() }
        slotCounts = (0..<Self.capacity).map { _ in AudioAtomicCounter() }
        slotTiming = (0..<Self.capacity).map { _ in AudioAtomicCounter() }
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    func note(_ reading: AirPlayMixScheduling.Reading?) {
        schedulingWord.store(AirPlayMixScheduling.pack(reading))
    }

    var scheduling: AirPlayMixScheduling.Reading? { AirPlayMixScheduling.unpack(schedulingWord.load()) }

    /// Mix thread only. The wake-up time is written last, so a reader that
    /// sees the same time before and after reading a slot read one record.
    func record(_ wake: Wake) {
        let index = written.load()
        let slot = Int(index % UInt64(Self.capacity))
        slotAt[slot].store(0)
        slotLate[slot].store(wake.late)
        slotCounts[slot].store(min(wake.totalBlocks, Self.blockMask) | UInt64(min(max(wake.rendered, 0), 0xFFFF)) << 40
                               | (wake.realtime ? 1 << 56 : 0) | (wake.realigned ? 1 << 57 : 0))
        slotTiming[slot].store(min(wake.burst / 1000, 0xFFFF_FFFF) << 32 | min(wake.lagAfter / 1000, 0xFFFF_FFFF))
        slotAt[slot].store(max(1, wake.at))
        written.store(index + 1)
    }

    /// The recorded wake-ups, oldest first.
    var wakes: [Wake] {
        let end = written.load()
        let first = end > UInt64(Self.capacity) ? end - UInt64(Self.capacity) : 0
        var result: [Wake] = []
        result.reserveCapacity(Int(end - first))
        for index in first..<end {
            let slot = Int(index % UInt64(Self.capacity))
            let at = slotAt[slot].load()
            guard at != 0 else { continue }
            let late = slotLate[slot].load(), counts = slotCounts[slot].load(), timing = slotTiming[slot].load()
            // Rewritten while being read: skip it.
            guard slotAt[slot].load() == at else { continue }
            result.append(Wake(at: at, late: late, rendered: Int(counts >> 40 & 0xFFFF),
                               totalBlocks: counts & Self.blockMask, burst: (timing >> 32) * 1000,
                               lagAfter: (timing & 0xFFFF_FFFF) * 1000,
                               realtime: counts & (1 << 56) != 0, realigned: counts & (1 << 57) != 0))
        }
        // A slot rewritten completely between reads holds a newer wake-up.
        result.sort { $0.at < $1.at }
        return result
    }

    func report() -> Report {
        let requested = startRequested.load(), running = threadRunning.load(), mixed = firstMix.load()
        func since(_ value: UInt64) -> UInt64? { requested != 0 && value >= requested ? value - requested : nil }
        return Report(threadStart: since(running), firstMix: since(mixed),
                      startRequestedAt: requested == 0 ? nil : requested, firstMixAt: mixed == 0 ? nil : mixed,
                      wakes: wakes, lateWakes: lateWakes.load(), budgetLimitedWakes: budgetLimitedWakes.load(),
                      scheduling: scheduling)
    }

    /// Frames per second between the first wake-up that ends at or after
    /// `start` and the last one, measured at burst ends: there the clock has
    /// either caught up (at most one block ahead) or says how far behind it
    /// is, so the figure does not depend on when anyone looked.
    static func sustainedRate(of wakes: [Wake], after start: UInt64, blockFrames: Int) -> SustainedRate? {
        guard let firstIndex = wakes.firstIndex(where: { $0.end >= start }), let last = wakes.last else { return nil }
        let first = wakes[firstIndex]
        guard last.end > first.end, last.totalBlocks >= first.totalBlocks else { return nil }
        let frames = Double(last.totalBlocks - first.totalBlocks) * Double(blockFrames)
        let span = last.end - first.end
        let lag = wakes[firstIndex...].map(\.lagAfter).max() ?? 0
        return SustainedRate(framesPerSecond: frames * 1e9 / Double(span), span: span,
                             wakes: wakes.count - firstIndex, worstLagAfterWake: lag)
    }
}

/// The local 48 kHz mix clock for one AirPlay output. A GCD timer was delayed
/// by up to 110 ms under load on a MacBook Air, and the old policy discarded
/// the whole PCM bridge after 100 ms — an audible gap each time. This thread
/// uses the Mach time-constraint (realtime) policy, renders 10 ms blocks on a
/// fixed host-clock schedule and, when it is late, catches up from the
/// apps' own capture queues (see `AirPlayMixSchedule`) instead of dropping audio.
/// It records its own start-up and every wake-up in `timeline`.
final class AirPlayMixThread {
    static let blockFrames = 480
    static let periodNanoseconds: UInt64 = 10_000_000
    /// Beyond this lateness (sleep, debugger) the schedule is realigned.
    static let realignNanoseconds: UInt64 = 1_000_000_000
    /// Overdue blocks always rendered per wake (the 3.3.0 fixed burst).
    static let burstBlocks = 4
    /// Extra catch-up time per wake beyond `burstBlocks` while the thread
    /// really runs realtime; stays inside the 9 ms realtime constraint. A
    /// release build renders a block in ~0.05 ms, so 4 ms covers 80 blocks.
    static let burstBudgetNanoseconds: UInt64 = 4_000_000
    /// No wake renders more than the realign horizon (1 s of audio).
    static let maximumBurstBlocks = 100

    static func schedule(start: UInt64, ticks: (UInt64) -> UInt64) -> AirPlayMixSchedule {
        AirPlayMixSchedule(start: start, period: ticks(periodNanoseconds), realign: ticks(realignNanoseconds),
                           minimumBurst: burstBlocks, burstBudget: ticks(burstBudgetNanoseconds),
                           maximumBurst: maximumBurstBlocks)
    }

    let delayedMixResets = AudioAtomicCounter()
    let maximumMixDelay = AudioAtomicCounter()
    let catchUpBlocks = AudioAtomicCounter()
    let timeline = AirPlayMixTimeline()
    private let running = AudioAtomicCounter(1)
    private let realtime = AudioAtomicCounter()
    private let finished = DispatchSemaphore(value: 0)
    private let bus: AppAudioRenderBus
    private let bridge: AirPlayPCMBridge
    private let scratch: UnsafeMutablePointer<Float>
    private var thread: Thread?

    init(bus: AppAudioRenderBus, bridge: AirPlayPCMBridge) {
        self.bus = bus
        self.bridge = bridge
        scratch = .allocate(capacity: Self.blockFrames * 2)
        scratch.initialize(repeating: 0, count: Self.blockFrames * 2)
    }
    deinit { scratch.deallocate() }

    /// The realtime promotion was accepted. Whether the scheduler honours it
    /// is `timeline.scheduling`.
    var isRealtime: Bool { realtime.load() == 1 }

    func start() {
        timeline.startRequested.store(AirPlayMixTimeline.now())
        let thread = Thread { [self] in
            run()
            finished.signal()
        }
        thread.name = "com.kyw.aom.airplay.mix"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Blocks until the thread has left its loop (at most one period).
    func stop() {
        guard running.load() == 1 else { return }
        running.store(0)
        if thread != nil { _ = finished.wait(timeout: .now() + 2) }
        thread = nil
    }

    static func promoteCurrentThreadToRealtime(period: UInt64, computation: UInt64, constraint: UInt64) -> Bool {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0 else { return false }
        func ticks(_ nanoseconds: UInt64) -> UInt32 {
            UInt32(min(Double(UInt32.max), Double(nanoseconds) * Double(timebase.denom) / Double(timebase.numer)))
        }
        var policy = thread_time_constraint_policy_data_t(
            period: ticks(period), computation: ticks(computation),
            constraint: ticks(constraint), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        return status == KERN_SUCCESS
    }

    private func run() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = UInt64(max(1, timebase.numer)), denom = UInt64(max(1, timebase.denom))
        func ticks(_ nanoseconds: UInt64) -> UInt64 { nanoseconds * denom / numer }
        func nanoseconds(_ ticks: UInt64) -> UInt64 { ticks * numer / denom }
        timeline.threadRunning.store(AirPlayMixTimeline.now())
        if Self.promoteCurrentThreadToRealtime(period: Self.periodNanoseconds,
                                               computation: 2_000_000, constraint: 9_000_000) {
            realtime.store(1)
        }
        // What the scheduler made of the request: it can accept the policy
        // and still run the thread timeshare (see AirPlayMixScheduling).
        var scheduling = AirPlayMixScheduling.current()
        timeline.note(scheduling)
        let burstPause = ticks(1_000_000)
        let lateWake = ticks(AirPlayMixTimeline.lateWakeNanoseconds)
        var schedule = Self.schedule(start: mach_absolute_time(), ticks: ticks)
        var totalBlocks: UInt64 = 0
        var wakes: UInt64 = 0
        while running.load() == 1 {
            var now = mach_absolute_time()
            if now < schedule.next {
                mach_wait_until(schedule.next)
                continue
            }
            let wake = schedule.wake(at: now)
            wakes += 1
            let throttled = wake.late > lateWake
            if throttled { timeline.lateWakes.add() }
            // The host can demote or restore the thread at any time (App Nap,
            // a background clamp): read it again after a late wake-up and
            // every 100 wake-ups (about once a second on time).
            if throttled || wakes % 100 == 0 {
                scheduling = AirPlayMixScheduling.current()
                timeline.note(scheduling)
            }
            let runsRealtime = scheduling?.realtime ?? isRealtime
            maximumMixDelay.raise(to: nanoseconds(wake.late))
            // After sleep the backlog is stale; the per-app queues trim their
            // own excess. Never clear audio the bridge still holds.
            if wake.realigned { delayedMixResets.add() }
            let burstStart = now
            var rendered = 0
            while running.load() == 1 && schedule.shouldRender(now: now, burstStart: burstStart, rendered: rendered,
                                                                 realtime: runsRealtime) {
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers:
                    AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(Self.blockFrames * 8), mData: scratch))
                withUnsafeMutablePointer(to: &buffers) { bus.render(frames: Self.blockFrames, output: $0, allowWaiting: true) }
                bridge.push(scratch, frames: Self.blockFrames)
                schedule.didRender()
                rendered += 1
                totalBlocks += 1
                now = mach_absolute_time()
                if totalBlocks == 1 { timeline.firstMix.store(nanoseconds(now)) }
            }
            if rendered > 1 { catchUpBlocks.add(UInt64(rendered - 1)) }
            // A burst cut short by stop() is not a supply sample.
            guard running.load() == 1 else { break }
            let behind = schedule.next <= now
            if behind { timeline.budgetLimitedWakes.add() }
            timeline.record(.init(at: nanoseconds(burstStart), late: nanoseconds(wake.late), rendered: rendered,
                                  totalBlocks: totalBlocks, burst: nanoseconds(now - burstStart),
                                  lagAfter: nanoseconds(schedule.lag(at: now)), realtime: runsRealtime,
                                  realigned: wake.realigned))
            if behind {
                // Still behind after the budget: yield briefly, then continue.
                mach_wait_until(schedule.resume(after: now, pause: burstPause))
            }
        }
    }
}
