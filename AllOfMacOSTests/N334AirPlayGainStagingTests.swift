import XCTest
import AudioToolbox
import Accelerate
@testable import AllOfMacOS

/// 3.3.4 (N334, AirPlay crackle): gain staging on the AirPlay bus.
///
/// The live log (3.3.3, audio-health.json) had the network bus's −1 dBTP
/// limiter engaging on single transients, 2–6.45 dB deep, often several in
/// half a minute, with output Magic Boost (Music) on, a strong custom EQ and
/// two apps capturing. What reproduces that here (synthetic signals only):
/// Magic Boost lifting a quiet or moderate bed (gain 3–20) and passing short
/// transients (clicks, plosives, rim shots, claps) with most of that gain,
/// because its attack only acts on the few samples above its threshold. Hot
/// (+6 dBFS) or summed sources alone need at most about 1.6 dB, and loud
/// music normalised to −0.2 dBFS under 1 dB. These tests measure the shipped
/// 3.3.3 network chain against the 3.3.4 one (`AppAudioRenderBus.network()`:
/// Magic Boost → `AudioLookaheadLeveler` → limiter) on the same material,
/// and the Magic Boost near-silence floor.
final class N334AirPlayGainStagingTests: XCTestCase {
    static let userGains: [Float] = [7.353, 4.4275, 2.4916, 0, -0.6881, 1.5300, 5.0925, 7.7407, 5.5013, 1.8286]
    static let flat = [Float](repeating: 0, count: 10)
    static let rate = 48000.0
    /// The AirPlay mix thread's block.
    static let block = AirPlayMixThread.blockFrames

    // MARK: - Signals (interleaved stereo, synthetic)

    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53) * 2 - 1
        }
        mutating func unit() -> Double { (next() + 1) / 2 }
    }

    static func lin(_ db: Double) -> Double { pow(10, db / 20) }
    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

    static func normalize(_ x: [Float], peakDB: Double) -> [Float] {
        var m: Float = 0
        vDSP_maxmgv(x, 1, &m, vDSP_Length(x.count))
        guard m > 0 else { return x }
        let s = Float(lin(peakDB)) / m
        return x.map { $0 * s }
    }

    /// Kick, 50 Hz bass, hats, two tones and noise (the main probe's "pop").
    static func pop(seconds: Double, seed: UInt64 = 7) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n * 2)
        var rng = LCG(s: seed)
        var phaseKick = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            phaseKick += 2 * .pi * (45 + 75 * exp(-beat / 0.03)) / rate
            let kick = 0.6 * exp(-beat / 0.12) * sin(phaseKick)
            let bass = 0.35 * sin(2 * .pi * 50 * t)
            let hat = 0.15 * exp(-t.truncatingRemainder(dividingBy: 0.25) / 0.02) * rng.next()
            let voice = 0.12 * sin(2 * .pi * 1000 * t) + 0.08 * sin(2 * .pi * 3000 * t)
            let noise = 0.05 * rng.next()
            out[i * 2] = Float(kick + bass + hat + voice + noise)
            out[i * 2 + 1] = Float(kick + bass + hat * 0.8 + voice + noise * 0.9)
        }
        return out
    }

    static func pink(seconds: Double, seed: UInt64 = 11) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n * 2)
        var rng = LCG(s: seed)
        var b = [Double](repeating: 0, count: 7)
        for i in 0..<n {
            let w = rng.next()
            b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980
            let p = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
            b[6] = w * 0.115926
            out[i * 2] = Float(p); out[i * 2 + 1] = Float(p)
        }
        return out
    }

    /// A loud master: driven `drive` dB into a hard clip at full scale.
    static func brickwall(_ x: [Float], drive: Double) -> [Float] {
        let g = Float(lin(drive))
        return normalize(x, peakDB: 0).map { max(-1, min(1, $0 * g)) }
    }

    static func hit(kind: Int, rng: inout LCG) -> [Double] {
        switch kind {
        case 0: // click: 0.5 ms Hann-windowed noise
            return (0..<24).map { k in (0.5 - 0.5 * cos(2 * .pi * Double(k) / 23)) * rng.next() }
        case 1: // snare
            return (0..<Int(0.2 * rate)).map { k in
                let s = Double(k) / rate
                return rng.next() * exp(-s / 0.03) + 0.6 * sin(2 * .pi * 190 * s) * exp(-s / 0.05)
            }
        case 2: // hat: differentiated noise
            var previous = 0.0
            return (0..<Int(0.08 * rate)).map { k in
                let w = rng.next(), v = (w - previous) * exp(-Double(k) / rate / 0.01)
                previous = w
                return v
            }
        case 3: // rim: 1.7 kHz burst
            return (0..<Int(0.04 * rate)).map { k in
                let s = Double(k) / rate
                return sin(2 * .pi * 1700 * s) * exp(-s / 0.006)
            }
        default: // clap: three 4 ms bursts 9 ms apart, then a tail
            return (0..<Int(0.15 * rate)).map { k in
                let s = Double(k) / rate
                var e = 0.0
                for j in 0..<3 where s >= Double(j) * 0.009 { e += exp(-(s - Double(j) * 0.009) / 0.004) }
                if s >= 0.027 { e += 0.5 * exp(-(s - 0.027) / 0.03) }
                return rng.next() * e
            }
        }
    }

    /// A quiet pad (`bed` dB peak) with percussive hits (`hit` dB peak) 0.25–1.25 s apart.
    static func sparseHits(seconds: Double, bed: Double, hit hitDB: Double, seed: UInt64 = 5,
                           kinds: [Int] = [0, 1, 2, 3, 4]) -> [Float] {
        let n = Int(seconds * rate)
        var pad = [Float](repeating: 0, count: n * 2)
        var rng = LCG(s: seed)
        for i in 0..<n {
            let t = Double(i) / rate
            let am = 0.6 + 0.4 * sin(2 * .pi * 0.3 * t)
            let tone = am * (sin(2 * .pi * 220 * t) + 0.7 * sin(2 * .pi * 277.18 * t + 1) + 0.5 * sin(2 * .pi * 329.63 * t + 2))
            let noise = 0.05 * rng.next()
            pad[i * 2] = Float(tone + noise); pad[i * 2 + 1] = Float(tone * 0.95 + noise)
        }
        var out = normalize(pad, peakDB: bed)
        let peak = lin(hitDB)
        var time = 0.4, index = 0
        while time < seconds - 0.3 {
            let shape = hit(kind: kinds[index % kinds.count], rng: &rng)
            let m = shape.reduce(0) { max($0, abs($1)) }
            let start = Int(time * rate), pan = 0.8 + 0.2 * rng.unit()
            for (k, v) in shape.enumerated() where start + k < n {
                out[(start + k) * 2] += Float(v / m * peak)
                out[(start + k) * 2 + 1] += Float(v / m * peak * pan)
            }
            index += 1
            time += 0.25 + rng.unit()
        }
        return out
    }

    /// Syllables (harmonics through two formants, some opening with a
    /// plosive burst) in words and phrases, −58 dBFS room noise between. −1 dBFS peak.
    static func speech(seconds: Double, seed: UInt64 = 9) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n * 2)
        var rng = LCG(s: seed)
        let noise = lin(-58)
        for i in 0..<n { let v = Float(noise * rng.next()); out[i * 2] = v; out[i * 2 + 1] = v }
        var time = 0.3
        while time < seconds - 0.8 {
            for _ in 0..<(2 + Int(rng.unit() * 4)) {
                let length = 0.12 + 0.18 * rng.unit()
                let f0 = 110 + 50 * rng.unit(), f1 = 500 + 300 * rng.unit(), f2 = 1200 + 800 * rng.unit()
                let start = Int(time * rate), count = Int(length * rate)
                let plosive = rng.unit() < 0.4
                var weights = [Double](repeating: 0, count: 26)
                for h in 1...25 {
                    let f = f0 * Double(h)
                    weights[h] = (exp(-pow((f - f1) / 150, 2)) + 0.6 * exp(-pow((f - f2) / 200, 2))
                                  + 0.25 * exp(-pow((f - 2600) / 300, 2))) / Double(h).squareRoot()
                }
                var phase = 0.0
                var syllable = [Float](repeating: 0, count: count)
                for k in 0..<count {
                    let s = Double(k) / rate
                    let envelope = min(1, s / 0.01) * min(1, max(0, length - s) / 0.03)
                    phase += 2 * .pi * f0 * (1 + 0.05 * s) / rate
                    var v = 0.0
                    for h in 1...25 where weights[h] > 1e-4 { v += weights[h] * sin(Double(h) * phase) }
                    let burst = plosive && s < 0.005 ? 1.5 * rng.next() * (1 - s / 0.005) : 0
                    syllable[k] = Float(0.25 * envelope * v + 0.4 * burst)
                }
                for k in 0..<count where start + k < n {
                    out[(start + k) * 2] += syllable[k]; out[(start + k) * 2 + 1] += syllable[k]
                }
                time += length + 0.03 + 0.05 * rng.unit()
            }
            time += 0.3 + 0.9 * rng.unit()
        }
        return normalize(out, peakDB: -1)
    }

    /// 50 Hz bass and a kick with 2 ms onsets and offsets (no clicks of its own).
    static func bassKick(seconds: Double) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n * 2)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let onset = beat < 0.005 ? 0.5 - 0.5 * cos(.pi * beat / 0.005) : 1
            let offset = beat > 0.49 ? 0.5 + 0.5 * cos(.pi * (beat - 0.49) / 0.01) : 1
            phase += 2 * .pi * (45 + 75 * exp(-beat / 0.03)) / rate
            let kick = 0.6 * onset * offset * exp(-beat / 0.12) * sin(phase)
            let bass = 0.35 * sin(2 * .pi * 50 * t)
            out[i * 2] = Float(kick + bass); out[i * 2 + 1] = Float(kick + bass)
        }
        return out
    }

    /// The bass line (Magic Boost lifts it at −14 dBFS) with ticks band-limited
    /// to 6–12 kHz, 0.35–1 s apart. The ticks have no energy between 300 Hz
    /// and 2 kHz, so the dynamics' modulation of the bass shows there.
    static func bassWithTicks(seconds: Double, bass: Double = -14, tick tickDB: Double = -6) -> [Float] {
        var x = normalize(bassKick(seconds: seconds), peakDB: bass)
        let taps = 255
        let h: [Double] = (0..<taps).map { m in
            let d = Double(m - taps / 2)
            func low(_ fc: Double) -> Double { d == 0 ? 2 * fc : sin(2 * .pi * fc * d) / (.pi * d) }
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(m) / Double(taps - 1)) + 0.08 * cos(4 * .pi * Double(m) / Double(taps - 1))
            return (low(12000 / rate) - low(6000 / rate)) * w
        }
        var rng = LCG(s: 17)
        var time = 0.5
        let n = x.count / 2
        while time < seconds - 0.2 {
            let burst = (0..<24).map { _ in rng.next() }
            var tick = [Double](repeating: 0, count: 24 + taps - 1)
            for i in 0..<24 { for m in 0..<taps { tick[i + m] += burst[i] * h[m] } }
            let m = tick.reduce(0) { max($0, abs($1)) }
            let start = Int(time * rate)
            for (k, v) in tick.enumerated() where start + k < n {
                let s = Float(v / m * lin(tickDB))
                x[(start + k) * 2] += s; x[(start + k) * 2 + 1] += s
            }
            time += 0.35 + 0.65 * rng.unit()
        }
        return x
    }

    // MARK: - The chains

    /// One app: its MixerBox (user EQ, gain 1) through `Mixer.mix`, block by block.
    final class App {
        let box = MixerBox(gain: 1, muted: false)
        let signal: [Float]
        var input = [Float](repeating: 0, count: N334AirPlayGainStagingTests.block * 2)
        var output = [Float](repeating: 0, count: N334AirPlayGainStagingTests.block * 2)
        init(signal: [Float], eq: [Float]) {
            box.setEffects(app: AudioEQ(sampleRate: N334AirPlayGainStagingTests.rate),
                           master: AudioEQ(gains: eq, sampleRate: N334AirPlayGainStagingTests.rate), appBoost: 0)
            self.signal = signal
        }
        func render(block index: Int) {
            let frames = N334AirPlayGainStagingTests.block, base = index * frames * 2
            for i in 0..<(frames * 2) { input[i] = base + i < signal.count ? signal[base + i] : 0 }
            input.withUnsafeMutableBufferPointer { ip in
                output.withUnsafeMutableBufferPointer { op in
                    var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: ip.baseAddress))
                    var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: op.baseAddress))
                    withUnsafePointer(to: &inList) { i in
                        withUnsafeMutablePointer(to: &outList) { o in Mixer.mix(input: i, output: o, box: box) }
                    }
                }
            }
        }
    }

    /// The 3.3.3 network bus (Magic Boost → limiter) or the 3.3.4 one
    /// (Magic Boost → leveler → limiter, `AppAudioRenderBus.network()`);
    /// `local`: a local output's bus (Magic Boost → −0.2 dBFS limiter), unchanged.
    enum Chain { case shipped, levelled, local }

    struct Run {
        var name = ""
        var chain = Chain.shipped
        var seconds = 0.0
        var sumPeak: Float = 0
        var boostPeak: Float = 0
        /// Per block after warm-up: the limiter's and the leveler's deepest reduction, dB.
        var limiterDB: [Double] = []
        var levelerDB: [Double] = []
        /// Limiter episodes as the bus logs them: deepest dB, length ms.
        var episodes: [(depth: Double, ms: Int)] = []
        /// After warm-up, interleaved: Magic Boost's output and the bus output.
        var boosted: [Float] = []
        var output: [Float] = []
        var latency = 0

        func share(_ values: [Double], over threshold: Double) -> Double {
            Double(values.filter { $0 > threshold }.count) / Double(max(1, values.count))
        }
        var limiterMax: Double { limiterDB.max() ?? 0 }
        var levelerMax: Double { levelerDB.max() ?? 0 }
        /// Blocks with more than 1 dB / 3 dB of reduction in all (leveler and limiter).
        func duckedShare(over threshold: Double) -> Double {
            Double(zip(limiterDB, levelerDB).filter { $0 + $1 > threshold }.count) / Double(max(1, limiterDB.count))
        }
        var outputTruePeak: Float {
            N334AirPlayGainStagingTests.truePeak(N334AirPlayGainStagingTests.channel(output, 0),
                                                 N334AirPlayGainStagingTests.channel(output, 1))
        }
    }

    /// Runs `signals` (one per app) through the chain in 480-frame blocks;
    /// statistics and audio after `warmUp` seconds (Magic Boost's gain climbs first).
    static func play(_ name: String, _ chain: Chain, apps signals: [[Float]], eq: [Float] = userGains,
                     boost: Bool = true, warmUp: Double = 2) -> Run {
        let apps = signals.map { App(signal: $0, eq: eq) }
        let magic = AudioMagicBoost(sampleRate: Self.rate)
        let limiter = chain == .local
            ? AudioLookaheadLimiter(sampleRate: Self.rate, ceiling: AppAudioRenderBus.ceiling)
            : AudioLookaheadLimiter(sampleRate: Self.rate, ceiling: AppAudioRenderBus.networkCeiling, truePeak: true,
                                    releaseSeconds: AppAudioRenderBus.networkRelease)
        // As `AppAudioRenderBus.network()` makes it.
        let leveler: AudioLookaheadLeveler? = chain != .levelled ? nil
            : AudioLookaheadLeveler(sampleRate: Self.rate,
                                    target: limiter.detectionThreshold * AppAudioRenderBus.levelerTargetBelowLimiter)
        let frames = Self.block
        let total = (signals.map { $0.count / 2 }.max() ?? 0) / frames
        let warm = Int(warmUp * Self.rate) / frames
        var left = [Float](repeating: 0, count: frames), right = left
        var result = Run()
        result.name = name; result.chain = chain
        result.seconds = Double((total - warm) * frames) / Self.rate
        result.latency = (leveler?.latencyFrames ?? 0) + limiter.latencyFrames
        result.boosted.reserveCapacity((total - warm) * frames * 2)
        result.output.reserveCapacity((total - warm) * frames * 2)
        var engaged = false, quiet = 0, episodeFrames = 0, episodeDeepest: Float = 1
        for b in 0..<total {
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            for app in apps {
                app.render(block: b)
                for i in 0..<frames { left[i] += app.output[i * 2]; right[i] += app.output[i * 2 + 1] }
            }
            let measured = b >= warm
            if measured { for i in 0..<frames { result.sumPeak = max(result.sumPeak, max(abs(left[i]), abs(right[i]))) } }
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                magic.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames, enabled: boost)
            } }
            if measured {
                for i in 0..<frames {
                    result.boostPeak = max(result.boostPeak, max(abs(left[i]), abs(right[i])))
                    result.boosted.append(left[i]); result.boosted.append(right[i])
                }
            }
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                leveler?.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
                limiter.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
            } }
            let deepest = limiter.takeDeepestReduction()
            let levelled = leveler?.takeDeepestReduction() ?? 1
            if measured {
                for i in 0..<frames { result.output.append(left[i]); result.output.append(right[i]) }
                result.limiterDB.append(-Self.db(Double(deepest)))
                result.levelerDB.append(-Self.db(Double(levelled)))
            }
            // AppAudioRenderBus's episode bookkeeping, block by block.
            if deepest < AppAudioRenderBus.limiterEngageGain {
                if !engaged { engaged = true; episodeFrames = 0; episodeDeepest = deepest }
                episodeDeepest = min(episodeDeepest, deepest)
                quiet = 0
            } else if engaged {
                quiet += frames
                if Double(quiet) >= AppAudioRenderBus.limiterReleaseHoldSeconds * Self.rate {
                    engaged = false
                    if measured { result.episodes.append((-Self.db(Double(episodeDeepest)), episodeFrames * 1000 / Int(Self.rate))) }
                }
            }
            if engaged { episodeFrames += frames }
        }
        if engaged { result.episodes.append((-Self.db(Double(episodeDeepest)), episodeFrames * 1000 / Int(Self.rate))) }
        return result
    }

    // MARK: - Measures

    static func channel(_ x: [Float], _ c: Int) -> [Float] { stride(from: c, to: x.count, by: 2).map { x[$0] } }

    static func truePeak(_ channels: [Float]...) -> Float {
        channels.reduce(0) { max($0, truePeak($1)) }
    }

    /// Reference 4× oversampled peak: three points between every pair of
    /// samples from a 128-tap Kaiser-windowed sinc (β 10), as AudioContinuityTests.
    static func truePeak(_ x: [Float]) -> Float {
        let half = 64, width = 2 * half
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            repeat { term *= (x / 2 / k) * (x / 2 / k); sum += term; k += 1 } while term > sum * 1e-17
            return sum
        }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        guard x.count > width else { return peak }
        let count = x.count - width + 1
        var result = [Float](repeating: 0, count: count)
        for phase in 1...3 {
            let offset = Double(phase) / 4
            let row: [Float] = (0..<width).map { m in
                let d = Double(m - half + 1) - offset
                let r = d / Double(half)
                let sinc = d == 0 ? 1 : sin(.pi * d) / (.pi * d)
                return Float(sinc * bessel(10 * sqrt(max(0, 1 - r * r))) / bessel(10))
            }
            vDSP_conv(x, 1, row, 1, &result, 1, vDSP_Length(count), vDSP_Length(width))
            var maximum: Float = 0
            vDSP_maxmgv(result, 1, &maximum, vDSP_Length(count))
            peak = max(peak, maximum)
        }
        return peak
    }

    /// Energy between `low` and `high` Hz (511-tap Blackman band-pass).
    static func bandEnergy(_ x: [Float], low: Double, high: Double) -> Double {
        let taps = 511
        var h = [Float](repeating: 0, count: taps)
        for m in 0..<taps {
            let d = Double(m - taps / 2)
            func lowPass(_ fc: Double) -> Double { d == 0 ? 2 * fc : sin(2 * .pi * fc * d) / (.pi * d) }
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(m) / Double(taps - 1)) + 0.08 * cos(4 * .pi * Double(m) / Double(taps - 1))
            h[m] = Float((lowPass(high / rate) - lowPass(low / rate)) * w)
        }
        guard x.count > taps else { return 0 }
        let count = x.count - taps + 1
        var y = [Float](repeating: 0, count: count)
        vDSP_conv(x, 1, h, 1, &y, 1, vDSP_Length(count), vDSP_Length(taps))
        var band: Float = 0
        vDSP_svesq(y, 1, &band, vDSP_Length(count))
        return Double(band)
    }

    static func energy(_ x: [Float]) -> Double {
        var e: Float = 0
        vDSP_svesq(x, 1, &e, vDSP_Length(x.count))
        return Double(e)
    }

    /// The output less the input (Magic Boost's output, `delay` frames
    /// earlier) matched by the best gain per 10 ms block: what the dynamics
    /// added beyond a slow gain change (fast modulation and its sidebands).
    static func blockResidual(reference x: [Float], output y: [Float], delay: Int) -> [Float] {
        var residual = [Float](repeating: 0, count: y.count)
        var start = delay
        while start + block <= y.count {
            var xy = 0.0, xx = 0.0
            for n in start..<(start + block) { let a = Double(x[n - delay]); xy += a * Double(y[n]); xx += a * a }
            let g = xx > 0 ? xy / xx : 0
            for n in start..<(start + block) { residual[n] = Float(Double(y[n]) - g * Double(x[n - delay])) }
            start += block
        }
        return residual
    }

    /// `part` relative to `whole`, dB.
    static func share(_ part: Double, of whole: Double) -> Double { 10 * log10(max(part, 1e-30) / max(whole, 1e-30)) }

    static func describe(_ run: Run) -> String {
        let depths = run.episodes.map(\.depth)
        return String(format: "%@ [%@] sum %.1f dBFS, after Magic Boost %.1f dBFS | limiter max %.2f dB, >1 dB in %.1f%% of blocks, >3 dB in %.1f%% | leveler max %.2f dB | ducked >1 dB %.1f%%, >3 dB %.1f%% | output %.2f dBTP | limiter episodes %ld (%@)",
                      run.name, run.chain == .shipped ? "3.3.3" : run.chain == .levelled ? "3.3.4" : "local", db(Double(run.sumPeak)), db(Double(run.boostPeak)),
                      run.limiterMax, 100 * run.share(run.limiterDB, over: 1), 100 * run.share(run.limiterDB, over: 3),
                      run.levelerMax, 100 * run.duckedShare(over: 1), 100 * run.duckedShare(over: 3),
                      db(Double(run.outputTruePeak)), run.episodes.count,
                      depths.prefix(8).map { String(format: "%.1f", $0) }.joined(separator: " "))
    }

    // MARK: - The bus these tests measure

    /// Renders `signals` (one app each, user EQ) through `bus` in 480-frame
    /// blocks, as the AirPlay mix thread does; the output and each block's stages.
    func render(_ bus: AppAudioRenderBus, apps signals: [[Float]], seconds: Double? = nil,
                afterEachBlock: () -> Void = {}) -> (output: [Float], chunks: [AppAudioRenderBus.ChunkDynamics]) {
        for signal in signals {
            let app = App(signal: signal, eq: Self.userGains)
            var index = 0
            bus.add(id: UUID()) { frames, list in
                app.render(block: index)
                index += 1
                let data = UnsafeMutableAudioBufferListPointer(list)[0].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<(frames * 2) { data[i] = app.output[i] }
            }
        }
        var block = [Float](repeating: 0, count: Self.block * 2)
        var output: [Float] = [], chunks: [AppAudioRenderBus.ChunkDynamics] = []
        let blocks = seconds.map { Int($0 * Self.rate) / Self.block } ?? (signals.map { $0.count }.max() ?? 0) / 2 / Self.block
        for _ in 0..<blocks {
            block.withUnsafeMutableBufferPointer { pointer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                withUnsafeMutablePointer(to: &list) { bus.render(frames: Self.block, output: $0, allowWaiting: true) }
            }
            output += block
            chunks.append(bus.lastChunk)
            afterEachBlock()
        }
        return (output, chunks)
    }

    static func largestDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// `AppAudioRenderBus.network()` is the levelled chain measured below,
    /// sample for sample (two apps, output Magic Boost on); a local output's
    /// bus is still the 3.3.3 chain (Magic Boost → −0.2 dBFS limiter), with
    /// its latency unchanged.
    func testTheNetworkBusIsTheLevelledChainTheseTestsMeasure() {
        let signals = [Self.sparseHits(seconds: 6, bed: -30, hit: -3), Self.normalize(Self.pink(seconds: 6), peakDB: -30)]
        let expected = Self.play("bus", .levelled, apps: signals, warmUp: 0)
        let bus = AppAudioRenderBus.network()
        XCTAssertTrue(bus.levels)
        XCTAssertEqual(bus.limiterCeiling, AppAudioRenderBus.networkCeiling)
        XCTAssertEqual(bus.dynamicsLatencyFrames, AudioMagicBoost.lookaheadFrames + expected.latency)
        XCTAssertEqual(expected.latency, 480 + 32 + 64 + 32, "10 ms more than 3.3.3 on AirPlay")
        bus.setBoostLevel(1)
        let rendered = render(bus, apps: signals)
        XCTAssertEqual(rendered.output.count, expected.output.count)
        XCTAssertLessThanOrEqual(Self.largestDifference(rendered.output, expected.output), 1e-6, "the bus is the chain")
        XCTAssertEqual(rendered.chunks.map { -Self.db(Double($0.levelerGain)) }.max() ?? 0, expected.levelerMax, accuracy: 0.01)
        XCTAssertGreaterThan(expected.levelerMax, 3, "the material makes the leveler work")

        let local = AppAudioRenderBus()
        XCTAssertFalse(local.levels, "local outputs keep Magic Boost → limiter")
        XCTAssertEqual(local.dynamicsLatencyFrames, AudioMagicBoost.lookaheadFrames + 64, "local latency unchanged")
        local.setBoostLevel(1)
        let localExpected = Self.play("local", .local, apps: signals, warmUp: 0)
        let localRendered = render(local, apps: signals)
        XCTAssertLessThanOrEqual(Self.largestDifference(localRendered.output, localExpected.output), 1e-6,
                                 "a local bus is the 3.3.3 chain")
        XCTAssertTrue(localRendered.chunks.allSatisfy { $0.levelerGain == 1 && $0.levelerInputPeak == 0 })
    }

    // MARK: - Gain staging

    /// The live log's engagements, reproduced: Magic Boost lifts a quiet bed
    /// and passes short transients with most of that gain, and the 3.3.3
    /// limiter takes several dB off each within 1.3 ms. On the 3.3.4 bus the
    /// leveler takes them over 10 ms instead: the fast stage stays under
    /// 1 dB, the output under −1 dBTP.
    func testBoostedTransientsNoLongerMakeTheFastLimiterWork() {
        let s = 14.0
        let cases: [(String, [[Float]], [Float])] = [
            ("hits −3 over a −30 bed", [Self.sparseHits(seconds: s, bed: -30, hit: -3)], Self.userGains),
            ("hits −3 over a −20 bed, a second app at −40", [Self.sparseHits(seconds: s, bed: -20, hit: -3),
                                                             Self.normalize(Self.pink(seconds: s, seed: 3), peakDB: -40)], Self.userGains),
            ("clicks −6 over a −30 bed", [Self.sparseHits(seconds: s, bed: -30, hit: -6, kinds: [0])], Self.userGains),
            ("speech", [Self.speech(seconds: s)], Self.userGains),
            ("speech, flat EQ", [Self.speech(seconds: s)], Self.flat),
        ]
        for (name, signals, eq) in cases {
            let before = Self.play(name, .shipped, apps: signals, eq: eq)
            let after = Self.play(name, .levelled, apps: signals, eq: eq)
            print("N334 " + Self.describe(before))
            print("N334 " + Self.describe(after))
            XCTAssertGreaterThan(before.limiterMax, 3, "\(name): the 3.3.3 limiter works as in the live log")
            XCTAssertLessThanOrEqual(after.share(after.limiterDB, over: 1), 0.01, "\(name): the fast stage rarely passes 1 dB")
            XCTAssertLessThanOrEqual(after.limiterMax, 1, "\(name)")
            XCTAssertLessThanOrEqual(after.outputTruePeak, AppAudioRenderBus.networkCeiling, "\(name): −1 dBTP kept")
            XCTAssertGreaterThan(after.levelerMax, 2, "\(name): the leveler did the work")
        }
    }

    /// Hot float sources and summed apps: the fast stage stays under 1 dB
    /// almost all the time and the output under −1 dBTP.
    func testHotAndSummedSourcesLeaveTheFastLimiterUnderOneDecibel() {
        let s = 12.0
        let cases: [(String, [[Float]])] = [
            ("pop at +6 dBFS", [Self.normalize(Self.pop(seconds: s), peakDB: 6)]),
            ("pop and pink at +3 dBFS, two apps", [Self.normalize(Self.pop(seconds: s), peakDB: 3),
                                                   Self.normalize(Self.pink(seconds: s), peakDB: 3)]),
            ("a master clipped 8 dB into full scale", [Self.brickwall(Self.pop(seconds: s), drive: 8)]),
            ("pop at −0.2 dBFS", [Self.normalize(Self.pop(seconds: s), peakDB: -0.2)]),
        ]
        for (name, signals) in cases {
            let before = Self.play(name, .shipped, apps: signals)
            let after = Self.play(name, .levelled, apps: signals)
            print("N334 " + Self.describe(before))
            print("N334 " + Self.describe(after))
            XCTAssertLessThanOrEqual(after.share(after.limiterDB, over: 1), 0.01, "\(name)")
            XCTAssertLessThanOrEqual(after.limiterMax, max(1, before.limiterMax), "\(name): never more than before")
            XCTAssertLessThanOrEqual(after.outputTruePeak, AppAudioRenderBus.networkCeiling, "\(name): −1 dBTP kept")
        }
    }

    /// The distortion the user hears: what the dynamics do to the music
    /// beyond a slow gain change. Measured as the residual once the output is
    /// matched to Magic Boost's output by the best gain per 10 ms block, in
    /// all and, for a bass line under 6–12 kHz ticks, between 300 Hz and
    /// 2 kHz, where the bass's modulation sidebands land: the 3.3.3 limiter
    /// dips within 1.3 ms, the leveler over 10 ms. One case leaves Magic
    /// Boost off and drives the ticks hot, so only the dynamics differ.
    func testTheLevelerDistortsLessThanTheShippedLimiter() {
        let cases: [(String, [Float], Bool)] = [
            ("bass + kick under boosted ticks", Self.bassWithTicks(seconds: 14), true),
            ("bass + kick under +8 dBFS ticks, Magic Boost off", Self.bassWithTicks(seconds: 14, bass: -6, tick: 8), false),
            ("hits −3 over a −30 bed", Self.sparseHits(seconds: 14, bed: -30, hit: -3), true),
            ("speech", Self.speech(seconds: 14), true),
        ]
        for (name, signal, boost) in cases {
            let before = Self.play(name, .shipped, apps: [signal], boost: boost)
            let after = Self.play(name, .levelled, apps: [signal], boost: boost)
            XCTAssertEqual(before.boosted, after.boosted, "the same Magic Boost output goes into both")
            let reference = Self.channel(before.boosted, 0)
            let old = Self.channel(before.output, 0), new = Self.channel(after.output, 0)
            let oldResidual = Self.blockResidual(reference: reference, output: old, delay: before.latency)
            let newResidual = Self.blockResidual(reference: reference, output: new, delay: after.latency)
            let oldAll = Self.share(Self.energy(oldResidual), of: Self.energy(old))
            let newAll = Self.share(Self.energy(newResidual), of: Self.energy(new))
            let oldBand = Self.share(Self.bandEnergy(oldResidual, low: 300, high: 2000), of: Self.energy(old))
            let newBand = Self.share(Self.bandEnergy(newResidual, low: 300, high: 2000), of: Self.energy(new))
            print("N334 " + Self.describe(before))
            print("N334 " + Self.describe(after))
            print(String(format: "N334 %@: residual after a 10 ms gain match %.1f dB (3.3.3) → %.1f dB (3.3.4); in 300 Hz–2 kHz %.1f → %.1f dB",
                         name, oldAll, newAll, oldBand, newBand))
            XCTAssertGreaterThan(before.limiterMax, 3, "\(name): the 3.3.3 limiter works hard on this")
            XCTAssertLessThan(newAll, oldAll - 4, "\(name): less distortion than 3.3.3")
            if name.hasPrefix("bass") { XCTAssertLessThan(newBand, oldBand - 3, "\(name): less modulation of the bass") }
            XCTAssertLessThanOrEqual(after.limiterMax, 1, "\(name)")
            XCTAssertLessThanOrEqual(after.outputTruePeak, AppAudioRenderBus.networkCeiling, "\(name)")
        }
    }

    // MARK: - Magic Boost near silence

    /// The 3.3.3 Magic Boost (Music, as Audio333Tests' reference): its release
    /// slowed to a hundredth only over blocks of exact zeros.
    private final class ShippedBoost {
        let rateScale = Float(44100 / N334AirPlayGainStagingTests.rate)
        let fadeStep = Float(1 / (0.04 * N334AirPlayGainStagingTests.rate))
        var delay = [Float](repeating: 0, count: 1024)
        var writeIndex = 0, filled = 0
        var gain: Float = 1, knee: Float = 1, mix: Float = 0
        func process(_ samples: inout [Float], frames: Int) {
            var silent = true
            for frame in 0..<frames where samples[frame] != 0 { silent = false; break }
            let release = AudioMagicBoost.releaseRate * rateScale * (silent ? 0.01 : 1)
            let attack = AudioMagicBoost.attackRate * rateScale
            for frame in 0..<frames {
                let input = samples[frame]
                let slot = writeIndex * 2
                let delayed = delay[slot]
                delay[slot] = input; delay[slot + 1] = input
                writeIndex += 1
                if writeIndex == 512 { writeIndex = 0 }
                if filled < 512 { filled += 1 }
                detect(input, attack, release); detect(input, attack, release)
                if filled >= 512 && mix < 1 { mix = min(1, mix + fadeStep) }
                samples[frame] = input + (delayed * AudioMagicBoost.outputGain(gain) - input) * mix
            }
        }
        private func detect(_ sample: Float, _ attack: Float, _ release: Float) {
            guard sample != 0 else { return }
            if abs(sample * gain) > AudioMagicBoost.threshold {
                gain = max(0.0001, gain - max(gain, 1) * attack)
                if knee > 1 { knee = max(1, knee - AudioMagicBoost.kneeAttackDrop) }
            } else {
                let next = gain + release * knee
                if next < AudioMagicBoost.maximumGain { gain = next }
                if knee < AudioMagicBoost.kneeCeiling { knee += AudioMagicBoost.kneeStep }
            }
        }
    }

    /// Mono through Magic Boost in the mix thread's blocks: 3.3.4's, or 3.3.3's.
    private func boosted(_ signal: [Float], shipped: Bool = false) -> [Float] {
        let current = AudioMagicBoost(sampleRate: Self.rate), old = ShippedBoost()
        var output: [Float] = []
        output.reserveCapacity(signal.count)
        var left = [Float](repeating: 0, count: Self.block), right = left
        var index = 0
        while index < signal.count {
            let count = min(Self.block, signal.count - index)
            for frame in 0..<count { left[frame] = signal[index + frame]; right[frame] = signal[index + frame] }
            if shipped {
                old.process(&left, frames: count)
            } else {
                left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                    current.process(left: l.baseAddress!, right: r.baseAddress!, frames: count, enabled: true)
                } }
            }
            output += left[..<count]
            index += count
        }
        return output
    }

    private static func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }

    /// Noise under −60 dBFS (a quiet passage's codec or room noise) is no
    /// longer lifted about +34 dB over the next 11 s: a few dB in 15 s.
    /// Digital silence, and anything at or above −60 dBFS, is boosted sample
    /// for sample as in 3.3.3 (so Audio333Tests' Music reference holds).
    func testMagicBoostNoLongerLiftsNearSilenceAndLeavesTheRestAsItWas() {
        let noise = Self.channel(Self.normalize(Self.pink(seconds: 15, seed: 13), peakDB: -66), 0)
        func rise(_ output: [Float]) -> Double {
            let last = (output.count - Int(Self.rate))..<output.count
            return Self.db(Self.rms(output[last])) - Self.db(Self.rms(noise[last]))
        }
        let then = rise(boosted(noise, shipped: true)), now = rise(boosted(noise))
        var rises: [String] = []
        for seconds in [5.0, 10, 15] {
            let cut = Array(noise.prefix(Int(seconds * Self.rate)))
            let last = (cut.count - Int(Self.rate))..<cut.count
            let a = boosted(cut, shipped: true), b = boosted(cut)
            rises.append(String(format: "%.0f s: %.1f → %.1f dB", seconds, Self.db(Self.rms(a[last])) - Self.db(Self.rms(cut[last])),
                                Self.db(Self.rms(b[last])) - Self.db(Self.rms(cut[last]))))
        }
        print("N334 −66 dBFS noise through Magic Boost, lift 3.3.3 → 3.3.4: " + rises.joined(separator: ", "))
        XCTAssertGreaterThan(then, 25, "3.3.3 lifted it by about +34 dB")
        XCTAssertLessThan(now, 6, "a few dB at most")
        // At or above the floor nothing changes: −45 dBFS noise, a tone after
        // digital silence, a quiet tone (Audio333Tests pins Music's output).
        let audible = Self.channel(Self.normalize(Self.pink(seconds: 4, seed: 21), peakDB: -45), 0)
        XCTAssertEqual(boosted(audible), boosted(audible, shipped: true))
        let tone = (0..<96000).map { Float(0.1 * sin(2 * Double.pi * 220 * Double($0) / Self.rate)) }
        let pause = [Float](repeating: 0, count: 96000) + tone
        let paused = boosted(pause)
        XCTAssertEqual(paused, boosted(pause, shipped: true))
        XCTAssertTrue(paused.prefix(96000).allSatisfy { $0 == 0 }, "digital silence stays silent")
        let quiet = tone.map { $0 * 0.05 }
        XCTAssertEqual(boosted(quiet), boosted(quiet, shipped: true))
        XCTAssertEqual(AudioMagicBoost.nearSilence, Float(Self.lin(-60)), accuracy: 1e-6)
    }

    // MARK: - Diagnostics

    /// The ring's kinds keep their raw values (the leveler's two come last)
    /// and its layout: a limiter or leveler record's `extra` now packs the
    /// stage's input peak, the apps' summed peak and the other stage's
    /// reduction (and, on release, the length as before).
    func testDynamicsEventsCarryTheInputPeakTheOtherStageAndTheAppsSum() throws {
        XCTAssertEqual(AudioEventKind.limiterEngaged.rawValue, 6)
        XCTAssertEqual(AudioEventKind.limiterReleased.rawValue, 7)
        XCTAssertEqual(AudioEventKind.effectChanged.rawValue, 24)
        XCTAssertEqual(AudioEventKind.levelerEngaged.rawValue, 25)
        XCTAssertEqual(AudioEventKind.levelerReleased.rawValue, 26)
        let reading = AudioDynamicsReading(inputPeak: Float(Self.lin(4.6)), sumPeak: Float(Self.lin(-5.4)),
                                           otherGain: Float(Self.lin(-3.1)))
        let decoded = AudioDynamicsReading.decode(reading.packed(durationMS: 2190))
        XCTAssertEqual(decoded.durationMS, 2190)
        XCTAssertEqual(try XCTUnwrap(decoded.inputPeakDB), 4.6, accuracy: 0.011)
        XCTAssertEqual(try XCTUnwrap(decoded.sumPeakDB), -5.4, accuracy: 0.011)
        XCTAssertEqual(decoded.otherReductionDB, 3.1, accuracy: 0.011)
        XCTAssertEqual(AudioDynamicsReading.decode(2190),
                       .init(durationMS: 2190, inputPeakDB: nil, sumPeakDB: nil, otherReductionDB: 0),
                       "a 3.3.3 release record (its length only) still reads")
        XCTAssertEqual(AudioDynamicsReading.decode(AudioDynamicsReading().packed(durationMS: .max)).durationMS,
                       Int(AudioDynamicsReading.durationMask), "a long episode saturates")

        // A local bus (no leveler): a 200 Hz sine 4 dB over its ceiling for 1 s.
        let log = AudioEventLog(polls: false)
        let local = AppAudioRenderBus()
        log.register(name: "output:speakers", rings: [local.events])
        var loud = true, sample = 0
        local.add(id: UUID()) { frames, list in
            let data = UnsafeMutableAudioBufferListPointer(list)[0].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let value: Float = loud ? Float(1.6 * sin(2 * Double.pi * 200 * Double(sample) / 48000)) : 0
                data[frame * 2] = value; data[frame * 2 + 1] = value
                sample += 1
            }
        }
        _ = render(local, apps: [], seconds: 1) { log.poll() }
        loud = false
        _ = render(local, apps: [], seconds: 2.5) { log.poll() }
        let localEvents = log.snapshot().events
        let engaged = try XCTUnwrap(localEvents.first { $0.kind == .limiterEngaged })
        XCTAssertEqual(engaged.json["inputPeakDBFS"] as? Double ?? 0, Self.db(1.6), accuracy: 0.05, "\(engaged.json)")
        XCTAssertEqual(engaged.json["appsPeakDBFS"] as? Double ?? 0, Self.db(1.6), accuracy: 0.05)
        XCTAssertEqual(engaged.json["levelerDB"] as? Double, 0, "no leveler on a local output")
        let released = try XCTUnwrap(localEvents.first { $0.kind == .limiterReleased })
        XCTAssertEqual(Double(released.json["durationMS"] as? Int ?? 0), 3000, accuracy: 100, "1 s and the 2 s hold")
        XCTAssertGreaterThan(released.json["reductionDB"] as? Double ?? 0, 3)
        XCTAssertTrue(released.detail.hasPrefix("engaged for "), released.detail)
        XCTAssertTrue(released.detail.contains("input peak +4.1 dBFS"), released.detail)
        print("N334 local limiter events: \(engaged.json) / \(released.json)")

        // A network bus with output Magic Boost: boosted transients over a
        // quiet bed engage the leveler; the limiter stays out of it.
        let network = AppAudioRenderBus.network()
        network.setBoostLevel(1)
        let networkLog = AudioEventLog(polls: false)
        networkLog.register(name: "output:homepod", rings: [network.events]) {
            ["output.levelerEngagements": network.levelerEngagements.load(),
             "output.limiterEngagements": network.limiterEngagements.load()]
        }
        _ = render(network, apps: [Self.sparseHits(seconds: 8, bed: -30, hit: -3)], seconds: 11) { networkLog.poll() }
        let snapshot = networkLog.snapshot()
        let leveled = snapshot.events.filter { $0.kind == .levelerEngaged }
        let first = try XCTUnwrap(leveled.first)
        print("N334 network leveler events: \(snapshot.events.filter { $0.kind.isDynamics }.map(\.json))")
        XCTAssertEqual(snapshot.events.filter { $0.kind == .limiterEngaged }.count, 0, "the limiter only guards the ceiling")
        XCTAssertGreaterThan(first.json["reductionDB"] as? Double ?? 0, 1)
        XCTAssertGreaterThan(first.json["inputPeakDBFS"] as? Double ?? -100, -0.4, "over the leveler's target by more than 1 dB")
        XCTAssertLessThan(first.json["appsPeakDBFS"] as? Double ?? 0, -3, "while the apps' sum was not: Magic Boost lifted it")
        XCTAssertEqual(first.json["limiterDB"] as? Double, 0)
        let levelerReleased = try XCTUnwrap(snapshot.events.first { $0.kind == .levelerReleased })
        XCTAssertGreaterThan(levelerReleased.json["durationMS"] as? Int ?? 0, 2000)
        XCTAssertGreaterThan(levelerReleased.json["inputPeakDBFS"] as? Double ?? -100, 0, "at its deepest, over full scale")
        XCTAssertTrue(levelerReleased.detail.contains("limiter 0.0 dB"), levelerReleased.detail)
        XCTAssertEqual(snapshot.sinceReset["output.levelerEngagements"], UInt64(leveled.count))
        XCTAssertNil(snapshot.sinceReset["output.limiterEngagements"])
    }
}
