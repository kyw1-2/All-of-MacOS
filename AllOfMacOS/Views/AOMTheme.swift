import AppKit
import SwiftUI

/// AOM visual language (3.1, Liquid Glass alignment).
///
/// Two layers, as on macOS 26: content sits on the system window background
/// in opaque grouped boxes; navigation and floating controls (sidebar,
/// toolbar, panels, HUDs) are Liquid Glass drawn by the system or by
/// `aomFloatingSurface`. AOM no longer tints the canvas or paints a light rim
/// on opaque cards, so the toolbar's scroll-edge effect and the floating
/// sidebar render exactly as in Apple's own apps. See
/// docs/ui-liquid-glass-3.1.0.md for the 50+ references behind these rules.
///
/// macOS structure first: a system sidebar for navigation, a contextual
/// toolbar for the page's tools, and content panes on the system content
/// background. Colours are semantic system colours, so light/dark, Increase
/// Contrast and the user's accent choice come for free; colour is reserved for
/// the current selection, state and the one primary action. Text follows a
/// desktop scale (13 pt body, 11.5 pt metadata, 15 pt section titles, 22 pt
/// screen titles) instead of mobile sizes. These are AOM's own starting
/// values, not Apple or Toss specifications.
enum AOMTheme {
    // MARK: Canvas & surfaces

    /// The window background behind panes (system window background).
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let canvasNSColor = NSColor.windowBackgroundColor
    /// A content pane: lists, editors and libraries (white / dark grey).
    static let pane = Color(nsColor: .controlBackgroundColor)
    /// The work surface underneath documents and workflow steps: the system
    /// window background, so system glass and scroll-edge effects sample the
    /// same canvas as in Apple's apps (no custom tint).
    static let workspace = Color(nsColor: .windowBackgroundColor)
    /// Raised content inside a pane: cards for discrete items.
    static let paper = Color(nsColor: .controlBackgroundColor)
    static let card = paper
    static let solidCard = paper
    /// Quiet inset fill inside a pane: wells, hovered rows, thumbnails.
    static let cardAlt = Color.aomDynamic(
        light: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.961, alpha: 1),   // #F2F3F5
        dark: NSColor.white.withAlphaComponent(0.06)
    )
    /// Segmented tracks and pressed wells.
    static let track = Color.aomDynamic(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.09)
    )
    /// Dark emphasis surface (toasts).
    static let ink = Color.aomDynamic(
        light: NSColor(srgbRed: 0.098, green: 0.122, blue: 0.157, alpha: 1),   // #191F28
        dark: NSColor(srgbRed: 0.188, green: 0.196, blue: 0.220, alpha: 1)     // #303238
    )
    /// A faint fill laid over the card material so text keeps contrast on a
    /// busy desktop without hiding the glass (lighter in dark mode).
    static let cardGlassTint = Color.aomDynamic(
        light: NSColor.white.withAlphaComponent(0.5),
        dark: NSColor.white.withAlphaComponent(0.04)
    )
    /// Edges of cards and controls.
    static let hairline = Color(nsColor: .separatorColor)

    // MARK: Text

    static let text = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    /// Row and section separators.
    static let divider = Color(nsColor: .separatorColor)

    // MARK: Roles

    /// The primary action and the current selection: the app's accent
    /// (Settings → Appearance), Toss blue by default.
    static let blue = Color.accentColor
    static let actionBlue = blue
    static let positive = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    /// Category hues for small glyphs only — never large fills.
    static let indigo = Color(nsColor: .systemIndigo)
    static let cyan = Color(nsColor: .systemTeal)
    static let purple = Color(nsColor: .systemPurple)
    static let orange = Color(nsColor: .systemOrange)
    /// The product mark.
    static var heroGradient: LinearGradient {
        LinearGradient(colors: [heroStart, heroEnd], startPoint: .top, endPoint: .bottom)
    }
    static let heroStart = Color(nsColor: NSColor(srgbRed: 0.290, green: 0.584, blue: 0.976, alpha: 1))
    static let heroEnd = Color(nsColor: NSColor(srgbRed: 0.169, green: 0.443, blue: 0.918, alpha: 1))

    /// Label colour for text and glyphs on an accent fill. Light accents
    /// (yellow, orange, cyan, green) get near-black; the rest keep white.
    /// Derived from WCAG relative luminance of the fill, so it also holds for
    /// the user's accent choices in Settings → Appearance.
    static func onAccent(_ accent: Color) -> Color {
        guard let rgb = NSColor(accent).usingColorSpace(.deviceRGB) else { return .white }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        // Above ~0.35 white text drops below ~3:1 contrast while black rises
        // past ~8:1, so the light accents flip to a dark label.
        if luminance > 0.35 {
            return Color(nsColor: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        }
        return .white
    }

    // MARK: Geometry

    /// Cards for discrete items (captures, clipboard cards, notices). AOM 3
    /// steps every radius down so nested corners stay concentric inside the
    /// macOS 26 window corner (see `AOMRadius`).
    static let cardRadius: CGFloat = AOMRadius.card
    static let windowContentRadius: CGFloat = 18
    static let controlRadius: CGFloat = AOMRadius.control
    /// 3.2: tighter page gutters so content fills the window instead of
    /// floating in a wide margin (the "too much whitespace" fix).
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 12

    // MARK: Depth

    static var cardShadow: Color { Color.black.opacity(0.03) }

    /// Edge for cards and chrome. A neutral hairline that reads the same in
    /// light and dark (the old white rim vanished on light cards and glowed on
    /// dark ones).
    static func rim(hovering: Bool = false, contrast: ColorSchemeContrast = .standard) -> LinearGradient {
        if contrast == .increased {
            return LinearGradient(colors: [Color(nsColor: .secondaryLabelColor), Color(nsColor: .tertiaryLabelColor)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [Color.primary.opacity(hovering ? 0.16 : 0.10), Color.primary.opacity(hovering ? 0.10 : 0.05)],
                              startPoint: .top, endPoint: .bottom)
    }
    static let rimWidth: CGFloat = 0.5

    /// The response shared by pressable surfaces: quick, no bounce.
    static let press = Animation.easeOut(duration: 0.12)
}

// MARK: - Spacing, sizes and motion

/// Spacing tokens (pt). Use the role, not the number. 3.2 tightened the scale
/// one notch to raise content density without crowding controls.
enum AOMSpace {
    /// Icon-to-label gaps, tight stacks.
    static let xxs: CGFloat = 4
    /// Between related controls, row inner gaps.
    static let xs: CGFloat = 7
    /// Row horizontal padding, list header padding.
    static let s: CGFloat = 10
    /// Between groups inside a section; pane padding in dense panes.
    static let m: CGFloat = 13
    /// Pane padding; between sections.
    static let l: CGFloat = 18
    /// Above major page blocks.
    static let xl: CGFloat = 24
}

/// Layout sizes shared by the shell and pages (pt).
enum AOMSize {
    /// Global sidebar.
    static let sidebarMin: CGFloat = 190
    static let sidebarIdeal: CGFloat = 218
    static let sidebarMax: CGFloat = 260
    /// The Automation list column; the editor takes the rest.
    static let listColumnRange: ClosedRange<Double> = 270...380
    static let listColumnIdeal: Double = 312
    /// Below this the editor can't show an action row without truncating.
    static let editorMinimum: CGFloat = 440
    /// One- and two-line rows (2.2 compact density).
    static let rowSingle: CGFloat = 30
    static let rowDouble: CGFloat = 44
    /// A two-line row inside a `List`, including the list's own insets. Used
    /// as the list's minimum row height so rows inserted at the top (a new
    /// copy, a new automation) are never measured short.
    static let listRowDouble: CGFloat = 50
    /// Readable line length for editors and forms.
    static let readableWidth: CGFloat = 760
    /// One maximum content width for every page, so cards line up when you
    /// move between Workspace, Audio, Window Tiling and Insights.
    static let contentMaxWidth: CGFloat = 1120
    /// The one main-window minimum (content size). AppKit no longer applies a
    /// second, larger minimum after launch (it was 1040 × 650 vs 980 × 600).
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

/// Motion tokens. Every value collapses to no animation under Reduce Motion.
enum AOMMotion {
    /// Hover, press, small colour and opacity changes.
    static var quick: Animation? { AOMDesign.reduceMotion ? nil : .easeOut(duration: 0.12) }
    /// Panels, disclosure and layout changes.
    static var panel: Animation? { AOMDesign.reduceMotion ? nil : .snappy(duration: 0.22) }
}

// MARK: - Typography

/// The desktop type scale. Sizes track the macOS text styles (HIG: Title 1
/// 22, Title 2 17, Title 3 15, Headline/Body 13, Callout 12, Subheadline 11),
/// one step larger only for titles that name what you are editing. Section
/// pages take their title from the toolbar; content never repeats it.
enum AOMType {
    /// Title 1: the name of the thing being edited (22 pt).
    static let title1 = Font.title.weight(.semibold)
    /// Title 2: an empty state or a sheet's heading (17 pt).
    static let title2 = Font.title2.weight(.semibold)
    /// Title 3: a group heading inside a page (15 pt).
    static let title3 = Font.title3.weight(.semibold)
    /// Headline: card titles and emphasised row titles (13 pt bold).
    static let headline = Font.headline
    /// Badges, key hints and tertiary metadata (never body text).
    static let micro = Font.caption
    /// Screen title in content (the name of the thing being edited).
    static let pageTitle = Font.title.weight(.bold)
    static let pageTracking: CGFloat = -0.2
    static let heroTitle = pageTitle
    static let heroTracking = pageTracking
    static let subtitle = Font.body
    /// Upper-case micro labels (sparingly).
    static let sectionCaps = Font.subheadline.weight(.semibold)
    static let capsTracking: CGFloat = 0.4
    /// Section headings inside a pane.
    static let sectionTitle = Font.title3.weight(.semibold)
    static let cardTitle = Font.headline
    static let tileTitle = Font.headline
    /// First line of a list row.
    static let rowTitle = Font.body.weight(.medium)
    static let body = Font.body
    static let bodyEmphasis = Font.body.weight(.semibold)
    /// Second line of a row, captions, timestamps (11 pt).
    static let caption = Font.subheadline
    static let meta = caption
    static func metric(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

extension Font {
    static func aomDisplay(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .bold) }
    static func aomTitle(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .semibold) }
    static func aomHeadline(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold) }
    static func aomLabel(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold) }
    static func aomBody(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .regular) }
    static func aomCaption(_ size: CGFloat = 11.5) -> Font { .system(size: size, weight: .medium) }
}

extension View {
    /// Screen title: 22 pt semibold.
    func aomPageTitle() -> some View {
        font(AOMType.pageTitle).tracking(AOMType.pageTracking).foregroundStyle(AOMTheme.text)
    }
    /// Upper-case micro label.
    func aomSectionCaps() -> some View {
        font(AOMType.sectionCaps).tracking(AOMType.capsTracking).textCase(.uppercase).foregroundStyle(AOMTheme.textTertiary)
    }
}

extension Color {
    static func aomDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Window canvas

/// The window's lowest layer (system window background).
struct AOMWindowCanvas: View {
    var body: some View {
        AOMTheme.canvas
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Surfaces

/// The surfaces AOM uses. There is deliberately one content surface (the
/// sheet); everything else is grouped inside it.
enum AOMCardStyle: Equatable {
    /// White (light) / graphite (dark) sheet with a hairline edge.
    case paper
    /// Inset grey fill inside a sheet: no edge, no shadow.
    case well
    /// Frosted material with a rim light — floating chrome only.
    case glass
}

/// Applies one surface style: fill, edge, a barely-there shadow, continuous
/// corners.
struct AOMCardSurface: ViewModifier {
    var style: AOMCardStyle = .paper
    var radius: CGFloat = AOMTheme.cardRadius
    var padding: CGFloat? = 18
    var hovering = false
    var elevated = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding ?? 0)
            .background {
                background(shape)
                    .shadow(color: .black.opacity(shadowOpacity), radius: hovering ? 10 : 3, x: 0, y: hovering ? 4 : 1)
            }
            .overlay { edge(shape).allowsHitTesting(false) }
    }

    private var shadowOpacity: Double {
        guard elevated, style != .well, hovering else { return 0 }
        return scheme == .dark ? 0.30 : 0.06
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        switch style {
        case .paper:
            // 3.2 Liquid Glass: content cards are frosted on macOS 26 so the
            // translucent canvas (and the desktop behind it) reads through,
            // giving real depth instead of a flat white panel. Reduce
            // Transparency and Increase Contrast keep the opaque fill.
            if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(AOMTheme.cardGlassTint)
                }
            } else {
                shape.fill(AOMTheme.paper)
            }
        case .well:
            shape.fill(AOMTheme.cardAlt)
        case .glass:
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.white.opacity(scheme == .dark ? 0.04 : 0.35))
            }
        }
    }

    @ViewBuilder
    private func edge(_ shape: RoundedRectangle) -> some View {
        if contrast == .increased {
            shape.strokeBorder(Color(nsColor: .secondaryLabelColor), lineWidth: 1)
        } else {
            switch style {
            case .paper:
                shape.strokeBorder(hovering ? AOMTheme.text.opacity(0.14) : AOMTheme.hairline.opacity(0.9), lineWidth: 0.5)
            case .well:
                EmptyView()
            case .glass:
                shape.strokeBorder(AOMTheme.rim(hovering: hovering), lineWidth: AOMTheme.rimWidth)
            }
        }
    }
}

extension View {
    /// One AOM surface in the given style.
    func aomCardStyle(_ style: AOMCardStyle = .paper, radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = 18,
                      hovering: Bool = false, elevated: Bool = true) -> some View {
        modifier(AOMCardSurface(style: style, radius: radius, padding: padding, hovering: hovering, elevated: elevated))
    }

    /// Source-compatible sheet (paper).
    func aomCard(radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = 20, elevated: Bool = true) -> some View {
        modifier(AOMCardSurface(style: .paper, radius: radius, padding: padding, elevated: elevated))
    }

    /// Frosted surface for floating chrome.
    func aomGlassCard(radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = 16,
                      hovering: Bool = false, elevated: Bool = true) -> some View {
        modifier(AOMCardSurface(style: .glass, radius: radius, padding: padding, hovering: hovering, elevated: elevated))
    }

    func aomLift(_ hovering: Bool, radius: CGFloat = AOMTheme.cardRadius) -> some View {
        modifier(AOMLift(hovering: hovering, radius: radius))
    }
}

/// A one-point rise on hover that Reduce Motion removes.
struct AOMLift: ViewModifier {
    var hovering: Bool
    var radius: CGFloat = AOMTheme.cardRadius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: hovering && !reduceMotion ? -1 : 0)
            .animation(reduceMotion ? nil : AOMTheme.press, value: hovering)
    }
}

/// A one-pixel separator that matches the sheet dividers.
struct AOMDivider: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var scale

    var body: some View {
        let line = 1 / max(scale, 1)
        if axis == .horizontal {
            Rectangle().fill(AOMTheme.divider).frame(height: line)
        } else {
            Rectangle().fill(AOMTheme.divider).frame(width: line)
        }
    }
}

/// The vertical hairline between a sheet's content and its trailing editor.
/// Dragging it resizes the editor, like a split-view divider; the hit area is
/// a few points wider than the line.
struct AOMResizeDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which side of the divider the resized pane is on.
    var paneEdge: HorizontalEdge = .trailing
    @State private var dragStart: Double?
    @State private var hovering = false

    var body: some View {
        AOMDivider(axis: .vertical)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hovering { NSCursor.pop(); hovering = false }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        let delta = Double(value.translation.width) * (paneEdge == .trailing ? -1 : 1)
                        width = min(range.upperBound, max(range.lowerBound, start + delta))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Pressable surfaces

/// The shared physical response: 0.985 scale on press with a spring.
struct AOMCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AOMPressableBody(configuration: configuration)
    }
}

private struct AOMPressableBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .animation(reduceMotion ? nil : AOMTheme.press, value: configuration.isPressed)
    }
}

/// A row or cell inside a sheet as a button: a grey hover wash and the shared
/// spring press, no edge of its own.
struct AOMRowButtonStyle: ButtonStyle {
    var radius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        AOMRowButtonBody(configuration: configuration, radius: radius)
    }
}

private struct AOMRowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let radius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .background(shape.fill(AOMTheme.cardAlt.opacity(configuration.isPressed ? 1 : (hovering ? 0.85 : 0))))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : AOMTheme.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A whole sheet as a button: hover darkens the edge and lifts the shadow, a
/// press springs to 0.985.
struct AOMCardTileButtonStyle: ButtonStyle {
    var style: AOMCardStyle = .paper
    var radius: CGFloat = AOMTheme.cardRadius
    var padding: CGFloat? = 18

    func makeBody(configuration: Configuration) -> some View {
        AOMCardTileBody(configuration: configuration, style: style, radius: radius, padding: padding)
    }
}

/// Tile button kept for existing call sites.
struct AOMGlassTileButtonStyle: ButtonStyle {
    var radius: CGFloat = AOMTheme.cardRadius
    var padding: CGFloat? = 16
    var style: AOMCardStyle = .paper

    func makeBody(configuration: Configuration) -> some View {
        AOMCardTileBody(configuration: configuration, style: style, radius: radius, padding: padding)
    }
}

private struct AOMCardTileBody: View {
    let configuration: ButtonStyle.Configuration
    let style: AOMCardStyle
    let radius: CGFloat
    let padding: CGFloat?
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .aomCardStyle(style, radius: radius, padding: padding, hovering: hovering && isEnabled)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.5)
            .animation(reduceMotion ? nil : AOMTheme.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Icon glyph

/// A category or status glyph. 2.0 drops the coloured squircle backgrounds:
/// the glyph alone carries the hue, so content, selection and actions read
/// before decoration. `filled` keeps the hue; unfilled glyphs are secondary.
struct AOMIconBadge: View {
    let systemImage: String
    var tint: Color = AOMTheme.blue
    var size: CGFloat = 28
    var filled = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: max(11, size * 0.5), weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(filled ? tint : AOMTheme.textSecondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Search field

/// In-pane search field (pages prefer `.searchable` in the toolbar).

// MARK: - Buttons

/// Filled primary action (one per view).
struct AOMFilledButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        AOMFilledBody(configuration: configuration, tint: tint, height: height)
    }
}

private struct AOMFilledBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let height: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // macOS 26 control geometry: a capsule-ended rounded rectangle with a
        // flat accent fill; Liquid Glass supplies depth, not a painted rim.
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(AOMTheme.onAccent(tint))
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .background(tint.aomDarker(configuration.isPressed ? 0.14 : (hovering ? 0.07 : 0)), in: shape)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// Soft secondary action (accent wash), Toss's "weak" button.
struct AOMTintedButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        AOMTintedBody(configuration: configuration, tint: tint, height: height)
    }
}

private struct AOMTintedBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let height: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background(tint.opacity(configuration.isPressed ? 0.22 : (hovering ? 0.16 : 0.10)), in: shape)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// Small capsule for state and filters.
struct AOMChip: View {
    let text: String
    var tint: Color = AOMTheme.textSecondary
    var background: Color?
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(background ?? tint.opacity(contrast == .increased ? 0.22 : 0.12), in: Capsule())
        .overlay { if contrast == .increased { Capsule().strokeBorder(tint, lineWidth: 1) } }
    }

    @Environment(\.colorSchemeContrast) private var contrast
}

/// A key cap for shortcut hints.
struct AOMKeycap: View {
    let text: String
    /// White-on-transparent rendering for caps inside a selected list row,
    /// where the chip's fixed card fill would sit unreadably on the accent.
    var onSelection = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(onSelection ? Color.white.opacity(0.92) : AOMTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(onSelection ? Color.white.opacity(0.18) : AOMTheme.cardAlt,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(onSelection ? Color.white.opacity(0.35)
                                              : (contrast == .increased ? AOMTheme.textSecondary : AOMTheme.hairline),
                                  lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .overlay {
                // Lit top edge: key caps read as tiny glass chips.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                 startPoint: .top, endPoint: .center), lineWidth: 0.5)
            }
            .accessibilityLabel(text)
    }

    @Environment(\.colorSchemeContrast) private var contrast
}
