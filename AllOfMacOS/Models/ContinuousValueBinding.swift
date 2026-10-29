import Foundation

/// A continuous value binding (BTT parity, B03): instead of running its
/// actions, a trigger drives one continuous action with every value its input
/// produces.
///
/// Every source is first normalized to the AOM value 0…1:
/// - MIDI Control Change, Channel Pressure and Poly Pressure: value ÷ 127;
/// - MIDI Pitch Bend: 14-bit value ÷ 16383 (centre 8192 ≈ 0.5);
/// - Force Touch pressure (a Force Touch stage trigger): 0 at the stage
///   boundary, 1 at full pressure;
/// - Scroll (Scroll Up/Down with a modifier): relative, each scroll moves the
///   value by `scrollSensitivity` of the range per 100 points.
///
/// The mapping then clamps the AOM value to the input range, rescales it to
/// 0…1, optionally inverts it, applies the curve and scales the result into the
/// output range. The output is the target's own 0…1 level (volume scalar,
/// app volume up to 100 %, brightness).
struct ContinuousValueBinding: Codable, Hashable {
    enum Target: String, Codable, CaseIterable, Identifiable {
        case systemVolume, appVolume, displayBrightness
        var id: String { rawValue }
        var title: String {
            switch self {
            case .systemVolume: return "System volume"
            case .appVolume: return "App volume"
            case .displayBrightness: return "Display brightness"
            }
        }
        var help: String {
            switch self {
            case .systemVolume: return "Output volume of the current sound output. Needs an output with its own volume control."
            case .appVolume: return "One app's volume in AOM's per-app mixer (macOS 14.2 or later), 0–100 %. Leave the app empty to follow the frontmost app."
            case .displayBrightness: return "Brightness of the display under the pointer. Displays without a hardware control are dimmed in software, never below 10 %."
            }
        }
    }

    enum Curve: String, Codable, CaseIterable, Identifiable {
        case linear, exponential, logarithmic, sCurve
        var id: String { rawValue }
        var title: String {
            switch self {
            case .linear: return "Linear"
            case .exponential: return "Exponential (slow start)"
            case .logarithmic: return "Logarithmic (fast start)"
            case .sCurve: return "S-curve"
            }
        }
        /// Maps 0…1 onto 0…1; every curve is monotonic, so it can be inverted.
        func apply(_ x: Double) -> Double {
            let x = ContinuousValueBinding.unit(x)
            switch self {
            case .linear: return x
            case .exponential: return x * x
            case .logarithmic: return 1 - (1 - x) * (1 - x)
            case .sCurve: return x * x * (3 - 2 * x)
            }
        }
        func inverse(_ y: Double) -> Double {
            let y = ContinuousValueBinding.unit(y)
            switch self {
            case .linear: return y
            case .exponential: return y.squareRoot()
            case .logarithmic: return 1 - (1 - y).squareRoot()
            case .sCurve: return ContinuousValueBinding.unit(0.5 - sin(asin(1 - 2 * y) / 3))
            }
        }
    }

    var target: Target = .systemVolume
    /// App volume only. Empty means the frontmost app when the value arrives.
    var appBundleID: String = ""
    /// Part of the AOM value that is used; values outside are clamped.
    var inputMinimum: Double = 0
    var inputMaximum: Double = 1
    /// Range of the target the mapped value covers.
    var outputMinimum: Double = 0
    var outputMaximum: Double = 1
    var curve: Curve = .linear
    var inverted: Bool = false
    /// Pressure sources: keep the highest value of each press, so letting go
    /// does not lower the target; the next press starts again.
    var holdPeak: Bool = false
    /// Scroll only: fraction of the range one 100-point scroll covers (a
    /// mouse-wheel line counts as 10 points).
    var scrollSensitivity: Double = 0.25

    static let sensitivityRange: ClosedRange<Double> = 0.01...5

    init(target: Target = .systemVolume, appBundleID: String = "",
         inputMinimum: Double = 0, inputMaximum: Double = 1,
         outputMinimum: Double = 0, outputMaximum: Double = 1,
         curve: Curve = .linear, inverted: Bool = false, holdPeak: Bool = false,
         scrollSensitivity: Double = 0.25) {
        self.target = target; self.appBundleID = appBundleID
        self.inputMinimum = inputMinimum; self.inputMaximum = inputMaximum
        self.outputMinimum = outputMinimum; self.outputMaximum = outputMaximum
        self.curve = curve; self.inverted = inverted; self.holdPeak = holdPeak
        self.scrollSensitivity = scrollSensitivity
    }

    enum CodingKeys: String, CodingKey {
        case target, appBundleID, inputMinimum, inputMaximum, outputMinimum, outputMaximum
        case curve, inverted, holdPeak, scrollSensitivity
    }

    /// Every field is optional on disk so a binding written by a newer AOM
    /// with extra fields, or an older one with fewer, still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .systemVolume
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID) ?? ""
        inputMinimum = try c.decodeIfPresent(Double.self, forKey: .inputMinimum) ?? 0
        inputMaximum = try c.decodeIfPresent(Double.self, forKey: .inputMaximum) ?? 1
        outputMinimum = try c.decodeIfPresent(Double.self, forKey: .outputMinimum) ?? 0
        outputMaximum = try c.decodeIfPresent(Double.self, forKey: .outputMaximum) ?? 1
        curve = try c.decodeIfPresent(Curve.self, forKey: .curve) ?? .linear
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        holdPeak = try c.decodeIfPresent(Bool.self, forKey: .holdPeak) ?? false
        scrollSensitivity = try c.decodeIfPresent(Double.self, forKey: .scrollSensitivity) ?? 0.25
    }

    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    // MARK: Mapping

    /// Absolute sources: AOM value → target level.
    func output(forInput value: Double) -> Double {
        let span = inputMaximum - inputMinimum
        var t = span > 0 ? Self.unit((Self.unit(value) - inputMinimum) / span) : 0
        if inverted { t = 1 - t }
        return output(forPosition: t)
    }

    /// Relative sources keep a position (0…1, before the curve) and move it.
    func output(forPosition position: Double) -> Double {
        Self.unit(outputMinimum + (outputMaximum - outputMinimum) * curve.apply(position))
    }

    /// The position that produces `level`, so a scroll starts from where the
    /// target is now instead of jumping.
    func position(forOutput level: Double) -> Double {
        let span = outputMaximum - outputMinimum
        guard span > 0 else { return 0 }
        return curve.inverse((Self.unit(level) - outputMinimum) / span)
    }

    /// The AOM value that produces `level` (inverse of `output(forInput:)`),
    /// so an on-screen slider can start where the target is now.
    func input(forOutput level: Double) -> Double {
        var t = position(forOutput: level)
        if inverted { t = 1 - t }
        return Self.unit(inputMinimum + (inputMaximum - inputMinimum) * t)
    }

    // MARK: Sources

    /// Inputs that produce a continuous value.
    static func supports(_ input: TriggerInput) -> Bool {
        switch input {
        case .systemEvent(.midiMessage(_, let status, _, _, _, _)):
            return MIDIMessageType(rawValue: status)?.isContinuous ?? false
        case .systemEvent(.forceTouchStage): return true
        case .trackpadGesture(let gesture): return gesture.isTrackpadScroll
        default: return false
        }
    }

    /// Why this binding cannot be used on `input`, or nil.
    func problem(for input: TriggerInput) -> String? {
        guard Self.supports(input) else {
            return "Value bindings need MIDI Control Change, Pitch Bend, Channel or Poly Pressure, a Force Touch stage, or Scroll Up/Down."
        }
        return mappingProblem
    }

    /// Range and parameter checks that do not depend on the source (also used
    /// by floating-menu sliders, whose source is the slider itself).
    var mappingProblem: String? {
        let ends = [inputMinimum, inputMaximum, outputMinimum, outputMaximum]
        guard ends.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return "Ranges must lie within 0–1 (0–100 %)." }
        guard inputMinimum < inputMaximum else { return "The input range must not be empty." }
        guard outputMinimum < outputMaximum else { return "The output range must not be empty; use Invert to reverse the direction." }
        guard scrollSensitivity.isFinite, Self.sensitivityRange.contains(scrollSensitivity) else { return "Scroll sensitivity must be 0.01–5." }
        if target == .appVolume, appBundleID.count > 255 { return "The app bundle identifier is too long." }
        return nil
    }
}
