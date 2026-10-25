import Foundation

/// SoundSource-style 10-band equalizer, applied inside the per-app tap's
/// realtime mix path. Peaking biquads (RBJ cookbook) cascaded per band; the
/// lowest and highest bands are shelves, like a classic graphic EQ.
///
/// Realtime rules: `process` allocates nothing and locks nothing. UI updates
/// build a fresh `AudioEQ` value and swap the reference — the audio thread
/// keeps rendering the old one until the swap lands.
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
        self.gains = Array(gains.prefix(10))
        self.sampleRate = max(1, sampleRate)
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

/// The audio-thread-side EQ holder: value swapped atomically by reference.
/// A plain class-property write of a value type is not torn, so the mix path
/// reads `current` once per cycle and uses it for the whole buffer.
final class EQBox {
    var current: AudioEQ
    init(_ eq: AudioEQ) { current = eq }
}
