import SwiftUI

// Settings-row controls for the 3.3.3 audio and capture pages, built only on
// AOMTokens and AOMComponents (both stay as the UI stream left them): a slider
// that shows its value, a colour well for `#RRGGBBAA` settings, the
// dependent-row treatment (ui.md, e.3), and the widths they share so trailing
// controls line up from row to row.

enum AOMRowControlMetrics {
    /// A slider inside a settings row: four 40 pt steps.
    static let sliderWidth: CGFloat = AOMSpace.x10 * 4
    /// The value shown after a slider ("100%", "0.65 s", "1.5×").
    static let valueWidth: CGFloat = AOMSpace.x12
    /// A text field inside a settings row (a Workspace tile at its minimum).
    static let fieldWidth: CGFloat = AOMSize.tileMin
    /// How far dependent rows fade while their parent is off (ui.md, e.3).
    static let dependentOpacity = 0.55
}

extension View {
    /// Dependent options (e.3): indented by the caller, disabled rather than
    /// hidden while their parent is off, and dimmed so their titles read as
    /// unavailable too. Apply it inside the section, never to the section.
    func aomDependentRows(enabled: Bool) -> some View {
        disabled(!enabled).opacity(enabled ? 1 : AOMRowControlMetrics.dependentOpacity)
    }
}

/// A slider in a settings row with its value after it (e.3: "slider with its value").
struct AOMRowSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
         format: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: AOMSpace.x2) {
            // A regular slider (design-336 b.6); the value in Callout digits.
            slider
                .frame(width: AOMRowControlMetrics.sliderWidth)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(AOMFont.callout.monospacedDigit())
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
                .frame(width: AOMRowControlMetrics.valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step) { Text(title) }
        } else {
            Slider(value: $value, in: range) { Text(title) }
        }
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func multiple(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) + "×" }
    static func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) + " s" }
}

/// A colour well for a `#RRGGBBAA` setting: read with `AOMRGBAColor(hex:)`
/// (unset or unreadable shows `fallback`) and written back as `.hex`.
struct AOMHexColorWell: View {
    let title: String
    @Binding var hex: String?
    let fallback: AOMRGBAColor
    var supportsOpacity = true

    init(_ title: String, hex: Binding<String?>, fallback: AOMRGBAColor, supportsOpacity: Bool = true) {
        self.title = title
        self._hex = hex
        self.fallback = fallback
        self.supportsOpacity = supportsOpacity
    }

    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { (hex.flatMap(AOMRGBAColor.init(hex:)) ?? fallback).cgColor },
            set: { if let color = AOMRGBAColor(cgColor: $0) { hex = color.hex } }),
                    supportsOpacity: supportsOpacity)
            .labelsHidden()
            .accessibilityLabel(title)
    }
}
