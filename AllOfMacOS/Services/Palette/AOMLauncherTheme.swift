import AppKit
import Combine
import SwiftUI

// 7.8: launcher themes (Raycast's Theme picker). Until 7.7 the launcher had
// one look — Liquid Glass under an 86 % warm base — which read as a flat,
// pale sheet: the desktop barely showed and nothing could be changed. A
// theme now sets the panel's appearance (light or dark ink), the tint laid
// over a frosted blur, and the selection/accent; Opacity sets how much of
// the desktop comes through, Material picks the frosted blur (default) or
// Apple's Liquid Glass. Reduce Transparency and Increase Contrast still get
// an opaque panel in the theme's colour.

struct AOMLauncherTheme: Identifiable, Equatable {
    enum Scheme: Equatable { case system, light, dark }

    let id: String
    let name: String
    let scheme: Scheme
    /// The tint over the blur in light and dark appearance (fixed-scheme
    /// themes use only one of them).
    let lightBase: NSColor
    let darkBase: NSColor
    /// nil: the app's highlight colour.
    let accent: NSColor?

    static func == (lhs: AOMLauncherTheme, rhs: AOMLauncherTheme) -> Bool { lhs.id == rhs.id }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func light(_ id: String, _ name: String, _ base: UInt32, accent: UInt32?) -> AOMLauncherTheme {
        AOMLauncherTheme(id: id, name: name, scheme: .light, lightBase: rgb(base), darkBase: rgb(base), accent: accent.map(rgb))
    }

    private static func dark(_ id: String, _ name: String, _ base: UInt32, accent: UInt32?) -> AOMLauncherTheme {
        AOMLauncherTheme(id: id, name: name, scheme: .dark, lightBase: rgb(base), darkBase: rgb(base), accent: accent.map(rgb))
    }

    static let system = AOMLauncherTheme(id: "system", name: "Follow System", scheme: .system,
                                         lightBase: rgb(0xF6F6F8), darkBase: rgb(0x1B1B1F), accent: nil)

    /// In picker order: the neutral ones, the dark colours, the light colours.
    static let all: [AOMLauncherTheme] = [
        system,
        light("light", "Light", 0xF6F6F8, accent: nil),
        dark("dark", "Dark", 0x1B1B1F, accent: nil),
        dark("midnight", "Midnight", 0x10162A, accent: 0x7AA2F7),
        dark("graphite", "Graphite", 0x26272B, accent: 0x9AA5B8),
        dark("ocean", "Ocean", 0x0B2433, accent: 0x38BDF8),
        dark("forest", "Forest", 0x0F2219, accent: 0x4ADE80),
        dark("plum", "Plum", 0x241332, accent: 0xC084FC),
        dark("ember", "Ember", 0x2A1410, accent: 0xFB923C),
        light("paper", "Paper", 0xFBF7EF, accent: 0xB7791F),
        light("mint", "Mint", 0xECF8F3, accent: 0x10B981),
        light("rose", "Rose", 0xFDF0F3, accent: 0xF43F5E),
        light("sky", "Sky", 0xEEF5FD, accent: 0x3B82F6),
    ]

    static func named(_ id: String?) -> AOMLauncherTheme {
        all.first { $0.id == id } ?? system
    }

    /// nil follows the system; otherwise the panel is drawn in this appearance,
    /// so every dynamic colour inside (the launcher ink) resolves for it.
    var appearance: NSAppearance? {
        switch scheme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch scheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The tint at this opacity; it follows the panel's appearance.
    func base(opacity: Double) -> Color {
        let alpha = CGFloat(min(1, max(0, opacity)))
        let light = lightBase.withAlphaComponent(alpha), dark = darkBase.withAlphaComponent(alpha)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// The selected row: the theme's accent, quietly, or the neutral fill.
    var selection: Color {
        guard let accent else { return AOMCraftColor.selection }
        return Color(nsColor: NSColor(name: nil) { appearance in
            accent.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.24 : 0.17)
        })
    }

    var accentColor: Color? { accent.map { Color(nsColor: $0) } }

    /// Two colours for a swatch: the base it shows in, and its accent.
    var swatch: (base: Color, accent: Color) {
        let base = scheme == .light ? lightBase : darkBase
        return (Color(nsColor: base), Color(nsColor: accent ?? .controlAccentColor))
    }

    var schemeLabel: String {
        switch scheme {
        case .system: return "Light or dark with macOS"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The launcher's material under the theme tint.
enum AOMLauncherMaterial: String, CaseIterable, Identifiable {
    /// A strong blur of what is behind the panel (Raycast's frosted window).
    case frosted
    /// Apple's Liquid Glass (macOS 26+; the frosted blur before).
    case glass

    var id: String { rawValue }
    var title: String { self == .frosted ? "Frosted" : "Glass" }
}

/// What the launcher looks like now. Settings rows write the defaults
/// directly (`HubSliderRow` posts `.aomSettingChanged`), so this reloads on
/// that notification as well as on its own setters.
@MainActor
final class AOMLauncherAppearance: ObservableObject {
    static let shared = AOMLauncherAppearance()

    nonisolated static let themeKey = "AOMLauncherTheme"
    nonisolated static let opacityKey = "AOMLauncherOpacity"
    nonisolated static let materialKey = "AOMLauncherMaterial"
    /// 7.8: the tint lets about a third of the blurred desktop through
    /// (7.7's base was 86 % over glass, so almost nothing showed).
    nonisolated static let defaultOpacity = 0.68
    nonisolated static let opacityRange: ClosedRange<Double> = 0.3...1

    @Published private(set) var theme: AOMLauncherTheme
    @Published private(set) var opacity: Double
    @Published private(set) var material: AOMLauncherMaterial
    /// A theme shown while choosing one in the launcher, not yet saved.
    @Published private(set) var preview: AOMLauncherTheme?

    private var observer: Any?

    private init() {
        let values = Self.read()
        theme = values.theme
        opacity = values.opacity
        material = values.material
        observer = NotificationCenter.default.addObserver(forName: .aomSettingChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AOMLauncherAppearance.shared.reload() }
        }
    }

    private static func read() -> (theme: AOMLauncherTheme, opacity: Double, material: AOMLauncherMaterial) {
        let defaults = UserDefaults.standard
        let opacity = defaults.object(forKey: opacityKey) as? Double ?? defaultOpacity
        return (AOMLauncherTheme.named(defaults.string(forKey: themeKey)),
                clampOpacity(opacity),
                AOMLauncherMaterial(rawValue: defaults.string(forKey: materialKey) ?? "") ?? .frosted)
    }

    nonisolated static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(opacityRange.upperBound, max(opacityRange.lowerBound, value))
    }

    /// The theme the panel draws in now (a preview wins).
    var shown: AOMLauncherTheme { preview ?? theme }

    func reload() {
        let values = Self.read()
        if values.theme != theme { theme = values.theme }
        if values.opacity != opacity { opacity = values.opacity }
        if values.material != material { material = values.material }
        AOMLauncherController.shared.applyAppearance()
    }

    func setTheme(_ theme: AOMLauncherTheme) {
        preview = nil
        UserDefaults.standard.set(theme.id, forKey: Self.themeKey)
        self.theme = theme
        AOMLauncherController.shared.applyAppearance()
    }

    func setOpacity(_ value: Double) {
        let value = Self.clampOpacity(value)
        UserDefaults.standard.set(value, forKey: Self.opacityKey)
        opacity = value
    }

    func setMaterial(_ material: AOMLauncherMaterial) {
        UserDefaults.standard.set(material.rawValue, forKey: Self.materialKey)
        self.material = material
    }

    /// Arrowing through the theme screen tries each theme on the panel.
    func preview(_ theme: AOMLauncherTheme?) {
        guard preview != theme else { return }
        preview = theme == self.theme ? nil : theme
        AOMLauncherController.shared.applyAppearance()
    }
}
