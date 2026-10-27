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

struct AudioEqualizerControls: View {
    let gains: [Float]
    let enabled: Bool
    let onChange: (Int, Float) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Text("dB").font(.caption.weight(.semibold)).frame(height: 34)
                    Text("+12")
                    Spacer()
                    Text("0")
                    Spacer()
                    Text("−12")
                }
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 30, height: 210)
                ForEach(0..<10, id: \.self) { band in
                    VStack(spacing: 8) {
                        Text(String(format: "%+.0f dB", value(band)))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(value(band) == 0 ? Color.primary : Color.accentColor)
                            .frame(height: 26)
                        AudioBandSlider(gain: Binding(get: { Double(value(band)) }, set: { onChange(band, Float($0)) }),
                                        enabled: enabled, label: EQSection.label(band))
                            .frame(width: 44, height: 176)
                        Text(EQSection.label(band) + " Hz")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        HStack(spacing: 10) {
                            Button { onChange(band, max(-12, value(band) - 1)) } label: { Image(systemName: "minus") }
                                .help("Decrease \(EQSection.label(band)) Hz by 1 dB")
                                .accessibilityLabel("Decrease \(EQSection.label(band)) hertz by 1 decibel")
                            Button { onChange(band, min(12, value(band) + 1)) } label: { Image(systemName: "plus") }
                                .help("Increase \(EQSection.label(band)) Hz by 1 dB")
                                .accessibilityLabel("Increase \(EQSection.label(band)) hertz by 1 decibel")
                        }
                        .buttonStyle(.borderless)
                        Button("Reset") { onChange(band, 0) }
                            .buttonStyle(.link).font(.caption)
                            .accessibilityLabel("Reset \(EQSection.label(band)) hertz to zero decibels")
                    }
                    .frame(width: 70)
                    .disabled(!enabled)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
        }
        .frame(height: 310)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel("10-band equalizer")
    }
    private func value(_ band: Int) -> Float { gains.indices.contains(band) ? gains[band] : 0 }
}
