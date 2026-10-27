import Foundation
import Darwin

/// Priority-donating lock for realtime render paths. A waiting audio thread
/// boosts the owner instead of inverting priority like a plain mutex.
final class AudioUnfairLock {
    private let storage: UnsafeMutablePointer<os_unfair_lock_s>
    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock_s())
    }
    deinit { storage.deinitialize(count: 1); storage.deallocate() }
    func lock() { os_unfair_lock_lock(storage) }
    func unlock() { os_unfair_lock_unlock(storage) }
    func tryLock() -> Bool { os_unfair_lock_trylock(storage) }
}

/// Magic Boost, modelled on the behaviour of SoundSource 6's output and
/// per-app Magic Boost (Rogue Amoeba AudioHijackKit `AHCompressorNode`,
/// preset "Music": push 1, speed 0, makeup 1). The constants were recovered
/// by reverse engineering the installed 6.0.6 framework (REA/Ghidra, see
/// docs/audio-3.1.0-soundsource-boost.md); this is AOM's own implementation
/// of that behaviour, not Rogue Amoeba code.
///
/// It "listens ahead" 512 frames: the detector runs on incoming audio while
/// the output is the delayed signal, so gain falls before a loud passage is
/// heard instead of clipping its leading edge. Quiet passages are raised by
/// an accelerating release (up to +40 dB); a peak above 0.9 pulls the gain
/// down by 1.5 % per sample and resets the release acceleration. Enabling or
/// disabling crossfades dry and processed audio over 40 ms.
final class AudioMagicBoost {
    static let lookaheadFrames = 512
    static let threshold: Float = 0.9
    static let attackRate: Float = 0.015
    static let releaseRate: Float = 5e-7
    static let maximumGain: Float = 100
    static let kneeStep: Float = 0.1
    static let kneeCeiling: Float = 200
    static let kneeAttackDrop: Float = 5
    static let makeup: Float = 1
    /// SoundSource's output is a parallel blend: (dry + (gain - 0.15) * dry) / 2.
    static func outputGain(_ gain: Float) -> Float { makeup * (gain + 0.85) * 0.5 }

    private let rateScale: Float
    private let fadeStep: Float
    private let delay: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var filled = 0
    private(set) var gain: Float = 1
    private var knee: Float = 1
    private(set) var mix: Float = 0

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        rateScale = Float(44100 / rate)
        fadeStep = Float(1 / (0.04 * rate))
        delay = .allocate(capacity: Self.lookaheadFrames * 2)
        delay.initialize(repeating: 0, count: Self.lookaheadFrames * 2)
    }
    deinit { delay.deallocate() }

    /// True while processing or crossfading; false means audio passes untouched.
    var isActive: Bool { mix > 0 || filled > 0 }
    var latencyFrames: Int { Self.lookaheadFrames }

    private func reset() {
        memset(delay, 0, Self.lookaheadFrames * 2 * MemoryLayout<Float>.size)
        writeIndex = 0; filled = 0; gain = 1; knee = 1; mix = 0
    }

    /// In place. `left` and `right` may be the same pointer for mono.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                 frames: Int, enabled: Bool) {
        guard frames > 0 else { return }
        if !enabled && mix == 0 {
            if filled > 0 { reset() }
            return
        }
        // SoundSource releases a hundred times slower over digital silence so
        // the gain does not climb during a pause and blast the next sound.
        var silent = true
        for frame in 0..<frames where left[frame] != 0 || right[frame] != 0 { silent = false; break }
        let release = Self.releaseRate * rateScale * (silent ? 0.01 : 1)
        let attack = Self.attackRate * rateScale
        let capacity = Self.lookaheadFrames
        for frame in 0..<frames {
            let inputLeft = left[frame].isFinite ? left[frame] : 0
            let inputRight = right[frame].isFinite ? right[frame] : 0
            let slot = writeIndex * 2
            let delayedLeft = delay[slot], delayedRight = delay[slot + 1]
            delay[slot] = inputLeft; delay[slot + 1] = inputRight
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
            if filled < capacity { filled += 1 }
            // The stereo-linked gain is updated once per channel, as in the
            // reference; an exact zero leaves it unchanged.
            detect(inputLeft, attack: attack, release: release)
            detect(inputRight, attack: attack, release: release)
            if enabled {
                // Only crossfade once the delay line holds real audio.
                if filled >= capacity && mix < 1 { mix = min(1, mix + fadeStep) }
            } else {
                mix = max(0, mix - fadeStep)
            }
            let wet = Self.outputGain(gain)
            left[frame] = inputLeft + (delayedLeft * wet - inputLeft) * mix
            right[frame] = inputRight + (delayedRight * wet - inputRight) * mix
        }
        if !enabled && mix == 0 { reset() }
    }

    @inline(__always)
    private func detect(_ sample: Float, attack: Float, release: Float) {
        guard sample != 0 else { return }
        if abs(sample * gain) > Self.threshold {
            gain = max(0.0001, gain - max(gain, 1) * attack)
            // The reference can push the knee below 1 (a brief negative
            // release); AOM floors it at 1 so release never lowers the gain.
            if knee > 1 { knee = max(1, knee - Self.kneeAttackDrop) }
        } else {
            let next = gain + release * knee
            if next < Self.maximumGain { gain = next }
            if knee < Self.kneeCeiling { knee += Self.kneeStep }
        }
    }
}

/// Transparent lookahead peak limiter in the manner of AudioHijackKit's
/// `peak_limiter` (used by its Volume Overdrive): 64-frame lookahead at
/// 44.1/48 kHz, release to -20 dB in 25 ms. Required gain is minimum-filtered
/// over the lookahead window and smoothed by two moving averages that both
/// lie inside that window, so the smoothed gain reaches the needed reduction
/// before the peak is output: no sample exceeds `ceiling` and no waveform
/// top is flattened.
final class AudioLookaheadLimiter {
    let lookahead: Int
    let ceiling: Float
    private let firstWidth: Int
    private let secondWidth: Int
    private let releaseCoefficient: Float
    private let delay: UnsafeMutablePointer<Float>
    private var delayIndex = 0
    // Monotonic deque (minimum) of required gain over lookahead + 1 frames.
    private let dequeValues: UnsafeMutablePointer<Float>
    private let dequeFrames: UnsafeMutablePointer<Int>
    private let dequeCapacity: Int
    private var dequeHead = 0
    private var dequeCount = 0
    private var frame = 0
    private let first: UnsafeMutablePointer<Float>
    private let second: UnsafeMutablePointer<Float>
    private var firstIndex = 0, secondIndex = 0
    private var firstSum: Double, secondSum: Double
    private var envelope: Float = 1
    private(set) var reduction: Float = 1

    init(sampleRate: Double, ceiling: Float = 0.995) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        var frames = 64
        if rate > 64000 { frames *= 2 }
        if rate > 128000 { frames *= 2 }
        lookahead = frames
        self.ceiling = min(1, max(0.1, ceiling))
        firstWidth = frames / 2 + 1
        secondWidth = frames / 2 + 1
        // 1 - 10^(log10(0.1) / (rate * 0.025)): reaches -20 dB of the
        // remaining distance after 25 ms.
        releaseCoefficient = Float(1 - pow(0.1, 1 / (rate * 0.025)))
        delay = .allocate(capacity: frames * 2)
        delay.initialize(repeating: 0, count: frames * 2)
        dequeCapacity = frames + 2
        dequeValues = .allocate(capacity: dequeCapacity)
        dequeValues.initialize(repeating: 1, count: dequeCapacity)
        dequeFrames = .allocate(capacity: dequeCapacity)
        dequeFrames.initialize(repeating: 0, count: dequeCapacity)
        first = .allocate(capacity: firstWidth)
        first.initialize(repeating: 1, count: firstWidth)
        second = .allocate(capacity: secondWidth)
        second.initialize(repeating: 1, count: secondWidth)
        firstSum = Double(firstWidth)
        secondSum = Double(secondWidth)
    }

    deinit {
        delay.deallocate(); dequeValues.deallocate(); dequeFrames.deallocate()
        first.deallocate(); second.deallocate()
    }

    func reset() {
        memset(delay, 0, lookahead * 2 * MemoryLayout<Float>.size)
        delayIndex = 0; dequeHead = 0; dequeCount = 0; frame = 0
        for i in 0..<firstWidth { first[i] = 1 }
        for i in 0..<secondWidth { second[i] = 1 }
        firstSum = Double(firstWidth); secondSum = Double(secondWidth)
        firstIndex = 0; secondIndex = 0; envelope = 1; reduction = 1
    }

    /// In place; `left` and `right` may alias for mono. Output lags input by `lookahead`.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let window = lookahead + 1
        for index in 0..<frames {
            let inputLeft = left[index].isFinite ? max(-1e6, min(1e6, left[index])) : 0
            let inputRight = right[index].isFinite ? max(-1e6, min(1e6, right[index])) : 0
            let peak = max(abs(inputLeft), abs(inputRight))
            let required = peak > ceiling ? ceiling / peak : 1
            // Push into the monotonic minimum deque; evict entries that are
            // no longer the minimum or have left the window.
            while dequeCount > 0 {
                let tail = (dequeHead + dequeCount - 1) % dequeCapacity
                if dequeValues[tail] >= required { dequeCount -= 1 } else { break }
            }
            let slot = (dequeHead + dequeCount) % dequeCapacity
            dequeValues[slot] = required; dequeFrames[slot] = frame
            dequeCount += 1
            while dequeCount > 0 && dequeFrames[dequeHead] <= frame - window {
                dequeHead = (dequeHead + 1) % dequeCapacity; dequeCount -= 1
            }
            let minimum = dequeValues[dequeHead]
            firstSum += Double(minimum - first[firstIndex])
            first[firstIndex] = minimum
            firstIndex += 1
            if firstIndex == firstWidth {
                firstIndex = 0
                // Rebuild running sums periodically: long sessions cannot drift.
                var sum = 0.0
                for i in 0..<firstWidth { sum += Double(first[i]) }
                firstSum = sum
            }
            let firstAverage = Float(firstSum / Double(firstWidth))
            secondSum += Double(firstAverage - second[secondIndex])
            second[secondIndex] = firstAverage
            secondIndex += 1
            if secondIndex == secondWidth {
                secondIndex = 0
                var sum = 0.0
                for i in 0..<secondWidth { sum += Double(second[i]) }
                secondSum = sum
            }
            let smoothed = min(1, Float(secondSum / Double(secondWidth)))
            // Attack follows the smoothed curve exactly; release rises
            // exponentially and never exceeds it.
            if smoothed < envelope { envelope = smoothed }
            else { envelope = min(smoothed, envelope + (smoothed - envelope) * releaseCoefficient) }
            reduction = envelope
            let delaySlot = delayIndex * 2
            let outputLeft = delay[delaySlot] * envelope
            let outputRight = delay[delaySlot + 1] * envelope
            delay[delaySlot] = inputLeft; delay[delaySlot + 1] = inputRight
            delayIndex += 1
            if delayIndex == lookahead { delayIndex = 0 }
            left[index] = max(-ceiling, min(ceiling, outputLeft))
            right[index] = max(-ceiling, min(ceiling, outputRight))
            frame += 1
            if frame == Int.max / 2 {
                // Re-base frame stamps rather than overflow after years of audio.
                for i in 0..<dequeCount {
                    let s = (dequeHead + i) % dequeCapacity
                    dequeFrames[s] -= frame - window
                }
                frame = window
            }
        }
    }
}

/// Per-app Volume Overdrive (SoundSource: up to 400 %). Up to unity the
/// signal passes untouched; above unity the multiplier feeds the lookahead
/// limiter. Engaging or releasing the limiter crossfades for 20 ms, the
/// reference's transition, so its lookahead delay never produces a jump.
final class AudioVolumeOverdrive {
    static let maximum: Float = 4
    static func clamp(_ value: Float) -> Float { value.isFinite ? min(maximum, max(1, value)) : 1 }

    private let limiter: AudioLookaheadLimiter
    private let fadeStep: Float
    private let rampStep: Float
    private var current: Float = 1
    private var engagement: Float = 0
    private let dryLeft: UnsafeMutablePointer<Float>
    private let dryRight: UnsafeMutablePointer<Float>
    private let chunk: Int

    init(sampleRate: Double, chunk: Int = 512) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        limiter = AudioLookaheadLimiter(sampleRate: rate, ceiling: 0.995)
        fadeStep = Float(1 / (0.02 * rate))
        rampStep = Float(1 / (0.005 * rate))
        self.chunk = chunk
        dryLeft = .allocate(capacity: chunk); dryLeft.initialize(repeating: 0, count: chunk)
        dryRight = .allocate(capacity: chunk); dryRight.initialize(repeating: 0, count: chunk)
    }
    deinit { dryLeft.deallocate(); dryRight.deallocate() }

    var isActive: Bool { engagement > 0 || current != 1 }

    /// In place, at most `chunk` frames.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                 frames: Int, multiplier: Float) {
        let target = Self.clamp(multiplier)
        let engaged = target > 1.0001
        guard frames > 0, frames <= chunk else { return }
        if !engaged && engagement == 0 && current == 1 { return }
        memcpy(dryLeft, left, frames * 4); memcpy(dryRight, right, frames * 4)
        for frame in 0..<frames {
            // A 5 ms linear ramp of the multiplier itself.
            if current < target { current = min(target, current + (target - 1) * rampStep + 1e-6) }
            else if current > target { current = max(target, current - (current - 1) * rampStep - 1e-6) }
            left[frame] *= current; right[frame] *= current
        }
        limiter.process(left: left, right: right, frames: frames)
        if engaged && engagement >= 1 { return }
        for frame in 0..<frames {
            engagement = engaged ? min(1, engagement + fadeStep) : max(0, engagement - fadeStep)
            left[frame] = dryLeft[frame] + (left[frame] - dryLeft[frame]) * engagement
            right[frame] = dryRight[frame] + (right[frame] - dryRight[frame]) * engagement
        }
        if !engaged && engagement == 0 { current = 1; limiter.reset() }
    }
}
