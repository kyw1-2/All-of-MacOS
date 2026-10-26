import AVFoundation
import CoreAudio
import Darwin
import Accelerate

/// Separate tap and output clocks connected by a single-producer/consumer
/// queue. Capture and sample transport never acquire a mutex. DSP rendering is
/// serialized only for the brief interval when two output routes overlap.
final class AppAudioTransport {
    private let renderLock = NSLock()
    private let capacity = 32768
    private let queue = StereoPCMQueue(capacity: 32768)
    private let scratch: UnsafeMutablePointer<Float>
    private let rateBits: AudioAtomicCounter
    private let remote: AudioAtomicCounter
    private let largestPacket = AudioAtomicCounter()
    private let peakBits = AudioAtomicCounter()
    private let captureTick = AudioAtomicCounter()
    private let renderTick = AudioAtomicCounter()
    private let renderContentions = AudioAtomicCounter()
    private let secondsPerTick: Double

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
    private var targetFrames: Int {
        let rate = Double(bitPattern: rateBits.load())
        if remote.load() == 1 {
            return min(capacity / 2, max(Int(rate * 0.08), Int(largestPacket.load()) * 2))
        }
        return max(256, min(4096, Int(rate * 0.025)))
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
        result["largestPacketFrames"] = largestPacket.load()
        result["renderContentions"] = renderContentions.load()
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
        else if !renderLock.try() { renderContentions.add(); return }
        defer { renderLock.unlock() }
        let rate = Double(bitPattern: rateBits.load())
        let filled = queue.render(into: scratch, frames: frames,
                                  ratio: rate / SharedOutputRenderer.sampleRate, targetFrames: targetFrames)
        guard filled > 0 else { mixer.publishPeak(0); return }
        renderTick.store(mach_absolute_time())
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
        if capturing && !rendering {
            let since = missingOutputSince ?? now
            missingOutputSince = since
            if now - since > 5 { return .output }
        } else { missingOutputSince = nil }
        return nil
    }
}
