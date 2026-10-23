import AppKit
import SwiftUI

/// AOM visual language.
///
/// One flat, neutral canvas (Toss grey 100 in light mode, graphite in dark
/// mode) and one kind of surface: a white sheet with a hairline edge. Pages
/// group related content *inside* a sheet — rows, dividers and inset wells —
/// instead of scattering differently coloured cards. Colour is reserved for
/// small squircle icons, state and the one primary action blue. Text follows a
/// desktop-comfortable scale (14 pt body, 26 pt titles).
enum AOMTheme {
    // MARK: Canvas & surfaces

    private static let canvasLight = NSColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1)   // #F2F4F6
    private static let canvasDark = NSColor(srgbRed: 0.071, green: 0.075, blue: 0.086, alpha: 1)    // #121316

    /// The window canvas. Opaque and flat, so wallpaper never tints the UI.
    static let canvas = Color.aomDynamic(light: canvasLight, dark: canvasDark)
    static let canvasNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? canvasDark : canvasLight
    }
    /// The sheet: white (light) / raised graphite (dark).
    static let paper = Color.aomDynamic(
        light: .white,
        dark: NSColor(srgbRed: 0.110, green: 0.114, blue: 0.129, alpha: 1)     // #1C1D21
    )
    /// Fill for controls that sit on a sheet or the canvas.
    static let card = Color.aomDynamic(
        light: .white,
        dark: NSColor(srgbRed: 0.137, green: 0.141, blue: 0.161, alpha: 1)     // #232429
    )
    /// Quiet inset fill inside a sheet: wells, hovered rows, thumbnails.
    static let cardAlt = Color.aomDynamic(
        light: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1),   // #F2F4F6
        dark: NSColor(srgbRed: 0.149, green: 0.153, blue: 0.173, alpha: 1)     // #26272C
    )
    /// Segmented tracks that sit directly on the canvas.
    static let track = Color.aomDynamic(
        light: NSColor(srgbRed: 0.902, green: 0.914, blue: 0.929, alpha: 1),   // #E6E9ED
        dark: NSColor.white.withAlphaComponent(0.07)
    )
    /// Dark emphasis surface (toasts).
    static let ink = Color.aomDynamic(
        light: NSColor(srgbRed: 0.098, green: 0.122, blue: 0.157, alpha: 1),   // #191F28
        dark: NSColor(srgbRed: 0.188, green: 0.196, blue: 0.220, alpha: 1)     // #303238
    )
    static let solidCard = paper
    /// Sheet edge.
    static let hairline = Color.aomDynamic(
        light: NSColor.black.withAlphaComponent(0.055),
        dark: NSColor.white.withAlphaComponent(0.07)
    )

    // MARK: Text

    static let text = Color.aomDynamic(
        light: NSColor(srgbRed: 0.098, green: 0.122, blue: 0.157, alpha: 1),   // #191F28
        dark: NSColor(srgbRed: 0.937, green: 0.945, blue: 0.957, alpha: 1)     // #EFF1F4
    )
    static let textSecondary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.306, green: 0.349, blue: 0.408, alpha: 1),   // #4E5968
        dark: NSColor(srgbRed: 0.659, green: 0.690, blue: 0.729, alpha: 1)     // #A8B0BA
    )
    static let textTertiary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.545, green: 0.584, blue: 0.631, alpha: 1),   // #8B95A1
        dark: NSColor(srgbRed: 0.459, green: 0.494, blue: 0.537, alpha: 1)     // #757E89
    )
    /// Row and section separators inside a sheet.
    static let divider = Color.aomDynamic(
        light: NSColor(srgbRed: 0.918, green: 0.925, blue: 0.937, alpha: 1),   // #EAECEF
        dark: NSColor.white.withAlphaComponent(0.07)
    )

    // MARK: Accents

    static let blue = Color.aomDynamic(
        light: NSColor(srgbRed: 0.192, green: 0.510, blue: 0.965, alpha: 1),   // #3182F6
        dark: NSColor(srgbRed: 0.290, green: 0.584, blue: 0.976, alpha: 1)     // #4A95F9
    )
    /// Alias kept for call sites that name the primary action colour.
    static let actionBlue = blue
    static let indigo = Color.aomDynamic(
        light: NSColor(srgbRed: 0.365, green: 0.380, blue: 0.890, alpha: 1),   // #5D61E3
        dark: NSColor(srgbRed: 0.494, green: 0.506, blue: 0.980, alpha: 1)
    )
    static let cyan = Color.aomDynamic(
        light: NSColor(srgbRed: 0.000, green: 0.620, blue: 0.784, alpha: 1),   // #009EC8
        dark: NSColor(srgbRed: 0.220, green: 0.760, blue: 0.900, alpha: 1)
    )
    static let purple = Color.aomDynamic(
        light: NSColor(srgbRed: 0.596, green: 0.392, blue: 0.929, alpha: 1),   // #9864ED
        dark: NSColor(srgbRed: 0.700, green: 0.560, blue: 0.990, alpha: 1)
    )
    static let orange = Color.aomDynamic(
        light: NSColor(srgbRed: 0.976, green: 0.522, blue: 0.122, alpha: 1),   // #F9851F
        dark: NSColor(srgbRed: 1.000, green: 0.630, blue: 0.300, alpha: 1)
    )
    static let positive = Color.aomDynamic(
        light: NSColor(srgbRed: 0.012, green: 0.698, blue: 0.424, alpha: 1),   // #03B26C
        dark: NSColor(srgbRed: 0.200, green: 0.800, blue: 0.540, alpha: 1)
    )
    static let warning = Color.aomDynamic(
        light: NSColor(srgbRed: 0.965, green: 0.588, blue: 0.000, alpha: 1),
        dark: NSColor(srgbRed: 1.000, green: 0.690, blue: 0.200, alpha: 1)
    )
    /// The product mark: one blue, lit slightly from the top.
    static var heroGradient: LinearGradient {
        LinearGradient(colors: [heroStart, heroEnd], startPoint: .top, endPoint: .bottom)
    }
    static let heroStart = Color.aomDynamic(
        light: NSColor(srgbRed: 0.290, green: 0.584, blue: 0.976, alpha: 1),   // #4A95F9
        dark: NSColor(srgbRed: 0.290, green: 0.584, blue: 0.976, alpha: 1)
    )
    static let heroEnd = Color.aomDynamic(
        light: NSColor(srgbRed: 0.169, green: 0.443, blue: 0.918, alpha: 1),   // #2B71EA
        dark: NSColor(srgbRed: 0.169, green: 0.443, blue: 0.918, alpha: 1)
    )

    // MARK: Geometry

    /// Continuous corners at desktop scale.
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 10
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 20

    // MARK: Depth

    static var cardShadow: Color { Color.black.opacity(0.03) }

    /// Light rim used by glass chrome: highlight top leading, fade bottom trailing.
    static func rim(hovering: Bool = false, contrast: ColorSchemeContrast = .standard) -> LinearGradient {
        if contrast == .increased {
            return LinearGradient(colors: [Color(nsColor: .secondaryLabelColor), Color(nsColor: .tertiaryLabelColor)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [Color.white.opacity(hovering ? 0.65 : 0.45), Color.white.opacity(0.08)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let rimWidth: CGFloat = 0.75

    /// The physical response shared by every pressable surface.
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.8)
}

// MARK: - Typography

/// SF Pro at a desktop-comfortable scale with optical tracking.
enum AOMType {
    static let pageTitle = Font.system(size: 26, weight: .bold)
    static let pageTracking: CGFloat = -0.6
    static let heroTitle = Font.system(size: 26, weight: .bold)
    static let heroTracking: CGFloat = -0.6
    static let subtitle = Font.system(size: 14)
    /// Upper-case section labels.
    static let sectionCaps = Font.system(size: 11.5, weight: .bold)
    static let capsTracking: CGFloat = 0.8
    /// Titles of sections inside a sheet.
    static let sectionTitle = Font.system(size: 17, weight: .bold)
    static let cardTitle = Font.system(size: 16, weight: .semibold)
    static let tileTitle = Font.system(size: 15, weight: .semibold)
    static let rowTitle = Font.system(size: 14.5, weight: .semibold)
    static let body = Font.system(size: 14)
    static let bodyEmphasis = Font.system(size: 14, weight: .semibold)
    static let caption = Font.system(size: 12.5)
    static func metric(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold) }
}

extension Font {
    static func aomDisplay(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .bold) }
    static func aomTitle(_ size: CGFloat = 24) -> Font { .system(size: size, weight: .bold) }
    static func aomHeadline(_ size: CGFloat = 17) -> Font { .system(size: size + 1.5, weight: .semibold) }
    static func aomLabel(_ size: CGFloat = 14) -> Font { .system(size: size + 1.5, weight: .semibold) }
    static func aomBody(_ size: CGFloat = 14) -> Font { .system(size: size + 1.5, weight: .regular) }
    static func aomCaption(_ size: CGFloat = 12.5) -> Font { .system(size: size + 1.5, weight: .medium) }
}

extension View {
    /// Page title: 26 pt bold, −0.6 tracking.
    func aomPageTitle() -> some View {
        font(AOMType.pageTitle).tracking(AOMType.pageTracking).foregroundStyle(AOMTheme.text)
    }
    /// Upper-case section label.
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

/// The window's lowest layer: one flat neutral canvas. No glows or washes —
/// depth comes from the sheets on top of it.
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
        guard elevated, style != .well else { return 0 }
        if scheme == .dark { return hovering ? 0.30 : 0.18 }
        return hovering ? 0.06 : 0.025
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        switch style {
        case .paper:
            shape.fill(AOMTheme.paper)
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
                shape.strokeBorder(hovering ? AOMTheme.text.opacity(0.12) : AOMTheme.hairline, lineWidth: 0.75)
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

    var body: some View {
        if axis == .horizontal {
            Rectangle().fill(AOMTheme.divider).frame(height: 1)
        } else {
            Rectangle().fill(AOMTheme.divider).frame(width: 1)
        }
    }
}

/// The vertical hairline between a sheet's content and its trailing editor.
/// Dragging it resizes the editor, like a split-view divider; the hit area is
/// a few points wider than the line.
struct AOMResizeDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
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
                        width = min(range.upperBound, max(range.lowerBound, start - Double(value.translation.width)))
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
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
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
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
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
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : AOMTheme.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Icon badge

/// Squircle icon badge in the System Settings manner. `filled` is a solid
/// accent with a white glyph; otherwise a soft accent wash with an accent
/// glyph. No glows — the colour itself carries it.
struct AOMIconBadge: View {
    let systemImage: String
    var tint: Color = AOMTheme.blue
    var size: CGFloat = 44
    var filled = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .symbolRenderingMode(filled ? .monochrome : .hierarchical)
            .foregroundStyle(filled ? Color.white : tint)
            .frame(width: size, height: size)
            .background {
                if filled {
                    shape.fill(LinearGradient(colors: [tint, tint.aomDarker(0.10)], startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(tint.opacity(0.12))
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Search field

struct AOMSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(AOMTheme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(AOMType.body)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(AOMTheme.textTertiary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 36)
        .background(AOMTheme.paper, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? AOMTheme.blue.opacity(0.8) : AOMTheme.hairline, lineWidth: focused ? 1.5 : 0.75)
        }
    }
}

// MARK: - Buttons

/// Filled primary action.
struct AOMFilledButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 40

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint.aomDarker(configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0)), in: shape)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : AOMTheme.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// Soft secondary action (accent wash), Toss's "weak" button.
struct AOMTintedButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 36

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint.opacity(hovering ? 0.16 : 0.10), in: shape)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : AOMTheme.press, value: configuration.isPressed)
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
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
            }
            Text(text).font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(background ?? tint.opacity(0.12), in: Capsule())
    }
}

/// A key cap for shortcut hints.
struct AOMKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(AOMTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AOMTheme.hairline, lineWidth: 0.75)
            }
    }
}
