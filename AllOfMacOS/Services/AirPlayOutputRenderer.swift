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
        result["delayedMixResets"] = mixer?.delayedMixResets.load() ?? 0
        result["maximumMixDelayMS"] = Double(mixer?.maximumMixDelay.load() ?? 0) / 1_000_000
        result["catchUpBlocks"] = mixer?.catchUpBlocks.load() ?? 0
        result["realtimeMixer"] = mixer?.isRealtime ?? false
        return result
    }

    private func checkHealth() {
        guard !stopped, !failureDelivered else { return }
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

/// The local 48 kHz mix clock for one AirPlay output. A GCD timer was delayed
/// by up to 110 ms under load on a MacBook Air, and the old policy discarded
/// the whole PCM bridge after 100 ms — an audible gap each time. This thread
/// uses the Mach time-constraint (realtime) policy, renders 10 ms blocks on a
/// fixed host-clock schedule and, when it is late, catches up from the
/// apps' own capture queues in short bursts instead of dropping audio.
final class AirPlayMixThread {
    static let blockFrames = 480
    static let periodNanoseconds: UInt64 = 10_000_000
    /// Beyond this lateness (sleep, debugger) the schedule is realigned.
    static let realignNanoseconds: UInt64 = 1_000_000_000
    /// Blocks rendered per wake while catching up; keeps each burst far
    /// below the realtime computation budget.
    static let burstBlocks = 4

    let delayedMixResets = AudioAtomicCounter()
    let maximumMixDelay = AudioAtomicCounter()
    let catchUpBlocks = AudioAtomicCounter()
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

    var isRealtime: Bool { realtime.load() == 1 }

    func start() {
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
        if Self.promoteCurrentThreadToRealtime(period: Self.periodNanoseconds,
                                               computation: 2_000_000, constraint: 9_000_000) {
            realtime.store(1)
        }
        let period = ticks(Self.periodNanoseconds)
        let burstPause = ticks(1_000_000)
        var next = mach_absolute_time()
        while running.load() == 1 {
            var now = mach_absolute_time()
            if now < next {
                mach_wait_until(next)
                continue
            }
            let late = nanoseconds(now - next)
            maximumMixDelay.raise(to: late)
            if late > Self.realignNanoseconds {
                // After sleep the backlog is stale; the per-app queues trim
                // their own excess. Never clear audio the bridge still holds.
                delayedMixResets.add()
                next = now
            }
            var rendered = 0
            while next <= now && rendered < Self.burstBlocks && running.load() == 1 {
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers:
                    AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(Self.blockFrames * 8), mData: scratch))
                withUnsafeMutablePointer(to: &buffers) { bus.render(frames: Self.blockFrames, output: $0, allowWaiting: true) }
                bridge.push(scratch, frames: Self.blockFrames)
                next += period
                rendered += 1
                now = mach_absolute_time()
            }
            if rendered > 1 { catchUpBlocks.add(UInt64(rendered - 1)) }
            if next <= now {
                // Still behind: yield briefly, then continue the catch-up.
                mach_wait_until(now + burstPause)
            }
        }
    }
}
