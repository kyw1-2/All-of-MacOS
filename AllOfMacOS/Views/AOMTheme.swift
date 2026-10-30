import AppKit
import SwiftUI

/// AOM visual language (3.3.3). The values live in AOMTokens.swift; this file
/// keeps the 3.x role names (`AOMTheme.*`, `AOMType.*`) as aliases of those
/// tokens, plus the shared surfaces and pressable styles.
///
/// Two layers, as on macOS 26/27: content sits on one opaque canvas in opaque
/// cards with a hairline (`aomCard`); navigation and floating controls
/// (sidebar, toolbar, palette, HUDs) are Liquid Glass drawn by the system or
/// by `aomChrome`. Colour is reserved for interaction (the accent), status
/// (semantic colours with a glyph and text) and module identity badges.
enum AOMTheme {
    // MARK: Canvas & surfaces

    /// The page canvas behind every page (opaque, #FFFFFF / #282828).
    static let canvas = AOMColor.canvas
    static let canvasNSColor = AOMColor.canvasNSColor
    /// A content pane (lists, editors, drawers): the same opaque canvas, so the
    /// background never shifts between pages.
    static let pane = AOMColor.canvas
    /// The work surface underneath documents and workflow steps.
    static let workspace = AOMColor.canvas
    /// Cards for discrete items: the one opaque surface.
    static let paper = AOMColor.surface
    static let card = paper
    static let solidCard = paper
    /// Quiet inset fill inside a card: wells, hovered rows, thumbnails.
    static let cardAlt = AOMColor.sunken
    /// Segmented tracks and pressed wells.
    static let track = AOMColor.track
    /// Dark emphasis surface (kept for older call sites; toasts are chrome now).
    static let ink = Color.aomDynamic(
        light: NSColor(srgbRed: 0.098, green: 0.122, blue: 0.157, alpha: 1),
        dark: NSColor(srgbRed: 0.188, green: 0.196, blue: 0.220, alpha: 1)
    )
    /// Retired frosted-card tint (cards are opaque now); kept for source compatibility.
    static let cardGlassTint = Color.clear
    /// Edges of cards and controls.
    static let hairline = AOMColor.hairline

    // MARK: Text

    static let text = AOMColor.text
    static let textSecondary = AOMColor.textSecondary
    static let textTertiary = AOMColor.textTertiary
    /// Row and section separators.
    static let divider = AOMColor.hairline

    // MARK: Roles

    /// The primary action and the current selection: the person's accent.
    static let blue = AOMColor.accent
    static let actionBlue = blue
    static let positive = AOMColor.success
    static let warning = AOMColor.warning
    static let danger = AOMColor.danger
    /// Category hues for small glyphs only, never large fills.
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

    static let cardRadius: CGFloat = AOMRadius.card
    static let windowContentRadius: CGFloat = AOMRadius.panel
    static let controlRadius: CGFloat = AOMRadius.control
    /// Page margin and the gap between page sections.
    static let pagePadding: CGFloat = AOMSpace.pageMargin
    static let sectionSpacing: CGFloat = AOMSpace.sectionGap

    // MARK: Depth

    static var cardShadow: Color { Color.black.opacity(0.03) }

    /// Edge for chrome: a neutral hairline that reads the same in light and dark.
    static func rim(hovering: Bool = false, contrast: ColorSchemeContrast = .standard) -> LinearGradient {
        if contrast == .increased {
            return LinearGradient(colors: [AOMColor.strongLine, AOMColor.strongLine], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color.primary.opacity(hovering ? 0.16 : 0.10), Color.primary.opacity(hovering ? 0.10 : 0.06)],
                              startPoint: .top, endPoint: .bottom)
    }
    static let rimWidth: CGFloat = 0.5

    /// The response shared by pressable surfaces (the `quick` motion token).
    static let press = AOMMotion.quickCurve
}

// MARK: - Typography

/// The 3.x type names, mapped onto the macOS text-style ramp in `AOMFont`.
/// Section pages take their title from the toolbar; content never repeats it.
enum AOMType {
    /// The name of the thing being edited (17 pt semibold).
    static let title1 = AOMFont.title
    /// An empty state or a sheet's heading (15 pt semibold).
    static let title2 = AOMFont.pageStatus
    /// A group heading inside a page (13 pt semibold).
    static let title3 = AOMFont.section
    /// Card titles and emphasised row titles (13 pt bold).
    static let headline = AOMFont.headline
    /// Badges, key hints and tertiary metadata (never body text).
    static let micro = AOMFont.badge
    static let pageTitle = AOMFont.title
    static let pageTracking: CGFloat = 0
    /// The Workspace hero sentence (17 pt semibold; never Large Title).
    static let heroTitle = AOMFont.heroSentence
    static let heroTracking: CGFloat = 0
    static let subtitle = AOMFont.body
    /// Small group labels inside a card: sentence case, no tracking (c.2).
    static let sectionCaps = AOMFont.caption.weight(.semibold)
    static let capsTracking: CGFloat = 0
    /// Section titles above cards.
    static let sectionTitle = AOMFont.section
    static let cardTitle = AOMFont.headline
    static let tileTitle = AOMFont.headline
    /// First line of a list row.
    static let rowTitle = AOMFont.body
    static let body = AOMFont.body
    static let bodyEmphasis = AOMFont.bodyEmphasis
    /// Second line of a row, captions, timestamps (11 pt).
    static let caption = AOMFont.caption
    static let meta = caption
    /// Figures: Metric for tiles, Metric Large for summary strips.
    static func metric(_ size: CGFloat = 22) -> Font { size >= 20 ? AOMFont.metricLarge : AOMFont.metric }
}

extension View {
    /// Editor title (17 pt semibold).
    func aomPageTitle() -> some View {
        font(AOMType.pageTitle).foregroundStyle(AOMTheme.text)
    }
    /// A small group label inside a card: sentence case, secondary.
    func aomSectionCaps() -> some View {
        font(AOMType.sectionCaps).foregroundStyle(AOMTheme.textSecondary)
    }
}

// MARK: - Window canvas

/// The window's lowest layer: the opaque page canvas.
struct AOMWindowCanvas: View {
    var body: some View {
        AOMColor.canvas
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Surfaces

/// The surfaces AOM uses. There is one content surface (the card); wells sit
/// inside it; glass is for floating chrome only.
enum AOMCardStyle: Equatable {
    /// The opaque card: `surface` fill and a 0.5 pt hairline.
    case paper
    /// Inset fill inside a card: no edge, no shadow.
    case well
    /// Floating chrome: system glass on macOS 26+, a material before.
    case glass
}

/// Applies one surface style. Cards never cast a shadow at rest and never
/// lift on hover; hover shifts the fill only (c.6).
struct AOMCardSurface: ViewModifier {
    var style: AOMCardStyle = .paper
    var radius: CGFloat = AOMRadius.card
    var padding: CGFloat? = AOMSpace.cardPadding
    var hovering = false
    /// Kept for source compatibility; elevation is tone, not shadow.
    var elevated = true
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityShowBorders) private var showBorders

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .paper:
            content
                .padding(padding ?? 0)
                .background(hovering ? AOMColor.surfaceHover : AOMColor.surface, in: shape)
                .overlay {
                    shape.strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline,
                                       lineWidth: contrast == .increased || showBorders ? 1 : 0.5)
                        .allowsHitTesting(false)
                }
                .containerShape(shape)
        case .well:
            content
                .padding(padding ?? 0)
                .background(AOMColor.sunken, in: shape)
                .overlay {
                    if contrast == .increased || showBorders {
                        shape.strokeBorder(AOMColor.hairline, lineWidth: 1).allowsHitTesting(false)
                    }
                }
        case .glass:
            content
                .padding(padding ?? 0)
                .aomChrome(radius: radius)
        }
    }
}

extension View {
    /// One AOM surface in the given style.
    func aomCardStyle(_ style: AOMCardStyle = .paper, radius: CGFloat = AOMTheme.cardRadius,
                      padding: CGFloat? = AOMSpace.cardPadding,
                      hovering: Bool = false, elevated: Bool = true) -> some View {
        modifier(AOMCardSurface(style: style, radius: radius, padding: padding, hovering: hovering, elevated: elevated))
    }

    /// The content layer's only card style: radius 12, `surface` fill, 0.5 pt
    /// hairline (1 pt with Increase Contrast or Show Borders), 12 pt padding
    /// for free content (pass 0 when the card holds rows).
    func aomCard(radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = AOMSpace.cardPadding,
                 elevated: Bool = true) -> some View {
        modifier(AOMCardSurface(style: .paper, radius: radius, padding: padding, elevated: elevated))
    }

    /// Floating chrome surface (glass on macOS 26+).
    func aomGlassCard(radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = AOMSpace.cardPadding,
                      hovering: Bool = false, elevated: Bool = true) -> some View {
        modifier(AOMCardSurface(style: .glass, radius: radius, padding: padding, hovering: hovering, elevated: elevated))
    }

    /// Retired: tiles never lift on hover (c.6). Kept as a no-op for call sites.
    func aomLift(_ hovering: Bool, radius: CGFloat = AOMTheme.cardRadius) -> some View {
        modifier(AOMLift(hovering: hovering, radius: radius))
    }
}

/// Retired hover lift: content is returned unchanged.
struct AOMLift: ViewModifier {
    var hovering: Bool
    var radius: CGFloat = AOMTheme.cardRadius

    func body(content: Content) -> some View { content }
}

/// A one-pixel separator that matches the card dividers.
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
            .padding(.horizontal, AOMSpace.x1 - 1)
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

/// The shared press response: a quick dim, no scale.
struct AOMCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AOMPressableBody(configuration: configuration)
    }
}

private struct AOMPressableBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .aomAnimation(.quick, value: configuration.isPressed)
    }
}

/// A row or cell inside a card as a button: a quiet hover wash and the shared
/// press response, no edge of its own.
struct AOMRowButtonStyle: ButtonStyle {
    var radius: CGFloat = AOMRadius.well

    func makeBody(configuration: Configuration) -> some View {
        AOMRowButtonBody(configuration: configuration, radius: radius)
    }
}

private struct AOMRowButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let radius: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .background(shape.fill(AOMColor.sunken.opacity(configuration.isPressed ? 1 : (hovering ? 0.7 : 0))))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .aomAnimation(.quick, value: configuration.isPressed)
            .aomAnimation(.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A whole card as a button: hover shifts the fill, a press dims.
struct AOMCardTileButtonStyle: ButtonStyle {
    var style: AOMCardStyle = .paper
    var radius: CGFloat = AOMTheme.cardRadius
    var padding: CGFloat? = AOMSpace.cardPadding

    func makeBody(configuration: Configuration) -> some View {
        AOMCardTileBody(configuration: configuration, style: style, radius: radius, padding: padding)
    }
}

/// Tile button kept for existing call sites.
struct AOMGlassTileButtonStyle: ButtonStyle {
    var radius: CGFloat = AOMTheme.cardRadius
    var padding: CGFloat? = AOMSpace.cardPadding
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

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .aomCardStyle(style, radius: radius, padding: padding, hovering: hovering && isEnabled)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.5)
            .aomAnimation(.quick, value: configuration.isPressed)
            .aomAnimation(.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Icon glyph

/// A content glyph without a background (hierarchical). `filled` keeps the
/// hue; unfilled glyphs are secondary. Module identity uses `AOMModuleBadge`.
struct AOMIconBadge: View {
    let systemImage: String
    var tint: Color = AOMTheme.blue
    var size: CGFloat = AOMIcon.tileBadge
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

// MARK: - Buttons

/// The one primary action of a view: the system prominent style (tinted glass
/// on macOS 26+). Kept as a style type for older call sites.
struct AOMFilledButtonStyle: PrimitiveButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(height >= 32 ? .large : .regular)
    }
}

/// A secondary action in content: the system bordered style. The tint is
/// ignored on purpose; colour is reserved for the primary action and status.
struct AOMTintedButtonStyle: PrimitiveButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .controlSize(height >= 32 ? .large : .regular)
    }
}

/// Small capsule for state and filters (renders as an `AOMStatusPill`).
struct AOMChip: View {
    let text: String
    var tint: Color = AOMTheme.textSecondary
    var background: Color?
    var symbol: String?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: AOMSpace.x1) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(AOMFont.badge)
        .foregroundStyle(tint)
        .padding(.horizontal, AOMSpace.x2)
        .frame(minHeight: AOMIcon.row)
        .background(background ?? tint.opacity(contrast == .increased ? 0.22 : 0.12), in: Capsule())
        .overlay { if contrast == .increased { Capsule().strokeBorder(tint, lineWidth: 1) } }
    }
}

/// A key cap for shortcut hints (the one keycap; `KeycapBadge` renders this).
struct AOMKeycap: View {
    let text: String
    /// White-on-transparent rendering for caps inside a selected list row.
    var onSelection = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.keycap, style: .continuous)
        Text(text)
            .font(AOMFont.badge)
            .foregroundStyle(onSelection ? Color.white.opacity(0.92) : AOMTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, AOMSpace.x1 + 1)
            .frame(minWidth: 18, minHeight: 18)
            .background(onSelection ? Color.white.opacity(0.18) : AOMColor.sunken, in: shape)
            .overlay {
                shape.strokeBorder(onSelection ? Color.white.opacity(0.35)
                                               : (contrast == .increased ? AOMColor.strongLine : AOMColor.hairline),
                                   lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .accessibilityLabel(text)
    }
}
