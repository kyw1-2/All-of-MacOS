import Foundation

/// SoundSource-style 10-band equalizer, applied inside the per-app tap's
/// realtime mix path. Peaking biquads (RBJ cookbook) cascaded per band; the
/// lowest and highest bands are shelves, like a classic graphic EQ.
///
/// Runtime filtering uses AudioEQProcessor: coefficients are prepared on the
/// control thread, while separate channel histories live on the audio thread.
/// MixerBox synchronizes configuration handoff without blocking rendering.
struct AudioEQ: Equatable {
    static let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let presetFlat = [Float](repeating: 0, count: 10)
    static let presets: [String: [Float]] = [
        "Flat": presetFlat,
        "Bass Boost": [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
        "Treble Boost": [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],
        "Vocal": [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1],
        "Small Speakers": [5, 4, 3, 1, -1, -1, 0, 2, 3, 3],
        "Acoustic": [4, 4, 3, 1, 2, 2, 3, 3, 3, 2],
        "Classical": [5, 4, 3, 3, -1, -1, 0, 2, 3, 4],
        "Electronic": [5, 4, 2, 0, -2, 2, 1, 2, 4, 5],
        "Hip-Hop": [6, 5, 2, 3, -1, -1, 1, -1, 2, 3],
        "Jazz": [4, 3, 1, 2, -2, -2, 0, 1, 3, 4],
        "Pop": [-1, 1, 3, 4, 4, 3, 0, -1, -1, -1],
        "Rock": [5, 4, 3, 1, -1, -1, 1, 3, 4, 5],
        "Spoken Word": [-3, 0, 1, 3, 5, 5, 4, 2, 0, -2]
    ]

    let gains: [Float] // dB per band, -12...12
    let sampleRate: Double

    init(gains: [Float] = AudioEQ.presetFlat, sampleRate: Double = 48000) {
        self.gains = (0..<10).map { index in
            guard index < gains.count, gains[index].isFinite else { return 0 }
            return min(12, max(-12, gains[index]))
        }
        self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
    }

    var isEnabled: Bool { gains.contains { $0 != 0 } }

    struct Coefficients: Equatable {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
    }

    /// RBJ peaking EQ; shelves at the outer bands.
    static func bandCoefficients(band: Int, gainDb: Float, sampleRate: Double) -> Coefficients {
        let frequency = bandFrequencies[band]
        let A = pow(10, gainDb / 40)
        let w0 = 2 * .pi * min(frequency, sampleRate / 2.05) / sampleRate
        let cosw0 = Float(cos(w0)), sinw0 = Float(sin(w0))
        // Q ~1.1: one band touches its neighbours' skirt, like a graphic EQ.
        let alpha = sinw0 / (2 * 1.1)
        func make(_ b0: Float, _ b1: Float, _ b2: Float, _ a0: Float, _ a1: Float, _ a2: Float) -> Coefficients {
            Coefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }
        if band == 0 {
            // Low shelf.
            let sq = 2 * sqrt(A) * alpha
            return make(A * ((A + 1) - (A - 1) * cosw0 + sq),
                        2 * A * ((A - 1) - (A + 1) * cosw0),
                        A * ((A + 1) - (A - 1) * cosw0 - sq),
                        (A + 1) + (A - 1) * cosw0 + sq,
                        -2 * ((A - 1) + (A + 1) * cosw0),
                        (A + 1) + (A - 1) * cosw0 - sq)
        }
        if band == bandFrequencies.count - 1 {
            // High shelf.
            let sq = 2 * sqrt(A) * alpha
            return make(A * ((A + 1) + (A - 1) * cosw0 + sq),
                        -2 * A * ((A - 1) + (A + 1) * cosw0),
                        A * ((A + 1) + (A - 1) * cosw0 - sq),
                        (A + 1) - (A - 1) * cosw0 + sq,
                        2 * ((A - 1) - (A + 1) * cosw0),
                        (A + 1) - (A - 1) * cosw0 - sq)
        }
        return make(1 + alpha * A, -2 * cosw0, 1 - alpha * A,
                    1 + alpha / A, -2 * cosw0, 1 - alpha / A)
    }

    var coefficients: [Coefficients] {
        (0..<10).map { Self.bandCoefficients(band: $0, gainDb: gains[$0], sampleRate: sampleRate) }
    }

    /// Reserve the actual peak gain of the combined EQ curve before filtering.
    /// Adding positive slider values overestimates overlapping bands; taking
    /// only the largest slider underestimates them and still clips hot mixes.
    /// This calculation runs on the control thread when the curve changes.
    static func headroomGain(app: AudioEQ, master: AudioEQ) -> Float {
        guard app.isEnabled || master.isEnabled else { return 1 }
        let filters = [(app, app.coefficients), (master, master.coefficients)]
        let nyquist = min(app.sampleRate, master.sampleRate) / 2
        let low = min(10, nyquist / 100)
        let frequencies = [0, nyquist] + bandFrequencies.filter { $0 < nyquist } +
            (0...512).map { low * pow(nyquist / low, Double($0) / 512) }
        var maximum: Double = 1
        for frequency in frequencies {
            var magnitude: Double = 1
            for (eq, coefficients) in filters {
                let w = 2 * Double.pi * frequency / eq.sampleRate
                let c1 = cos(w), c2 = cos(2 * w), s1 = sin(w), s2 = sin(2 * w)
                for band in 0..<10 where eq.gains[band] != 0 {
                    let c = coefficients[band]
                    let numerator = hypot(Double(c.b0) + Double(c.b1) * c1 + Double(c.b2) * c2,
                                          Double(c.b1) * s1 + Double(c.b2) * s2)
                    let denominator = hypot(1 + Double(c.a1) * c1 + Double(c.a2) * c2,
                                            Double(c.a1) * s1 + Double(c.a2) * s2)
                    if denominator > 0 { magnitude *= numerator / denominator }
                }
            }
            if magnitude.isFinite { maximum = max(maximum, magnitude) }
        }
        return maximum > 1.0001 ? Float(1 / (maximum * 1.01)) : 1
    }

    /// One biquad over a deinterleaved run. Pure: state comes in and goes out.
    static func runBiquad(_ c: Coefficients, input: [Float], state: (Float, Float)) -> ([Float], (Float, Float)) {
        var x1 = state.0, x2 = state.1
        var y1: Float = 0, y2: Float = 0
        var output = [Float](repeating: 0, count: input.count)
        for index in input.indices {
            let x0 = input[index]
            let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            output[index] = y0
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
        }
        return (output, (x1, x2))
    }

    /// Whole EQ over a mono run — the unit-test surface (allocates freely).
    /// Zero-dB bands are skipped entirely: they are identities, and running
    /// them anyway costs float rounding for no effect.
    func process(_ input: [Float]) -> [Float] {
        var signal = input
        for band in 0..<10 where gains[band] != 0 {
            let c = Self.bandCoefficients(band: band, gainDb: gains[band], sampleRate: sampleRate)
            (signal, _) = Self.runBiquad(c, input: signal, state: (0, 0))
        }
        return signal
    }

    /// Realtime variant: reuses caller-owned scratch buffers, zero allocation.
    func process(into output: UnsafeMutablePointer<Float32>, input: UnsafePointer<Float32>, frames: Int,
                 scratch: UnsafeMutablePointer<Float32>) {
        guard isEnabled, frames > 0 else {
            for frame in 0..<frames { output[frame] = input[frame] }
            return
        }
        var source: UnsafePointer<Float32> = input
        var usingScratch = false
        for band in 0..<10 where gains[band] != 0 {
            let c = Self.bandCoefficients(band: band, gainDb: gains[band], sampleRate: sampleRate)
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            let destination = usingScratch ? output : scratch
            for frame in 0..<frames {
                let x0 = source[frame]
                let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                destination[frame] = y0
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
            }
            source = UnsafePointer(usingScratch ? output : scratch)
            usingScratch.toggle()
        }
        if source != output {
            for frame in 0..<frames { output[frame] = source[frame] }
        }
    }
}

/// Each session owns two channel histories which survive IO callbacks.
/// Coefficients are prepared on the control thread, never per audio sample.
/// Realtime code uses the block method: coefficients and Direct Form II
/// transposed histories live in preallocated memory, so the render thread
/// performs no allocation, reference counting or exclusivity checks.
final class AudioEQProcessor {
    let eq: AudioEQ
    /// Only bands with a nonzero gain are processed; 0 dB is an identity.
    let sectionCount: Int
    private let coefficients: UnsafeMutablePointer<Float> // b0 b1 b2 a1 a2 per section
    private let state: UnsafeMutablePointer<Float>        // z1 z2 per section per channel

    init(_ eq: AudioEQ) {
        self.eq = eq
        let active = (0..<10).filter { eq.gains[$0] != 0 }
        sectionCount = active.count
        coefficients = .allocate(capacity: max(1, active.count) * 5)
        coefficients.initialize(repeating: 0, count: max(1, active.count) * 5)
        state = .allocate(capacity: max(1, active.count) * 4)
        state.initialize(repeating: 0, count: max(1, active.count) * 4)
        let all = eq.coefficients
        for (section, band) in active.enumerated() {
            let c = all[band]
            coefficients[section * 5] = c.b0; coefficients[section * 5 + 1] = c.b1
            coefficients[section * 5 + 2] = c.b2; coefficients[section * 5 + 3] = c.a1
            coefficients[section * 5 + 4] = c.a2
        }
    }

    deinit { coefficients.deallocate(); state.deallocate() }

    var isIdentity: Bool { sectionCount == 0 }

    func reset() { for i in 0..<(max(1, sectionCount) * 4) { state[i] = 0 } }

    /// Per-sample entry point (tests and non-realtime callers).
    func process(_ sample: Float, channel: Int) -> Float {
        guard (0..<2).contains(channel) else { return 0 }
        var value = sample.isFinite ? sample : 0
        withUnsafeMutablePointer(to: &value) { process($0, frames: 1, channel: channel) }
        return value
    }

    /// In place over one deinterleaved channel.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        guard sectionCount > 0, frames > 0, (0..<2).contains(channel) else { return }
        for section in 0..<sectionCount {
            let c = coefficients + section * 5
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
            let z = state + (section * 2 + channel * sectionCount * 2)
            var z1 = z[0], z2 = z[1]
            for frame in 0..<frames {
                let x = buffer[frame]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                buffer[frame] = y
            }
            guard z1.isFinite, z2.isFinite, buffer[frames - 1].isFinite else {
                // One malformed/overflowing block must not poison the band's
                // persistent history and silence this channel until reconnect.
                z[0] = 0; z[1] = 0
                for frame in 0..<frames { buffer[frame] = 0 }
                continue
            }
            z[0] = z1; z[1] = z2
        }
    }
}
