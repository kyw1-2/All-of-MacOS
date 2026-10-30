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
    /// −1 dBTP: the receiver decodes a lossy stream, whose overshoot would
    /// clip a mix limited to −0.2 dB sample peak (3.3.2 audit), released
    /// slowly enough not to modulate bass (`networkRelease`). 3.3.4 (N334):
    /// levelled first (`AppAudioRenderBus.network()`), so the 1.3 ms
    /// limiter no longer takes several dB off transients Magic Boost lifted.
    let bus = AppAudioRenderBus.network()
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
    /// The rate the bridge resamples to and the AUHAL input format uses.
    private var configuredRate: Double = 0
    private var configuredFrames: UInt32 = 0
    private var configuredChannels: UInt32 = 0
    /// What the device itself reported right after the format was applied
    /// (crackle audit 3.3.2, follow-up). Notifications compare against these
    /// readings, like with like: comparing the nominal rate with a rate taken
    /// from the AUHAL format (or the other way round) classified every later
    /// notification as a format change, and each one restarted the unit and
    /// cleared the bridge — at least 150 ms of silence per notification.
    private var baseline = ConfigurationBaseline(nominalRate: 0, deviceRate: 0, channels: 0)
    /// Keeps App Nap and timer coalescing away from the mix clock while this
    /// output exists (start() … tearDown(), device queue only).
    private let napGuard = AirPlayNapGuard(reason: "AirPlay output mixing (realtime audio)")
    /// The IO size AOM asks for, clamped to the device's range (device queue).
    private var ioTargetFrames: UInt32 = AirPlayOutputRenderer.preferredIOFrames
    /// Periodic IO re-request bookkeeping (device queue).
    private var lastIORequestAt: TimeInterval = 0
    private var cycleGapsAtLastRequest: UInt64 = 0
    private var stopped = false
    private var failureDelivered = false
    private let changed: () -> Void
    /// Seconds without a HAL render request (or without rendered audio)
    /// before native playback is restored. HomePods can pause a few seconds
    /// on Wi-Fi hiccups; the PCM bridge rides those out.
    static let stallLimit: TimeInterval = 6

    init(deviceID: AudioDeviceID, uid: String = "", changed: @escaping () -> Void) {
        self.deviceID = deviceID
        self.uid = uid
        self.queue = AirPlayDeviceQueues.queue(for: deviceID)
        self.changed = changed
        queue.async { [self] in start() }
    }

    /// The device UID, for the event log (3.3.3, A03).
    let uid: String
    /// Device queue only: this output's registration with the event log.
    private var eventSource: AudioEventLog.Source?
    private var eventName: String { "output:" + (uid.isEmpty ? String(deviceID) : uid) }

    /// Counters for the event log's totals (its poller's queue).
    private var eventCounters: [String: UInt64] {
        var result = bridge.eventCounters
        result["output.reconfigurations"] = reconfigurations.load()
        result["output.ignoredFormatNotices"] = ignoredFormatNotices.load()
        result["output.processorOverloads"] = processorOverloads.load()
        result["output.limiterEngagements"] = bus.limiterEngagements.load()
        result["output.levelerEngagements"] = bus.levelerEngagements.load()
        if let mixer { result["output.mixLateWakes"] = mixer.timeline.lateWakes.load() }
        return result
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

    /// Frames per IO cycle AOM asks for on the AirPlay device. The buffer
    /// size is a per-process HAL setting, so this changes only AOM's own IO.
    /// 3.3.2 audit: the device's default client buffer is 128 frames
    /// (2.7 ms) with no safety offset; coreaudiod logged "Overload possibly
    /// due to safety violation" and AOM "skipping cycle due to overload"
    /// several times an hour, each one a click. AirPlay already buffers
    /// about 2 s, so 21 ms more cycle time is inaudible.
    static let preferredIOFrames: UInt32 = 1024

    /// Asks for `preferredIOFrames` within the device's range; nil if the
    /// device refuses (the default then stays in use). A refusal is logged
    /// at .error once per device with the range the device allows; it used
    /// to be a .noMatch line, so a HomePod left at 128 frames went unseen.
    @discardableResult
    private func requestIOBufferFrames() -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var preferred = Self.preferredIOFrames
        let rangeKnown = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &range) == noErr
            && range.mMinimum.isFinite && range.mMaximum.isFinite && range.mMinimum >= 1 && range.mMaximum >= range.mMinimum
        if rangeKnown {
            preferred = UInt32(min(range.mMaximum, max(range.mMinimum, Double(preferred))))
        }
        ioTargetFrames = preferred
        address.mSelector = kAudioDevicePropertyBufferFrameSize
        var settable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        let setStatus = settableStatus == noErr && settable.boolValue
            ? AudioObjectSetPropertyData(deviceID, &address, 0, nil, 4, &preferred) : kAudioHardwareIllegalOperationError
        guard setStatus == noErr else {
            let allowed = rangeKnown ? "\(Int(range.mMinimum))–\(Int(range.mMaximum)) frames" : "range unknown"
            logIOBufferProblemOnce("AirPlay device refused AOM's \(preferred)-frame IO buffer (status \(setStatus), "
                + "settable \(settable.boolValue), allowed \(allowed)); the default size may overload and click")
            return nil
        }
        return preferred
    }

    /// One .error line per device and launch for IO-size problems (device
    /// queue; the set is shared by the renderers that replace each other).
    private static let ioLogLock = NSLock()
    private static var ioLoggedDevices = Set<AudioDeviceID>()
    private func logIOBufferProblemOnce(_ message: String) {
        Self.ioLogLock.lock()
        let first = Self.ioLoggedDevices.insert(deviceID).inserted
        Self.ioLogLock.unlock()
        if first { GestureLog.shared.logFromAnyThread(message, level: .error) }
    }

    /// How often AOM may ask again for its IO size (crackle audit 3.3.2,
    /// follow-up). Until then it asked at most `maximumBufferRequests` times
    /// per output and otherwise accepted whatever size the device fell back
    /// to (128 frames on a HomePod: HAL overloads, each a click) for the rest
    /// of the session.
    static let ioRerequestInterval: TimeInterval = 30
    /// The longest wait between two re-requests: a device that keeps AOM
    /// below its size is asked less and less often (each accepted set
    /// reconfigures AOM's IO, one possible gap).
    static let ioRerequestMaximumInterval: TimeInterval = 600

    /// The wait before the next re-request after `attempts` that did not
    /// stick: 30 s, then doubling up to 10 minutes.
    static func ioRerequestDelay(afterUnheededRequests attempts: Int) -> TimeInterval {
        let doubled = ioRerequestInterval * pow(2, Double(min(max(0, attempts), 16)))
        return min(ioRerequestMaximumInterval, doubled)
    }

    /// Whether the periodic health check asks for the IO size again: only
    /// while the device runs AOM below the size it wants (3.3.2 review: a
    /// cycle gap alone asked again every 30 s even at 1024 frames, and a HAL
    /// that restarts IO on a same-size set turned one gap into a click every
    /// 30 s). `cycleGapsGrew` is kept for callers and no longer decides.
    static func shouldRerequestIOBuffer(configured: UInt32, preferred: UInt32, cycleGapsGrew: Bool,
                                        secondsSinceLastRequest: TimeInterval,
                                        unheededRequests: Int = 0) -> Bool {
        guard configured < preferred else { return false }
        return secondsSinceLastRequest >= ioRerequestDelay(afterUnheededRequests: unheededRequests)
    }

    /// Re-requests whose size the device did not keep (device queue).
    private var unheededIORequests = 0

    /// Health check (device queue, never the HAL or mix thread).
    private func rerequestIOBufferIfNeeded(now: TimeInterval) {
        let gaps = bridge.deviceCycleGaps
        if configuredFrames >= ioTargetFrames { unheededIORequests = 0 }
        guard Self.shouldRerequestIOBuffer(configured: configuredFrames, preferred: ioTargetFrames,
                                           cycleGapsGrew: gaps > cycleGapsAtLastRequest,
                                           secondsSinceLastRequest: now - lastIORequestAt,
                                           unheededRequests: unheededIORequests) else { return }
        // Asked before and the device still runs AOM smaller: it clamps or
        // ignores the request. Say so once, with what it allows, and wait
        // longer before the next one.
        if lastIORequestAt > 0, configuredFrames < ioTargetFrames {
            unheededIORequests += 1
            logIOBufferProblemOnce("AirPlay device keeps AOM at \(configuredFrames)-frame IO although "
                + "\(ioTargetFrames) frames were requested; HAL overloads (clicks) remain possible")
        }
        lastIORequestAt = now
        cycleGapsAtLastRequest = gaps
        // The resulting BufferFrameSize notification retargets the bridge.
        requestIOBufferFrames()
    }

    private func start() {
        guard !stopped else { return }
        // Held until tearDown (every failure path goes through fail →
        // tearDown, and stop → tearDown); begin/end run on this queue.
        napGuard.acquire()
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
        // A refusal is logged once at .error inside the request.
        requestIOBufferFrames()
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
        baseline = observedBaseline(unit: instance, appliedRate: format.mSampleRate)
        bridge.configure(outputRate: format.mSampleRate, deviceFrames: Int(deviceFrames))
        var callback = AURenderCallbackStruct(inputProc: { context, _, timeStamp, _, frames, buffers in
            guard let buffers else { return noErr }
            // The device's sample time tells cycles the HAL skipped (an
            // overload is a gap in it), which is what the user hears as a click.
            let stamp = timeStamp.pointee
            let sampleTime = stamp.mFlags.contains(.sampleTimeValid) ? stamp.mSampleTime : -1
            Unmanaged<AirPlayPCMBridge>.fromOpaque(context).takeUnretainedValue()
                .render(frames: Int(frames), output: buffers, sampleTime: sampleTime)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(bridge).toOpaque())
        guard check(AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))), "set callback"),
              check(AudioUnitInitialize(instance), "initialize") else { return }
        // Silence is prebuffered before any muting process tap is attached.
        bridge.prime()
        startedAt = ProcessInfo.processInfo.systemUptime
        guard check(AudioOutputUnitStart(instance), "start") else { return }
        // Initializing and starting the unit can put AOM's IO buffer back to
        // the device default (128 frames on AirPlay, the size coreaudiod
        // reported overloads at); ask once more and follow what it took.
        size = 4
        if AudioObjectGetPropertyData(deviceID, &frameAddress, 0, nil, &size, &deviceFrames) == noErr,
           deviceFrames > 0, deviceFrames < Self.preferredIOFrames, requestIOBufferFrames() != nil {
            bufferRequests += 1
            size = 4
            if AudioObjectGetPropertyData(deviceID, &frameAddress, 0, nil, &size, &deviceFrames) == noErr,
               deviceFrames > 0, deviceFrames <= maximum, Double(deviceFrames) * 48000 / format.mSampleRate <= 32000 {
                configuredFrames = deviceFrames
                bridge.updateDeviceFrames(Int(deviceFrames))
            }
        }
        GestureLog.shared.logFromAnyThread("AirPlay output: \(Int(format.mSampleRate)) Hz, \(configuredFrames)-frame IO",
                                           level: .noMatch)
        // The periodic re-request (checkHealth) counts from here.
        lastIORequestAt = ProcessInfo.processInfo.systemUptime
        cycleGapsAtLastRequest = bridge.deviceCycleGaps
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
        // 3.3.3 (A01): the HAL's own word for an IO cycle that ran past its
        // deadline (kAudioDeviceProcessorOverload, documented in
        // AudioHardware.h; sent from the IO thread, delivered here on the
        // device queue). Counted beside the sample-time gaps it explains.
        var overloadAddress = AudioObjectPropertyAddress(mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let overloadListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.processorOverloaded()
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &overloadAddress, queue, overloadListener) == noErr {
            listeners.append((overloadAddress, overloadListener))
        }
        // The share of the IO cycle's client portion the HAL gives this
        // process (kAudioDevicePropertyIOCycleUsage, 0…1). 1, the default,
        // is already the most: the IO thread starts as early as it can, and
        // a lower value would only shorten AOM's time. Read, not set.
        var usageAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOCycleUsage,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var usage: Float32 = 0
        size = 4
        if AudioObjectGetPropertyData(deviceID, &usageAddress, 0, nil, &size, &usage) == noErr, usage.isFinite {
            ioCycleUsageBits.store(UInt64(usage.bitPattern))
        }
        let thread = AirPlayMixThread(bus: bus, bridge: bridge)
        thread.start()
        mixer = thread
        // 3.3.3 (A03): the HAL thread's ring (gaps, bridge trims/underruns),
        // the mix thread's (limiter, late wake-ups) and the counters.
        eventSource = AudioEventLog.shared.register(name: eventName, rings: [bridge.events, bus.events]) { [weak self] in
            self?.eventCounters ?? [:]
        }
        let usageBits = ioCycleUsageBits.load()
        AudioEventLog.shared.record(.outputStarted, source: eventName, value: Int64(configuredFrames),
            detail: "AirPlay \(Int(configuredRate)) Hz, \(configuredFrames)-frame IO, IO cycle usage "
                + (usageBits == 0 ? "unread" : String(format: "%.2f", Float(bitPattern: UInt32(truncatingIfNeeded: usageBits)))))
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(250), leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.checkHealth() }
        timer = source
        source.resume()
    }

    /// What a device notification means for the running output (3.3.2).
    /// Until 3.3.1 any difference failed the output: the taps were released
    /// and the HomePod reconnected seconds later, a gap of several seconds
    /// for a change as small as a new IO buffer size.
    enum ConfigurationChange: Equatable {
        case none
        /// The IO buffer size changed: retarget the bridge, keep playing.
        case bufferSize(UInt32)
        /// Rate or channel layout changed: reapply the format in place.
        case format
        /// The device is gone.
        case lost
    }

    /// nil arguments are reads that failed; a failed read on a live device is
    /// treated as transient (the health check catches a real stall).
    /// One configured rate for both readings (kept for existing callers).
    static func classify(alive: UInt32?, frames: UInt32?, nominalRate: Double?, deviceRate: Double?,
                         channels: UInt32?, configuredRate: Double, configuredFrames: UInt32,
                         configuredChannels: UInt32) -> ConfigurationChange {
        classify(alive: alive, frames: frames, nominalRate: nominalRate, deviceRate: deviceRate, channels: channels,
                 baseline: ConfigurationBaseline(nominalRate: configuredRate, deviceRate: configuredRate,
                                                 channels: configuredChannels),
                 configuredFrames: configuredFrames)
    }

    /// What the device reported once the current format was applied. Each
    /// reading is compared with the same reading taken then: the device's
    /// nominal rate and the AUHAL's hardware format can legitimately differ,
    /// and comparing either with the other's value made every notification
    /// a "format change" (unit restart and bridge clear, again and again).
    struct ConfigurationBaseline: Equatable {
        var nominalRate: Double
        var deviceRate: Double
        var channels: UInt32
    }

    /// The baseline from readings right after the format was applied; a
    /// failed read falls back to the applied rate.
    static func baseline(appliedRate: Double, nominalRate: Double?, deviceRate: Double?,
                         channels: UInt32) -> ConfigurationBaseline {
        ConfigurationBaseline(nominalRate: nominalRate ?? appliedRate, deviceRate: deviceRate ?? appliedRate,
                              channels: channels)
    }

    static func classify(alive: UInt32?, frames: UInt32?, nominalRate: Double?, deviceRate: Double?,
                         channels: UInt32?, baseline: ConfigurationBaseline,
                         configuredFrames: UInt32) -> ConfigurationChange {
        guard let alive, alive != 0 else { return .lost }
        if let nominalRate, nominalRate != baseline.nominalRate { return .format }
        if let deviceRate, deviceRate != baseline.deviceRate { return .format }
        if let channels, channels != baseline.channels { return .format }
        if let frames, frames > 0, frames != configuredFrames { return .bufferSize(frames) }
        return .none
    }

    /// Reads the device's nominal rate and the AUHAL hardware format now
    /// (device queue, after the unit took its format).
    private func observedBaseline(unit: AudioUnit, appliedRate: Double) -> ConfigurationBaseline {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var nominal: Double = 0
        var size: UInt32 = 8
        let nominalOK = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nominal) == noErr
        var hardware = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout.size(ofValue: hardware))
        let hardwareOK = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                                              &hardware, &size) == noErr
        return Self.baseline(appliedRate: appliedRate, nominalRate: nominalOK ? nominal : nil,
                             deviceRate: hardwareOK ? hardware.mSampleRate : nil,
                             channels: hardwareOK ? hardware.mChannelsPerFrame : configuredChannels)
    }

    /// In-place format changes survived (diagnostics; written on the device queue).
    let reconfigurations = AudioAtomicCounter()
    /// kAudioDeviceProcessorOverload notifications (device queue).
    let processorOverloads = AudioAtomicCounter()
    /// kAudioDevicePropertyIOCycleUsage read at start (Float32 bits; 0: unread).
    private let ioCycleUsageBits = AudioAtomicCounter()

    private func processorOverloaded() {
        guard !stopped else { return }
        processorOverloads.add()
        AudioEventLog.shared.record(.overload, source: eventName, detail: "kAudioDeviceProcessorOverload")
    }
    /// Times AOM asked again for its IO buffer after it came back smaller
    /// (device queue only; at most a few per output, so two notifiers can
    /// never ping-pong).
    private var bufferRequests = 0
    static let maximumBufferRequests = 4

    private func configurationChanged(confirmed: Bool = false) {
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
        let change = Self.classify(alive: aliveStatus == noErr ? alive : nil,
                                   frames: bufferStatus == noErr ? frames : nil,
                                   nominalRate: rateStatus == noErr ? rate : nil,
                                   deviceRate: formatStatus == noErr ? format.mSampleRate : nil,
                                   channels: formatStatus == noErr ? format.mChannelsPerFrame : nil,
                                   baseline: baseline, configuredFrames: configuredFrames)
        switch change {
        case .none:
            break
        case .lost:
            fail("AirPlay device disconnected. Native playback restored; use Reconnect to retry.")
        case .bufferSize(let size):
            guard size <= 16384, Double(size) * 48000 / configuredRate <= 32000 else {
                fail("AirPlay buffer size unsupported. Native playback restored."); return
            }
            configuredFrames = size
            bridge.updateDeviceFrames(Int(size))
            AudioEventLog.shared.record(.bufferSize, source: eventName, value: Int64(size), detail: "IO buffer size changed")
            // Back to a small buffer (another client, a route change): ask
            // for the large one again, a bounded number of times.
            if size < Self.preferredIOFrames, bufferRequests < Self.maximumBufferRequests,
               requestIOBufferFrames() != nil {
                bufferRequests += 1
            }
        case .format:
            // A notice that leaves AOM's stream as it is (the same rate, at
            // least stereo) refreshes the baseline instead of restarting the
            // unit, and a new rate is confirmed 250 ms later first (crackle
            // audit 3.3.2, follow-up): every restart is a gap the receiver
            // hears, and the HAL sends such notices during route settlement.
            switch Self.formatResponse(nominalRate: rateStatus == noErr ? rate : nil,
                                       deviceRate: formatStatus == noErr ? format.mSampleRate : nil,
                                       channels: formatStatus == noErr ? format.mChannelsPerFrame : nil,
                                       configuredRate: configuredRate, confirmed: confirmed) {
            case .refreshBaseline:
                baseline = observedBaseline(unit: unit, appliedRate: configuredRate)
                ignoredFormatNotices.add()
                AudioEventLog.shared.record(.formatNotice, source: eventName, detail: "format notice; stream unchanged, no restart")
            case .confirmLater:
                guard !formatRecheckPending else { return }
                formatRecheckPending = true
                queue.asyncAfter(deadline: .now() + Self.formatConfirmDelay) { [weak self] in
                    guard let self else { return }
                    self.formatRecheckPending = false
                    self.configurationChanged(confirmed: true)
                }
            case .reconfigure:
                if !reconfigure(unit, nominalRate: rateStatus == noErr ? rate : nil) {
                    fail("AirPlay device format changed and could not be reapplied. Native playback restored; use Reconnect to retry.")
                }
            }
        }
    }

    /// Format notices that changed nothing AOM depends on (diagnostics).
    let ignoredFormatNotices = AudioAtomicCounter()
    /// A rate change waits this long to be confirmed by a second reading.
    static let formatConfirmDelay: TimeInterval = 0.25
    /// Device queue only.
    private var formatRecheckPending = false

    /// What a format notice does.
    enum FormatResponse: Equatable {
        /// AOM's stream is unchanged: new baseline readings, no restart.
        case refreshBaseline
        /// Read again after `formatConfirmDelay`; act only if it holds.
        case confirmLater
        /// Restart the unit with the new format in place.
        case reconfigure
    }

    /// The rate AOM's stream would run at is the nominal rate (else the
    /// AUHAL hardware rate); while it equals the configured rate and the
    /// device is still at least stereo, `reconfigure` would apply the same
    /// format again, so nothing restarts.
    static func formatResponse(nominalRate: Double?, deviceRate: Double?, channels: UInt32?,
                               configuredRate: Double, confirmed: Bool) -> FormatResponse {
        let stereo = channels.map { $0 >= 2 } ?? true
        let rate = nominalRate ?? deviceRate ?? configuredRate
        if stereo, rate.isFinite, abs(rate - configuredRate) < 0.5 { return .refreshBaseline }
        return confirmed ? .reconfigure : .confirmLater
    }

    /// Applies a new device format in place: the unit stops, takes the new
    /// rate and starts again while the taps, sources and mix clock stay.
    /// The bridge fades its queued audio out and restarts at the new rate.
    private func reconfigure(_ unit: AudioUnit, nominalRate: Double?) -> Bool {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: hardware))
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                                   &hardware, &size) == noErr, hardware.mChannelsPerFrame >= 2 else { return false }
        let rate = nominalRate ?? hardware.mSampleRate
        guard rate.isFinite, (8000...192000).contains(rate) else { return false }
        var format = AudioStreamBasicDescription(mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                   &format, UInt32(MemoryLayout.size(ofValue: format))) == noErr else { return false }
        requestIOBufferFrames()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        size = 4
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames) == noErr,
              frames > 0, frames <= 16384, Double(frames) * 48000 / rate <= 32000 else { return false }
        // Only a new rate makes the queued audio wrong. A notification that
        // changed nothing the bridge depends on (channel layout, a reading
        // that only looked different) keeps its audio: clearing it cost at
        // least 150 ms of silence each time.
        if rate != configuredRate {
            bridge.reconfigure(outputRate: rate, deviceFrames: Int(frames))
        } else {
            bridge.updateDeviceFrames(Int(frames))
        }
        guard AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else { return false }
        configuredRate = rate
        configuredFrames = frames
        configuredChannels = hardware.mChannelsPerFrame
        // The readings the next notification is compared with, taken now
        // that the unit runs the new format.
        baseline = observedBaseline(unit: unit, appliedRate: rate)
        reconfigurations.add()
        AudioEventLog.shared.record(.reconfiguration, source: eventName, value: Int64(frames),
                                    detail: "reconfigured in place: \(Int(rate)) Hz, \(frames)-frame IO")
        GestureLog.shared.logFromAnyThread("AirPlay output reconfigured in place: \(Int(rate)) Hz, \(frames)-frame IO",
                                           level: .noMatch)
        return true
    }

    var statistics: [String: Any] {
        var result = bridge.statistics
        let mixer = mixer
        result["delayedMixResets"] = mixer?.delayedMixResets.load() ?? 0
        result["maximumMixDelayMS"] = Double(mixer?.maximumMixDelay.load() ?? 0) / 1_000_000
        result["catchUpBlocks"] = mixer?.catchUpBlocks.load() ?? 0
        result["realtimeMixer"] = mixer?.isRealtime ?? false
        result["reconfigurations"] = reconfigurations.load()
        // Crackle audit 3.3.2, follow-up: format notices that restarted
        // nothing, and IO-size requests the device did not keep.
        result["ignoredFormatNotices"] = ignoredFormatNotices.load()
        // 3.3.3 (A01): the HAL's overload notices, and the cycle share it gives AOM.
        result["processorOverloads"] = processorOverloads.load()
        let usageBits = ioCycleUsageBits.load()
        result["ioCycleUsage"] = usageBits == 0 ? -1 : Double(Float(bitPattern: UInt32(truncatingIfNeeded: usageBits)))
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
        rerequestIOBufferIfNeeded(now: uptime)
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
        AudioEventLog.shared.record(.outputFailed, source: eventName, detail: message)
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
        if let source = eventSource {
            // The last records and counts before the rings go (3.3.3, A03).
            AudioEventLog.shared.unregister(source)
            eventSource = nil
            AudioEventLog.shared.record(.outputStopped, source: eventName)
        }
        napGuard.release()
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
///
/// 3.3.2: the target adapts. 150 ms is the floor; when the mix clock reports
/// a late wake-up (a demoted or throttled mix thread) the target rises to
/// twice that lateness plus two blocks and the device slice, up to 400 ms —
/// AirPlay itself buffers about 2 s — and decays over about half a minute.
/// The queue's controller moves the level there within ±0.2 %, and an
/// underrun re-primes to the raised target at once.
final class AirPlayPCMBridge {
    static let baseTargetFrames = 7200
    static let maximumTargetFrames = 19200
    /// Seconds for a lateness-raised target to decay by about 63 %.
    static let latenessDecaySeconds = 30.0
    private let queue: StereoPCMQueue
    private let outputRateBits = AudioAtomicCounter(Double(48000).bitPattern)
    private let targetValue = AudioAtomicCounter(UInt64(AirPlayPCMBridge.baseTargetFrames))
    private let deviceFramesValue = AudioAtomicCounter(128)
    /// Nanoseconds; raised by the mix thread, taken by the HAL callback.
    private let producerLateness = AudioAtomicCounter()
    private let effectiveTarget = AudioAtomicCounter(UInt64(AirPlayPCMBridge.baseTargetFrames))
    // HAL-callback-owned.
    private var latenessFrames: Double = 0
    private let callbackTick = AudioAtomicCounter()
    private let audioTick = AudioAtomicCounter()
    private let invalid = AudioAtomicCounter()
    private let secondsPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        queue = StereoPCMQueue(capacity: 96000, events: events)
    }

    /// The HAL thread's event ring (3.3.3, A03): cycle gaps, and the queue's
    /// trims, underruns and clears; read by `AudioEventLog`.
    let events = AudioEventRing(capacity: 64)

    static func target(outputRate: Double, deviceFrames: Int) -> Int {
        let rate = outputRate.isFinite && outputRate > 0 ? outputRate : 48000
        return min(48000, max(baseTargetFrames, Int(ceil(Double(max(1, deviceFrames)) * 48000 / rate)) * 3))
    }

    /// The level the queue is steered to: the floor, or what the observed
    /// mix-clock lateness needs, capped at 400 ms.
    static func adaptiveTarget(base: Int, latenessFrames: Double, deviceFrames: Int, outputRate: Double) -> Int {
        let slice = Double(max(1, deviceFrames)) * 48000 / max(1, outputRate)
        let needed = 2 * latenessFrames + Double(2 * AirPlayMixThread.blockFrames) + slice
        return min(maximumTargetFrames, max(base, Int(needed.rounded(.up))))
    }

    /// Setup, or while the HAL callback is stopped.
    func configure(outputRate: Double, deviceFrames: Int) {
        outputRateBits.store(outputRate.bitPattern)
        deviceFramesValue.store(UInt64(max(1, deviceFrames)))
        targetValue.store(UInt64(Self.target(outputRate: outputRate, deviceFrames: deviceFrames)))
    }
    /// A new device format while the HAL callback is stopped: the queued
    /// audio fades out and the stream restarts at the new rate.
    func reconfigure(outputRate: Double, deviceFrames: Int) {
        configure(outputRate: outputRate, deviceFrames: deviceFrames)
        queue.requestClear()
    }
    /// A buffer-size change only moves the target; safe while running.
    func updateDeviceFrames(_ frames: Int) {
        deviceFramesValue.store(UInt64(max(1, frames)))
        targetValue.store(UInt64(Self.target(outputRate: Double(bitPattern: outputRateBits.load()), deviceFrames: frames)))
    }
    /// The mix thread woke this late (nanoseconds).
    func noteMixLateness(_ nanoseconds: UInt64) { producerLateness.raise(to: nanoseconds) }
    func prime() { queue.prime(frames: Int(targetValue.load())) }
    var health: (lastCallback: TimeInterval, lastAudio: TimeInterval, invalidFormat: Bool) {
        (Double(callbackTick.load()) * secondsPerTick, Double(audioTick.load()) * secondsPerTick, invalid.load() != 0)
    }
    /// Device cycles the HAL skipped (each a click on the receiver), and the
    /// frames they cover, from gaps in the device's sample time. 3.3.1 showed
    /// "skipping cycle due to overload" in the log and nothing in its own
    /// diagnostics; these make the overload visible in audio-health.json.
    private let cycleGaps = AudioAtomicCounter()
    private let gapFrames = AudioAtomicCounter()
    // HAL-callback-owned.
    private var lastSampleTime: Double = -1
    private var lastCallbackFrames = 0
    /// Cycles the HAL skipped so far (any thread).
    var deviceCycleGaps: UInt64 { cycleGaps.load() }

    /// 3.3.3 (A01): after a gap the device has just played a hole (the HAL
    /// skipped AOM's cycle; on the HomePod tested, coreaudiod reports these as
    /// safety violations at its fixed 128-frame IO with no safety offset).
    /// The edge into the hole happened before AOM could know of it. The way
    /// out is shaped: the next output fades in from silence over this time
    /// instead of resuming mid-waveform. Nothing is skipped: the stream
    /// continues where it was, `gap` frames later.
    static let gapFadeSeconds = 0.005
    // HAL-callback-owned.
    private var gapFadeIndex = 0
    private var gapFadeLength = 0
    private let gapFadeIns = AudioAtomicCounter()
    /// 3.3.3 (A01): what the HAL callback costs, in host ticks: the worst
    /// callback, the sum and the count (two clock reads and three atomic
    /// updates per callback).
    private let costMaxTicks = AudioAtomicCounter()
    private let costTotalTicks = AudioAtomicCounter()
    private let costCallbacks = AudioAtomicCounter()

    /// The callback's cost so far: worst and mean, in microseconds.
    var renderCost: (maximumMicros: Double, meanMicros: Double, callbacks: UInt64) {
        let calls = costCallbacks.load()
        let mean = calls > 0 ? Double(costTotalTicks.load()) / Double(calls) : 0
        return (Double(costMaxTicks.load()) * secondsPerTick * 1e6, mean * secondsPerTick * 1e6, calls)
    }

    /// Monotonic counters for the event log's totals (any non-realtime thread).
    var eventCounters: [String: UInt64] {
        let stats = queue.statistics
        var result: [String: UInt64] = [:]
        for key in ["underruns", "trims", "clears", "discardedFrames", "droppedFrames"] {
            result["output.\(key)"] = stats[key] ?? 0
        }
        result["output.deviceCycleGaps"] = cycleGaps.load()
        result["output.deviceGapFrames"] = gapFrames.load()
        result["output.gapFadeIns"] = gapFadeIns.load()
        return result
    }

    var statistics: [String: Any] {
        var result = queue.statistics.mapValues { $0 as Any }
        let rate = Double(bitPattern: outputRateBits.load())
        result["outputRate"] = rate; result["targetFrames"] = targetValue.load()
        result["adaptiveTargetFrames"] = effectiveTarget.load()
        result["deviceBufferFrames"] = deviceFramesValue.load()
        result["driftCorrectionPPM"] = queue.driftCorrectionPPM
        result["deviceCycleGaps"] = cycleGaps.load()
        result["deviceGapFrames"] = gapFrames.load()
        result["gapFadeIns"] = gapFadeIns.load()
        let cost = renderCost
        result["renderCallbacks"] = cost.callbacks
        result["renderCostMaxMicros"] = (cost.maximumMicros * 10).rounded() / 10
        result["renderCostMeanMicros"] = (cost.meanMicros * 10).rounded() / 10
        // The share of one device cycle the callback takes on average.
        let cycleMicros = Double(deviceFramesValue.load()) / max(1, rate) * 1e6
        result["renderCycleLoadPercent"] = cycleMicros > 0 ? (cost.meanMicros / cycleMicros * 1000).rounded() / 10 : 0
        return result
    }
    func discard() { queue.requestClear() }
    /// Host ticks of the mix clock's last block and its size (3.3.3): the
    /// HAL callback counts that block as arriving over its period.
    private let pushTick = AudioAtomicCounter()
    private let pushFrames = AudioAtomicCounter(UInt64(AirPlayMixThread.blockFrames))
    func push(_ input: UnsafePointer<Float>, frames: Int, hostTime: UInt64? = nil) {
        queue.write(frames: frames) { (input[$0 * 2], input[$0 * 2 + 1]) }
        pushFrames.store(UInt64(max(0, frames)))
        pushTick.store(max(1, hostTime ?? mach_absolute_time()))
    }

    /// The level correction for the drift loop, in input frames: minus the
    /// part of the newest block its period has not yet "delivered". The mix
    /// clock writes 480 frames at once every 10 ms; read every 2.67 ms that
    /// sawtooth aliases into a slow beat (about 0.5 Hz at a few hundred ppm
    /// of drift) which the loop's 0.5 s filters pass, so the correction
    /// wobbled by ±20–40 ppm (3.3.3, A01 test). Spread over its period, the
    /// block adds no sawtooth.
    static func levelBias(blockFrames: Double, secondsSinceBlock: Double?) -> Double {
        guard let since = secondsSinceBlock, blockFrames > 0 else { return 0 }
        let period = blockFrames / 48000
        let delivered = min(1, max(0, since / period))
        return -blockFrames * (1 - delivered)
    }
    /// Counts a gap between this cycle's sample time and where the last one
    /// ended; a jump back is a device restart, not a gap. Negative: unknown.
    /// Returns the gap in frames (0: none).
    @discardableResult
    func noteCycle(sampleTime: Double, frames: Int) -> Double {
        guard sampleTime.isFinite, sampleTime >= 0 else { return 0 }
        var gap = 0.0
        if lastSampleTime >= 0 {
            let jump = sampleTime - (lastSampleTime + Double(lastCallbackFrames))
            if jump > 0.5 {
                gap = jump
                cycleGaps.add()
                gapFrames.add(UInt64(min(jump, 1e9).rounded()))
            }
        }
        lastSampleTime = sampleTime
        lastCallbackFrames = frames
        return gap
    }

    /// In place over interleaved stereo: continues the fade-in after a gap.
    private func applyGapFade(_ data: UnsafeMutablePointer<Float>, frames: Int) {
        let length = Float(gapFadeLength)
        var frame = 0
        while frame < frames && gapFadeIndex < gapFadeLength {
            gapFadeIndex += 1
            let x = Float(gapFadeIndex) / length
            let gain = x * x * (3 - 2 * x)
            data[frame * 2] *= gain
            data[frame * 2 + 1] *= gain
            frame += 1
        }
    }

    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>, sampleTime: Double = -1,
                hostTime: UInt64? = nil) {
        let entered = mach_absolute_time()
        let now = hostTime ?? entered
        callbackTick.store(entered)
        let gap = noteCycle(sampleTime: sampleTime, frames: frames)
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames > 0, frames <= 16384, buffers.count == 1,
              buffers[0].mNumberChannels == 2, Int(buffers[0].mDataByteSize) >= frames * 8,
              let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            invalid.store(1); return
        }
        let rate = Double(bitPattern: outputRateBits.load())
        let late = Double(producerLateness.take()) * 48000 / 1e9
        let decay = max(0, 1 - Double(frames) / rate / Self.latenessDecaySeconds)
        latenessFrames = max(late, latenessFrames * decay)
        let target = Self.adaptiveTarget(base: Int(targetValue.load()), latenessFrames: latenessFrames,
                                         deviceFrames: frames, outputRate: rate)
        effectiveTarget.store(UInt64(target))
        let lastPush = pushTick.load()
        let bias = Self.levelBias(blockFrames: Double(pushFrames.load()),
                                  secondsSinceBlock: lastPush == 0 ? nil : Double(now &- min(now, lastPush)) * secondsPerTick)
        let produced = queue.render(into: data, frames: frames, ratio: 48000 / rate, targetFrames: target,
            driftLimit: 0.002, fadeFrames: Int(rate * 0.005), outputRate: rate, levelBias: bias)
        if gap > 0 {
            // The device just played a hole; start again from silence (a
            // second gap during a fade starts it again: the hole was silent).
            gapFadeIndex = 0
            gapFadeLength = max(1, Int(rate * Self.gapFadeSeconds))
            gapFadeIns.add()
            events.push(.cycleGap, value: UInt64(min(gap, 1e9).rounded()), extra: UInt64(max(0, sampleTime)),
                        host: entered)
        }
        if gapFadeIndex < gapFadeLength { applyGapFade(data, frames: frames) }
        if produced > 0 { audioTick.store(mach_absolute_time()) }
        let cost = mach_absolute_time() &- entered
        costMaxTicks.raise(to: cost)
        costTotalTicks.add(cost)
        costCallbacks.add()
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

        /// The priority ceiling is the throttled band (darwin background or a
        /// background QoS clamp). One signal only: a suppressed process keeps
        /// the ceiling at 63, so `AirPlayHostDiagnosis` judges the host (N01).
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

/// Audit N01: what the host lets this process do, read on an ordinary thread
/// (never the mix thread) from independent signals. The priority ceiling
/// alone (`Reading.hostClamped`) catches a darwin-background or QoS-clamped
/// process, whose ceiling drops to 4, but not a suppressed one: the 3.3.1
/// re-audit's default remote environment kept the ceiling at 63 while the
/// threads ran timeshare at priority 4 and woke about 200 ms late
/// (work/reaudit-331-20261028/audio-host-*.log). Under the application
/// policy (`taskpolicy -a`) the same build runs the mix thread realtime.
struct AirPlayHostDiagnosis: Equatable {
    /// An ordinary thread's scheduler reading (nil when the kernel did not answer).
    var ordinaryThread: AirPlayMixScheduling.Reading?
    /// `getpriority(PRIO_DARWIN_PROCESS)`: the process runs darwin background.
    var darwinBackground: Bool
    /// The worst lateness of short timed waits on an ordinary thread, in
    /// nanoseconds; nil when not measured.
    var worstTimerLateness: UInt64?

    /// Why the host keeps this process out of realtime scheduling; empty when
    /// no signal says so.
    var throttleReasons: [String] {
        var reasons: [String] = []
        if darwinBackground { reasons.append("the process runs darwin background (PRIO_DARWIN_BG)") }
        if let thread = ordinaryThread {
            if thread.maximumPriority >= 0 && thread.maximumPriority <= 4 {
                reasons.append("threads may run at most at priority \(thread.maximumPriority) (background clamp)")
            }
            if !thread.realtime && thread.priority >= 0 && thread.priority <= 4 {
                reasons.append("ordinary threads run at priority \(thread.priority) (throttled or suppressed process)")
            }
        }
        if let late = worstTimerLateness, late > AirPlayMixTimeline.lateWakeNanoseconds {
            reasons.append(String(format: "2 ms timed waits wake %.0f ms late (timer coalescing)", Double(late) / 1e6))
        }
        return reasons
    }

    var throttled: Bool { !throttleReasons.isEmpty }

    /// Reads the host from the calling thread, which must be an ordinary
    /// one. `probeTimers` adds ten 2 ms waits (about 20 ms on a healthy
    /// host, longer on a throttled one), so keep it off hot paths.
    static func measure(probeTimers: Bool = true) -> AirPlayHostDiagnosis {
        var worst: UInt64?
        if probeTimers {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let numer = UInt64(max(1, timebase.numer)), denom = UInt64(max(1, timebase.denom))
            var late: UInt64 = 0
            for _ in 0..<10 {
                let target = mach_absolute_time() + 2_000_000 * denom / numer
                mach_wait_until(target)
                let now = mach_absolute_time()
                if now > target { late = max(late, (now - target) * numer / denom) }
            }
            worst = late
        }
        return AirPlayHostDiagnosis(ordinaryThread: AirPlayMixScheduling.current(),
                                    darwinBackground: getpriority(PRIO_DARWIN_PROCESS, 0) == 1,
                                    worstTimerLateness: worst)
    }
}

/// The mix clock's scheduling verdict, kept apart from the host diagnosis so
/// a broken promotion is never mistaken for a throttled host (audit N01): a
/// non-realtime mix thread on a host that allows realtime is a defect.
enum AirPlayMixVerdict: Equatable {
    /// The scheduler runs the mix thread in the realtime band.
    case realtime
    /// The host keeps the whole process out of realtime; the reasons say how.
    case hostThrottled(reasons: [String])
    /// The host allows realtime, yet the mix thread does not get it.
    case promotionFailed(detail: String)

    static func judge(host: AirPlayHostDiagnosis, mix: AirPlayMixScheduling.Reading?,
                      promotionAccepted: Bool) -> AirPlayMixVerdict {
        if let mix, mix.realtime { return .realtime }
        if host.throttled { return .hostThrottled(reasons: host.throttleReasons) }
        let observed = mix.map { "timeshare at priority \($0.priority)" } ?? "unread"
        return .promotionFailed(detail: promotionAccepted
            ? "the realtime promotion was accepted but the scheduler runs the mix thread \(observed)"
            : "the realtime promotion was refused (mix thread \(observed))")
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
            // The bridge sizes its buffer from how late this clock runs (a
            // realign after sleep is not scheduling lateness).
            if wake.late > 0 && !wake.realigned { bridge.noteMixLateness(nanoseconds(wake.late)) }
            let throttled = wake.late > lateWake
            if throttled {
                timeline.lateWakes.add()
                // The mix thread is the bus's only renderer: its ring's producer.
                bus.events.push(.mixLate, value: nanoseconds(wake.late) / 1000)
            }
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

/// Holds a latency-critical process activity while an AirPlay output runs
/// (crackle audit 3.3.2, follow-up). Nothing in AOM asked for one, so App Nap
/// and timer coalescing could demote the mix clock whenever AOM's windows were
/// hidden: the audit measured wake-ups 120–200 ms late. Idempotent; begin and
/// end are called from the output's device queue, never from the mix or HAL
/// thread. The closures are injectable for tests.
final class AirPlayNapGuard {
    typealias Begin = (String) -> NSObjectProtocol
    typealias End = (NSObjectProtocol) -> Void
    /// 3.3.2 review: `.userInitiated` includes idle-sleep prevention
    /// (NSActivityIdleSystemSleepDisabled), redundant while coreaudiod and
    /// AirPlayXPCHelper already hold the Mac awake for the AirPlay IO. The
    /// variant without it keeps App Nap and timer coalescing away.
    static let options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
    private let reason: String
    private let begin: Begin
    private let end: End
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init(reason: String,
         begin: @escaping Begin = { ProcessInfo.processInfo.beginActivity(options: AirPlayNapGuard.options, reason: $0) },
         end: @escaping End = { ProcessInfo.processInfo.endActivity($0) }) {
        self.reason = reason
        self.begin = begin
        self.end = end
    }
    deinit { release() }

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return token != nil }

    func acquire() {
        lock.lock(); defer { lock.unlock() }
        guard token == nil else { return }
        token = begin(reason)
    }

    func release() {
        lock.lock()
        let held = token
        token = nil
        lock.unlock()
        if let held { end(held) }
    }
}
