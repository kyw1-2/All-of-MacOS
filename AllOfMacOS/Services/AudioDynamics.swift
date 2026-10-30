import Foundation
import Darwin
import AudioToolbox

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
/// Named Magic Boost tunings (3.3.3, parity S06: SoundSource offers only a
/// switch; these are AOM's own). "Music" is the reference tuning above,
/// unchanged and the default; the others trade fullness for intelligibility
/// or a smaller dynamic range. Each sets where loud audio is held
/// (`threshold`), how fast quiet audio comes up (`releaseScale` × the
/// reference rate), how far (`maximumGain`), the dry share of the parallel
/// blend and the makeup gain, and for an output also the limiter's release.
struct AudioBoostPreset: Equatable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let threshold: Float
    let releaseScale: Float
    let maximumGain: Float
    let dry: Float
    let makeup: Float
    /// The output limiter's release on a local output, seconds (nil: 25 ms).
    /// A network (AirPlay) output never releases faster than its 150 ms.
    let limiterRelease: Double?

    static let music = AudioBoostPreset(id: "music", name: "Music",
        summary: "Fuller sound; quiet passages lifted, loud ones kept from overdriving (the reference tuning).",
        threshold: 0.9, releaseScale: 1, maximumGain: 100, dry: 0.85, makeup: 1, limiterRelease: nil)
    static let speech = AudioBoostPreset(id: "speech", name: "Speech",
        summary: "Quiet voices come up quickly; room noise is raised less.",
        threshold: 0.85, releaseScale: 3, maximumGain: 20, dry: 0.6, makeup: 1.1, limiterRelease: 0.05)
    static let movie = AudioBoostPreset(id: "movie", name: "Movie",
        summary: "Dialogue lifted, explosions held down.",
        threshold: 0.7, releaseScale: 2, maximumGain: 40, dry: 0.5, makeup: 1.15, limiterRelease: 0.1)
    static let night = AudioBoostPreset(id: "night", name: "Night",
        summary: "A small dynamic range for listening quietly.",
        threshold: 0.45, releaseScale: 4, maximumGain: 60, dry: 0.25, makeup: 1.2, limiterRelease: 0.2)
    static let all: [AudioBoostPreset] = [music, speech, movie, night]
    static let defaultID = music.id

    static func index(of id: String?) -> Int { all.firstIndex { $0.id == id } ?? 0 }
    static func preset(id: String?) -> AudioBoostPreset { all[index(of: id)] }

    /// Settings: the output's preset, and each app's (absent: Music).
    static let masterKey = "AOMAudioMasterBoostPreset"
    static func appKey(_ bundleID: String) -> String { "AOMAudioMagicBoostPreset_\(bundleID)" }
    static func storedID(bundleID: String?, defaults: UserDefaults = .standard) -> String {
        let key = bundleID.map(appKey) ?? masterKey
        return preset(id: defaults.string(forKey: key)).id
    }
    static func store(_ id: String, bundleID: String?, defaults: UserDefaults = .standard) {
        let key = bundleID.map(appKey) ?? masterKey
        let preset = preset(id: id)
        if preset.id == defaultID { defaults.removeObject(forKey: key) } else { defaults.set(preset.id, forKey: key) }
    }
}

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
    /// 3.3.4 (N334): a block whose peak stays under this (−60 dBFS) releases
    /// like digital silence (a hundredth of the rate), so noise is not lifted.
    static let nearSilence: Float = 0.001
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
    /// 3.3.3 (S06): the preset the control thread wants (an index into
    /// `AudioBoostPreset.all`) and, render thread only, the one in use, read
    /// from a table made at init (no array or allocation on the render path).
    private let presetSlot = AudioAtomicCounter(0)
    private var appliedPreset = 0
    private let presetCount: Int
    private let table: UnsafeMutablePointer<Float>
    private static let fields = 5
    private var threshold = AudioMagicBoost.threshold
    private var releaseRate = AudioMagicBoost.releaseRate
    private var maximumGain = AudioMagicBoost.maximumGain
    /// The blend's dry share and makeup glide to a new preset's (about 20 ms)
    /// so switching never steps the level.
    private var dry: Float = 0.85, dryTarget: Float = 0.85
    private var makeupGain: Float = AudioMagicBoost.makeup, makeupTarget: Float = AudioMagicBoost.makeup
    private let glide: Float

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        rateScale = Float(44100 / rate)
        fadeStep = Float(1 / (0.04 * rate))
        glide = Float(1 / (0.02 * rate))
        delay = .allocate(capacity: Self.lookaheadFrames * 2)
        delay.initialize(repeating: 0, count: Self.lookaheadFrames * 2)
        let presets = AudioBoostPreset.all
        presetCount = presets.count
        table = .allocate(capacity: presets.count * Self.fields)
        for (index, preset) in presets.enumerated() {
            let row = table + index * Self.fields
            row[0] = preset.threshold; row[1] = preset.releaseScale; row[2] = preset.maximumGain
            row[3] = preset.dry; row[4] = preset.makeup
        }
    }
    deinit { delay.deallocate(); table.deallocate() }

    /// Control thread: the tuning to use from the next block on.
    func setPreset(index: Int) {
        presetSlot.store(UInt64(min(max(0, index), AudioBoostPreset.all.count - 1)))
    }
    var presetIndex: Int { Int(presetSlot.load()) }

    /// Render thread: takes up a new preset (five loads from the table).
    @inline(__always)
    private func adoptPreset() {
        let wanted = Int(presetSlot.load())
        guard wanted != appliedPreset, wanted >= 0, wanted < presetCount else { return }
        appliedPreset = wanted
        let row = table + wanted * Self.fields
        threshold = row[0]
        releaseRate = Self.releaseRate * row[1]
        maximumGain = row[2]
        dryTarget = row[3]
        makeupTarget = row[4]
        if gain > maximumGain { gain = maximumGain }
    }

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
        // 3.3.4 (N334): so does AOM over near-silence, a block whose peak
        // stays under −60 dBFS (`nearSilence`). Codec or room noise in a quiet
        // passage is not digital zero, and the full release lifted it about
        // +34 dB in 11 s: a hiss rising for ten seconds. Every block at or
        // above −60 dBFS, and exact zeros, behave as before.
        adoptPreset()
        var silent = true
        for frame in 0..<frames where !(abs(left[frame]) < Self.nearSilence && abs(right[frame]) < Self.nearSilence) {
            silent = false; break
        }
        let release = releaseRate * rateScale * (silent ? 0.01 : 1)
        let attack = Self.attackRate * rateScale
        let capacity = Self.lookaheadFrames
        let gliding = dry != dryTarget || makeupGain != makeupTarget
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
            if gliding {
                dry += max(-glide, min(glide, dryTarget - dry))
                makeupGain += max(-glide, min(glide, makeupTarget - makeupGain))
            }
            // The reference blend, makeup × (gain + dry) / 2 (Music: dry 0.85).
            let wet = makeupGain * (gain + dry) * 0.5
            left[frame] = inputLeft + (delayedLeft * wet - inputLeft) * mix
            right[frame] = inputRight + (delayedRight * wet - inputRight) * mix
        }
        if !enabled && mix == 0 { reset() }
    }

    @inline(__always)
    private func detect(_ sample: Float, attack: Float, release: Float) {
        guard sample != 0 else { return }
        if abs(sample * gain) > threshold {
            gain = max(0.0001, gain - max(gain, 1) * attack)
            // The reference can push the knee below 1 (a brief negative
            // release); AOM floors it at 1 so release never lowers the gain.
            if knee > 1 { knee = max(1, knee - Self.kneeAttackDrop) }
        } else {
            let next = gain + release * knee
            if next < maximumGain { gain = next }
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
    /// Set at init; `setRelease` swaps it in place (render thread, no
    /// allocation) so the delay line and gain state carry on.
    private var releaseCoefficient: Float
    /// The per-sample release step for a release time: reaches −20 dB of the
    /// remaining distance after `seconds` (clamped to 5 ms…2 s).
    static func releaseCoefficient(sampleRate: Double, seconds: Double) -> Float {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        let release = seconds.isFinite ? min(2, max(0.005, seconds)) : 0.025
        return Float(1 - pow(0.1, 1 / (rate * release)))
    }
    /// Changes the release without touching the delay line or the envelope
    /// (3.3.2 review: Volume Overdrive used to switch to a second limiter
    /// when an app moved to or from AirPlay, with whatever that one's delay
    /// line last held). Precompute the coefficient off the render thread.
    func setReleaseCoefficient(_ coefficient: Float) {
        guard coefficient.isFinite, coefficient > 0, coefficient <= 1 else { return }
        releaseCoefficient = coefficient
    }
    /// Network outputs detect inter-sample (true) peaks; the delay line is
    /// then longer by the detector's latency so the lookahead is unchanged.
    let truePeak: Bool
    private let detector: AudioTruePeakDetector?
    private let detectionCeiling: Float
    private let delayLength: Int
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
    /// The deepest gain since the last `takeDeepestReduction` (render thread).
    private var deepest: Float = 1
    /// 3.3.4 (N334): the largest detected input peak (true peak in true-peak
    /// mode) since the last `takeLargestPeak`, for the event log.
    private var largestPeak: Float = 0

    /// The lowest gain applied since the last call, then starts again (1:
    /// the limiter did nothing). Render thread; for the event log (3.3.3).
    func takeDeepestReduction() -> Float {
        let value = deepest
        deepest = 1
        return value
    }

    /// The largest input peak the detector saw since the last call (linear;
    /// 0 for silence), then starts again. Render thread; for the event log.
    func takeLargestPeak() -> Float {
        let value = largestPeak
        largestPeak = 0
        return value
    }

    /// Where reduction starts: the ceiling, less the true-peak margin.
    var detectionThreshold: Float { detectionCeiling }

    /// Total delay from input to output, frames.
    var latencyFrames: Int { delayLength }

    /// `releaseSeconds`: the time to recover to −20 dB of the remaining
    /// reduction (25 ms, the reference's). The network bus uses a slower one:
    /// a release that short follows the cycles of a bass note on loud masters
    /// and modulates them, which is heard as grit.
    init(sampleRate: Double, ceiling: Float = 0.995, truePeak: Bool = false, releaseSeconds: Double = 0.025) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        var frames = 64
        if rate > 64000 { frames *= 2 }
        if rate > 128000 { frames *= 2 }
        lookahead = frames
        self.ceiling = min(1, max(0.1, ceiling))
        self.truePeak = truePeak
        detector = truePeak ? AudioTruePeakDetector() : nil
        // The 4× estimate reads low on broadband transients near Nyquist
        // (measured up to 0.15 dB on hard-switched 19 kHz bursts): keep a
        // 0.22 dB margin so the output's true peak stays under the ceiling.
        detectionCeiling = truePeak ? self.ceiling * 0.975 : self.ceiling
        delayLength = frames + (truePeak ? AudioTruePeakDetector.delay : 0)
        firstWidth = frames / 2 + 1
        secondWidth = frames / 2 + 1
        // 1 - 10^(log10(0.1) / (rate * release)): reaches -20 dB of the
        // remaining distance after `releaseSeconds`.
        let release = releaseSeconds.isFinite ? min(2, max(0.005, releaseSeconds)) : 0.025
        releaseCoefficient = Float(1 - pow(0.1, 1 / (rate * release)))
        delay = .allocate(capacity: delayLength * 2)
        delay.initialize(repeating: 0, count: delayLength * 2)
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
        memset(delay, 0, delayLength * 2 * MemoryLayout<Float>.size)
        detector?.reset()
        delayIndex = 0; dequeHead = 0; dequeCount = 0; frame = 0
        for i in 0..<firstWidth { first[i] = 1 }
        for i in 0..<secondWidth { second[i] = 1 }
        firstSum = Double(firstWidth); secondSum = Double(secondWidth)
        firstIndex = 0; secondIndex = 0; envelope = 1; reduction = 1
    }

    /// In place; `left` and `right` may alias for mono. Output lags input by `latencyFrames`.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let window = lookahead + 1
        for index in 0..<frames {
            let inputLeft = left[index].isFinite ? max(-1e6, min(1e6, left[index])) : 0
            let inputRight = right[index].isFinite ? max(-1e6, min(1e6, right[index])) : 0
            // True-peak mode: the estimate is for the frame `delay` frames
            // back, which the longer delay line accounts for.
            let peak = detector?.peak(inputLeft, inputRight, threshold: detectionCeiling)
                ?? max(abs(inputLeft), abs(inputRight))
            if peak > largestPeak { largestPeak = peak }
            let required = peak > detectionCeiling ? detectionCeiling / peak : 1
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
            if envelope < deepest { deepest = envelope }
            let delaySlot = delayIndex * 2
            let outputLeft = delay[delaySlot] * envelope
            let outputRight = delay[delaySlot + 1] * envelope
            delay[delaySlot] = inputLeft; delay[delaySlot + 1] = inputRight
            delayIndex += 1
            if delayIndex == delayLength { delayIndex = 0 }
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

/// 3.3.4 (N334, AirPlay crackle): the leveler in front of a network bus's
/// true-peak limiter.
///
/// Output Magic Boost lifts a quiet passage (gain 3–20) and, since its attack
/// only acts on the samples above its threshold, a click, a plosive or a rim
/// shot (well under a millisecond over it) passes with most of that gain. The
/// network limiter then took 2–8 dB off each within its 1.3 ms lookahead (the
/// live log's engagements: single transients, in runs) and modulated
/// everything under it, heard as grit for as long as such a passage lasted.
///
/// The leveler takes those overs instead. It is the limiter's design over a
/// 10 ms window instead of 1.3 ms: true-peak detection, the minimum required
/// gain over the window smoothed by two moving averages that lie inside it
/// (the gain is down before the peak is output), and a program-dependent
/// release: a lone peak recovers over 0.5 s, a run of them over 1.5 s (a slow
/// envelope follows the reduction over about 2 s and holds it, so a hot
/// passage is levelled rather than pumped). Its target sits just under the
/// limiter's detection threshold, which leaves the limiter to guard the
/// ceiling. It never clamps; the limiter after it is the guarantee.
/// Preallocated; no allocation, lock or object release per frame.
final class AudioLookaheadLeveler {
    static let lookaheadSeconds = 0.01
    static let fastReleaseSeconds = 0.5
    static let slowReleaseSeconds = 1.5
    static let slowAttackSeconds = 2.0

    let lookahead: Int
    let target: Float
    private let detector = AudioTruePeakDetector()
    private let delayLength: Int
    private let delay: UnsafeMutablePointer<Float>
    private var delayIndex = 0
    // Monotonic deque (minimum) of required gain over lookahead + 1 frames.
    private let dequeValues: UnsafeMutablePointer<Float>
    private let dequeFrames: UnsafeMutablePointer<Int>
    private let dequeCapacity: Int
    private var dequeHead = 0
    private var dequeCount = 0
    private var frame = 0
    private let firstWidth: Int
    private let secondWidth: Int
    private let first: UnsafeMutablePointer<Float>
    private let second: UnsafeMutablePointer<Float>
    private var firstIndex = 0, secondIndex = 0
    private var firstSum: Double, secondSum: Double
    private let fastRelease: Float
    private let slowRelease: Float
    private let slowAttack: Float
    /// The gain that follows each peak (released over 0.5 s) and the one that
    /// follows the reduction itself (about 2 s down, 1.5 s back up); the
    /// lower of the two is applied.
    private var fast: Float = 1
    private var slow: Float = 1
    private(set) var reduction: Float = 1
    private var deepest: Float = 1
    private var largestPeak: Float = 0

    /// Total delay from input to output, frames (10 ms and the detector's 32).
    var latencyFrames: Int { delayLength }

    init(sampleRate: Double, target: Float) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        // Even, so the two averages together span exactly the window.
        let frames = max(2, 2 * Int((rate * Self.lookaheadSeconds / 2).rounded()))
        lookahead = frames
        self.target = target.isFinite ? min(1, max(0.1, target)) : 0.85
        delayLength = frames + AudioTruePeakDetector.delay
        firstWidth = frames / 2 + 1
        secondWidth = frames / 2 + 1
        fastRelease = AudioLookaheadLimiter.releaseCoefficient(sampleRate: rate, seconds: Self.fastReleaseSeconds)
        slowRelease = AudioLookaheadLimiter.releaseCoefficient(sampleRate: rate, seconds: Self.slowReleaseSeconds)
        slowAttack = AudioLookaheadLimiter.releaseCoefficient(sampleRate: rate, seconds: Self.slowAttackSeconds)
        delay = .allocate(capacity: delayLength * 2)
        delay.initialize(repeating: 0, count: delayLength * 2)
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

    /// The lowest gain applied since the last call (1: none), then starts
    /// again. Render thread; for the event log.
    func takeDeepestReduction() -> Float {
        let value = deepest
        deepest = 1
        return value
    }

    /// The largest input true peak since the last call (linear), then starts
    /// again. Render thread; for the event log.
    func takeLargestPeak() -> Float {
        let value = largestPeak
        largestPeak = 0
        return value
    }

    func reset() {
        memset(delay, 0, delayLength * 2 * MemoryLayout<Float>.size)
        detector.reset()
        delayIndex = 0; dequeHead = 0; dequeCount = 0; frame = 0
        for i in 0..<firstWidth { first[i] = 1 }
        for i in 0..<secondWidth { second[i] = 1 }
        firstSum = Double(firstWidth); secondSum = Double(secondWidth)
        firstIndex = 0; secondIndex = 0
        fast = 1; slow = 1; reduction = 1
    }

    /// In place; `left` and `right` may alias for mono. Output lags input by `latencyFrames`.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let window = lookahead + 1
        for index in 0..<frames {
            let inputLeft = left[index].isFinite ? max(-1e6, min(1e6, left[index])) : 0
            let inputRight = right[index].isFinite ? max(-1e6, min(1e6, right[index])) : 0
            // The estimate is for the frame `AudioTruePeakDetector.delay`
            // frames back, which the longer delay line accounts for.
            let peak = detector.peak(inputLeft, inputRight, threshold: target)
            if peak > largestPeak { largestPeak = peak }
            let required = peak > target ? target / peak : 1
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
            // Attack follows the smoothed curve exactly; each envelope
            // releases on its own time, and the slow one only follows the
            // fast one down slowly, so a lone peak hardly moves it.
            if smoothed < fast { fast = smoothed }
            else { fast = min(smoothed, fast + (smoothed - fast) * fastRelease) }
            if fast < slow { slow += (fast - slow) * slowAttack }
            else { slow = min(fast, slow + (fast - slow) * slowRelease) }
            let gain = min(fast, slow)
            reduction = gain
            if gain < deepest { deepest = gain }
            let delaySlot = delayIndex * 2
            let outputLeft = delay[delaySlot] * gain
            let outputRight = delay[delaySlot + 1] * gain
            delay[delaySlot] = inputLeft; delay[delaySlot + 1] = inputRight
            delayIndex += 1
            if delayIndex == delayLength { delayIndex = 0 }
            left[index] = outputLeft
            right[index] = outputRight
            frame += 1
            if frame == Int.max / 2 {
                for i in 0..<dequeCount {
                    let s = (dequeHead + i) % dequeCapacity
                    dequeFrames[s] -= frame - window
                }
                frame = window
            }
        }
    }
}

/// Inter-sample peak estimate for the limiter's detector, as ITU-R
/// BS.1770-4 true-peak meters take it: 4× oversampling, i.e. each sample and
/// three points interpolated between it and the next, from a 64-tap
/// Kaiser-windowed sinc per phase (flat to about 22 kHz at 48 kHz). The
/// reported peak is for the frame `delay` frames before the newest input.
/// Preallocated; no allocation or locking per frame.
final class AudioTruePeakDetector {
    static let taps = 64
    static let delay = taps / 2
    /// 3 × taps, row-major: one row per interpolated point.
    private let coefficients: UnsafeMutablePointer<Float>
    /// Interleaved stereo, `taps` frames written twice (contiguous windows).
    private let history: UnsafeMutablePointer<Float>
    private var slot = 0
    /// The largest L1 norm of the three rows: |point| ≤ norm · max|x|.
    private let norm: Float
    /// Frames until the last loud-enough sample leaves the window.
    private var loudFrames = 0

    init(beta: Double = 8) {
        let taps = Self.taps
        coefficients = .allocate(capacity: 3 * taps)
        history = .allocate(capacity: 4 * taps)
        history.initialize(repeating: 0, count: 4 * taps)
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            repeat { term *= (x / 2 / k) * (x / 2 / k); sum += term; k += 1 } while term > sum * 1e-17
            return sum
        }
        let half = Double(taps) / 2
        var largest = 1.0
        for phase in 1...3 {
            // Window m is frame n − (taps − 1) + m; the point lies between
            // frames n − delay and n − delay + 1, i.e. after m = taps/2 − 1.
            let at = Double(taps / 2 - 1) + Double(phase) / 4
            var row = [Double](repeating: 0, count: taps)
            for m in 0..<taps {
                let d = Double(m) - at
                let sinc = d == 0 ? 1 : sin(.pi * d) / (.pi * d)
                let r = d / half
                row[m] = sinc * bessel(beta * sqrt(max(0, 1 - r * r))) / bessel(beta)
            }
            let sum = row.reduce(0, +)
            for m in 0..<taps { coefficients[(phase - 1) * taps + m] = Float(row[m] / sum) }
            largest = max(largest, row.reduce(0) { $0 + abs($1) } / abs(sum))
        }
        norm = Float(largest) * 1.001
    }
    deinit { coefficients.deallocate(); history.deallocate() }

    func reset() {
        memset(history, 0, 4 * Self.taps * MemoryLayout<Float>.size)
        slot = 0
        loudFrames = 0
    }

    /// Pushes one frame; returns the largest |value| of the frame `delay`
    /// frames back and the three points after it, over both channels.
    /// While no sample in the window could reach `threshold` (|x| times the
    /// kernel's L1 norm bounds any interpolated point) only the centre
    /// sample is returned, which is exact enough to say "below".
    func peak(_ left: Float, _ right: Float, threshold: Float = 0) -> Float {
        let taps = Self.taps
        slot += 1
        if slot == taps { slot = 0 }
        history[slot * 2] = left; history[slot * 2 + 1] = right
        history[(slot + taps) * 2] = left; history[(slot + taps) * 2 + 1] = right
        // Oldest first: frames n − (taps − 1) … n, a taps × 2 matrix.
        let window = history + (slot + 1) * 2
        let centre = taps / 2 - 1
        var peak = max(abs(window[centre * 2]), abs(window[centre * 2 + 1]))
        if max(abs(left), abs(right)) * norm > threshold { loudFrames = taps }
        guard loudFrames > 0 else { return peak }
        loudFrames -= 1
        // All three points of both channels in one pass (a plain loop: for a
        // 3 × 64 × 2 product it is ten times faster than vDSP_mmul).
        let c0 = coefficients, c1 = coefficients + taps, c2 = coefficients + 2 * taps
        var l0: Float = 0, r0: Float = 0, l1: Float = 0, r1: Float = 0, l2: Float = 0, r2: Float = 0
        for m in 0..<taps {
            let l = window[m * 2], r = window[m * 2 + 1]
            l0 += c0[m] * l; r0 += c0[m] * r
            l1 += c1[m] * l; r1 += c1[m] * r
            l2 += c2[m] * l; r2 += c2[m] * r
        }
        peak = max(peak, max(max(abs(l0), abs(r0)), max(max(abs(l1), abs(r1)), max(abs(l2), abs(r2)))))
        return peak
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
    /// The limiter's two releases (3.3.2 review): the reference's, and the
    /// network bus's for an app overdriven into an AirPlay output.
    private let localRelease: Float
    private let networkRelease: Float
    /// Render thread only: the network release is in use.
    private var networkReleaseOn = false

    /// `releaseSeconds`: the limiter's release. 25 ms is the reference's;
    /// an app overdriven into an AirPlay output switches to
    /// `networkReleaseSeconds` (the network bus's 150 ms, `useNetworkRelease`),
    /// since a 25 ms release follows the cycles of a bass note and modulates
    /// them (heard as grit).
    init(sampleRate: Double, chunk: Int = 512, releaseSeconds: Double = 0.025,
         networkReleaseSeconds: Double = AppAudioRenderBus.networkRelease) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        limiter = AudioLookaheadLimiter(sampleRate: rate, ceiling: 0.995, releaseSeconds: releaseSeconds)
        localRelease = AudioLookaheadLimiter.releaseCoefficient(sampleRate: rate, seconds: releaseSeconds)
        networkRelease = AudioLookaheadLimiter.releaseCoefficient(sampleRate: rate, seconds: networkReleaseSeconds)
        fadeStep = Float(1 / (0.02 * rate))
        rampStep = Float(1 / (0.005 * rate))
        self.chunk = chunk
        dryLeft = .allocate(capacity: chunk); dryLeft.initialize(repeating: 0, count: chunk)
        dryRight = .allocate(capacity: chunk); dryRight.initialize(repeating: 0, count: chunk)
    }
    deinit { dryLeft.deallocate(); dryRight.deallocate() }

    var isActive: Bool { engagement > 0 || current != 1 }

    /// Switches the limiter's release in place when the app's output becomes
    /// (or stops being) an AirPlay receiver. 3.3.2 review: MixerBox used to
    /// switch to a second Overdrive whose delay line still held whatever it
    /// last played, a jump whenever an overdriven app moved between a local
    /// output and AirPlay. One limiter, one delay line: nothing jumps.
    /// Render thread; no allocation.
    func useNetworkRelease(_ on: Bool) {
        guard on != networkReleaseOn else { return }
        networkReleaseOn = on
        limiter.setReleaseCoefficient(on ? networkRelease : localRelease)
    }

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

// MARK: - Audio Unit hosting (3.3.3, parity S03)

/// One Audio Unit effect (a v2 component: Apple's AULowpass, AUPeakLimiter,
/// AUNBandEQ, AUDelay… or an installed third-party one) on an output's master
/// chain. Everything that can block or allocate — finding the component,
/// creating, configuring and initialising the instance, its state — happens
/// on a control thread; the render thread only copies into preallocated
/// buffers and calls AudioUnitRender. Stereo, 32-bit float, deinterleaved,
/// at the bus's 48 kHz, at most `maximumFrames` per call.
final class AudioUnitEffectHost {
    struct Choice: Equatable, Hashable {
        var type: OSType
        var subtype: OSType
        var manufacturer: OSType
        var name: String = ""

        /// "aufx:lpas:appl" — the settings form.
        var key: String { [type, subtype, manufacturer].map(Self.fourCC).joined(separator: ":") }

        init(type: OSType = kAudioUnitType_Effect, subtype: OSType, manufacturer: OSType, name: String = "") {
            self.type = type; self.subtype = subtype; self.manufacturer = manufacturer; self.name = name
        }

        init?(key: String, name: String = "") {
            let parts = key.split(separator: ":").map(String.init)
            guard parts.count == 3, let type = Self.code(parts[0]), let subtype = Self.code(parts[1]),
                  let manufacturer = Self.code(parts[2]) else { return nil }
            self.init(type: type, subtype: subtype, manufacturer: manufacturer, name: name)
        }

        static func fourCC(_ value: OSType) -> String {
            String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "????"
        }

        static func code(_ text: String) -> OSType? {
            let bytes = Array(text.utf8)
            guard bytes.count == 4 else { return nil }
            return bytes.reduce(0) { $0 << 8 | OSType($1) }
        }

        var description: AudioComponentDescription {
            AudioComponentDescription(componentType: type, componentSubType: subtype,
                                      componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
        }
    }

    /// Settings: the output effect's component key, and its saved state.
    static let choiceKey = "AOMAudioMasterEffect"
    static let stateKey = "AOMAudioMasterEffectState"

    /// Hosts alive (tests check that swapped-out ones are released).
    private static let liveCount = AudioAtomicCounter()
    static var live: Int { Int(liveCount.load()) }

    let choice: Choice
    let maximumFrames: Int
    private let unit: AudioUnit
    /// The block to process: left then right, `maximumFrames` each.
    private let input: UnsafeMutablePointer<Float>
    private let list: UnsafeMutableAudioBufferListPointer
    private var sampleTime: Double = 0
    private var frames = 0
    /// Render calls that failed (the block then passes dry).
    private let failures = AudioAtomicCounter()
    var failedRenders: UInt64 { failures.load() }

    /// The effects installed on this Mac (control thread).
    static func installedEffects() -> [Choice] {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0,
                                                    componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        var result: [Choice] = []
        var component = AudioComponentFindNext(nil, &description)
        while let current = component {
            var found = AudioComponentDescription()
            var name: Unmanaged<CFString>?
            if AudioComponentGetDescription(current, &found) == noErr,
               AudioComponentCopyName(current, &name) == noErr, let name {
                result.append(Choice(type: found.componentType, subtype: found.componentSubType,
                                     manufacturer: found.componentManufacturer, name: name.takeRetainedValue() as String))
            }
            component = AudioComponentFindNext(current, &description)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Control thread. nil when the component is missing or refuses the format.
    init?(choice: Choice, sampleRate: Double = 48000, maximumFrames: Int = 512, state: Data? = nil) {
        var description = choice.description
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else { return nil }
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var maximum = UInt32(maximumFrames)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size) == noErr,
              AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, size) == noErr,
              AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                   &maximum, 4) == noErr else {
            AudioComponentInstanceDispose(instance)
            return nil
        }
        self.choice = choice
        self.maximumFrames = maximumFrames
        unit = instance
        input = .allocate(capacity: maximumFrames * 2)
        input.initialize(repeating: 0, count: maximumFrames * 2)
        list = AudioBufferList.allocate(maximumBuffers: 2)
        for index in 0..<2 {
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        }
        Self.liveCount.add()
        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, data in
            guard let data else { return noErr }
            Unmanaged<AudioUnitEffectHost>.fromOpaque(refCon)._withUnsafeGuaranteedRef {
                $0.provide(frames: Int(frames), into: data)
            }
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr else { return nil }
        if let state { restore(state) }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        input.deallocate()
        free(list.unsafeMutablePointer)
        Self.liveCount.add(UInt64.max) // -1
    }

    /// The instance, for an editor view (control thread only).
    var audioUnit: AudioUnit { unit }

    /// The unit's state (kAudioUnitProperty_ClassInfo) as a property list.
    var state: Data? {
        var info: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, &size) == noErr,
              let info else { return nil }
        let list = info.takeRetainedValue()
        return try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    private func restore(_ data: Data) {
        guard let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return }
        var info: CFPropertyList = list as CFPropertyList
        _ = AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info,
                                 UInt32(MemoryLayout<CFPropertyList>.size))
    }

    /// Render thread: the unit pulls the block it is given.
    fileprivate func provide(frames count: Int, into data: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        let copied = min(count, frames)
        for index in 0..<buffers.count {
            let source = input + (index == 0 ? 0 : maximumFrames)
            if let destination = buffers[index].mData {
                let capacity = Int(buffers[index].mDataByteSize) / 4
                let n = min(copied, capacity)
                memcpy(destination, source, n * 4)
                if capacity > n { memset(destination + n * 4, 0, (capacity - n) * 4) }
            } else {
                buffers[index].mData = UnsafeMutableRawPointer(source)
                buffers[index].mDataByteSize = UInt32(copied * 4)
            }
        }
    }

    /// Render thread, in place. On failure the block stays dry.
    @discardableResult
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames count: Int) -> Bool {
        guard count > 0, count <= maximumFrames else { return false }
        memcpy(input, left, count * 4)
        memcpy(input + maximumFrames, right, count * 4)
        frames = count
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: UnsafeMutableRawPointer(left))
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: UnsafeMutableRawPointer(right))
        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = sampleTime
        stamp.mFlags = .sampleTimeValid
        let status = AudioUnitRender(unit, &flags, &stamp, 0, UInt32(count), list.unsafeMutablePointer)
        sampleTime += Double(count)
        var finite = status == noErr
        if finite {
            for index in 0..<count where !left[index].isFinite || !right[index].isFinite { finite = false; break }
        }
        guard finite else {
            memcpy(left, input, count * 4)
            memcpy(right, input + maximumFrames, count * 4)
            failures.add()
            return false
        }
        return true
    }
}
