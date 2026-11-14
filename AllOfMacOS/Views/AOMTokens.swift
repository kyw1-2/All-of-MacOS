import AppKit
import SwiftUI

// AOM design tokens: the macOS text styles (13 pt body) and regular controls,
// on an 8 pt page rhythm.
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
//   status (always with a glyph and text), module hues key charts and rings
//   only. Icons are monochrome SF Symbols; nothing is a coloured badge.
// - Motion confirms, it never decorates; Reduce Motion turns movement into a
//   short crossfade.

// MARK: - Spacing (4 pt grid, 8 pt rhythm)

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

    // 24 pt margins and section gaps, 16 pt inside cards, 12 pt between tiles
    // (HIG: ~12 pt around bezeled elements).
    static let pageMargin = x6
    static let sectionGap = x6
    static let titleGap = x2
    static let cardPadding = x4
    static let tileGap = x3
    static let rowInset = x3
    /// Divider inset for rows with a leading 20 pt symbol: 12 + 20 + 8.
    static let rowSymbolInset = rowInset + AOMIcon.row + x2

    static let xs = x2
    static let s = x3
    static let m = x3
    static let l = x4
}

// MARK: - Layout sizes

enum AOMSize {
    /// Global sidebar, sized for the system's medium sidebar rows.
    static let sidebarMin: CGFloat = 200
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMax: CGFloat = 280
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
    /// A Workspace module row: name over status beside the figure and switch.
    static let moduleRowHeight: CGFloat = 52
    /// A text or link preview in the clipboard detail pane.
    static let textPreviewMinHeight: CGFloat = 116
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

    // New names only; the values above stay.
    /// The ⌘K palette's empty-state column.
    static let quickActionMin: CGFloat = 132
    /// Workspace quick actions: a round glass button over its name.
    static let quickActionButton: CGFloat = 48
    static let quickActionCell: CGFloat = 92
    /// A capture mode button's round glass face.
    static let modeButton: CGFloat = 40
    /// A section title row: a 20 pt ⓘ or link with 1 pt above and below.
    static let sectionTitleHeight: CGFloat = AOMIcon.row + 2
    /// List + detail pages (Folder Rules, Text Actions, Files): the list
    /// column, the detail minimum and the optional trailing inspector.
    static let moduleListRange: ClosedRange<Double> = 240...360
    static let moduleListIdeal: Double = 280
    static let detailMinimum: CGFloat = 420
    static let inspectorWidth: ClosedRange<CGFloat> = 260...360
    static let inspectorIdeal: CGFloat = 300
    /// A token (pill) in a token field, and the field's minimum height.
    static let tokenHeight: CGFloat = 22
    static let tokenFieldMinHeight: CGFloat = 28
    /// A live log row: one line of Body with its time stamp.
    static let logRow: CGFloat = 28
    /// Floating confirmations (toasts) never grow wider than this.
    static let toastMaxWidth: CGFloat = 520
}

// MARK: - Type ramp (macOS text styles)

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
    /// Title (22) bold: the page header's status sentence and the Workspace
    /// header — the one large line on a page.
    static let pageTitle = Font.title.weight(.bold)
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

    /// Large Title (26) semibold, monospaced digits: the one big figure of a
    /// status header (a Focus timer, files tidied today). Never a sentence.
    static let display = Font.largeTitle.weight(.semibold).monospacedDigit()
    /// Time stamps in live logs and history rows.
    static let timestamp = Font.subheadline.monospacedDigit()
    /// Token (pill) labels in token fields and condition values.
    static let token = Font.callout
}

// MARK: - Corner radii (continuous corners everywhere)

enum AOMRadius {
    /// Keycaps, tiny chips.
    static let keycap: CGFloat = 5
    /// Thumbnails and wells inside cards; minimum concentric radius.
    static let control: CGFloat = 7
    /// Layout diagrams and previews inside panes, row hover and selection fills.
    static let well: CGFloat = 10
    /// Panes (groups of rows), section groups.
    static let card: CGFloat = 16
    /// ⌘K palette, the Workspace glass header, large HUDs, floating panels.
    static let panel: CGFloat = 22

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

// MARK: - Colour roles

enum AOMColor {
    // Interaction
    static let accent = Color.accentColor

    // Text
    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // Surfaces (opaque; glass is reserved for chrome)
    /// Every page background: a neutral grey with no tint (#F5F5F7 light,
    /// #1E1E1E dark), the grouped-content canvas of System Settings.
    static let canvas = Color.aomDynamic(light: NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1),
                                         dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1))
    /// Main-window pages: clear, so the window's glass backdrop
    /// (`AOMWorkspaceBackground`) shows through. Sheets and panels keep the
    /// opaque `canvas`.
    static let pageBackground = Color.clear
    /// Groups of rows and content blocks: a frosted pane over the glass
    /// backdrop — translucent white in light mode, a faint lift in dark mode —
    /// with no edge. Over an opaque sheet it reads as a lighter surface.
    static let surface = Color.aomDynamic(light: NSColor(white: 1, alpha: 0.62),
                                          dark: NSColor(white: 1, alpha: 0.075),
                                          highContrastLight: .white,
                                          highContrastDark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1))
    /// A pane under the pointer.
    static let surfaceHover = Color.aomDynamic(light: NSColor(white: 1, alpha: 0.80),
                                               dark: NSColor(white: 1, alpha: 0.11))
    /// Pressed panes.
    static let surfacePressed = Color.aomDynamic(light: NSColor(white: 1, alpha: 0.45),
                                                 dark: NSColor(white: 1, alpha: 0.05))
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

    // Interaction layer
    /// Keyboard focus ring for custom focusable views (the system colour).
    static let focusRing = Color(nsColor: .keyboardFocusIndicatorColor)
    /// Selected rows in custom lists: the system selection, grey while the
    /// window is inactive.
    static let selection = Color(nsColor: .selectedContentBackgroundColor)
    /// Row hover and press fills (the same values `AOMRowButtonStyle` draws).
    static let rowHover = Color(nsColor: .tertiarySystemFill).opacity(0.7)
    static let rowPressed = Color(nsColor: .tertiarySystemFill)
    /// A drop target under a drag: an accent wash under an accent ring.
    static let dropWash = Color.accentColor.opacity(0.12)
    /// Text wells: token fields, path rows.
    static let field = Color(nsColor: .textBackgroundColor)
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

    /// The tone's default glyph.
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

// MARK: - Modules (identity hues and symbols)

/// The tools and productivity modules. Their hues key charts and progress
/// rings (Today, Insights, Focus) and nothing else: never icons, the sidebar,
/// buttons or status.
enum AOMModule: String, CaseIterable, Identifiable {
    case automation, tiling, capture, clipboard, audio, systemTools
    // 3.4 productivity modules
    case folderRules, textActions, files, focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automation: return "Automation"
        case .tiling: return "Window Tiling"
        case .capture: return "Capture"
        case .clipboard: return "Clipboard"
        case .audio: return "Audio"
        case .systemTools: return "System Tools"
        case .folderRules: return "Folder Rules"
        case .textActions: return "Text Actions"
        case .files: return "Files"
        case .focus: return "Focus"
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
        case .folderRules: return "folder.badge.gearshape"
        case .textActions: return "character.cursor.ibeam"
        case .files: return "folder.fill"
        case .focus: return "timer"
        }
    }

    /// Series colours, distinct from each other and from the status colours.
    var hue: Color {
        switch self {
        case .automation: return Color(nsColor: .systemIndigo)
        case .tiling: return Color.aomDynamic(light: NSColor(srgbRed: 0.031, green: 0.569, blue: 0.698, alpha: 1),     // #0891B2
                                              dark: NSColor(srgbRed: 0.024, green: 0.714, blue: 0.831, alpha: 1))      // #06B6D4
        case .capture: return Color(nsColor: .systemPurple)
        case .clipboard: return Color(nsColor: .systemOrange)
        case .audio: return Color(nsColor: .systemPink)
        case .systemTools: return Color.aomDynamic(light: NSColor(srgbRed: 0.051, green: 0.580, blue: 0.533, alpha: 1), // #0D9488
                                                   dark: NSColor(srgbRed: 0.078, green: 0.722, blue: 0.651, alpha: 1))  // #14B8A6
        // Green, amber, blue and tangerine sit
        // between the six existing hues; none is the danger red, so a running
        // Focus session never reads as an error or a recording. White glyphs
        // keep ≥ 3:1 (computed WCAG ratios in the comments).
        case .folderRules: return Color.aomDynamic(light: NSColor(srgbRed: 0.118, green: 0.482, blue: 0.204, alpha: 1),    // #1E7B34 5.3:1
                                                   dark: NSColor(srgbRed: 0.180, green: 0.588, blue: 0.290, alpha: 1))     // #2E964A 3.8:1
        case .textActions: return Color.aomDynamic(light: NSColor(srgbRed: 0.690, green: 0.471, blue: 0, alpha: 1),        // #B07800 3.8:1
                                                   dark: NSColor(srgbRed: 0.725, green: 0.522, blue: 0, alpha: 1))         // #B98500 3.3:1
        case .files: return Color(nsColor: .systemBlue)                                                                       // 4.0 / 3.6:1
        case .focus: return Color.aomDynamic(light: NSColor(srgbRed: 0.824, green: 0.337, blue: 0.039, alpha: 1),           // #D2560A 4.1:1
                                             dark: NSColor(srgbRed: 0.910, green: 0.396, blue: 0.059, alpha: 1))            // #E8650F 3.3:1
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
        case .folderRules: return .folderRules
        case .textActions: return .textActions
        case .files: return .files
        case .focus: return .focus
        }
    }

    init?(tab: AOMMainTab) {
        guard let module = Self.allCases.first(where: { $0.tab == tab }) else { return nil }
        self = module
    }
}

// MARK: - Elevation (tone first, shadow second)

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

// MARK: - Motion

enum AOMMotion {
    static let quickCurve = Animation.snappy(duration: 0.2)
    static let standardCurve = Animation.smooth(duration: 0.3)
    static let panelCurve = Animation.smooth(duration: 0.35)
    static let successCurve = Animation.bouncy(duration: 0.4)
    static let dragCurve = Animation.interactiveSpring()
    static let settleCurve = Animation.snappy(duration: 0.3)
    /// What every token becomes under Reduce Motion (pair with `.transition(.opacity)`).
    static let crossfade = Animation.easeInOut(duration: 0.15)
    /// How long a confirmation stays: plain, and with an Undo button (3.4).
    static let toastSeconds: Double = 2.5
    static let undoToastSeconds: Double = 6

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

// MARK: - Icons

enum AOMIcon {
    /// Row icon frame at Body (13 pt text); the glyph takes the row's text style.
    static let row: CGFloat = 20
    /// Workspace tile and quick-action squircle, glyph 16 pt semibold.
    static let tileBadge: CGFloat = 32
    static let tileGlyph: CGFloat = 16
    /// Page-header squircle, glyph 20 pt.
    static let headerBadge: CGFloat = 40
    /// Empty-state glyph.
    static let empty: CGFloat = 40
    /// Minimum hit area for icon buttons (the default macOS control, HIG).
    static let hitArea: CGFloat = 28
    /// Status dot inside pills and badges.
    static let dot: CGFloat = 6

    /// Large status header (Focus timer, Folder Rules today): the squircle
    /// and the progress ring around it.
    static let statusBadge: CGFloat = 48
    static let statusRing: CGFloat = 64
    /// Rows in a module's item list that carry a small squircle.
    static let listBadge: CGFloat = 24
    /// The glyph frame of a floating HUD (mic mute, focus start).
    static let hudGlyph: CGFloat = 40
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
