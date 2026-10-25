import AVFoundation
import CoreAudio

/// Bounded stereo bridge between the tap clock and the playback clock. Both
/// audio callbacks use try-lock only; neither can wait on the UI or the other
/// callback. Storage and render scratch are allocated before audio starts.
final class AppAudioTransport {
    private let lock = NSLock()
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
    private let targetFrames: Int

    init(sampleRate: Double) {
        targetFrames = max(256, min(4096, Int(sampleRate * 0.025)))
        samples = .allocate(capacity: capacity * 2)
        scratch = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
        scratch.initialize(repeating: 0, count: capacity * 2)
    }
    deinit { samples.deallocate(); scratch.deallocate() }

    var activity: (captured: UInt64, rendered: UInt64, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        return (capturedFrames, renderedFrames, inputPeak)
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
            peak = max(peak, max(abs(l), abs(r)))
            writeIndex = (writeIndex + 1) % capacity
            count += 1
        }
        capturedFrames &+= UInt64(frames)
        inputPeak = peak
    }

    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>, mixer: MixerBox) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        guard frames > 0, frames <= capacity, lock.try() else { return }
        if !buffered {
            guard count >= targetFrames else { lock.unlock(); return }
            buffered = true
        }
        // Very small interpolation corrections prevent independent clocks from
        // slowly draining/filling the ring. AVAudioEngine handles nominal-rate
        // conversion; this only follows drift around the short target buffer.
        let correction = max(-0.002, min(0.002, Double(count - targetFrames) / Double(targetFrames) * 0.001))
        var filled = 0
        while filled < frames && count > 1 {
            let next = (readIndex + 1) % capacity
            let fraction = Float(fractionalPosition)
            for channel in 0..<2 {
                let a = samples[readIndex * 2 + channel], b = samples[next * 2 + channel]
                scratch[filled * 2 + channel] = a + (b - a) * fraction
            }
            fractionalPosition += 1 + correction
            let advance = min(count, Int(fractionalPosition))
            readIndex = (readIndex + advance) % capacity
            count -= advance
            fractionalPosition -= Double(advance)
            filled += 1
        }
        if filled < frames {
            for index in (filled * 2)..<(frames * 2) { scratch[index] = 0 }
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
