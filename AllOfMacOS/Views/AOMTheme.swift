import AppKit
import SwiftUI

/// Neutral workspace surfaces with a single action accent. Shared by the
/// main window, editors, settings and clipboard shelf in light and dark mode.
enum AOMTheme {
    // MARK: Palette

    static let canvas = Color.aomDynamic(
        light: NSColor(srgbRed: 0.985, green: 0.985, blue: 0.981, alpha: 1),
        dark: NSColor(srgbRed: 0.094, green: 0.094, blue: 0.102, alpha: 1)
    )
    static let card = Color.aomDynamic(
        light: .white,
        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1)
    )
    static let cardAlt = Color.aomDynamic(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.945, alpha: 1),
        dark: NSColor(srgbRed: 0.153, green: 0.153, blue: 0.165, alpha: 1)
    )
    static let text = Color.aomDynamic(
        light: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.165, alpha: 1),
        dark: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1)
    )
    static let textSecondary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.427, green: 0.427, blue: 0.455, alpha: 1),
        dark: NSColor(srgbRed: 0.604, green: 0.639, blue: 0.682, alpha: 1)
    )
    static let textTertiary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.520, green: 0.520, blue: 0.550, alpha: 1),
        dark: NSColor(srgbRed: 0.451, green: 0.478, blue: 0.514, alpha: 1)
    )
    static let divider = Color.aomDynamic(
        light: NSColor(srgbRed: 0.875, green: 0.875, blue: 0.890, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.192, blue: 0.216, alpha: 1)
    )
    static let blue = Color.aomDynamic(
        light: NSColor(srgbRed: 0.192, green: 0.510, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.278, green: 0.573, blue: 0.980, alpha: 1)
    )
    /// White labels need a deeper blue than small accent icons.
    static let actionBlue = Color(red: 0.125, green: 0.424, blue: 0.90)
    static let positive = Color.aomDynamic(
        light: NSColor(srgbRed: 0.0, green: 0.706, blue: 0.478, alpha: 1),
        dark: NSColor(srgbRed: 0.235, green: 0.784, blue: 0.573, alpha: 1)
    )
    static let warning = Color.aomDynamic(
        light: NSColor(srgbRed: 1.0, green: 0.478, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.573, blue: 0.157, alpha: 1)
    )

    // MARK: Geometry

    static let cardRadius: CGFloat = 9
    static let controlRadius: CGFloat = 6
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18

    // MARK: Shadow

    static var cardShadow: Color {
        Color.aomDynamic(light: NSColor.black.withAlphaComponent(0.025),
                         dark: NSColor.black.withAlphaComponent(0.18))
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
