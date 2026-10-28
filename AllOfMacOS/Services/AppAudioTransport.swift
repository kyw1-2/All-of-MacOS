import AVFoundation
import CoreAudio
import Darwin
import Accelerate

/// Separate tap and output clocks connected by a single-producer/consumer
/// queue. Capture and sample transport never acquire a mutex. DSP rendering is
/// serialized only for the brief interval when two output routes overlap.
final class AppAudioTransport {
    private let renderLock = AudioUnfairLock()
    /// 65 536 frames (1.4 s at 48 kHz): room for the AirPlay trim floor below
    /// (until 3.3.2 32 768, half of it).
    private let capacity = 65536
    private let queue = StereoPCMQueue(capacity: 65536)
    private let scratch: UnsafeMutablePointer<Float>
    private let rateBits: AudioAtomicCounter
    private let remote: AudioAtomicCounter
    private let largestPacket = AudioAtomicCounter()
    private let peakBits = AudioAtomicCounter()
    private let captureTick = AudioAtomicCounter()
    private let renderTick = AudioAtomicCounter()
    private let renderContentions = AudioAtomicCounter()
    private let secondsPerTick: Double
    /// Render-thread only: frames of silence still to run through the app's
    /// DSP after its audio stopped (see `render`).
    private var flushRemaining = 0
    /// Longer than the app chain's delay lines: Magic Boost looks 512 frames
    /// ahead and Volume Overdrive's limiter 64, and an EQ rings down.
    static let flushFrames = 2048

    init(sampleRate: Double, bufferedForAirPlay: Bool = false) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let rate = sampleRate.isFinite && (8000...384000).contains(sampleRate) ? sampleRate : 48000
        rateBits = AudioAtomicCounter(rate.bitPattern)
        remote = AudioAtomicCounter(bufferedForAirPlay ? 1 : 0)
        scratch = .allocate(capacity: capacity * 2)
        scratch.initialize(repeating: 0, count: capacity * 2)
    }
    deinit { scratch.deallocate() }

    func updateSampleRate(_ rate: Double) {
        guard rate.isFinite, (8000...384000).contains(rate), rate.bitPattern != rateBits.load() else { return }
        rateBits.store(rate.bitPattern)
        queue.requestClear()
    }
    func setBufferedForAirPlay(_ enabled: Bool) {
        let value: UInt64 = enabled ? 1 : 0
        guard value != remote.load() else { return }
        remote.store(value)
        queue.requestClear()
    }
    /// The level the queue steers to.
    ///
    /// AirPlay: 80 ms, or two capture packets and a margin when the tap
    /// delivers larger ones. 3.3.2 had cut it to 40 ms to shorten the gap
    /// before a newly tapped app is heard; with the 1024-frame capture
    /// packets AirPlay routes now use, that left about 27 ms of tolerance for
    /// capture jitter, and every underrun is a fade to silence and back
    /// (HomePod crackle audit, follow-up). 3.3.1 ran 80 ms with no underrun
    /// in 5.5 hours of HomePod playback; AirPlay itself adds about 2 s.
    static func targetFrames(rate: Double, airPlay: Bool, largestPacket: Int, capacity: Int) -> Int {
        if airPlay {
            return min(capacity / 4, max(Int(rate * 0.08), largestPacket * 2 + 512))
        }
        return max(256, min(4096, Int(rate * 0.025)))
    }

    /// Where an AirPlay stream starts: at its target (3.3.2 review). It used
    /// to start at 40 ms so a newly tapped app was heard sooner, and the
    /// ±0.2 % drift loop then needed about 20 s to grow it to 80 ms; every
    /// resume after a pause started again at the margin the follow-up audit
    /// found too thin. Local outputs start at their target too (nil).
    static func startFrames(rate: Double, airPlay: Bool, largestPacket: Int, capacity: Int) -> Int? {
        guard airPlay else { return nil }
        return targetFrames(rate: rate, airPlay: true, largestPacket: largestPacket, capacity: capacity)
    }

    /// The backlog an AirPlay queue skips: half a second. The AirPlay mix
    /// clock renders in bursts after a late wake-up, and before a burst the
    /// level is the target plus the lateness, which is not a backlog; with
    /// the floor at three targets a wake-up 110 ms late made the queue skip
    /// the burst's audio and then run dry in it. The drift controller and the
    /// capture-gap clear handle everything slower. Local outputs keep three
    /// targets (their consumer is the device clock itself).
    static func trimFloorFrames(rate: Double, airPlay: Bool) -> Int {
        airPlay ? Int(rate * 0.5) : 0
    }

    private var targetFrames: Int {
        Self.targetFrames(rate: Double(bitPattern: rateBits.load()), airPlay: remote.load() == 1,
                          largestPacket: Int(largestPacket.load()), capacity: capacity)
    }
    var activity: (captured: UInt64, rendered: UInt64, peak: Float, recent: Bool, rendering: Bool) {
        let stats = queue.statistics
        let rate = Double(bitPattern: rateBits.load())
        let recentWindow = remote.load() == 1 ? max(1, Double(targetFrames) / rate * 4) : 0.25
        let now = Double(mach_absolute_time()) * secondsPerTick
        let capture = captureTick.load(), render = renderTick.load()
        return (stats["capturedFrames"] ?? 0, stats["renderedFrames"] ?? 0,
                Float(bitPattern: UInt32(truncatingIfNeeded: peakBits.load())),
                capture > 0 && now - Double(capture) * secondsPerTick < recentWindow,
                render > 0 && now - Double(render) * secondsPerTick < recentWindow)
    }
    var statistics: [String: Any] {
        var result = queue.statistics.mapValues { $0 as Any }
        result["sampleRate"] = Double(bitPattern: rateBits.load())
        result["targetFrames"] = targetFrames
        result["startFrames"] = Self.startFrames(rate: Double(bitPattern: rateBits.load()), airPlay: remote.load() == 1,
                                                 largestPacket: Int(largestPacket.load()), capacity: capacity) ?? targetFrames
        result["largestPacketFrames"] = largestPacket.load()
        result["renderContentions"] = renderContentions.load()
        result["driftCorrectionPPM"] = queue.driftCorrectionPPM
        return result
    }
    func capture(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0,
              let left = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let planar = first.mNumberChannels == 1 && buffers.count >= 2
        let channels = Int(first.mNumberChannels)
        var frames = Int(first.mDataByteSize) / (4 * channels)
        var right = left
        if planar {
            guard let data = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            right = data; frames = min(frames, Int(buffers[1].mDataByteSize) / 4)
        }
        // HAL may invoke a tap with zero frames during a media transition.
        // This is not capture activity: counting it would arm the output-stall
        // watchdog while the player is paused or replacing its audio stream.
        guard frames > 0 else { return }
        let rate = Double(bitPattern: rateBits.load())
        let gapLimit = remote.load() == 1 ? max(1, Double(frames) / rate * 4) : 0.25
        let now = mach_absolute_time(), previous = captureTick.load()
        if previous > 0 && Double(now - previous) * secondsPerTick > gapLimit { queue.requestClear() }
        largestPacket.raise(to: UInt64(frames))
        var peak: Float = 0
        queue.write(frames: frames) { frame in
            let l = left[planar ? frame : frame * channels]
            let r = planar ? right[frame] : left[frame * channels + min(1, channels - 1)]
            peak = max(peak, max(l.isFinite ? abs(l) : 0, r.isFinite ? abs(r) : 0))
            return (l, r)
        }
        peakBits.store(UInt64(peak.bitPattern)); captureTick.store(now)
    }
    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>, mixer: MixerBox, allowWaiting: Bool = false) {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames > 0, frames <= capacity else { return }
        if allowWaiting { renderLock.lock() }
        else if !renderLock.tryLock() { renderContentions.add(); return }
        defer { renderLock.unlock() }
        let rate = Double(bitPattern: rateBits.load())
        let airPlay = remote.load() == 1
        let filled = queue.render(into: scratch, frames: frames,
                                  ratio: rate / SharedOutputRenderer.sampleRate, targetFrames: targetFrames,
                                  trimFloorFrames: Self.trimFloorFrames(rate: rate, airPlay: airPlay),
                                  startFrames: Self.startFrames(rate: rate, airPlay: airPlay,
                                                                largestPacket: Int(largestPacket.load()), capacity: capacity))
        if filled > 0 {
            renderTick.store(mach_absolute_time())
            flushRemaining = Self.flushFrames
        } else {
            // The queue's fade-out reached the app's DSP, but Magic Boost and
            // Volume Overdrive output it up to 512 frames later. Until 3.3.2
            // the chain stopped with that audio still in their delay lines:
            // the output jumped to silence there, and the stale audio started
            // abruptly when the app played again — two clicks per underrun,
            // clear or pause. The chain now runs on silence until it is empty.
            guard flushRemaining > 0 else { mixer.publishPeak(0); return }
            flushRemaining = max(0, flushRemaining - frames)
        }
        // `queue.render` cleared what it did not fill.
        var input = AudioBufferList(mNumberBuffers: 1, mBuffers:
            AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: scratch))
        withUnsafePointer(to: &input) { Mixer.mix(input: $0, output: output, box: mixer) }
    }
}

/// A stopped app is idle, not broken. Only sustained missing callbacks from
/// a playing producer or a live capture require releasing its muting tap.
struct AudioActivityWatchdog {
    enum Failure: Equatable { case capture, output }
    private var missingCaptureSince: TimeInterval?
    private var missingOutputSince: TimeInterval?

    mutating func failure(playing: Bool, capturing: Bool, rendering: Bool, now: TimeInterval) -> Failure? {
        if playing && !capturing {
            let since = missingCaptureSince ?? now
            missingCaptureSince = since
            if now - since > 5 { return .capture }
        } else { missingCaptureSince = nil }
        // Paused producers can still emit empty/silent callbacks. Never
        // infer a broken output clock unless the producer is playing.
        if playing && capturing && !rendering {
            let since = missingOutputSince ?? now
            missingOutputSince = since
            if now - since > 5 { return .output }
        } else { missingOutputSince = nil }
        return nil
    }
}
