import AppKit
import SwiftUI

// AOM design tokens. 3.3.6 (docs/design-3.3.6.md) returns to the macOS text
// styles (13 pt body) and regular controls after the fixed 12 pt / small
// controls of 3.3.5 read too small, and spaces pages on an 8 pt rhythm.
//
// This is the one file allowed raw numbers and colours. Views use the roles
// below (`AOMSpace.pageMargin`, `AOMFont.section`, `AOMColor.surface`,
// `AOMRadius.card`, `AOMMotion.quick` …), never literals, so every page shares
// one scale. Components built on these tokens live in AOMComponents.swift;
// the older names in AOMTheme / AOMDesignKit / AOMDesignSystem are aliases of
// these values and stay source compatible.
//
// Rules in one place:
// - Glass is chrome, content is solid: Liquid Glass only on the toolbar, the
//   system sidebar, the ⌘K palette, HUDs and floating panels (`aomChrome`),
//   behind `if #available(macOS 26, *)` with a material fallback. Cards,
//   tiles, lists and forms are opaque `surface` with a hairline.
// - Colour has three jobs: the accent marks interaction, semantic colours mark
//   status (always with a glyph and text), module hues are identity badges in
//   content only.
// - Motion confirms, it never decorates; Reduce Motion turns movement into a
//   short crossfade.

// MARK: - Spacing (c.1: 4 pt grid, 8 pt rhythm)

enum AOMSpace {
    /// Badge offsets and hairline nudges only.
    static let x0_5: CGFloat = 2
    /// Icon ↔ label in chips and keycaps.
    static let x1: CGFloat = 4
    /// Label ↔ control; section title ↔ its card; tile gap; compact stack gap.
    static let x2: CGFloat = 8
    /// Row horizontal inset, card padding, gap between bezeled controls.
    static let x3: CGFloat = 12
    /// Page margin; hero horizontal padding.
    static let x4: CGFloat = 16
    /// Gap between page sections.
    static let x5: CGFloat = 20
    /// Gap between bezel-less icon buttons.
    static let x6: CGFloat = 24
    /// Top of an empty state or first-run block.
    static let x8: CGFloat = 32
    static let x10: CGFloat = 40
    static let x12: CGFloat = 48

    // 3.3.6 (design-3.3.6 b.2): 24 pt margins and section gaps, 16 pt inside
    // cards, 12 pt between tiles (HIG: ~12 pt around bezeled elements).
    static let pageMargin = x6
    static let sectionGap = x6
    static let titleGap = x2
    static let cardPadding = x4
    static let tileGap = x3
    static let rowInset = x3
    /// Divider inset for rows with a leading 20 pt symbol: 12 + 20 + 8.
    static let rowSymbolInset = rowInset + AOMIcon.row + x2

    // 3.2 names, remapped onto the grid (c.1 migration table).
    /// was 4
    static let xxs = x1
    /// was 7
    static let xs = x2
    /// was 10
    static let s = x3
    /// was 13 (10 in 3.3.5)
    static let m = x3
    /// was 18 (14 in 3.3.5)
    static let l = x4
    /// was 24 (24 until 3.3.4)
    static let xl = x5
}

// MARK: - Layout sizes (c.1)

enum AOMSize {
    /// Global sidebar, sized for the system's medium sidebar rows.
    static let sidebarMin: CGFloat = 200
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMax: CGFloat = 280
    /// Row heights: dense list or table (the system table row), a grouped-form
    /// row with a regular control, and a title over a one-line description
    /// (System Settings).
    static let rowDense: CGFloat = 24
    static let rowStandard: CGFloat = 36
    static let rowDetail: CGFloat = 48
    /// Legacy one- and two-line list rows (AOMListRow).
    static let rowSingle: CGFloat = 28
    static let rowDouble: CGFloat = 44
    /// A two-line row inside a `List`, including the list's own insets
    /// (`rowDouble` + 4). Used as the list's minimum row height so rows
    /// inserted at the top (a new copy, a new automation) are never measured short.
    static let listRowDouble: CGFloat = 48
    /// The Automation list column; the editor takes the rest.
    static let listColumnRange: ClosedRange<Double> = 270...380
    static let listColumnIdeal: Double = 312
    /// Below this the editor can't show an action row without truncating.
    static let editorMinimum: CGFloat = 440
    /// Readable line length for editors and forms.
    static let readableWidth: CGFloat = 760
    /// Readable text (paragraphs, help popovers stay well under this).
    static let readableText: CGFloat = 640
    /// Dashboards and grids fill the detail column up to this, centred beyond.
    static let contentMaxWidth: CGFloat = 1200
    /// Workspace module tiles: three columns from 3 × 240 + 2 × 12 pt.
    static let tileMin: CGFloat = 240
    static let tileMax: CGFloat = 420
    /// A Workspace tile: the squircle row (name over status) and the count line.
    static let tileHeight: CGFloat = 104
    /// The Workspace side column (Today, This Mac) beside quick actions and activity.
    static let sideColumn: CGFloat = 340
    /// The ⌘K palette.
    static let paletteWidth: CGFloat = 600
    /// Inline help popover width.
    static let helpPopoverWidth: CGFloat = 280
    /// The one main-window minimum (content size).
    static let windowMinWidth: CGFloat = 980
    static let windowMinHeight: CGFloat = 600
    /// The diagnostics drawer sits beside the page only when the detail column
    /// is wide enough for the Automation page's two panes (list minimum +
    /// editor minimum) plus the widest drawer; narrower, it floats over the
    /// page's trailing edge so the editor never drops below `editorMinimum`.
    static let drawerWidth: ClosedRange<CGFloat> = 280...340
    static let drawerSideBySideMinimum: CGFloat =
        CGFloat(listColumnRange.lowerBound) + editorMinimum + drawerWidth.upperBound + 1
}

// MARK: - Type ramp (design-3.3.6 b.1: macOS text styles)

/// The macOS built-in text styles (HIG Typography): Body 13, Callout 12,
/// Subheadline 11, Headline 13 bold, Title 3 15, Title 2 17, Title 22. Styles,
/// not fixed sizes, so optical sizing, tracking and the system text-size
/// settings apply. Nothing in a sentence is below 11 pt.
enum AOMFont {
    /// 26 pt bold: large glyphs only (empty-state and thumbnail placeholders).
    static let hero = Font.largeTitle.weight(.bold)
    /// Title 2 (17) semibold: the Workspace status sentence, once per window.
    static let heroSentence = Font.title2.weight(.semibold)
    /// Title 3 (15) semibold: onboarding steps, editor and sheet titles.
    static let title = Font.title3.weight(.semibold)
    /// Title 3 (15) semibold: the module page header sentence.
    static let pageStatus = Font.title3.weight(.semibold)
    /// Headline (13 bold): section titles ("Needs attention", "Rules").
    static let section = Font.headline
    /// Headline (13 bold): card and tile titles, emphasised row titles.
    static let headline = Font.headline
    /// Body (13): rows, sentences, buttons.
    static let body = Font.body
    static let bodyEmphasis = Font.body.weight(.semibold)
    /// Callout (12): one-line descriptions, tile status lines.
    static let callout = Font.callout
    /// Subheadline (11): metadata (time, counts), section footers.
    static let caption = Font.subheadline
    /// Caption (10) medium: badges and keycaps, never sentences.
    static let badge = Font.caption.weight(.medium)
    /// Key codes, paths, logs, JSON.
    static let mono = Font.callout.monospaced()
    /// Live values in rows; any changing number also gets `.monospacedDigit()`.
    static let metric = Font.body.weight(.semibold).monospacedDigit()
    /// Title (22) semibold: tile counts and summary figures (Workspace, Insights).
    static let metricLarge = Font.title.weight(.semibold).monospacedDigit()
}

// MARK: - Corner radii (c.3: continuous corners everywhere)

enum AOMRadius {
    /// Keycaps, tiny chips.
    static let keycap: CGFloat = 5
    /// Thumbnails and wells inside cards; minimum concentric radius.
    static let control: CGFloat = 6
    /// Layout diagrams and previews inside cards, row hover and selection fills.
    static let well: CGFloat = 8
    /// Cards, Workspace tiles, section groups.
    static let card: CGFloat = 12
    /// ⌘K palette, large HUDs, quick-access overlay, floating panels.
    static let panel: CGFloat = 18

    // 3.2 names (c.3 migration).
    /// HUDs, toasts and the recording bar (was 16).
    static let hud = panel
    /// Control strips floating over the screen (was 14).
    static let bar = card
    /// Tiles and thumbnails inside a card (was 9).
    static let tile = well

    /// Module and status squircles: the app-icon proportion (22.5% of the side).
    static func squircle(_ size: CGFloat) -> CGFloat { (size * 0.225).rounded() }

    /// Inner radius that stays concentric inside `outer` at `inset`, never below `control`.
    static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat { max(control, outer - inset) }
}

// MARK: - Colour roles (c.5)

enum AOMColor {
    // Interaction
    static let accent = Color.accentColor

    // Text
    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // Surfaces (opaque; glass is reserved for chrome)
    /// Every page background: grouped canvas, #FFFFFF / #282828.
    static let canvas = Color.aomDynamic(light: .white, dark: NSColor(white: 0.157, alpha: 1))
    static let canvasNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.157, alpha: 1) : .white
    }
    /// Cards, tiles, section groups: #F4F4F6 / #323234, a step stronger than
    /// 3.3.5's #F8F8F8 so cards read without leaning on the hairline.
    static let surface = Color.aomDynamic(light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1),
                                          dark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.204, alpha: 1),
                                          highContrastLight: NSColor(white: 0.985, alpha: 1),
                                          highContrastDark: NSColor(white: 0.17, alpha: 1))
    /// A card under the pointer: the fill shifts, the card never lifts.
    static let surfaceHover = Color.aomDynamic(light: NSColor(srgbRed: 0.929, green: 0.929, blue: 0.937, alpha: 1),
                                               dark: NSColor(srgbRed: 0.231, green: 0.231, blue: 0.239, alpha: 1))
    /// Pressed tiles and cards.
    static let surfacePressed = Color.aomDynamic(light: NSColor(srgbRed: 0.902, green: 0.902, blue: 0.910, alpha: 1),
                                                 dark: NSColor(srgbRed: 0.267, green: 0.267, blue: 0.275, alpha: 1))
    /// Wells, thumbnails, empty slots.
    static let sunken = Color(nsColor: .tertiarySystemFill)
    /// Hover cards, dragged tiles, the chrome fallback under Reduce Transparency.
    static let raised = Color(nsColor: .controlBackgroundColor)
    /// Segmented tracks and pressed wells.
    static let track = Color(nsColor: .quaternarySystemFill)
    /// 0.5 pt edges; 1 pt with Increase Contrast or Show Borders.
    static let hairline = Color(nsColor: .separatorColor)
    /// Edges under Increase Contrast.
    static let strongLine = Color(nsColor: .secondaryLabelColor)

    // Status (always with a glyph and text)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let info = Color.accentColor
    static let paused = Color(nsColor: .systemGray)
    static let recording = Color(nsColor: .systemRed)

    /// Text variants that reach 4.5:1 on white in light mode (#1E7B34, #B25000,
    /// #C4161C); the system colours already pass in dark mode.
    static let successText = Color.aomDynamic(light: NSColor(srgbRed: 0.118, green: 0.482, blue: 0.204, alpha: 1), dark: .systemGreen)
    static let warningText = Color.aomDynamic(light: NSColor(srgbRed: 0.698, green: 0.314, blue: 0, alpha: 1), dark: .systemOrange)
    static let dangerText = Color.aomDynamic(light: NSColor(srgbRed: 0.769, green: 0.086, blue: 0.110, alpha: 1), dark: .systemRed)
}

/// The semantic tone of a status, notice or pill.
enum AOMTone: Equatable {
    case success, warning, danger, info, neutral, recording

    /// Fills, dots and glyphs.
    var color: Color {
        switch self {
        case .success: return AOMColor.success
        case .warning: return AOMColor.warning
        case .danger: return AOMColor.danger
        case .info: return AOMColor.info
        case .neutral: return AOMColor.paused
        case .recording: return AOMColor.recording
        }
    }

    /// Text in the tone that keeps 4.5:1.
    var textColor: Color {
        switch self {
        case .success: return AOMColor.successText
        case .warning: return AOMColor.warningText
        case .danger, .recording: return AOMColor.dangerText
        case .info: return AOMColor.accent
        case .neutral: return AOMColor.textSecondary
        }
    }

    /// The tone's default glyph (c.8 status glyphs).
    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .neutral: return "pause.circle.fill"
        case .recording: return "record.circle"
        }
    }

    /// Background wash for notices and pills (10–12%, stronger with Increase Contrast).
    func wash(increasedContrast: Bool) -> Color { color.opacity(increasedContrast ? 0.22 : 0.12) }
}

// MARK: - Modules (c.5 identity hues, c.8 symbols)

/// The six tools plus the two places without a hue. Module hues appear only
/// in content badges (tiles, page headers), never in the sidebar, on buttons
/// or as status.
enum AOMModule: String, CaseIterable, Identifiable {
    case automation, tiling, capture, clipboard, audio, systemTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automation: return "Automation"
        case .tiling: return "Window Tiling"
        case .capture: return "Capture"
        case .clipboard: return "Clipboard"
        case .audio: return "Audio"
        case .systemTools: return "System Tools"
        }
    }

    var symbol: String {
        switch self {
        case .automation: return "bolt.fill"
        case .tiling: return "rectangle.split.2x2.fill"
        case .capture: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard.fill"
        case .audio: return "waveform"
        case .systemTools: return "wrench.and.screwdriver.fill"
        }
    }

    /// White glyphs on these reach ≥3.1:1 in both modes (measured, c.5).
    var hue: Color {
        switch self {
        case .automation: return Color(nsColor: .systemIndigo)
        case .tiling: return Color.aomDynamic(light: NSColor(srgbRed: 0, green: 0.518, blue: 0.549, alpha: 1),       // #00848C
                                              dark: NSColor(srgbRed: 0.039, green: 0.604, blue: 0.643, alpha: 1))    // #0A9AA4
        case .capture: return Color(nsColor: .systemPurple)
        case .clipboard: return Color(nsColor: .systemBrown)
        case .audio: return Color(nsColor: .systemPink)
        case .systemTools: return Color(nsColor: NSColor(srgbRed: 0.486, green: 0.486, blue: 0.510, alpha: 1))     // #7C7C82
        }
    }

    var tab: AOMMainTab {
        switch self {
        case .automation: return .gestures
        case .tiling: return .snapping
        case .capture: return .capture
        case .clipboard: return .clipboard
        case .audio: return .audio
        case .systemTools: return .tools
        }
    }

    init?(tab: AOMMainTab) {
        guard let module = Self.allCases.first(where: { $0.tab == tab }) else { return nil }
        self = module
    }
}

// MARK: - Elevation (c.6: tone first, shadow second)

enum AOMElevation {
    case raised, overlay
}

private struct AOMElevationShadow: ViewModifier {
    let level: AOMElevation
    var enabled = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // Increase Contrast: borders replace shadows.
        let factor: Double = !enabled || contrast == .increased ? 0 : (scheme == .dark ? (level == .raised ? 2 : 1.5) : 1)
        switch level {
        case .raised:
            content
                .shadow(color: .black.opacity(0.10 * factor), radius: 3, y: 2)
                .shadow(color: .black.opacity(0.08 * factor), radius: 12, y: 8)
        case .overlay:
            content
                .shadow(color: .black.opacity(0.12 * factor), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.18 * factor), radius: 16, y: 12)
        }
    }
}

extension View {
    /// Level 2 (hover cards, dragged tiles) or 3 (overlay chrome before macOS 26;
    /// system glass already draws its own shadow, so never add this to glass).
    func aomElevation(_ level: AOMElevation, enabled: Bool = true) -> some View {
        modifier(AOMElevationShadow(level: level, enabled: enabled))
    }
}

// MARK: - Motion (c.7)

enum AOMMotion {
    static let quickCurve = Animation.snappy(duration: 0.2)
    static let standardCurve = Animation.smooth(duration: 0.3)
    static let panelCurve = Animation.smooth(duration: 0.35)
    static let successCurve = Animation.bouncy(duration: 0.4)
    static let dragCurve = Animation.interactiveSpring()
    static let settleCurve = Animation.snappy(duration: 0.3)
    /// What every token becomes under Reduce Motion (pair with `.transition(.opacity)`).
    static let crossfade = Animation.easeInOut(duration: 0.15)

    /// The system setting, for code without a view environment. Views prefer
    /// `@Environment(\.accessibilityReduceMotion)` with `resolve(_:reduceMotion:)`
    /// or `aomAnimation(_:value:)`.
    static var systemReduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : animation
    }

    /// Hover, press, switch, badge and state flips.
    static var quick: Animation { resolve(quickCurve, reduceMotion: systemReduceMotion) }
    /// Expand or collapse, inline help, tile reflow.
    static var standard: Animation { resolve(standardCurve, reduceMotion: systemReduceMotion) }
    /// Palette, drawer, inspector in and out.
    static var panel: Animation { resolve(panelCurve, reduceMotion: systemReduceMotion) }
    /// At most once per action (capture saved, snap landed); removed under Reduce Motion.
    static var success: Animation? { systemReduceMotion ? nil : successCurve }
    /// Following the pointer; removed under Reduce Motion.
    static var drag: Animation? { systemReduceMotion ? nil : dragCurve }
    /// Landing after a drag.
    static var settle: Animation { resolve(settleCurve, reduceMotion: systemReduceMotion) }
}

/// Motion token names for `aomAnimation(_:value:)`.
enum AOMMotionToken {
    case quick, standard, panel, success, settle

    var curve: Animation {
        switch self {
        case .quick: return AOMMotion.quickCurve
        case .standard: return AOMMotion.standardCurve
        case .panel: return AOMMotion.panelCurve
        case .success: return AOMMotion.successCurve
        case .settle: return AOMMotion.settleCurve
        }
    }
}

private struct AOMAnimationModifier<V: Equatable>: ViewModifier {
    let token: AOMMotionToken
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(token == .success && reduceMotion ? nil : AOMMotion.resolve(token.curve, reduceMotion: reduceMotion),
                          value: value)
    }
}

extension View {
    /// A motion token that reads Reduce Motion from the environment.
    func aomAnimation<V: Equatable>(_ token: AOMMotionToken, value: V) -> some View {
        modifier(AOMAnimationModifier(token: token, value: value))
    }
}

// MARK: - Icons (c.8)

enum AOMIcon {
    /// Row icon frame at Body (13 pt text); the glyph takes the row's text style.
    static let row: CGFloat = 20
    /// Workspace tile and quick-action squircle, glyph 16 pt semibold.
    static let tileBadge: CGFloat = 32
    static let tileGlyph: CGFloat = 16
    /// Page-header squircle, glyph 20 pt.
    static let headerBadge: CGFloat = 40
    static let headerGlyph: CGFloat = 20
    /// Workspace status squircle and its glyph.
    static let hero: CGFloat = 40
    static let heroGlyph: CGFloat = 22
    /// Empty-state glyph.
    static let empty: CGFloat = 40
    /// Minimum hit area for icon buttons (the default macOS control, HIG).
    static let hitArea: CGFloat = 28
    /// Status dot inside pills and badges.
    static let dot: CGFloat = 6
}

// MARK: - Dynamic colours

extension Color {
    /// A colour with light, dark and optional Increase Contrast variants.
    /// (`Package.swift` excludes the asset catalog, so dynamic colours live in code.)
    static func aomDynamic(light: NSColor, dark: NSColor,
                           highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: return dark
            case .accessibilityHighContrastDarkAqua: return highContrastDark ?? dark
            case .accessibilityHighContrastAqua: return highContrastLight ?? light
            default: return light
            }
        })
    }
}
