import CoreGraphics
import Foundation

/// Text for the ruler's labels, the clipboard and VoiceOver.
enum ScreenRulerFormat {
    /// "120", "60.5", "33.33": whole numbers stay whole, fractions keep up to
    /// two decimals. Always a "." decimal point, which CSS needs.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The clipboard text for a width and height already in the wanted unit.
    static func copyText(width: Double, height: Double, format: ScreenRulerCopyFormat) -> String {
        switch format {
        case .times: return "\(number(width)) × \(number(height))"
        case .compact: return "\(number(width))x\(number(height))"
        case .css: return "width: \(number(width))px; height: \(number(height))px;"
        }
    }

    /// The clipboard text for a measurement. CSS is always in points (a CSS
    /// pixel is a point on a Mac); the other formats use the shown unit.
    static func copyText(for measurement: ScreenRulerMeasurement, unit: ScreenRulerUnit,
                         format: ScreenRulerCopyFormat) -> String {
        let size = measurement.size(in: format == .css ? .points : unit)
        return copyText(width: size.width, height: size.height, format: format)
    }

    /// One length for a label: "120 pt", or "120 pt · 240 px" with both units
    /// (the second unit is left out on a 1× display, where they are equal).
    static func length(pixels: Int, scale: CGFloat, unit: ScreenRulerUnit, showsBoth: Bool) -> String {
        let primary = "\(number(ScreenRulerGeometry.value(pixels: pixels, scale: scale, unit: unit))) \(unit.symbol)"
        guard showsBoth, abs(scale - 1) > 0.001 else { return primary }
        let other = unit.toggled
        return primary + " · \(number(ScreenRulerGeometry.value(pixels: pixels, scale: scale, unit: other))) \(other.symbol)"
    }

    /// A size for a label: "120 × 44 pt", or "120 × 44 pt · 240 × 88 px".
    static func size(width: Int, height: Int, scale: CGFloat, unit: ScreenRulerUnit, showsBoth: Bool) -> String {
        func text(_ unit: ScreenRulerUnit) -> String {
            "\(number(ScreenRulerGeometry.value(pixels: width, scale: scale, unit: unit))) × "
                + "\(number(ScreenRulerGeometry.value(pixels: height, scale: scale, unit: unit))) \(unit.symbol)"
        }
        guard showsBoth, abs(scale - 1) > 0.001 else { return text(unit) }
        return text(unit) + " · " + text(unit.toggled)
    }

    /// What VoiceOver reads: "Width 120 points, height 44 points".
    static func spoken(_ measurement: ScreenRulerMeasurement, unit: ScreenRulerUnit) -> String {
        let size = measurement.size(in: unit)
        let kind: String
        switch measurement {
        case .distances: kind = "Distances"
        case .area(let area): kind = area.snapped ? "Object" : "Area"
        }
        return "\(kind): width \(number(size.width)) \(unit.spokenName), height \(number(size.height)) \(unit.spokenName)"
    }
}
