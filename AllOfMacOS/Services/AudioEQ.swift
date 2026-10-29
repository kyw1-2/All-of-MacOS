import Foundation

/// SoundSource-style 10-band equalizer, applied inside the per-app tap's
/// realtime mix path. Peaking biquads (RBJ cookbook) cascaded per band; the
/// lowest and highest bands are shelves, like a classic graphic EQ.
///
/// Runtime filtering uses AudioEQProcessor: coefficients are prepared on the
/// control thread, while separate channel histories live on the audio thread.
/// MixerBox synchronizes configuration handoff without blocking rendering.
///
/// 3.3.3 (parity S04): a second 10-band stage, `deviceGains`, carries the
/// output device's own EQ (a headphone correction) after the curve in
/// `gains`; both run as one cascade, so the headroom covers both.
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
    /// The output device's EQ, the same ten bands after `gains` (flat: none).
    let deviceGains: [Float]
    let sampleRate: Double

    init(gains: [Float] = AudioEQ.presetFlat, sampleRate: Double = 48000, deviceGains: [Float] = AudioEQ.presetFlat) {
        self.gains = Self.clamped(gains)
        self.deviceGains = Self.clamped(deviceGains)
        self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
    }

    /// Ten finite values within ±12 dB (missing bands are 0).
    static func clamped(_ values: [Float]) -> [Float] {
        (0..<10).map { index in
            guard index < values.count, values[index].isFinite else { return 0 }
            return min(12, max(-12, values[index]))
        }
    }

    var isEnabled: Bool { gains.contains { $0 != 0 } || deviceGains.contains { $0 != 0 } }

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

    /// The first stage's ten bands (0 dB bands included).
    var coefficients: [Coefficients] {
        (0..<10).map { Self.bandCoefficients(band: $0, gainDb: gains[$0], sampleRate: sampleRate) }
    }

    /// Every biquad that does something, in processing order: the curve's
    /// nonzero bands, then the device stage's.
    var sections: [Coefficients] {
        var result: [Coefficients] = []
        for stage in [gains, deviceGains] {
            for band in 0..<10 where stage[band] != 0 {
                result.append(Self.bandCoefficients(band: band, gainDb: stage[band], sampleRate: sampleRate))
            }
        }
        return result
    }

    /// The cascade's magnitude in dB at `frequency` (control thread).
    func responseDB(at frequency: Double) -> Double {
        Self.magnitudeDB(of: sections, at: frequency, sampleRate: sampleRate)
    }

    static func magnitudeDB(of sections: [Coefficients], at frequency: Double, sampleRate: Double) -> Double {
        var magnitude = 1.0
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), c2 = cos(2 * w), s1 = sin(w), s2 = sin(2 * w)
        for c in sections {
            let numerator = hypot(Double(c.b0) + Double(c.b1) * c1 + Double(c.b2) * c2,
                                  Double(c.b1) * s1 + Double(c.b2) * s2)
            let denominator = hypot(1 + Double(c.a1) * c1 + Double(c.a2) * c2,
                                    Double(c.a1) * s1 + Double(c.a2) * s2)
            if denominator > 0 { magnitude *= numerator / denominator }
        }
        return 20 * log10(max(magnitude, 1e-12))
    }

    /// Reserve the actual peak gain of the combined EQ curve before filtering.
    /// Adding positive slider values overestimates overlapping bands; taking
    /// only the largest slider underestimates them and still clips hot mixes.
    /// This calculation runs on the control thread when the curve changes.
    static func headroomGain(app: AudioEQ, master: AudioEQ) -> Float {
        guard app.isEnabled || master.isEnabled else { return 1 }
        let filters = [(app, app.sections), (master, master.sections)]
        let nyquist = min(app.sampleRate, master.sampleRate) / 2
        let low = min(10, nyquist / 100)
        let frequencies = [0, nyquist] + bandFrequencies.filter { $0 < nyquist } +
            (0...512).map { low * pow(nyquist / low, Double($0) / 512) }
        var maximum: Double = 1
        for frequency in frequencies {
            var magnitude: Double = 1
            for (eq, sections) in filters {
                let w = 2 * Double.pi * frequency / eq.sampleRate
                let c1 = cos(w), c2 = cos(2 * w), s1 = sin(w), s2 = sin(2 * w)
                for c in sections {
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
        for c in sections {
            (signal, _) = Self.runBiquad(c, input: signal, state: (0, 0))
        }
        return signal
    }

    /// Realtime variant: reuses caller-owned scratch buffers, zero allocation
    /// beyond computing the sections (callers precompute when it matters).
    func process(into output: UnsafeMutablePointer<Float32>, input: UnsafePointer<Float32>, frames: Int,
                 scratch: UnsafeMutablePointer<Float32>) {
        guard isEnabled, frames > 0 else {
            for frame in 0..<frames { output[frame] = input[frame] }
            return
        }
        var source: UnsafePointer<Float32> = input
        var usingScratch = false
        for c in sections {
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
        let sections = eq.sections
        sectionCount = sections.count
        coefficients = .allocate(capacity: max(1, sections.count) * 5)
        coefficients.initialize(repeating: 0, count: max(1, sections.count) * 5)
        state = .allocate(capacity: max(1, sections.count) * 4)
        state.initialize(repeating: 0, count: max(1, sections.count) * 4)
        for (section, c) in sections.enumerated() {
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

// MARK: - Per-output EQ and AutoEQ import (3.3.3, parity S04)

/// EQ presets per output device: a curve saved under a name (an imported
/// AutoEQ file, or any 10-band curve) is assigned to an output's UID and
/// follows that output: every app session playing to it runs the curve as
/// the master EQ's device stage, so plugging in the headphones switches it
/// in and unplugging switches it out (an output move re-applies effects).
/// No measurement data ships with AOM; curves come only from the user.
enum AudioDeviceEQ {
    /// [name: [Double] × 10] — the user's curves.
    static let presetsKey = "AOMAudioUserEQPresets"
    /// [device UID: preset name] — which curve each output uses.
    static let assignmentsKey = "AOMAudioDeviceEQAssignments"

    static func userPresets(defaults: UserDefaults = .standard) -> [String: [Float]] {
        let stored = defaults.dictionary(forKey: presetsKey) as? [String: [Double]] ?? [:]
        return stored.mapValues { AudioEQ.clamped($0.map(Float.init)) }
    }

    /// The names an output can use: the built-in curves (not Flat) and the user's.
    static func presetNames(defaults: UserDefaults = .standard) -> [String] {
        let builtIn = AudioEQ.presets.keys.filter { $0 != "Flat" }.sorted()
        let user = userPresets(defaults: defaults).keys.sorted()
        return user + builtIn.filter { !user.contains($0) }
    }

    @discardableResult
    static func savePreset(name: String, gains: [Float], defaults: UserDefaults = .standard) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return nil }
        var stored = defaults.dictionary(forKey: presetsKey) as? [String: [Double]] ?? [:]
        stored[trimmed] = AudioEQ.clamped(gains).map(Double.init)
        defaults.set(stored, forKey: presetsKey)
        return trimmed
    }

    /// Removes a user curve and every assignment to it.
    static func deletePreset(name: String, defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: presetsKey) as? [String: [Double]] ?? [:]
        stored.removeValue(forKey: name)
        defaults.set(stored, forKey: presetsKey)
        let assignments = (defaults.dictionary(forKey: assignmentsKey) as? [String: String] ?? [:]).filter { $0.value != name }
        defaults.set(assignments, forKey: assignmentsKey)
    }

    static func assignment(uid: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: assignmentsKey) as? [String: String])?[uid]
    }

    /// nil removes the output's curve.
    static func assign(_ name: String?, uid: String, defaults: UserDefaults = .standard) {
        guard !uid.isEmpty else { return }
        var assignments = defaults.dictionary(forKey: assignmentsKey) as? [String: String] ?? [:]
        if let name, gains(forPreset: name, defaults: defaults) != nil { assignments[uid] = name }
        else { assignments.removeValue(forKey: uid) }
        defaults.set(assignments, forKey: assignmentsKey)
    }

    /// A user curve first, then a built-in one.
    static func gains(forPreset name: String, defaults: UserDefaults = .standard) -> [Float]? {
        userPresets(defaults: defaults)[name] ?? AudioEQ.presets[name]
    }

    /// The device stage for an output (flat when it has none).
    static func deviceGains(uid: String?, defaults: UserDefaults = .standard) -> [Float] {
        guard let uid, let name = assignment(uid: uid, defaults: defaults),
              let gains = gains(forPreset: name, defaults: defaults) else { return AudioEQ.presetFlat }
        return gains
    }

    static func hasEQ(uid: String?, defaults: UserDefaults = .standard) -> Bool {
        deviceGains(uid: uid, defaults: defaults).contains { $0 != 0 }
    }
}

/// Reads AutoEQ's "ParametricEQ.txt" (the Equalizer APO format AutoEQ
/// publishes: `Preamp: -6.2 dB`, `Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.70`)
/// and maps it onto AOM's 10-band EQ: the file's filters give a target curve
/// (RBJ peaking and shelving biquads), and the ten band gains are fitted to
/// it by least squares over 20 Hz–20 kHz on a log scale. A 10-band graphic
/// EQ cannot follow narrow filters exactly, so the fit reports its error.
/// The preamp is not applied: AOM sets its own headroom from the curve.
enum AutoEQImport {
    enum FilterType: String, Equatable {
        case peak, lowShelf, highShelf
    }

    struct Filter: Equatable {
        var type: FilterType
        var frequency: Double
        var gain: Double
        var q: Double
    }

    struct Profile: Equatable {
        var preamp: Double
        var filters: [Filter]
        /// Lines that look like filters AOM cannot use (low/high pass…).
        var skipped: [String]
    }

    struct Fit: Equatable {
        var gains: [Float]
        /// dB between the file's curve and AOM's, 20 Hz–20 kHz.
        var rmsError: Double
        var maximumError: Double
        var preamp: Double
        var skipped: [String]
    }

    enum ImportError: LocalizedError, Equatable {
        case noFilters
        case unreadable
        var errorDescription: String? {
            switch self {
            case .noFilters: return "The file has no usable filters (expected AutoEQ's ParametricEQ.txt)."
            case .unreadable: return "The file could not be read as text."
            }
        }
    }

    private static let number = #"(-?\d+(?:\.\d+)?)"#

    static func parse(_ text: String) throws -> Profile {
        var preamp = 0.0
        var filters: [Filter] = []
        var skipped: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.lowercased().hasPrefix("preamp") {
                if let value = capture(#"(?i)preamp\s*:\s*"# + number + #"\s*db"#, in: line).first { preamp = value }
                continue
            }
            guard line.lowercased().hasPrefix("filter") else { continue }
            let tokens = line.replacingOccurrences(of: ":", with: " ").split(separator: " ").map(String.init)
            guard let state = tokens.firstIndex(where: { $0.uppercased() == "ON" || $0.uppercased() == "OFF" }),
                  tokens[state].uppercased() == "ON", state + 1 < tokens.count else { continue }
            let code = tokens[state + 1].uppercased()
            let type: FilterType?
            switch code {
            case "PK", "PEQ", "MODAL": type = .peak
            case "LS", "LSC", "LSQ": type = .lowShelf
            case "HS", "HSC", "HSQ": type = .highShelf
            default: type = nil
            }
            guard let type else { skipped.append(line); continue }
            guard let frequency = capture(#"(?i)fc\s+"# + number + #"\s*hz"#, in: line).first,
                  frequency > 0, frequency < 100_000 else { skipped.append(line); continue }
            let gain = capture(#"(?i)gain\s+"# + number + #"\s*db"#, in: line).first ?? 0
            let q = capture(#"(?i)\bq\s+"# + number, in: line).first ?? (type == .peak ? 1.41 : 0.71)
            guard gain.isFinite, abs(gain) <= 30, q.isFinite, q > 0.05, q <= 30 else { skipped.append(line); continue }
            filters.append(Filter(type: type, frequency: frequency, gain: gain, q: q))
        }
        guard !filters.isEmpty else { throw ImportError.noFilters }
        return Profile(preamp: preamp, filters: filters, skipped: skipped)
    }

    private static func capture(_ pattern: String, in line: String) -> [Double] {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line) else { return [] }
        return Double(line[range]).map { [$0] } ?? []
    }

    /// RBJ cookbook biquad for one of the file's filters.
    static func coefficients(_ filter: Filter, sampleRate: Double) -> AudioEQ.Coefficients {
        let A = pow(10, filter.gain / 40)
        let w0 = 2 * Double.pi * min(filter.frequency, sampleRate / 2.05) / sampleRate
        let cosw0 = cos(w0), alpha = sin(w0) / (2 * filter.q)
        var b0, b1, b2, a0, a1, a2: Double
        switch filter.type {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cosw0; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw0; a2 = 1 - alpha / A
        case .lowShelf:
            let sq = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw0 + sq); b1 = 2 * A * ((A - 1) - (A + 1) * cosw0)
            b2 = A * ((A + 1) - (A - 1) * cosw0 - sq); a0 = (A + 1) + (A - 1) * cosw0 + sq
            a1 = -2 * ((A - 1) + (A + 1) * cosw0); a2 = (A + 1) + (A - 1) * cosw0 - sq
        case .highShelf:
            let sq = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw0 + sq); b1 = -2 * A * ((A - 1) + (A + 1) * cosw0)
            b2 = A * ((A + 1) + (A - 1) * cosw0 - sq); a0 = (A + 1) - (A - 1) * cosw0 + sq
            a1 = 2 * ((A - 1) - (A + 1) * cosw0); a2 = (A + 1) - (A - 1) * cosw0 - sq
        }
        return AudioEQ.Coefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                                    a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// The fit's frequency grid: 96 points, 20 Hz–20 kHz, log-spaced.
    static let grid: [Double] = (0..<96).map { 20 * pow(1000, Double($0) / 95) }

    /// The file's curve on the grid, dB.
    static func target(_ profile: Profile, sampleRate: Double = 48000) -> [Double] {
        let sections = profile.filters.map { coefficients($0, sampleRate: sampleRate) }
        return grid.map { AudioEQ.magnitudeDB(of: sections, at: $0, sampleRate: sampleRate) }
    }

    /// Ten band gains fitted to the file's curve (Gauss–Newton with a small
    /// damping term; bands clamped to ±12 dB).
    static func fit(_ profile: Profile, sampleRate: Double = 48000) -> Fit {
        let goal = target(profile, sampleRate: sampleRate)
        func model(_ gains: [Float]) -> [Double] {
            let eq = AudioEQ(gains: gains, sampleRate: sampleRate)
            let sections = eq.sections
            return grid.map { AudioEQ.magnitudeDB(of: sections, at: $0, sampleRate: sampleRate) }
        }
        // Start from the curve at each band's centre.
        let sections = profile.filters.map { coefficients($0, sampleRate: sampleRate) }
        var gains = AudioEQ.clamped(AudioEQ.bandFrequencies.map {
            Float(AudioEQ.magnitudeDB(of: sections, at: $0, sampleRate: sampleRate))
        })
        let delta: Float = 0.05
        for _ in 0..<20 {
            let current = model(gains)
            let residual = zip(goal, current).map { $0 - $1 }
            var jacobian = [[Double]](repeating: [Double](repeating: 0, count: 10), count: grid.count)
            for band in 0..<10 {
                var nudged = gains
                nudged[band] += nudged[band] > 11.9 ? -delta : delta
                let step = Double(nudged[band] - gains[band])
                let shifted = model(nudged)
                for point in grid.indices { jacobian[point][band] = (shifted[point] - current[point]) / step }
            }
            var normal = [[Double]](repeating: [Double](repeating: 0, count: 10), count: 10)
            var right = [Double](repeating: 0, count: 10)
            for point in grid.indices {
                for i in 0..<10 {
                    right[i] += jacobian[point][i] * residual[point]
                    for j in 0..<10 { normal[i][j] += jacobian[point][i] * jacobian[point][j] }
                }
            }
            for i in 0..<10 { normal[i][i] += 0.01 * Double(grid.count) / 10 }
            guard let step = solve(normal, right) else { break }
            let next = AudioEQ.clamped(zip(gains, step).map { $0 + Float($1) })
            if zip(next, gains).allSatisfy({ abs($0 - $1) < 0.001 }) { gains = next; break }
            gains = next
        }
        let errors = zip(goal, model(gains)).map { $0 - $1 }
        let rms = (errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)).squareRoot()
        let rounded = gains.map { ($0 * 10).rounded() / 10 }
        return Fit(gains: rounded, rmsError: rms, maximumError: errors.map(abs).max() ?? 0,
                   preamp: profile.preamp, skipped: profile.skipped)
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        var a = matrix, b = vector
        let n = b.count
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-12 else { return nil }
            a.swapAt(column, pivot); b.swapAt(column, pivot)
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// The file's name without AutoEQ's suffix: "HD 650 ParametricEQ.txt" → "HD 650".
    static func presetName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for suffix in [" ParametricEQ", "ParametricEQ", " parametric eq"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported EQ" : name
    }

    /// Reads a user-chosen file (at most 256 KB), fits it and saves it as a
    /// user curve; returns the name it was saved under.
    static func importFile(at url: URL, defaults: UserDefaults = .standard) throws -> (name: String, fit: Fit) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 256 * 1024 else { throw ImportError.unreadable }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable
        }
        let result = fit(try parse(text))
        guard let name = AudioDeviceEQ.savePreset(name: presetName(for: url), gains: result.gains, defaults: defaults) else {
            throw ImportError.unreadable
        }
        return (name, result)
    }
}
