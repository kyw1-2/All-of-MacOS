import AppKit
import SwiftUI

// AOM design tokens: 13 pt body text, distinct headings, 34 / 44 pt rows,
// and a readable centred column of at most 960 pt. Discovery cards use the
// same surfaces and accent as settings, editors and navigation.
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
//   behind `if #available(macOS 26, *)` with a material fallback. In the
//   main window, panes of rows are frosted `surface` with no edge over the
//   window's glass backdrop; anything drawn over other content (a label on a
//   chart) uses the opaque `overlaySurface`.
// - Colour has three jobs: the accent marks interaction, semantic colours mark
//   status (always with a glyph and text), and since 5.0 module hues mark
//   identity — the tool's squircle mark (AOMIdentity.swift) in the sidebar,
//   page header, action bar, cards, palette, row icons — plus charts and
//   rings. Controls never take a module hue.
// - Motion confirms, it never decorates; Reduce Motion turns movement into a
//   short crossfade.

// MARK: - Spacing (4 pt grid, 8 pt rhythm)

enum AOMSpace {
    /// Badge offsets and hairline nudges only.
    static let x0_5: CGFloat = 2
    /// Icon ↔ label in chips and keycaps.
    static let x1: CGFloat = 4
    /// Label ↔ control; symbol ↔ label; tile gap; compact stack gap.
    static let x2: CGFloat = 8
    /// Card padding, the top of a page, gap between bezeled controls.
    static let x3: CGFloat = 12
    /// Hero horizontal padding.
    static let x4: CGFloat = 16
    /// Page margin.
    static let x5: CGFloat = 20
    /// Gap between bezel-less icon buttons; one regular control high.
    static let x6: CGFloat = 24
    /// Top of an empty state or first-run block.
    static let x8: CGFloat = 32
    static let x10: CGFloat = 40
    static let x12: CGFloat = 48

    // 20 pt page margins, 18 pt between sections, 12 pt inside cards, 8 pt
    // between tiles, rows inset 10 pt (the macOS 26 list row padding).
    static let pageMargin = x5
    /// From the toolbar to the top of a page's first content, on every page,
    /// so switching pages never moves the first line up or down.
    static let pageTop = x5
    static let sectionGap: CGFloat = 24
    /// Section title ↔ its card.
    static let titleGap: CGFloat = 6
    static let cardPadding = x3
    static let tileGap = x2
    /// Leading and trailing inset of a row's content; section titles and
    /// footers use it too, so they share the rows' leading line.
    static let rowInset: CGFloat = 10
    /// Above and below a row's text, inside its minimum height.
    static let rowPadding: CGFloat = 3
    /// Divider inset for rows with a leading identity mark: 10 + 20 + 10,
    /// so the hairline starts under the title (System Settings).
    static let rowSymbolInset = rowInset + AOMIcon.identityRow + rowInset

    static let xs = x2
    static let s = x3
    static let m = x3
    static let l = x4
}

// MARK: - Layout sizes

enum AOMSize {
    static let directoryTileMin: CGFloat = 220
    static let directoryIcon: CGFloat = 32
    static let workspaceModeWidth: CGFloat = 240
    /// Global sidebar, wide enough for task groups and the search label.
    static let sidebarMin: CGFloat = 220
    static let sidebarIdeal: CGFloat = 236
    static let sidebarMax: CGFloat = 300
    /// A settings row: one line, and one line with a description under it.
    static let rowStandard: CGFloat = 34
    static let rowDetail: CGFloat = 44
    /// One- and two-line list rows (AOMListRow).
    static let rowSingle: CGFloat = 26
    static let rowDouble: CGFloat = 38
    /// A two-line row inside a `List`, including the list's own insets
    /// (`rowDouble` + 4). Used as the list's minimum row height so rows
    /// inserted at the top (a new copy, a new automation) are never measured short.
    static let listRowDouble: CGFloat = 42
    /// The Automation list column; the editor takes the rest.
    static let listColumnRange: ClosedRange<Double> = 270...380
    static let listColumnIdeal: Double = 312
    /// Below this the editor can't show an action row without truncating.
    static let editorMinimum: CGFloat = 440
    /// Readable line length for editors and forms.
    static let readableWidth: CGFloat = 720
    /// The content column of the Settings window and its sheets: the
    /// readable width less the page margins on both sides, so a pane and a
    /// sheet at their minimum width (`readableWidth`) show the same column.
    static let settingsColumn: CGFloat = readableWidth - AOMSpace.pageMargin * 2
    /// Readable text (paragraphs, help popovers stay well under this).
    static let readableText: CGFloat = 640
    /// The page column: content fills the detail column up to this and is
    /// centred beyond it. List + detail pages keep their full-width split.
    static let contentMaxWidth: CGFloat = 960
    /// Workspace module tiles: three columns from 3 × 240 + 2 × 8 pt.
    static let tileMin: CGFloat = 240
    static let tileMax: CGFloat = 420
    /// A Workspace module row: name over status beside the figure and switch.
    static let moduleRowHeight: CGFloat = 38
    /// The control slot at a module row's trailing edge: wide enough for a
    /// small bordered "Create…" or "Set Up…", so switches, buttons and
    /// chevrons end on one vertical line down every column of rows.
    static let moduleControlSlot: CGFloat = 64
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

    /// The ⌘K palette's empty-state column.
    static let quickActionMin: CGFloat = 132
    /// Workspace quick actions: a 36 pt button over its name.
    static let quickActionButton: CGFloat = 36
    static let quickActionCell: CGFloat = 76
    /// A capture mode button's round face.
    static let modeButton: CGFloat = 36
    /// A section title row: a 16 pt ⓘ or an 18 pt link, so a title with or
    /// without an accessory is one height.
    static let sectionTitleHeight: CGFloat = 18
    /// List + detail pages (Folder Rules, Text Actions, Files): the list
    /// column, the detail minimum and the optional trailing inspector.
    static let moduleListRange: ClosedRange<Double> = 240...360
    static let moduleListIdeal: Double = 280
    static let detailMinimum: CGFloat = 420
    static let inspectorWidth: ClosedRange<CGFloat> = 260...360
    static let inspectorIdeal: CGFloat = 300
    /// A token (pill) in a token field, and the field's minimum height.
    static let tokenHeight: CGFloat = 20
    static let tokenFieldMinHeight: CGFloat = 28
    /// A live log row: one line of Body with its time stamp.
    static let logRow: CGFloat = 24
    /// The action bar under every page (5.0).
    static let actionBarHeight: CGFloat = 34
    /// Floating confirmations (toasts) never grow wider than this.
    static let toastMaxWidth: CGFloat = 520
}

// MARK: - Type ramp (macOS text styles)

/// The macOS built-in text styles (HIG Typography): Body 13, Callout 12,
/// Subheadline 11, Title 3 15, Title 2 17, Title 22. Styles, not fixed sizes,
/// so optical sizing, tracking and the system text-size settings apply.
/// Content is 13 pt and metadata 11–12 pt; hierarchy comes from weight and
/// brightness, emphasis is medium or semibold, never bold. Nothing in a
/// sentence is below 11 pt.
enum AOMFont {
    static let workspaceTitle = Font.title.weight(.semibold)
    /// Title (22) semibold: large glyphs only (empty-state and thumbnail placeholders).
    static let hero = Font.title.weight(.semibold)
    /// Body (13) semibold: compact status sentences.
    static let heroSentence = Font.body.weight(.semibold)
    /// Title 3 (15) medium: onboarding steps, editor and sheet titles.
    static let title = Font.title3.weight(.medium)
    /// Title 2 (17) semibold: page and discovery headings.
    static let pageTitle = Font.title2.weight(.semibold)
    /// Body (13) semibold: a module page's status sentence.
    static let pageStatus = Font.body.weight(.semibold)
    /// Callout (12) semibold, shown in secondary colour: section titles
    /// ("Needs attention", "Rules") that sit above their group and recede.
    static let section = Font.body.weight(.semibold)
    /// Body (13) medium: card and tile titles, emphasised row titles.
    static let headline = Font.body.weight(.medium)
    /// Body (13): rows, sentences, buttons.
    static let body = Font.body
    /// Body (13) medium.
    static let bodyEmphasis = Font.body.weight(.medium)
    /// Callout (12): one-line descriptions, tile status lines.
    static let callout = Font.callout
    /// Subheadline (11): metadata (time, counts), section footers.
    static let caption = Font.subheadline
    /// Caption (10) medium: badges and keycaps, never sentences.
    static let badge = Font.caption.weight(.medium)
    /// Key codes, paths, logs, JSON.
    static let mono = Font.callout.monospaced()
    /// Body (13) medium: live values in rows; any changing number also gets
    /// `.monospacedDigit()`.
    static let metric = Font.body.weight(.medium).monospacedDigit()
    /// Title 2 (17) medium: tile counts and summary figures (Workspace, Insights).
    static let metricLarge = Font.title2.weight(.medium).monospacedDigit()

    /// Title (22) medium, monospaced digits: the one live figure of a page
    /// (a Focus timer, files tidied today). Never a sentence.
    static let display = Font.title.weight(.medium).monospacedDigit()
    /// Time stamps in live logs and history rows.
    static let timestamp = Font.subheadline.monospacedDigit()
    /// Token (pill) labels in token fields and condition values.
    static let token = Font.callout
}

// MARK: - Corner radii (continuous corners everywhere)

enum AOMRadius {
    /// Keycaps, tiny chips.
    static let keycap: CGFloat = 4
    /// Thumbnails and wells inside cards; minimum concentric radius.
    static let control: CGFloat = 5
    /// Layout diagrams and previews inside panes, row hover and selection fills.
    static let well: CGFloat = 6
    /// Panes (groups of rows), section groups: the macOS 26 card corner.
    static let card: CGFloat = 12
    /// ⌘K palette, the Workspace header, large HUDs, floating panels.
    static let panel: CGFloat = 14

    /// HUDs, toasts and the recording bar.
    static let hud = panel
    /// Control strips floating over the screen.
    static let bar = card
    /// Tiles and thumbnails inside a card.
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
    /// Main-window pages: the opaque canvas. Liquid Glass stays in the
    /// functional layer (sidebar, toolbar, floating panels); HIG Materials:
    /// "Don't use Liquid Glass in the content layer."
    static let pageBackground = canvas
    /// Groups of rows and content blocks: opaque white (#FFFFFF) in light
    /// mode, #2A2A2A in dark — one clear step above the canvas, never tinted.
    static let surface = Color.aomDynamic(light: .white,
                                          dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.165, alpha: 1),
                                          highContrastLight: .white,
                                          highContrastDark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1))
    /// Opaque: labels and small panels that sit over other drawn content
    /// (a chart's grid lines, a layout diagram). The frosted `surface` lets
    /// those lines run through the text, nearly unchanged in dark mode.
    static let overlaySurface = Color.aomDynamic(light: .white,
                                                 dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.165, alpha: 1),
                                                 highContrastLight: .white,
                                                 highContrastDark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1))
    /// A pane under the pointer: the fill shifts one small step.
    static let surfaceHover = Color.aomDynamic(light: NSColor(srgbRed: 0.980, green: 0.980, blue: 0.984, alpha: 1),
                                               dark: NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1))
    /// Pressed panes.
    static let surfacePressed = Color.aomDynamic(light: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.953, alpha: 1),
                                                 dark: NSColor(srgbRed: 0.220, green: 0.220, blue: 0.220, alpha: 1))
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
    /// Row symbol frame; the glyph is drawn at Callout, in secondary colour.
    static let row: CGFloat = 16
    /// Workspace tile and quick-action squircle, glyph 13 pt medium.
    static let tileBadge: CGFloat = 24
    static let tileGlyph: CGFloat = 13
    /// Page-header squircle.
    static let headerBadge: CGFloat = 28
    /// Empty-state glyph.
    static let empty: CGFloat = 28
    /// The symbol frame inside a text button (a capsule link): one Callout
    /// line tall, so a tall glyph (`rectangle.stack`) cannot make its button
    /// taller than its neighbours.
    static let inlineGlyph: CGFloat = 14
    /// Hit area for icon buttons: one regular control high.
    static let hitArea: CGFloat = 24
    /// Status dot inside pills and badges.
    static let dot: CGFloat = 6

    /// Large status header (Focus timer, Folder Rules today): the squircle
    /// and the progress ring around it.
    static let statusBadge: CGFloat = 36
    static let statusRing: CGFloat = 48
    /// Rows in a module's item list that carry a small squircle.
    static let listBadge: CGFloat = 20
    /// The glyph frame of a floating HUD (mic mute, focus start).
    static let hudGlyph: CGFloat = 40

    // 5.0 identity marks (AOMAppIcon): a filled glyph on the tool's hue.
    /// Setting rows, sidebar rows and palette rows (System Settings row icon).
    static let identityRow: CGFloat = 20
    /// The action bar at the bottom of a page.
    static let identityBar: CGFloat = 18
    /// Explore cards and Workspace module tiles.
    static let identityCard: CGFloat = 34
    /// A page's identity header.
    static let identityHeader: CGFloat = 40
    /// Empty states and the Workspace banner.
    static let identityHero: CGFloat = 52
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
