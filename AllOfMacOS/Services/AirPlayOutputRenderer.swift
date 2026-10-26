import Foundation
import AudioToolbox
import CoreAudio
import Darwin

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
    // Serial lifecycle ordering also prevents a manual reconnect from creating
    // a replacement HAL unit before the old unit has finished disposing.
    private static let workQueue = DispatchQueue(label: "com.kyw.aom.airplay.mix", qos: .userInteractive)
    private let queue = AirPlayOutputRenderer.workQueue
    private let stateLock = NSLock()
    private var phase: State = .preparing
    private let bridge = AirPlayPCMBridge()
    // Everything below is confined to queue; callback only touches bridge.
    private var unit: AudioUnit?
    private var timer: DispatchSourceTimer?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var startedAt: TimeInterval = 0
    private var configuredRate: Double = 0
    private var configuredFrames: UInt32 = 0
    private var configuredChannels: UInt32 = 0
    private var nextMixTime: UInt64 = 0
    private var stopped = false
    private var failureDelivered = false
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 480 * 2)
    private let changed: () -> Void

    init(deviceID: AudioDeviceID, changed: @escaping () -> Void) {
        self.deviceID = deviceID
        self.changed = changed
        scratch.initialize(repeating: 0, count: 960)
        queue.async { [self] in start() }
    }

    deinit { scratch.deallocate() }

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
        nextMixTime = DispatchTime.now().uptimeNanoseconds
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
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

    private func tick() {
        guard !stopped, !failureDelivered else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // A delayed dispatch timer never renders an unbounded backlog after
        // sleep or contention. Drop stale PCM and resume with a fade instead.
        if now > nextMixTime && now - nextMixTime > 100_000_000 {
            bridge.discard()
            nextMixTime = now
        }
        var blocks = 0
        while nextMixTime <= now && blocks < 4 {
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers:
                AudioBuffer(mNumberChannels: 2, mDataByteSize: 3840, mData: scratch))
            withUnsafeMutablePointer(to: &buffers) { bus.render(frames: 480, output: $0) }
            bridge.push(scratch, frames: 480)
            nextMixTime += 10_000_000
            blocks += 1
        }
        let health = bridge.health
        let uptime = ProcessInfo.processInfo.systemUptime
        if health.invalidFormat {
            fail("AirPlay supplied an unsupported render buffer. Native playback restored.")
        } else if health.lastCallback > 0 && uptime - health.lastCallback > 3 {
            fail("AirPlay output stopped requesting audio. Native playback restored; use Reconnect to retry.")
        } else if health.lastCallback == 0 && uptime - startedAt > 15 {
            fail("AirPlay output did not start. Native playback restored; use Reconnect to retry.")
        } else if health.lastAudio > 0 && uptime - health.lastAudio > 3 {
            fail("AirPlay audio buffer could not recover. Native playback restored; use Reconnect to retry.")
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
    private let lock = NSLock()
    private let capacity = 96000
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: 192000)
    private var read = 0
    private var write = 0
    private var count = 0
    private var fraction: Double = 0
    private var step: Double = 1
    private var target = 7200 // 150 ms, independent of HomePod's own latency
    private var primed = false
    private var fade: Float = 0
    private var lastCallback: TimeInterval = 0
    private var lastAudio: TimeInterval = 0
    private var invalidFormat = false
    private var outputRate: Double = 48000
    private var correction: Double = 0
    private let secondsPerTick: Double

    init() {
        samples.initialize(repeating: 0, count: 192000)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    deinit { samples.deallocate() }

    // Setup only, before starting the HAL callback or producer.
    func configure(outputRate: Double, deviceFrames: Int) {
        self.outputRate = outputRate
        step = 48000 / outputRate
        target = min(capacity / 2, max(7200, Int(ceil(Double(deviceFrames) * step)) * 3))
    }
    func prime() { count = target; write = target; primed = true }

    var health: (lastCallback: TimeInterval, lastAudio: TimeInterval, invalidFormat: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (lastCallback, lastAudio, invalidFormat)
    }
    func discard() {
        lock.lock(); defer { lock.unlock() }
        read = write; count = 0; fraction = 0; primed = false; fade = 0; correction = 0
    }
    func push(_ input: UnsafePointer<Float>, frames: Int) {
        // The producer is a dedicated worker, not a HAL callback. Waiting for
        // the bounded consumer avoids silently dropping whole mix blocks.
        lock.lock()
        defer { lock.unlock() }
        if count + frames > min(capacity - 1, target * 3) {
            // A stalled receiver must not replay stale buffered audio.
            read = write; count = 0; fraction = 0; primed = false; fade = 0
        }
        let first = min(frames, capacity - write)
        memcpy(samples + write * 2, input, first * 8)
        if first < frames { memcpy(samples, input + first * 2, (frames - first) * 8) }
        write = (write + frames) % capacity
        count += frames
    }
    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames > 0, lock.try() else { return }
        defer { lock.unlock() }
        let now = Double(mach_absolute_time()) * secondsPerTick
        lastCallback = now
        guard frames > 0, frames <= 16384, buffers.count == 1,
              buffers[0].mNumberChannels == 2, Int(buffers[0].mDataByteSize) >= frames * 8,
              let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            invalidFormat = true; return
        }
        if !primed {
            guard count >= target else { return }
            primed = true
        }
        // Slow bounded clock correction, not an abrupt rate reset on every UI
        // change. Interpolation also handles 44.1 / 48 kHz hardware differences.
        let desired = max(-0.005, min(0.005, Double(count - target) / Double(target) * 0.001))
        correction += (desired - correction) * 0.02
        let increment = step * (1 + correction)
        var produced = 0
        while produced < frames && count > max(1, Int(fraction + increment)) {
            let next = (read + 1) % capacity
            fade = min(1, fade + Float(1 / (outputRate * 0.02)))
            for channel in 0..<2 {
                let a = samples[read * 2 + channel], b = samples[next * 2 + channel]
                data[produced * 2 + channel] = (a + (b - a) * Float(fraction)) * fade
            }
            fraction += increment
            let advance = Int(fraction)
            read = (read + advance) % capacity
            count -= advance; fraction -= Double(advance)
            produced += 1
        }
        if produced > 0 { lastAudio = now }
        if produced < frames { primed = false; fraction = 0; fade = 0 }
    }
}
