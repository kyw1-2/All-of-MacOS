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
final class AudioEQProcessor {
    let eq: AudioEQ
    private let coefficients: [AudioEQ.Coefficients]
    private var z1 = [Float](repeating: 0, count: 20)
    private var z2 = [Float](repeating: 0, count: 20)
    init(_ eq: AudioEQ) { self.eq = eq; coefficients = eq.coefficients }

    func process(_ sample: Float, channel: Int) -> Float {
        guard (0..<2).contains(channel) else { return 0 }
        var value = sample.isFinite ? sample : 0
        for band in 0..<10 where eq.gains[band] != 0 {
            let index = channel * 10 + band
            let c = coefficients[band]
            let output = c.b0 * value + z1[index]
            let nextZ1 = c.b1 * value - c.a1 * output + z2[index]
            let nextZ2 = c.b2 * value - c.a2 * output
            guard output.isFinite, nextZ1.isFinite, nextZ2.isFinite else {
                // One malformed/overflowing sample must not poison the band's
                // persistent history and silence this channel until reconnect.
                z1[index] = 0; z2[index] = 0; value = 0
                continue
            }
            z1[index] = nextZ1
            z2[index] = nextZ2
            value = output
        }
        return value
    }
}

/// AOM's linked stereo compressor with makeup gain. This is not a copy of
/// SoundSource's proprietary algorithm. State persists between buffers;
/// attack/release smooth changes instead of distorting every sample with tanh.
final class AudioAdaptiveBoost {
    private let envelopeAttack: Float
    private let envelopeRelease: Float
    private let gainAttack: Float
    private let gainRelease: Float
    private var envelope: Float = 0
    private var gain: Float = 1
    private var targetGain: Float = 1
    private var controlFrame = 0
    private var previousLevel = 0

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        envelopeAttack = Float(exp(-1 / (0.003 * rate)))
        envelopeRelease = Float(exp(-1 / (0.150 * rate)))
        gainAttack = Float(exp(-1 / (0.005 * rate)))
        gainRelease = Float(exp(-1 / (0.100 * rate)))
    }

    func process(left: inout Float, right: inout Float, level: Int) {
        left = left.isFinite ? left : 0
        right = right.isFinite ? right : 0
        let peak = max(abs(left), abs(right))
        let coefficient = peak > envelope ? envelopeAttack : envelopeRelease
        envelope = coefficient * envelope + (1 - coefficient) * peak
        let strength = min(3, max(0, level))
        if strength == 0 {
            targetGain = 1
        } else if controlFrame == 0 || strength != previousLevel {
            let threshold: Float = strength == 1 ? 0.28 : (strength == 2 ? 0.22 : 0.18)
            let ratio: Float = Float(strength + 1)
            let makeup: Float = strength == 1 ? 1.5 : (strength == 2 ? 2 : 2.5)
            let reduction = envelope > threshold ? pow(threshold / envelope, 1 - 1 / ratio) : 1
            // Do not raise a silent/noise-only input toward the makeup level.
            targetGain = envelope < 0.001 ? 1 : min(makeup, makeup * reduction)
        }
        previousLevel = strength
        controlFrame = (controlFrame + 1) & 31
        let smoothing = targetGain < gain ? gainAttack : gainRelease
        gain = smoothing * gain + (1 - smoothing) * targetGain
        left *= gain; right *= gain
    }
}
