import AppKit
import SwiftUI

/// A single visual language for the whole app: a light grey canvas, white
/// elevated cards with no hairline borders, large confident type and one vivid
/// blue accent. Modelled on consumer fintech apps (Toss) rather than the
/// System Settings list idiom the app used before.
enum AOMTheme {
    // MARK: Palette

    static let canvas = Color.aomDynamic(
        light: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.063, green: 0.067, blue: 0.078, alpha: 1)
    )
    static let card = Color.aomDynamic(
        light: .white,
        dark: NSColor(srgbRed: 0.106, green: 0.110, blue: 0.125, alpha: 1)
    )
    static let cardAlt = Color.aomDynamic(
        light: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.141, green: 0.149, blue: 0.169, alpha: 1)
    )
    static let text = Color.aomDynamic(
        light: NSColor(srgbRed: 0.098, green: 0.122, blue: 0.157, alpha: 1),
        dark: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.965, alpha: 1)
    )
    static let textSecondary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.420, green: 0.463, blue: 0.518, alpha: 1),
        dark: NSColor(srgbRed: 0.604, green: 0.639, blue: 0.682, alpha: 1)
    )
    static let textTertiary = Color.aomDynamic(
        light: NSColor(srgbRed: 0.690, green: 0.722, blue: 0.757, alpha: 1),
        dark: NSColor(srgbRed: 0.451, green: 0.478, blue: 0.514, alpha: 1)
    )
    static let divider = Color.aomDynamic(
        light: NSColor(srgbRed: 0.898, green: 0.910, blue: 0.922, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.192, blue: 0.216, alpha: 1)
    )
    static let blue = Color.aomDynamic(
        light: NSColor(srgbRed: 0.192, green: 0.510, blue: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.278, green: 0.573, blue: 0.980, alpha: 1)
    )
    static let positive = Color.aomDynamic(
        light: NSColor(srgbRed: 0.0, green: 0.706, blue: 0.478, alpha: 1),
        dark: NSColor(srgbRed: 0.235, green: 0.784, blue: 0.573, alpha: 1)
    )
    static let warning = Color.aomDynamic(
        light: NSColor(srgbRed: 1.0, green: 0.478, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.573, blue: 0.157, alpha: 1)
    )

    // MARK: Geometry

    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 24

    // MARK: Shadow

    static var cardShadow: Color {
        Color.aomDynamic(light: NSColor.black.withAlphaComponent(0.055),
                         dark: NSColor.black.withAlphaComponent(0.45))
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

/// White, borderless, softly elevated card. The single container primitives
/// every page uses instead of System Settings' hairline-bordered boxes.
struct AOMCard: ViewModifier {
    var radius: CGFloat = AOMTheme.cardRadius
    var padding: CGFloat? = 20
    var elevated = true

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(AOMTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: elevated ? AOMTheme.cardShadow : .clear,
                    radius: elevated ? 14 : 0, x: 0, y: elevated ? 6 : 0)
    }
}

extension View {
    func aomCard(radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = 20, elevated: Bool = true) -> some View {
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
    var tint: Color = AOMTheme.blue
    var height: CGFloat = 48
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aomLabel(14.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet secondary action on the grey canvas.
struct AOMTintedButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.blue
    var height: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aomLabel(14))
            .foregroundStyle(tint)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint.opacity(configuration.isPressed ? 0.18 : 0.10),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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
