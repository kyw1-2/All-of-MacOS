import AVFoundation
import CoreAudio
import Darwin
import Accelerate

/// Bounded stereo bridge between the tap clock and the playback clock. Both
/// audio callbacks use try-lock only; neither can wait on the UI or the other
/// callback. Storage and render scratch are allocated before audio starts.
final class AppAudioTransport {
    private let lock = NSLock()
    // A route handoff can briefly register this source on two output buses.
    // Serialize the complete DSP render (including scratch / EQ state).
    private let renderLock = NSLock()
    private let capacity = 32768
    private let samples: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var fractionalPosition: Double = 0
    private var buffered = false
    private var capturedFrames: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var inputPeak: Float = 0
    private var targetFrames: Int
    private var bufferedForAirPlay: Bool
    private var sampleRate: Double
    private var lastCaptureTime: TimeInterval = 0
    private let secondsPerTick: Double

    init(sampleRate: Double, bufferedForAirPlay: Bool = false) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        self.sampleRate = sampleRate
        self.bufferedForAirPlay = bufferedForAirPlay
        targetFrames = max(256, min(bufferedForAirPlay ? 16384 : 4096, Int(sampleRate * (bufferedForAirPlay ? 0.08 : 0.025))))
        samples = .allocate(capacity: capacity * 2)
        scratch = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
        scratch.initialize(repeating: 0, count: capacity * 2)
    }
    deinit { samples.deallocate(); scratch.deallocate() }

    func updateSampleRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard rate != sampleRate else { return }
        sampleRate = rate
        targetFrames = max(256, min(bufferedForAirPlay ? capacity / 2 : 4096, Int(rate * (bufferedForAirPlay ? 0.08 : 0.025))))
        readIndex = 0; writeIndex = 0; count = 0
        fractionalPosition = 0; buffered = false
    }

    func setBufferedForAirPlay(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled != bufferedForAirPlay else { return }
        bufferedForAirPlay = enabled
        targetFrames = max(256, min(enabled ? capacity / 2 : 4096, Int(sampleRate * (enabled ? 0.08 : 0.025))))
        readIndex = writeIndex; count = 0; fractionalPosition = 0; buffered = false
    }

    var activity: (captured: UInt64, rendered: UInt64, peak: Float, recent: Bool) {
        lock.lock(); defer { lock.unlock() }
        let recentWindow = bufferedForAirPlay ? max(1, Double(targetFrames) / sampleRate * 4) : 0.25
        return (capturedFrames, renderedFrames, inputPeak,
                Double(mach_absolute_time()) * secondsPerTick - lastCaptureTime < recentWindow)
    }

    func capture(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0,
              let left = first.mData?.assumingMemoryBound(to: Float.self), lock.try() else { return }
        defer { lock.unlock() }
        let planar = first.mNumberChannels == 1 && buffers.count >= 2
        let channels = Int(first.mNumberChannels)
        var frames = Int(first.mDataByteSize) / (4 * channels)
        var right = left
        if planar {
            guard let data = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            right = data
            frames = min(frames, Int(buffers[1].mDataByteSize) / 4)
        }
        if bufferedForAirPlay {
            targetFrames = min(capacity / 2, max(targetFrames, frames * 2))
        }
        let now = Double(mach_absolute_time()) * secondsPerTick
        // AirPlay can deliver packets longer than the local 250 ms gap
        // threshold. Do not reset every packet before its queue can prime.
        let gapLimit = bufferedForAirPlay ? max(1, Double(frames) / sampleRate * 4) : 0.25
        if now - lastCaptureTime > gapLimit {
            readIndex = 0; writeIndex = 0; count = 0
            fractionalPosition = 0; buffered = false
        }
        lastCaptureTime = now
        // Bound latency after a stalled consumer rather than replaying an old
        // half-second of audio when a device recovers.
        if count + frames > max(targetFrames * 4, frames * 2) {
            readIndex = writeIndex; count = 0; fractionalPosition = 0; buffered = false
        }
        var peak: Float = 0
        for frame in 0..<frames {
            if count == capacity {
                readIndex = (readIndex + 1) % capacity
                count -= 1
            }
            let l = left[planar ? frame : frame * channels]
            let r = planar ? right[frame] : left[frame * channels + min(1, channels - 1)]
            samples[writeIndex * 2] = l.isFinite ? l : 0
            samples[writeIndex * 2 + 1] = r.isFinite ? r : 0
            peak = max(peak, max(abs(samples[writeIndex * 2]), abs(samples[writeIndex * 2 + 1])))
            writeIndex = (writeIndex + 1) % capacity
            count += 1
        }
        capturedFrames &+= UInt64(frames)
        inputPeak = peak
    }

    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>, mixer: MixerBox) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                vDSP_vclr(data, 1, vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride))
            }
        }
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }
        guard frames > 0, frames <= capacity, lock.try() else { mixer.publishPeak(0); return }
        if !buffered {
            guard count >= targetFrames else { lock.unlock(); mixer.publishPeak(0); return }
            buffered = true
        }
        // Convert the tap's nominal rate to the stable 48 kHz render bus,
        // then apply a small drift correction for independent device clocks.
        let correction = max(-0.002, min(0.002, Double(count - targetFrames) / Double(targetFrames) * 0.001))
        let step = sampleRate / SharedOutputRenderer.sampleRate * (1 + correction)
        var filled = 0
        while filled < frames && count > max(1, Int(fractionalPosition + step)) {
            let next = (readIndex + 1) % capacity
            let fraction = Float(fractionalPosition)
            for channel in 0..<2 {
                let a = samples[readIndex * 2 + channel], b = samples[next * 2 + channel]
                scratch[filled * 2 + channel] = a + (b - a) * fraction
            }
            fractionalPosition += step
            let advance = min(count, Int(fractionalPosition))
            readIndex = (readIndex + advance) % capacity
            count -= advance
            fractionalPosition -= Double(advance)
            filled += 1
        }
        if filled < frames {
            vDSP_vclr(scratch + filled * 2, 1, vDSP_Length((frames - filled) * 2))
            buffered = false
            fractionalPosition = 0
        }
        renderedFrames &+= UInt64(filled)
        lock.unlock()
        var input = AudioBufferList(mNumberBuffers: 1,
                                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: scratch))
        withUnsafePointer(to: &input) { Mixer.mix(input: $0, output: output, box: mixer) }
    }
}
