import AppKit
import SwiftUI

/// Neutral workspace surfaces with a single action accent. Shared by the
/// main window, editors, settings and clipboard shelf in light and dark mode.
enum AOMTheme {
    // MARK: Palette

    static let canvas = Color.aomDynamic(
        light: NSColor(srgbRed: 0.969, green: 0.965, blue: 0.953, alpha: 1),
        dark: NSColor(srgbRed: 0.086, green: 0.086, blue: 0.078, alpha: 1)
    )
    static let card = Color.aomDynamic(
        light: .white,
        dark: NSColor(srgbRed: 0.122, green: 0.118, blue: 0.106, alpha: 1)
    )
    static let cardAlt = Color.aomDynamic(
        light: NSColor(srgbRed: 0.945, green: 0.937, blue: 0.918, alpha: 1),
        dark: NSColor(srgbRed: 0.161, green: 0.157, blue: 0.145, alpha: 1)
    )
    static let text = Color.aomDynamic(
        light: NSColor(srgbRed: 0.106, green: 0.102, blue: 0.090, alpha: 1),
        dark: NSColor(srgbRed: 0.957, green: 0.953, blue: 0.937, alpha: 1)
    )
    static let textSecondary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.431, green: 0.416, blue: 0.380, alpha: 1),
        dark: NSColor(srgbRed: 0.659, green: 0.643, blue: 0.604, alpha: 1)
    )
    static let textTertiary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.663, green: 0.645, blue: 0.604, alpha: 1),
        dark: NSColor(srgbRed: 0.478, green: 0.463, blue: 0.431, alpha: 1)
    )
    static let divider = Color.aomDynamic(
        light: NSColor(srgbRed: 0.902, green: 0.886, blue: 0.855, alpha: 1),
        dark: NSColor(srgbRed: 0.196, green: 0.192, blue: 0.176, alpha: 1)
    )
    static let blue = Color.aomDynamic(
        light: NSColor(srgbRed: 0.184, green: 0.416, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.325, green: 0.514, blue: 0.996, alpha: 1)
    )
    /// Alias kept for call sites that name the primary action colour.
    static let actionBlue = blue
    static let indigo = Color.aomDynamic(
        light: NSColor(srgbRed: 0.404, green: 0.325, blue: 0.902, alpha: 1),
        dark: NSColor(srgbRed: 0.510, green: 0.443, blue: 0.960, alpha: 1)
    )
    static var heroGradient: LinearGradient {
        LinearGradient(colors: [blue, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let positive = Color.aomDynamic(
        light: NSColor(srgbRed: 0.0, green: 0.706, blue: 0.478, alpha: 1),
        dark: NSColor(srgbRed: 0.235, green: 0.784, blue: 0.573, alpha: 1)
    )
    static let warning = Color.aomDynamic(
        light: NSColor(srgbRed: 1.0, green: 0.478, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.573, blue: 0.157, alpha: 1)
    )

    // MARK: Geometry

    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 12
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 24

    // MARK: Shadow

    static var cardShadow: Color {
        Color.aomDynamic(light: NSColor.black.withAlphaComponent(0.025),
                         dark: NSColor.black.withAlphaComponent(0.18))
    }
}

/// Hover lift used by every interactive card: a small vertical translation and a
/// deeper shadow, suppressed when Reduce Motion is on.
struct AOMLift: ViewModifier {
    var hovering: Bool
    var radius: CGFloat = AOMTheme.cardRadius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .shadow(color: hovering ? AOMTheme.cardShadow : AOMTheme.cardShadow,
                    radius: hovering ? 22 : 12, x: 0, y: hovering ? 10 : 5)
            .offset(y: hovering && !reduceMotion ? -1.5 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: hovering)
    }
}

extension View {
    func aomLift(_ hovering: Bool, radius: CGFloat = AOMTheme.cardRadius) -> some View {
        modifier(AOMLift(hovering: hovering, radius: radius))
    }
}

extension Color {
    static func aomDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Card surface

/// Quiet content surface with a fine outline and no elevation.
struct AOMCard: ViewModifier {
    var radius: CGFloat = AOMTheme.cardRadius
    var padding: CGFloat? = 12
    var elevated = true
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(contrast == .increased ? AOMTheme.textSecondary : AOMTheme.divider.opacity(0.55), lineWidth: 1)
            }

    }
}

extension View {
    func aomCard(radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = 12, elevated: Bool = true) -> some View {
        modifier(AOMCard(radius: radius, padding: padding, elevated: elevated))
    }
}

// MARK: - Typography

extension Font {
    static func aomDisplay(_ size: CGFloat = 32) -> Font { .system(size: size, weight: .bold) }
    static func aomTitle(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold) }
    static func aomHeadline(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .bold) }
    static func aomLabel(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .semibold) }
    static func aomBody(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular) }
    static func aomCaption(_ size: CGFloat = 12.5) -> Font { .system(size: size, weight: .medium) }
}

// MARK: - Buttons

/// Filled, full-width-when-asked primary action: tall, rounded, one colour.
struct AOMFilledButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aomLabel(12))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(AOMDesign.animation(.easeOut(duration: 0.12)), value: configuration.isPressed)
    }
}

/// Quiet secondary action on the grey canvas.
struct AOMTintedButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.blue
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aomLabel(12))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint.opacity(configuration.isPressed ? 0.18 : 0.10),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Small pill, for state and filters.
struct AOMChip: View {
    let text: String
    var tint: Color = AOMTheme.textSecondary
    var background: Color?
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.aomCaption(12))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(background ?? tint.opacity(0.10), in: Capsule())
    }
}

/// Compact controls share the same generous hit area without expanding a toolbar.
struct AOMToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aomLabel(13))
            .foregroundStyle(configuration.role == .destructive ? Color.red : AOMTheme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(configuration.isPressed ? AOMTheme.divider : AOMTheme.cardAlt,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct AOMSearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(AOMTheme.textSecondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.aomBody(13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(AOMTheme.textSecondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(AOMTheme.cardAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Press feedback is immediate; motion respects the system accessibility setting.
struct AOMCardButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !AOMDesign.reduceMotion ? 0.985 : 1)
            .animation(AOMDesign.animation(.easeOut(duration: 0.14)), value: configuration.isPressed)
    }
}
