import AppKit
import SwiftUI

// AOM 5.0 "Studio" identity layer.
//
// Up to 4.x every page and tool drew the same monochrome symbol tinted with
// the accent, so eleven tools read as one undifferentiated list. 5.0 gives
// each destination a fixed identity, the way System Settings, Raycast and
// Loop do: a filled SF Symbol in white on a squircle filled with the tool's
// own hue. The identity is used where a person looks for *which* tool they
// are in or about to open — the sidebar, the page header, the action bar,
// Workspace cards, the ⌘K palette, setting-row symbols and empty states.
// Interaction (switches, selection, prominent buttons) keeps the system
// accent, so controls behave identically on every page; status keeps the
// semantic colours with a glyph and words.

/// What a destination looks like: a filled symbol on a coloured squircle.
struct AOMIdentity: Equatable {
    let symbol: String
    let color: Color
    /// The Workspace mark: a two-hue brand gradient instead of one hue.
    var isBrand = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.symbol == rhs.symbol && lhs.isBrand == rhs.isBrand && lhs.color == rhs.color
    }

    /// The fill of the squircle.
    var fill: AnyShapeStyle {
        if isBrand {
            return AnyShapeStyle(LinearGradient(colors: [AOMBrand.start, AOMBrand.end],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(color.gradient)
    }

    /// Neutral identity for Settings categories and anything without a tool.
    static func neutral(_ symbol: String) -> AOMIdentity {
        AOMIdentity(symbol: symbol, color: AOMBrand.graphite)
    }
}

/// Brand colours: the Workspace mark, the sidebar header and the Workspace
/// banner. Indigo into magenta, the two ends of the module palette.
enum AOMBrand {
    static let start = Color.aomDynamic(light: NSColor(srgbRed: 0.329, green: 0.306, blue: 0.890, alpha: 1),   // #544EE3
                                        dark: NSColor(srgbRed: 0.420, green: 0.396, blue: 0.957, alpha: 1))    // #6B65F4
    static let end = Color.aomDynamic(light: NSColor(srgbRed: 0.851, green: 0.247, blue: 0.588, alpha: 1),     // #D93F96
                                      dark: NSColor(srgbRed: 0.918, green: 0.329, blue: 0.659, alpha: 1))      // #EA54A8
    /// System Settings' "General" grey: Settings, neutral rows.
    static let graphite = Color.aomDynamic(light: NSColor(srgbRed: 0.482, green: 0.494, blue: 0.529, alpha: 1), // #7B7E87
                                           dark: NSColor(srgbRed: 0.427, green: 0.439, blue: 0.475, alpha: 1))  // #6D7079
    /// Insights: a slate blue that sits apart from Files' system blue.
    static let slate = Color.aomDynamic(light: NSColor(srgbRed: 0.333, green: 0.408, blue: 0.565, alpha: 1),   // #556890
                                        dark: NSColor(srgbRed: 0.408, green: 0.490, blue: 0.659, alpha: 1))    // #687DA8

    static var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension AOMMainTab {
    /// The destination's fixed identity (symbol + hue).
    var identity: AOMIdentity {
        switch self {
        case .home: return AOMIdentity(symbol: "square.grid.2x2.fill", color: AOMBrand.start, isBrand: true)
        case .gestures: return AOMIdentity(symbol: "bolt.fill", color: AOMModule.automation.hue)
        case .snapping: return AOMIdentity(symbol: "rectangle.split.2x2.fill", color: AOMModule.tiling.hue)
        case .capture: return AOMIdentity(symbol: "camera.viewfinder", color: AOMModule.capture.hue)
        case .clipboard: return AOMIdentity(symbol: "doc.on.clipboard.fill", color: AOMModule.clipboard.hue)
        case .audio: return AOMIdentity(symbol: "waveform", color: AOMModule.audio.hue)
        case .tools: return AOMIdentity(symbol: "wrench.and.screwdriver.fill", color: AOMModule.systemTools.hue)
        case .insights: return AOMIdentity(symbol: "chart.bar.fill", color: AOMBrand.slate)
        case .folderRules: return AOMIdentity(symbol: "folder.fill.badge.gearshape", color: AOMModule.folderRules.hue)
        case .textActions: return AOMIdentity(symbol: "character.cursor.ibeam", color: AOMModule.textActions.hue)
        case .files: return AOMIdentity(symbol: "doc.on.doc.fill", color: AOMModule.files.hue)
        case .focus: return AOMIdentity(symbol: "timer", color: AOMModule.focus.hue)
        }
    }

    /// One short verb phrase for the action bar and Explore cards.
    var tagline: String {
        switch self {
        case .home: return "Every tool, one place"
        case .gestures: return "Inputs that run actions"
        case .snapping: return "Place windows by gesture"
        case .capture: return "Shoot, record, annotate"
        case .clipboard: return "Everything you copied"
        case .audio: return "Per-app sound and devices"
        case .tools: return "Quick fixes for your Mac"
        case .insights: return "What runs, and how often"
        case .folderRules: return "Folders that tidy themselves"
        case .textActions: return "Act on selected text"
        case .files: return "Faster Open and Save"
        case .focus: return "Sessions without distraction"
        }
    }
}

extension AOMModule {
    var identity: AOMIdentity { tab.identity }
}

extension SettingsCategory {
    /// Settings panes borrow the hue of the tool they configure; the rest
    /// take System Settings' conventions (graphite General, blue Privacy).
    var identity: AOMIdentity {
        switch self {
        case .general: return .neutral("gearshape.fill")
        case .capture: return AOMIdentity(symbol: "camera.viewfinder", color: AOMModule.capture.hue)
        case .clipboard: return AOMIdentity(symbol: "doc.on.clipboard.fill", color: AOMModule.clipboard.hue)
        case .automation: return AOMIdentity(symbol: "hand.draw.fill", color: AOMModule.automation.hue)
        case .shortcuts: return AOMIdentity(symbol: "command", color: AOMModule.audio.hue)
        case .permissions: return AOMIdentity(symbol: "hand.raised.fill", color: AOMModule.files.hue)
        case .data: return AOMIdentity(symbol: "externaldrive.fill", color: AOMModule.folderRules.hue)
        case .about: return .neutral("info")
        }
    }
}

// MARK: - The mark

/// How strongly a mark carries its hue (6.0 "Calm", after the 5.0 reviews:
/// saturated squircles on every row read as decoration, not information).
enum AOMMarkStyle {
    /// The glyph in its hue on a soft wash of the same hue (Linear, Craft,
    /// Notion): the default wherever a destination or command is listed.
    case tinted
    /// The glyph alone in its hue, no plate (Things' sidebar).
    case glyph
    /// White glyph on the solid hue: reserved for the app's own brand mark.
    case solid
}

/// A destination's or command's mark. Off items turn grey (no filter
/// layers, so long lists never render offscreen); Increase Contrast adds an
/// edge to plated styles. On a selected row of a key window it turns white.
struct AOMAppIcon: View {
    let identity: AOMIdentity
    var size: CGFloat = AOMIcon.identityRow
    var active = true
    var style: AOMMarkStyle = .tinted
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @Environment(\.backgroundProminence) private var prominence

    init(_ identity: AOMIdentity, size: CGFloat = AOMIcon.identityRow, active: Bool = true,
         style: AOMMarkStyle = .tinted) {
        self.identity = identity
        self.size = size
        self.active = active
        self.style = style
    }

    init(_ tab: AOMMainTab, size: CGFloat = AOMIcon.identityRow, active: Bool = true,
         style: AOMMarkStyle = .tinted) {
        self.init(tab.identity, size: size, active: active, style: style)
    }

    private var hue: Color {
        guard active else { return AOMColor.textTertiary }
        return identity.isBrand ? AOMBrand.start : identity.color
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: (size * 0.28).rounded(), style: .continuous)
        let onSelection = prominence == .increased
        switch style {
        case .glyph:
            Image(systemName: identity.symbol)
                .font(.system(size: (size * 0.78).rounded(), weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(onSelection ? Color.white : hue)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .tinted:
            Image(systemName: identity.symbol)
                .font(.system(size: (size * 0.5).rounded(), weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(onSelection ? Color.white : hue)
                .frame(width: size, height: size)
                .background(onSelection ? Color.white.opacity(0.2) : hue.opacity(scheme == .dark ? 0.2 : 0.12), in: shape)
                .overlay {
                    if contrast == .increased { shape.strokeBorder(AOMColor.strongLine, lineWidth: 1) }
                }
                .accessibilityHidden(true)
        case .solid:
            Image(systemName: identity.symbol)
                .font(.system(size: (size * 0.5).rounded(), weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(active ? identity.fill : AnyShapeStyle(AOMColor.paused.opacity(0.55)), in: shape)
                .overlay {
                    if contrast == .increased { shape.strokeBorder(AOMColor.strongLine, lineWidth: 1) }
                }
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Page identity in the environment

private struct AOMPageTabKey: EnvironmentKey {
    static let defaultValue: AOMMainTab? = nil
}

extension EnvironmentValues {
    /// The main-window page a view belongs to (set by `AOMPageHost`). Rows,
    /// headers and empty states use it to draw the page's identity; views
    /// outside the main window (Settings, sheets, HUDs) see nil and stay neutral.
    var aomPageTab: AOMMainTab? {
        get { self[AOMPageTabKey.self] }
        set { self[AOMPageTabKey.self] = newValue }
    }
}

/// A setting row's symbol (6.0): a neutral glyph in a fixed column. Colour
/// marks *which tool*; a row inside a tool needs no second colour.
struct AOMRowIcon: View {
    let symbol: String
    var size: CGFloat = AOMIcon.identityRow
    var active = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (size * 0.7).rounded(), weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(active ? AOMColor.textSecondary : AOMColor.textTertiary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
