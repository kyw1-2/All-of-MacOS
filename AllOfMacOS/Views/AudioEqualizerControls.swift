import AppKit
import SwiftUI

/// A real vertical control keeps its full travel and hit area. Rotating a
/// horizontal Slider inside a 14 pt frame had reduced both to a tiny sliver.
private struct AudioBandSlider: NSViewRepresentable {
    @Binding var gain: Double
    let enabled: Bool
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: gain, minValue: -12, maxValue: 12,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isVertical = true
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = false
        slider.setAccessibilityLabel(label + " gain, decibels")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = gain
        slider.isEnabled = enabled
    }
    final class Coordinator: NSObject {
        var parent: AudioBandSlider
        init(_ parent: AudioBandSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) { parent.gain = slider.doubleValue.rounded() }
    }
}

/// The ten bands side by side: each band's gain, its slider, its frequency
/// and ±1 dB buttons. A band's context menu resets it to 0 dB; the sheet's
/// Flat button (or the Flat preset) resets them all.
struct AudioEqualizerControls: View {
    /// Sizes no design token covers.
    private enum Metrics {
        /// One band's column: wide enough for "+12" and "16 kHz".
        static let bandWidth: CGFloat = 44
        /// The slider's travel (−12 … +12 dB).
        static let sliderHeight: CGFloat = 130
        /// The dB scale before the first band.
        static let scaleWidth: CGFloat = 26
        /// The whole control, a legacy scroll bar included.
        static let height: CGFloat = 220
    }

    let gains: [Float]
    let enabled: Bool
    let onChange: (Int, Float) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: AOMSpace.x1) {
                scale
                ForEach(0..<10, id: \.self) { band in
                    bandColumn(band)
                }
            }
            .padding(AOMSpace.x2)
        }
        .frame(height: Metrics.height)
        .opacity(enabled ? 1 : AOMRowControlMetrics.dependentOpacity)
        .accessibilityLabel("10-band equalizer")
    }

    /// +12, 0 and −12 beside the sliders' travel, under a "dB" heading that
    /// names the unit of the gains row.
    private var scale: some View {
        VStack(spacing: AOMSpace.x1) {
            Text("dB").font(AOMFont.caption.weight(.semibold))
            VStack(spacing: 0) {
                Text("+12")
                Spacer(minLength: 0)
                Text("0")
                Spacer(minLength: 0)
                Text("−12")
            }
            .frame(height: Metrics.sliderHeight)
        }
        .font(AOMFont.caption.monospacedDigit())
        .foregroundStyle(AOMColor.textSecondary)
        .frame(width: Metrics.scaleWidth)
        .accessibilityHidden(true)
    }

    private func bandColumn(_ band: Int) -> some View {
        let gain = value(band)
        let changed = Int(gain.rounded()) != 0
        return VStack(spacing: AOMSpace.x1) {
            Text(Self.gainText(gain))
                .font(AOMFont.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(changed ? AOMColor.accent : AOMColor.text)
                .lineLimit(1)
            AudioBandSlider(gain: Binding(get: { Double(gain) }, set: { onChange(band, Float($0)) }),
                            enabled: enabled, label: Self.spokenFrequency(band))
                .frame(width: Metrics.bandWidth - AOMSpace.x1, height: Metrics.sliderHeight)
            Text(Self.frequencyText(band))
                .font(AOMFont.caption.monospacedDigit())
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: AOMSpace.x1) {
                Button { onChange(band, max(-12, gain - 1)) } label: { Image(systemName: "minus") }
                    .help("Decrease \(Self.frequencyText(band)) by 1 dB")
                    .accessibilityLabel("Decrease \(Self.spokenFrequency(band)) by 1 decibel")
                Button { onChange(band, min(12, gain + 1)) } label: { Image(systemName: "plus") }
                    .help("Increase \(Self.frequencyText(band)) by 1 dB")
                    .accessibilityLabel("Increase \(Self.spokenFrequency(band)) by 1 decibel")
            }
            .buttonStyle(.borderless)
        }
        .frame(width: Metrics.bandWidth)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset \(Self.frequencyText(band)) to 0 dB") { onChange(band, 0) }
                .disabled(gain == 0)
        }
        .disabled(!enabled)
    }

    private func value(_ band: Int) -> Float { gains.indices.contains(band) ? gains[band] : 0 }

    /// "+3", "0", "−12": the scale's "dB" heading carries the unit.
    private static func gainText(_ gain: Float) -> String {
        let rounded = Int(gain.rounded())
        if rounded == 0 { return "0" }
        return rounded > 0 ? "+\(rounded)" : "−\(-rounded)"
    }

    /// "32 Hz" … "1 kHz" … "16 kHz".
    private static func frequencyText(_ band: Int) -> String {
        let hz = AudioEQ.bandFrequencies[band]
        return hz >= 1000 ? "\(Int(hz / 1000)) kHz" : "\(Int(hz)) Hz"
    }

    /// The band for VoiceOver: "32 hertz", "1 kilohertz".
    private static func spokenFrequency(_ band: Int) -> String {
        let hz = AudioEQ.bandFrequencies[band]
        return hz >= 1000 ? "\(Int(hz / 1000)) kilohertz" : "\(Int(hz)) hertz"
    }
}
