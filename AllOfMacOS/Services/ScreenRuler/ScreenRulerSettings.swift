import AppKit

/// The unit the ruler shows. Points are what layouts are written in (and
/// what CSS pixels are on a Mac); pixels are the display's backing pixels.
enum ScreenRulerUnit: String, CaseIterable, Identifiable, Codable {
    case points = "pt"
    case pixels = "px"

    var id: String { rawValue }
    var symbol: String { rawValue }
    var title: String { self == .points ? "Points" : "Pixels" }
    var spokenName: String { self == .points ? "points" : "pixels" }
    var toggled: ScreenRulerUnit { self == .points ? .pixels : .points }
}

/// What ⌘C puts on the clipboard for a measurement.
enum ScreenRulerCopyFormat: String, CaseIterable, Identifiable, Codable {
    /// "120 × 44"
    case times
    /// "120x44"
    case compact
    /// "width: 120px; height: 44px;" (always in points: a CSS pixel is a point)
    case css

    var id: String { rawValue }

    /// The format applied to a 120 × 44 measurement.
    var example: String { ScreenRulerFormat.copyText(width: 120, height: 44, format: self) }

    /// The short name in the format menu.
    var title: String { self == .css ? "CSS" : example }
}

/// Screen Ruler preferences, shown on the Capture page. Every key starts
/// with "AOMScreenRuler", so Settings › Data › Reset Preferences resets them;
/// `backedUpKeys` lists them for settings backups.
struct ScreenRulerSettings {
    static let toleranceKey = "AOMScreenRulerTolerance"
    static let unitKey = "AOMScreenRulerUnit"
    static let showsBothUnitsKey = "AOMScreenRulerShowsBothUnits"
    static let guideColorKey = "AOMScreenRulerGuideColor"
    static let hidesCursorKey = "AOMScreenRulerHidesCursor"
    static let copyFormatKey = "AOMScreenRulerCopyFormat"
    static let snapsAreaKey = "AOMScreenRulerSnapsArea"
    static let showsColorKey = "AOMScreenRulerShowsColor"

    /// The settings a backup carries (all of them: none is machine-specific).
    static let backedUpKeys = [toleranceKey, unitKey, showsBothUnitsKey, guideColorKey, hidesCursorKey,
                               copyFormatKey, snapsAreaKey, showsColorKey]

    /// How far a colour may drift from the start pixel (per channel, as a
    /// fraction of full scale) and still count as the same surface.
    static let defaultTolerance = 0.1
    static let toleranceRange: ClosedRange<Double> = 0...0.5
    /// A raspberry red that stands out on light and dark interfaces and keeps
    /// white label text above 4.5:1 contrast.
    static let defaultGuideColor = AOMRGBAColor(red: 0.878, green: 0, blue: 0.302) // #E0004D

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var tolerance: Double {
        get {
            guard let value = defaults.object(forKey: Self.toleranceKey) as? Double, value.isFinite else {
                return Self.defaultTolerance
            }
            return min(Self.toleranceRange.upperBound, max(Self.toleranceRange.lowerBound, value))
        }
        nonmutating set { defaults.set(min(Self.toleranceRange.upperBound, max(Self.toleranceRange.lowerBound, newValue)), forKey: Self.toleranceKey) }
    }

    var unit: ScreenRulerUnit {
        get { defaults.string(forKey: Self.unitKey).flatMap(ScreenRulerUnit.init(rawValue:)) ?? .points }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.unitKey) }
    }

    /// Show the other unit next to the chosen one ("120 pt · 240 px").
    var showsBothUnits: Bool {
        get { defaults.object(forKey: Self.showsBothUnitsKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.showsBothUnitsKey) }
    }

    var guideColor: AOMRGBAColor {
        get { defaults.string(forKey: Self.guideColorKey).flatMap(AOMRGBAColor.init(hex:)) ?? Self.defaultGuideColor }
        nonmutating set { defaults.set(newValue.hex, forKey: Self.guideColorKey) }
    }

    var hidesCursor: Bool {
        get { defaults.object(forKey: Self.hidesCursorKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.hidesCursorKey) }
    }

    var copyFormat: ScreenRulerCopyFormat {
        get { defaults.string(forKey: Self.copyFormatKey).flatMap(ScreenRulerCopyFormat.init(rawValue:)) ?? .times }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.copyFormatKey) }
    }

    /// Shrink a dragged box to the content inside it (⌥ while dragging keeps the box as drawn).
    var snapsArea: Bool {
        get { defaults.object(forKey: Self.snapsAreaKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.snapsAreaKey) }
    }

    /// Show the hex colour under the pointer.
    var showsColor: Bool {
        get { defaults.object(forKey: Self.showsColorKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.showsColorKey) }
    }

    /// The values one measuring session uses, read once when it starts.
    var options: ScreenRulerOptions {
        ScreenRulerOptions(tolerance: tolerance, unit: unit, showsBothUnits: showsBothUnits,
                           guideColor: guideColor, hidesCursor: hidesCursor, copyFormat: copyFormat,
                           snapsArea: snapsArea, showsColor: showsColor)
    }
}

/// One session's settings, fixed for its lifetime (Space still flips the unit).
struct ScreenRulerOptions: Equatable {
    var tolerance = ScreenRulerSettings.defaultTolerance
    var unit = ScreenRulerUnit.points
    var showsBothUnits = false
    var guideColor = ScreenRulerSettings.defaultGuideColor
    var hidesCursor = false
    var copyFormat = ScreenRulerCopyFormat.times
    var snapsArea = true
    var showsColor = false
}
