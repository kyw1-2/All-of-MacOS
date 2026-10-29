import Foundation
import Darwin
import Accelerate
#if canImport(Synchronization)
import Synchronization
#endif

private protocol AudioAtomicStorage: AnyObject {
    func load() -> UInt64
    func store(_ value: UInt64)
    func add(_ value: UInt64) -> UInt64
    func exchange(expected: UInt64, desired: UInt64) -> Bool
}

#if canImport(Synchronization)
@available(macOS 15.0, *)
private final class ModernAudioAtomic: AudioAtomicStorage {
    private let value: Atomic<UInt64>
    init(_ initial: UInt64) { value = Atomic(initial) }
    func load() -> UInt64 { value.load(ordering: .acquiring) }
    func store(_ new: UInt64) { value.store(new, ordering: .releasing) }
    func add(_ amount: UInt64) -> UInt64 { value.wrappingAdd(amount, ordering: .acquiringAndReleasing).newValue }
    func exchange(expected: UInt64, desired: UInt64) -> Bool {
        value.compareExchange(expected: expected, desired: desired, ordering: .acquiringAndReleasing).exchanged
    }
}
#endif

/// macOS 14 compatibility; all storage is allocated before any IO starts.
private final class LegacyAudioAtomic: AudioAtomicStorage {
    private let value: UnsafeMutablePointer<Int64>
    init(_ initial: UInt64) { value = .allocate(capacity: 1); value.initialize(to: Int64(bitPattern: initial)) }
    deinit { value.deinitialize(count: 1); value.deallocate() }
    func load() -> UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(0, value)) }
    func store(_ new: UInt64) {
        var old = load()
        while !exchange(expected: old, desired: new) { old = load() }
    }
    func add(_ amount: UInt64) -> UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(Int64(bitPattern: amount), value)) }
    func exchange(expected: UInt64, desired: UInt64) -> Bool {
        OSAtomicCompareAndSwap64Barrier(Int64(bitPattern: expected), Int64(bitPattern: desired), value)
    }
}

final class AudioAtomicCounter {
    private let storage: AudioAtomicStorage
    init(_ initial: UInt64 = 0) {
#if canImport(Synchronization)
        if #available(macOS 15.0, *) { storage = ModernAudioAtomic(initial); return }
#endif
        storage = LegacyAudioAtomic(initial)
    }
    func load() -> UInt64 { storage.load() }
    func store(_ value: UInt64) { storage.store(value) }
    @discardableResult func add(_ value: UInt64 = 1) -> UInt64 { storage.add(value) }
    func raise(to value: UInt64) {
        var old = load()
        while old < value {
            if storage.exchange(expected: old, desired: value) { return }
            old = load()
        }
    }
    /// The current value, leaving zero (a consumer taking a raised peak).
    func take() -> UInt64 {
        var old = load()
        while !storage.exchange(expected: old, desired: 0) { old = load() }
        return old
    }
    /// Stores `desired` only if the value is still `expected`.
    @discardableResult
    func compareExchange(expected: UInt64, desired: UInt64) -> Bool {
        storage.exchange(expected: expected, desired: desired)
    }
}

/// Band-limited interpolation prototype (J. O. Smith's bandlimited
/// interpolation): one wing of a Kaiser-windowed sinc sampled `phases` times
/// per input sample, with per-entry slopes for linear phase interpolation.
/// Immutable after init and shared by every queue; built on a control thread
/// (a queue's init) before any render path can read it.
///
/// 3.3.2 (HomePod crackle audit): both PCM queues used two-point linear
/// interpolation. Its response is a time-varying comb (−5 dB at 15 kHz half
/// way between samples) and its images fold back into the audio band at
/// non-unity ratios (48 → 44.1 kHz). This kernel has 32 zero crossings per
/// wing (64 taps), β = 9 (≈ 90 dB stopband) and a cutoff of 0.455 of the
/// lower rate: flat to 0.41 (19.7 kHz at 48 kHz) with the stopband starting
/// at that rate's Nyquist. Phase-interpolation error at 512 phases is below
/// −95 dB.
final class AudioSincKernel {
    static let shared = AudioSincKernel()
    /// Zero crossings per wing at unit scale (input samples).
    let halfWidth: Int
    /// Table entries per input sample.
    let phases: Int
    /// `halfWidth * phases`: entries at or beyond it are zero.
    let extent: Int
    /// One wing, for stretched (downsampling) kernels.
    let values: UnsafeMutablePointer<Float>
    let slopes: UnsafeMutablePointer<Float>
    /// Polyphase rows for unit scale: `phases + 1` rows of `2 * halfWidth`
    /// contiguous taps; row r holds the taps for a fraction of r / phases,
    /// tap j weighting input frame `position - (halfWidth - 1) + j`.
    let rows: UnsafeMutablePointer<Float>
    var taps: Int { 2 * halfWidth }

    init(halfWidth: Int = 32, phases: Int = 512, beta: Double = 9, cutoff: Double = 0.455) {
        self.halfWidth = halfWidth
        self.phases = phases
        extent = halfWidth * phases
        values = .allocate(capacity: extent + 2)
        slopes = .allocate(capacity: extent + 2)
        rows = .allocate(capacity: (phases + 1) * 2 * halfWidth)
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            let half = x / 2
            repeat {
                term *= (half / k) * (half / k)
                sum += term
                k += 1
            } while term > sum * 1e-17
            return sum
        }
        let norm = bessel(beta)
        var table = [Double](repeating: 0, count: extent + 2)
        for index in 0..<extent {
            let t = Double(index) / Double(phases)
            let x = 2 * cutoff * t
            let sinc = index == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let r = t / Double(halfWidth)
            table[index] = 2 * cutoff * sinc * bessel(beta * sqrt(max(0, 1 - r * r))) / norm
        }
        // Unity DC gain: the taps of the zero phase sum to one.
        var sum = table[0]
        for tap in 1..<halfWidth { sum += 2 * table[tap * phases] }
        for index in 0..<(extent + 2) { values[index] = Float(table[index] / sum) }
        for index in 0...extent { slopes[index] = values[index + 1] - values[index] }
        slopes[extent + 1] = 0
        // Distances are whole table steps, so the rows reuse the wing exactly.
        let width = 2 * halfWidth
        for row in 0...phases {
            for tap in 0..<width {
                let index = abs((tap - halfWidth + 1) * phases - row)
                rows[row * width + tap] = index < extent ? values[index] : 0
            }
        }
    }
    deinit { values.deallocate(); slopes.deallocate(); rows.deallocate() }
}

/// Clock recovery between two free-running clocks from the queue's fill
/// level: a PI controller on the level (normalised to the target) sets the
/// resampling correction, limited to ±`limit`. Two cascaded 0.5 s low-pass
/// stages remove the producer/consumer block sawtooth before it reaches the
/// ratio, so the pitch never wobbles at the block rate. With ω ≈ 0.25 rad/s
/// and ζ ≈ 0.8 a drift step settles in about 20 s and is absorbed without a
/// trim; the integral is the measured drift, kept across restarts.
///
/// The plant: dx/dt = (inputRate / target) · (drift − correction), where x
/// is the level error over the target, so gains scale with that factor and
/// every queue (per-app 40 ms or AirPlay bridge 150 ms) has the same loop.
struct AudioDriftController: Equatable {
    static let naturalFrequency = 0.25
    static let damping = 0.8
    static let smoothingSeconds = 0.5

    private(set) var correction: Double = 0
    private(set) var integral: Double = 0
    private var fast = 0.0
    private var slow = 0.0
    private var primed = false

    /// The filters restart from the next level; the drift estimate stays.
    mutating func restart() { primed = false }

    /// Fixed-ratio operation: no correction at all.
    mutating func zero() { primed = false; integral = 0; correction = 0 }

    @discardableResult
    mutating func update(level: Double, target: Double, seconds: Double, inputRate: Double, limit: Double) -> Double {
        guard limit > 0, target > 0, seconds > 0, inputRate > 0, level.isFinite else {
            correction = 0
            return 0
        }
        let error = max(-1, min(4, (level - target) / target))
        if !primed { fast = error; slow = error; primed = true }
        let blend = min(1, seconds / Self.smoothingSeconds)
        fast += (error - fast) * blend
        slow += (fast - slow) * blend
        let plant = inputRate / target
        let kp = 2 * Self.damping * Self.naturalFrequency / plant
        let ki = Self.naturalFrequency * Self.naturalFrequency / plant
        // Anti-windup: the integral alone never exceeds the limit.
        integral = max(-limit, min(limit, integral + ki * slow * seconds))
        correction = max(-limit, min(limit, kp * slow + integral))
        return correction
    }
}

/// Single producer / single consumer stereo queue with a band-limited
/// resampler on the consumer side. Release/acquire cursors publish complete
/// samples and keep the writer off every frame the interpolator can still
/// read (the playhead's wing, `history` frames, is retained). No mutex,
/// allocation or dispatch occurs in either path; the caller serializes
/// consumers during output handoff. Control threads may request a clear but
/// never modify consumer state.
///
/// 3.3.2 (HomePod crackle audit) — every discontinuity is now shaped:
/// * start and restart fade in, an underrun fades out over a full
///   `fadeFrames` (the last `fadeFrames` rendered frames are held back as a
///   tail, so there is always audio left to fade), a clear fades the old
///   stream out, and an excess backlog is skipped with a crossfade instead
///   of a cut;
/// * drift is followed by `AudioDriftController` (±`driftLimit`, 0.2 %) in
///   place of a proportional nudge that only trims could rescue;
/// * an underrun raises the queue's own target for the following minutes.
/// With `fadeFrames` 0 the queue renders without any of the shaping, and at
/// ratio 1 without drift control it copies samples bit-exactly.
final class StereoPCMQueue {
    /// Widest supported downsampling stretch of the kernel (384 → 48 kHz).
    static let maximumStretch = 8
    /// Largest output slice and fade one call renders.
    static let maximumFrames = 16384
    static let maximumFade = 4096

    let capacity: Int
    /// Frames retained behind the playhead for the interpolator's left wing.
    let history: Int
    /// Ring frames mirrored after the end so every kernel window is contiguous.
    private let mirror: Int
    private let samples: UnsafeMutablePointer<Float>
    private let kernel: AudioSincKernel
    private let kernelValues: UnsafeMutablePointer<Float>
    private let kernelSlopes: UnsafeMutablePointer<Float>
    private let kernelRows: UnsafeMutablePointer<Float>
    private let written: AudioAtomicCounter
    /// The consumer's playhead (statistics and `queuedFrames`).
    private let read: AudioAtomicCounter
    /// The producer may overwrite frames below this cursor.
    private let released = AudioAtomicCounter()
    private let clearBoundary = AudioAtomicCounter()
    private let clearGeneration = AudioAtomicCounter()
    private let enqueued = AudioAtomicCounter()
    private let dropped = AudioAtomicCounter()
    private let underruns = AudioAtomicCounter()
    private let discarded = AudioAtomicCounter()
    private let clears = AudioAtomicCounter()
    private let rendered = AudioAtomicCounter()
    private let trims = AudioAtomicCounter()
    /// Frames the kernel computed (output frames, tails and trim crossfades
    /// included): the consumer's work, for the constant-time check (3.3.3).
    private let resampled = AudioAtomicCounter()
    private let correctionBits = AudioAtomicCounter(Double(0).bitPattern)
    private let targetValue = AudioAtomicCounter()

    // Consumer-owned state.
    private var generation: UInt64 = 0
    private var position: UInt64
    private var phase: Double = 0
    private var streaming = false
    private var fadeInIndex = 0
    private var fadeInLength = 0
    private var controller = AudioDriftController()
    private var extra = 0
    private var calmFrames = 0
    private let tail: UnsafeMutablePointer<Float>
    private var tailCount = 0
    private let work: UnsafeMutablePointer<Float>
    private let blend: UnsafeMutablePointer<Float>
    /// One output frame's kernel taps (the widest stretched window).
    private let coefficientScratch: UnsafeMutablePointer<Float>

    init(capacity: Int, kernel: AudioSincKernel = .shared) {
        self.kernel = kernel
        kernelValues = kernel.values
        kernelSlopes = kernel.slopes
        kernelRows = kernel.rows
        history = kernel.halfWidth * Self.maximumStretch + 2
        mirror = 2 * kernel.halfWidth * Self.maximumStretch + 4
        precondition(capacity > 2 * (history + mirror))
        self.capacity = capacity
        samples = .allocate(capacity: (capacity + mirror) * 2)
        samples.initialize(repeating: 0, count: (capacity + mirror) * 2)
        // Cursors start one wing in, so the first window reads silence.
        written = AudioAtomicCounter(UInt64(history))
        read = AudioAtomicCounter(UInt64(history))
        position = UInt64(history)
        tail = .allocate(capacity: Self.maximumFade * 2)
        tail.initialize(repeating: 0, count: Self.maximumFade * 2)
        work = .allocate(capacity: (Self.maximumFade + Self.maximumFrames) * 2)
        work.initialize(repeating: 0, count: (Self.maximumFade + Self.maximumFrames) * 2)
        blend = .allocate(capacity: Self.maximumFade * 2)
        blend.initialize(repeating: 0, count: Self.maximumFade * 2)
        coefficientScratch = .allocate(capacity: 2 * kernel.halfWidth * Self.maximumStretch + 2)
        coefficientScratch.initialize(repeating: 0, count: 2 * kernel.halfWidth * Self.maximumStretch + 2)
    }
    deinit {
        samples.deallocate(); tail.deallocate(); work.deallocate(); blend.deallocate()
        coefficientScratch.deallocate()
    }

    var statistics: [String: UInt64] {
        let r = read.load(), w = written.load()
        return ["capturedFrames": enqueued.load(), "renderedFrames": rendered.load(),
                "queuedFrames": w >= r ? w - r : 0,
                "droppedFrames": dropped.load(), "underruns": underruns.load(),
                "discardedFrames": discarded.load(), "clears": clears.load(),
                "trims": trims.load(), "adaptiveTargetFrames": targetValue.load(),
                "resampledFrames": resampled.load()]
    }
    var queuedFrames: Int {
        let r = read.load(), w = written.load()
        return w >= r ? Int(min(UInt64(capacity), w - r)) : 0
    }
    /// The resampling correction last applied, in parts per million.
    var driftCorrectionPPM: Double { Double(bitPattern: correctionBits.load()) * 1e6 }

    /// Setup only, before producer and consumer start (silence prebuffer).
    func prime(frames: Int) {
        precondition(frames >= 0 && frames < capacity - history)
        written.store(written.load() + UInt64(frames))
        streaming = true
        fadeInIndex = 0; fadeInLength = 0
    }

    func requestClear() {
        clearBoundary.raise(to: written.load())
        clearGeneration.add()
    }

    @discardableResult
    func write(frames: Int, sample: (Int) -> (Float, Float)) -> Int {
        guard frames > 0 else { return 0 }
        let w = written.load(), r = released.load()
        let occupied = w >= r ? min(UInt64(capacity), w - r) : UInt64(capacity)
        let accepted = min(frames, capacity - Int(occupied))
        var slot = Int(w % UInt64(capacity))
        for frame in 0..<accepted {
            let (l, r) = sample(frame)
            let left = l.isFinite ? l : 0, right = r.isFinite ? r : 0
            samples[slot * 2] = left
            samples[slot * 2 + 1] = right
            if slot < mirror {
                samples[(capacity + slot) * 2] = left
                samples[(capacity + slot) * 2 + 1] = right
            }
            slot += 1
            if slot == capacity { slot = 0 }
        }
        written.store(w + UInt64(accepted))
        enqueued.add(UInt64(accepted))
        if accepted < frames {
            dropped.add(UInt64(frames - accepted))
            // Crackle audit 3.3.2, follow-up: what does not fit is lost, so
            // the next write would follow the old audio as a hard splice
            // (after a consumer stall of more than the queue's capacity).
            // A clear fades the old stream out and restarts on fresh audio.
            requestClear()
        }
        return accepted
    }

    @inline(__always)
    private static func smooth(_ x: Float) -> Float { x * x * (3 - 2 * x) }

    /// Output is interleaved stereo at the caller's clock; returns the frames
    /// that carry stream audio (fade tails included). Initial priming is not
    /// counted as an underrun; only loss after a running stream is counted.
    /// `ratio` is input frames per output frame; `outputRate` only sets the
    /// controller's time scale. `trimFloorFrames` raises the backlog a trim
    /// needs: a consumer that renders in bursts (the AirPlay mix clock after
    /// a late wake-up) briefly sees a large level that is not a backlog.
    /// `startFrames` (nil: the target) lets the stream start below its
    /// target, which the drift controller then grows the level to, so a new
    /// stream is heard sooner without running on a thin margin for good.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int, ratio: Double,
                targetFrames: Int, driftLimit: Double = 0.002, fadeFrames: Int = 240,
                outputRate: Double = 48000, trimFloorFrames: Int = 0, startFrames: Int? = nil,
                levelBias: Double = 0) -> Int {
        guard frames > 0, ratio.isFinite, ratio > 0 else { return 0 }
        memset(output, 0, frames * 8)
        guard frames <= Self.maximumFrames else { return 0 }
        let fade = min(Self.maximumFade, max(0, fadeFrames))
        let w = written.load()
        let currentGeneration = clearGeneration.load()
        if generation != currentGeneration {
            generation = currentGeneration
            let boundary = max(position, min(w, clearBoundary.load()))
            discarded.add(boundary - position); clears.add()
            if streaming {
                // The held-back tail is the old stream's last audio: it fades out.
                fadeOut(tail, frames: tailCount)
                streaming = false
            }
            position = boundary
            phase = 0
            controller.restart()
        }
        let limit = max(0, driftLimit)
        let exact = ratio == 1 && limit == 0 && phase == 0
        // Within 1 % of unity (clock drift) the unit kernel is used: its
        // stopband edge then sits within 0.01 Nyquist of the output's.
        let stretch = ratio > 1.01 ? min(Double(Self.maximumStretch), ratio) : 1
        let scale = Float(1 / stretch)
        let span = exact ? 0 : Int((Double(kernel.halfWidth) * stretch).rounded(.up))
        let target = min(capacity / 2, max(2, targetFrames) + extra)
        let start = min(target, startFrames.map { max(2, $0) + extra } ?? target)
        targetValue.store(UInt64(target))
        var available = Int(w - position)
        if streaming && limit > 0 {
            controller.update(level: Double(available) + levelBias, target: Double(target),
                              seconds: Double(frames) / max(1, outputRate),
                              inputRate: max(1, outputRate) * ratio, limit: limit)
        } else if limit == 0 {
            controller.zero()
        }
        let step = exact ? 1 : ratio * (1 + controller.correction)
        correctionBits.store(controller.correction.bitPattern)
        let margin = exact ? 0 : Int(step.rounded(.up)) + 2
        func needed(_ count: Int) -> Int {
            guard !exact else { return count }
            return Int((phase + Double(max(0, count - 1)) * step).rounded(.down)) + span + 1 + margin
        }
        // Steady state holds `fade` rendered frames back as the tail.
        let wanted = max(0, frames + fade - tailCount)
        if !streaming && available >= max(needed(wanted), start) {
            streaming = true
            fadeInIndex = 0; fadeInLength = fade
            controller.restart()
        }
        if streaming {
            let trimAbove = min(capacity - 1 - history,
                                max(target * 3, Int((Double(frames) * ratio).rounded(.up)) * 2, trimFloorFrames))
            if available > trimAbove {
                // A backlog (device stall, sleep) is skipped with a crossfade
                // from the held-back tail into the newer audio.
                let keep = min(available, max(target, needed(wanted + tailCount)))
                let next = w - UInt64(keep)
                discarded.add(next - position); trims.add()
                position = next
                controller.restart()
                if fade > 0 && tailCount > 0 {
                    fadeInIndex = fadeInLength
                    let made = produce(into: blend, count: tailCount, written: w, step: step, span: span,
                                       scale: scale, exact: exact)
                    for frame in 0..<tailCount {
                        let g = Self.smooth(Float(frame + 1) / Float(tailCount + 1))
                        let incoming0 = frame < made ? blend[frame * 2] : 0
                        let incoming1 = frame < made ? blend[frame * 2 + 1] : 0
                        tail[frame * 2] += (incoming0 - tail[frame * 2]) * g
                        tail[frame * 2 + 1] += (incoming1 - tail[frame * 2 + 1]) * g
                    }
                }
                available = Int(w - position)
            }
        }
        memcpy(work, tail, tailCount * 8)
        var total = tailCount
        if streaming {
            let made = produce(into: work + total * 2, count: wanted, written: w, step: step, span: span,
                               scale: scale, exact: exact)
            total += made
            if made < wanted {
                // Underrun: the newest `fade` frames fade to silence, so the
                // stream always ends smoothly, however little was left.
                fadeOut(work + (total - min(fade, total)) * 2, frames: min(fade, total))
                streaming = false
                underruns.add()
                calmFrames = 0
                extra = min(3 * max(2, targetFrames), extra + max(frames, targetFrames / 2))
            } else {
                calmFrames += frames
                if extra > 0 && Double(calmFrames) >= max(1, outputRate) * 120 {
                    extra = max(0, extra - max(1, targetFrames / 4))
                    calmFrames = 0
                }
            }
        }
        let emit = min(frames, total)
        memcpy(output, work, emit * 8)
        tailCount = total - emit
        if tailCount > 0 { memmove(tail, work + emit * 2, tailCount * 8) }
        read.store(position)
        let floor = position > UInt64(history) ? position - UInt64(history) : 0
        if floor > released.load() { released.store(floor) }
        rendered.add(UInt64(emit))
        return emit
    }

    /// In place: 1 → 0 over `frames`, ending at exact silence.
    private func fadeOut(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        for frame in 0..<frames {
            let g = 1 - Self.smooth(Float(frame + 1) / Float(frames))
            buffer[frame * 2] *= g
            buffer[frame * 2 + 1] *= g
        }
    }

    /// Renders up to `count` frames from the playhead, applying a pending
    /// fade-in; stops where the kernel would read unwritten frames.
    private func produce(into destination: UnsafeMutablePointer<Float>, count: Int, written w: UInt64,
                         step: Double, span: Int, scale: Float, exact: Bool) -> Int {
        let made = produceFrames(into: destination, count: count, written: w, step: step, span: span,
                                 scale: scale, exact: exact)
        if made > 0 { resampled.add(UInt64(made)) }
        return made
    }

    private func produceFrames(into destination: UnsafeMutablePointer<Float>, count: Int, written w: UInt64,
                               step: Double, span: Int, scale: Float, exact: Bool) -> Int {
        guard count > 0 else { return 0 }
        var made = 0
        if exact {
            let possible = min(count, Int(w - position))
            var slot = Int(position % UInt64(capacity))
            while made < possible {
                var gain: Float = 1
                if fadeInIndex < fadeInLength {
                    fadeInIndex += 1
                    gain = Self.smooth(Float(fadeInIndex) / Float(fadeInLength))
                }
                destination[made * 2] = samples[slot * 2] * gain
                destination[made * 2 + 1] = samples[slot * 2 + 1] * gain
                made += 1
                slot += 1
                if slot == capacity { slot = 0 }
            }
            position += UInt64(possible)
            return made
        }
        let phases = kernel.phases, extent = kernel.extent
        let values = kernelValues, slopes = kernelSlopes
        let unit = scale == 1 && span == kernel.halfWidth
        let taps = unit ? kernel.taps : 2 * span
        let stride = Float(phases) * scale
        let coefficients = coefficientScratch
        var slot = Int((position - UInt64(span - 1)) % UInt64(capacity))
        while made < count && position + UInt64(span) < w {
            let window = samples + slot * 2
            let p = Float(phase)
            if unit {
                // Polyphase rows: two contiguous rows, one weight between them.
                let location = p * Float(phases)
                let row = min(phases - 1, Int(location))
                var weight = location - Float(row)
                let a = kernelRows + row * taps
                vDSP_vintb(a, 1, a + taps, 1, &weight, coefficients, 1, vDSP_Length(taps))
            } else {
                // Downsampling: the kernel stretches by 1/scale, cutting off
                // below the output's Nyquist. Tap j is frame
                // position − (span − 1) + j, at distance |j − (span − 1) − p|.
                for tap in 0..<taps {
                    let location = abs(Float(tap - span + 1) - p) * stride
                    let index = Int(location)
                    coefficients[tap] = index < extent
                        ? (values[index] + (location - Float(index)) * slopes[index]) * scale : 0
                }
            }
            var left: Float = 0, right: Float = 0
            vDSP_dotpr(coefficients, 1, window, 2, &left, vDSP_Length(taps))
            vDSP_dotpr(coefficients, 1, window + 1, 2, &right, vDSP_Length(taps))
            var gain: Float = 1
            if fadeInIndex < fadeInLength {
                fadeInIndex += 1
                gain = Self.smooth(Float(fadeInIndex) / Float(fadeInLength))
            }
            destination[made * 2] = left.isFinite ? left * gain : 0
            destination[made * 2 + 1] = right.isFinite ? right * gain : 0
            made += 1
            phase += step
            let advance = Int(phase)
            phase -= Double(advance)
            position += UInt64(advance)
            slot += advance
            if slot >= capacity { slot -= capacity }
        }
        return made
    }
}
