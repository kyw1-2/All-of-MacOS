import SwiftUI

// 3.3.3 BTT input editors. New file so the views owned by the UI stream stay
// untouched; see work/integration-333/btt-input.md for where each one goes.
// Plain Form controls, so the shared design system can restyle them.

/// Filters for a MIDI trigger, covering every channel-voice message. Replaces
/// the `systemEventKind == "midi"` block of the trigger editor; the values map
/// one-to-one onto `SystemTriggerKind.midiMessage`.
struct MIDITriggerFilterFields: View {
    @Binding var status: Int
    @Binding var channel: Int
    @Binding var number: Int
    @Binding var minimum: Int
    @Binding var maximum: Int

    private var type: MIDIMessageType { MIDIMessageType(rawValue: status) ?? .noteOn }

    var body: some View {
        Picker("Message", selection: $status) {
            ForEach(MIDIMessageType.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .onChange(of: status) { _, newValue in
            let next = MIDIMessageType(rawValue: newValue) ?? .noteOn
            // Each type gets its whole value range; Note On keeps velocity 0 out.
            minimum = next == .noteOn ? 1 : next.valueRange.lowerBound
            maximum = next.valueRange.upperBound
            if !next.hasNumber { number = 0 }
        }
        Stepper("Channel: \(channel == 0 ? "Any" : String(channel))", value: $channel, in: 0...16)
        if let title = type.numberTitle {
            Stepper("\(title): \(number < 0 ? "Any" : String(number))", value: $number, in: MIDIMessageType.anyNumber...127)
        }
        if let title = type.valueTitle {
            let range = type.valueRange
            let step = type == .pitchBend ? 128 : 1
            Stepper("Minimum \(title.lowercased()): \(minimum)", value: $minimum,
                    in: range.lowerBound...max(range.lowerBound, min(maximum, range.upperBound)), step: step)
            Stepper("Maximum \(title.lowercased()): \(maximum)", value: $maximum,
                    in: min(max(minimum, range.lowerBound), range.upperBound)...range.upperBound, step: step)
        }
        Text(help).font(.caption).foregroundStyle(.secondary)
    }

    private var help: String {
        switch type {
        case .noteOn, .noteOff: return "Note On with velocity 0 counts as Note Off. Choose Any to react to every note."
        case .controlChange: return "Controller value 0–127. Turn on a value binding below to drive volume or brightness with it."
        case .programChange: return "Fires when the device selects this program (Any = every program)."
        case .channelPressure: return "Aftertouch for the whole channel, 0–127."
        case .polyPressure: return "Aftertouch of one key, 0–127."
        case .pitchBend: return "14-bit bend, 0–16383; the wheel rests at 8192."
        }
    }
}

/// The value-binding section of the trigger editor. Shows nothing for inputs
/// that cannot drive a value, so it can be placed under every trigger.
struct ContinuousValueBindingEditor: View {
    @Binding var binding: ContinuousValueBinding?
    let input: TriggerInput

    private var isScroll: Bool { if case .trackpadGesture = input { return true }; return false }
    private var isPressure: Bool {
        switch input {
        case .systemEvent(.forceTouchStage): return true
        case .systemEvent(.midiMessage(_, let status, _, _, _, _)): return status == 0xA0 || status == 0xD0
        default: return false
        }
    }

    var body: some View {
        if ContinuousValueBinding.supports(input) {
            Toggle("Drive a value instead of running actions", isOn: Binding(
                get: { binding != nil },
                set: { binding = $0 ? (binding ?? ContinuousValueBinding()) : nil }))
            if let current = binding {
                Picker("Target", selection: field(\.target)) {
                    ForEach(ContinuousValueBinding.Target.allCases) { Text($0.title).tag($0) }
                }
                Text(current.target.help).font(.caption).foregroundStyle(.secondary)
                if current.target == .appVolume {
                    TextField("App bundle ID (empty = frontmost app)", text: field(\.appBundleID))
                }
                if isScroll {
                    slider("Sensitivity", field(\.scrollSensitivity), in: 0.05...2, format: { String(format: "%.2f", $0) })
                    Text("Scrolling moves the value; Scroll Up raises it when you scroll up, Scroll Down when you scroll down.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    slider("Input from", field(\.inputMinimum), in: 0...1, format: Self.percent)
                    slider("Input to", field(\.inputMaximum), in: 0...1, format: Self.percent)
                }
                slider("Output from", field(\.outputMinimum), in: 0...1, format: Self.percent)
                slider("Output to", field(\.outputMaximum), in: 0...1, format: Self.percent)
                Picker("Curve", selection: field(\.curve)) {
                    ForEach(ContinuousValueBinding.Curve.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Invert", isOn: field(\.inverted))
                if isPressure {
                    Toggle("Keep the strongest press after letting go", isOn: field(\.holdPeak))
                }
                if let problem = current.problem(for: input) {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded())) %" }

    private func slider(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue)).monospacedDigit().frame(minWidth: 48, alignment: .trailing)
        }
    }

    private func field<T>(_ keyPath: WritableKeyPath<ContinuousValueBinding, T>) -> Binding<T> {
        Binding(get: { (binding ?? ContinuousValueBinding())[keyPath: keyPath] },
                set: { binding?[keyPath: keyPath] = $0 })
    }
}

/// System-event kinds added in 3.3.3, for the trigger editor's kind list.
enum BTTInputTriggerKinds {
    static let options: [(key: String, title: String)] = [
        ("forceStage1", "Force Touch stage 1 (click)"), ("forceStage2", "Force Touch stage 2 (deep press)")]
    static func kind(for key: String) -> SystemTriggerKind? {
        switch key {
        case "forceStage1": return .forceTouchStage(stage: 1)
        case "forceStage2": return .forceTouchStage(stage: 2)
        default: return nil
        }
    }
    static func key(for kind: SystemTriggerKind) -> String? {
        if case .forceTouchStage(let stage) = kind { return "forceStage\(stage)" }
        return nil
    }
}

/// Settings row for the stage hysteresis (Trackpad / Force Touch settings).
struct ForceTouchStageSettingsRow: View {
    @AppStorage(PressureStageTracker.hysteresisKey) private var hysteresis = PressureStageTracker.defaultHysteresis
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Force Touch stage hysteresis")
                Slider(value: $hysteresis, in: PressureStageTracker.hysteresisRange)
                Text(String(format: "%.2f", hysteresis)).monospacedDigit()
            }
            Text("How far the pressure must ease off before a stage can fire again. Stage 2 needs Force Click and haptic feedback turned on in Trackpad settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
