import SwiftUI

// 3.3.3 BTT input editors in the shared row style (`AOMSettingRow`, ⓘ help
// instead of captions). Wired by integ-automation: the MIDI fields in the
// new-trigger sheet, the value binding in the trigger's Options, the stage
// hysteresis in Settings › Gestures & Triggers › Force Click; see
// work/integration-333/btt-input.md.

/// Filters for a MIDI trigger, covering every channel-voice message. Replaces
/// the `systemEventKind == "midi"` block of the trigger editor; the values map
/// one-to-one onto `SystemTriggerKind.midiMessage`. Emits setting rows, so it
/// sits inside a section card.
struct MIDITriggerFilterFields: View {
    @Binding var status: Int
    @Binding var channel: Int
    @Binding var number: Int
    @Binding var minimum: Int
    @Binding var maximum: Int

    private var type: MIDIMessageType { MIDIMessageType(rawValue: status) ?? .noteOn }

    var body: some View {
        AOMSettingRow("Message", help: help) {
            Picker("Message", selection: $status) {
                ForEach(MIDIMessageType.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
        }
        .onChange(of: status) { _, newValue in
            let next = MIDIMessageType(rawValue: newValue) ?? .noteOn
            // Each type gets its whole value range; Note On keeps velocity 0 out.
            minimum = next == .noteOn ? 1 : next.valueRange.lowerBound
            maximum = next.valueRange.upperBound
            if !next.hasNumber { number = 0 }
        }
        AOMSettingRow("Channel") {
            AOMRowStepper("Channel", value: $channel, in: 0...16, display: channel == 0 ? "Any" : String(channel))
        }
        if let title = type.numberTitle {
            AOMSettingRow(title) {
                AOMRowStepper(title, value: $number, in: MIDIMessageType.anyNumber...127,
                              display: number < 0 ? "Any" : String(number))
            }
        }
        if let title = type.valueTitle {
            let range = type.valueRange
            let step = type == .pitchBend ? 128 : 1
            let low = "Minimum \(title.lowercased())"
            let high = "Maximum \(title.lowercased())"
            AOMSettingRow(low) {
                AOMRowStepper(low, value: $minimum,
                              in: range.lowerBound...max(range.lowerBound, min(maximum, range.upperBound)),
                              step: step, display: String(minimum))
            }
            AOMSettingRow(high) {
                AOMRowStepper(high, value: $maximum,
                              in: min(max(minimum, range.lowerBound), range.upperBound)...range.upperBound,
                              step: step, display: String(maximum))
            }
        }
    }

    private var help: String {
        switch type {
        case .noteOn, .noteOff: return "Note On with velocity 0 counts as Note Off. Choose Any to react to every note."
        case .controlChange: return "Controller value 0–127. To drive volume or brightness with it, turn on Value Binding in the automation's Options."
        case .programChange: return "Fires when the device selects this program (Any = every program)."
        case .channelPressure: return "Aftertouch for the whole channel, 0–127."
        case .polyPressure: return "Aftertouch of one key, 0–127."
        case .pitchBend: return "14-bit bend, 0–16383; the wheel rests at 8192."
        }
    }
}

/// The value-binding rows of the trigger editor. Shows nothing for inputs
/// that cannot drive a value, so it can be placed under every trigger. The
/// switch comes first; its dependent rows are indented and stay visible but
/// disabled while it is off (e.3).
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
            AOMToggleRow("Drive a value instead of running actions",
                         help: "The input sets the system volume, an app's volume or the display brightness directly, through the range and curve below. While this is on, the trigger's actions don't run.",
                         isOn: Binding(
                            get: { binding != nil },
                            set: { binding = $0 ? (binding ?? ContinuousValueBinding()) : nil }))
            let current = binding ?? ContinuousValueBinding()
            Group {
                AOMSettingRow("Target", indent: true, help: current.target.help) {
                    Picker("Target", selection: field(\.target)) {
                        ForEach(ContinuousValueBinding.Target.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if current.target == .appVolume {
                    AOMSettingRow("App", indent: true,
                                  help: "The app's bundle ID, such as com.apple.Music. Leave it empty to follow the frontmost app.") {
                        TextField("App bundle ID (empty = frontmost app)", text: field(\.appBundleID))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: AOMEditorSize.rowField)
                    }
                }
                if isScroll {
                    slider("Sensitivity", field(\.scrollSensitivity), in: 0.05...2, format: { String(format: "%.2f", $0) },
                           help: "Scrolling moves the value; Scroll Up raises it when you scroll up, Scroll Down when you scroll down.")
                } else {
                    slider("Input from", field(\.inputMinimum), in: 0...1, format: Self.percent)
                    slider("Input to", field(\.inputMaximum), in: 0...1, format: Self.percent)
                }
                slider("Output from", field(\.outputMinimum), in: 0...1, format: Self.percent)
                slider("Output to", field(\.outputMaximum), in: 0...1, format: Self.percent)
                AOMSettingRow("Curve", indent: true) {
                    Picker("Curve", selection: field(\.curve)) {
                        ForEach(ContinuousValueBinding.Curve.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                AOMToggleRow("Invert", indent: true, isOn: field(\.inverted))
                if isPressure {
                    AOMToggleRow("Keep the strongest press after letting go", indent: true, isOn: field(\.holdPeak))
                }
            }
            .disabled(binding == nil)
            .opacity(binding == nil ? 0.55 : 1)
            if let problem = binding?.problem(for: input) {
                AOMEditorNote(problem, tone: .danger).aomRowInset()
            }
        }
    }

    private static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded())) %" }

    private func slider(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>,
                        format: @escaping (Double) -> String, help: String? = nil) -> some View {
        AOMSettingRow(title, indent: true, help: help) {
            HStack(spacing: AOMSpace.x2) {
                Slider(value: value, in: range)
                    .frame(width: AOMEditorSize.rowSlider)
                    .accessibilityLabel(title)
                    .accessibilityValue(format(value.wrappedValue))
                AOMRowValue(format(value.wrappedValue))
            }
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

/// Settings row for the stage hysteresis (Settings › Gestures & Triggers ›
/// Force Click). A grouped-form row: label with its ⓘ, then the slider and
/// its value.
struct ForceTouchStageSettingsRow: View {
    @AppStorage(PressureStageTracker.hysteresisKey) private var hysteresis = PressureStageTracker.defaultHysteresis

    private var value: String { String(format: "%.2f", hysteresis) }

    var body: some View {
        LabeledContent {
            HStack(spacing: AOMSpace.x2) {
                Slider(value: $hysteresis, in: PressureStageTracker.hysteresisRange)
                    .frame(width: AOMEditorSize.rowSlider)
                    .accessibilityLabel("Force Touch stage hysteresis")
                    .accessibilityValue(value)
                AOMRowValue(value)
            }
        } label: {
            HStack(spacing: AOMSpace.x1) {
                Text("Force Touch stage hysteresis")
                AOMInfoButton("How far the pressure must ease off before a stage can fire again. Stage 2 needs Force Click and haptic feedback turned on in Trackpad settings.",
                              topic: "Force Touch stage hysteresis")
            }
        }
    }
}
