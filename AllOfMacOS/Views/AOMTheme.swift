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

// MARK: - Ambient glass background

/// Frosted backdrop: a desaturated base plus three static colour fields, so the
/// material has something to refract without a per-frame blur cost.
struct AOMAmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AOMTheme.canvas.opacity(0.94)
                Circle()
                    .fill(AOMTheme.blue.opacity(scheme == .dark ? 0.30 : 0.20))
                    .frame(width: 620, height: 620)
                    .blur(radius: 140)
                    .offset(x: -geometry.size.width * 0.30, y: -geometry.size.height * 0.32)
                Circle()
                    .fill(AOMTheme.indigo.opacity(scheme == .dark ? 0.26 : 0.16))
                    .frame(width: 520, height: 520)
                    .blur(radius: 130)
                    .offset(x: geometry.size.width * 0.32, y: -geometry.size.height * 0.08)
                Circle()
                    .fill(Color(red: 0.20, green: 0.72, blue: 0.86).opacity(scheme == .dark ? 0.16 : 0.10))
                    .frame(width: 460, height: 460)
                    .blur(radius: 130)
                    .offset(x: geometry.size.width * 0.06, y: geometry.size.height * 0.44)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(AOMTheme.card)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(scheme == .dark ? Color.black.opacity(0.30) : Color.white.opacity(0.52))
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(contrast == .increased
                                  ? AOMTheme.textSecondary
                                  : Color.white.opacity(scheme == .dark ? 0.22 : 0.65),
                                  lineWidth: contrast == .increased ? 1 : 0.9)
            }
            .shadow(color: elevated ? AOMTheme.cardShadow : .clear,
                    radius: elevated ? 18 : 0, x: 0, y: elevated ? 8 : 0)
    }
}

struct AOMCardButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !AOMDesign.reduceMotion ? 0.985 : 1)
            .animation(AOMDesign.animation(.easeOut(duration: 0.14)), value: configuration.isPressed)
    }
}

/// Search field on the same glass language as cards.
struct AOMSearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AOMTheme.textSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Font.aomBody(13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(AOMTheme.textTertiary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8)
        }
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

extension View {
    func aomCard(radius: CGFloat = AOMTheme.cardRadius, padding: CGFloat? = 20, elevated: Bool = true) -> some View {
        modifier(AOMCard(radius: radius, padding: padding, elevated: elevated))
    }
}

// MARK: - Buttons

/// Filled primary action: tall, rounded, one colour.
struct AOMFilledButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.aomLabel(13.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// Quiet secondary action on glass.
struct AOMTintedButtonStyle: ButtonStyle {
    var tint: Color = AOMTheme.actionBlue
    var height: CGFloat = 40
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.aomLabel(13))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8)
            }
            .opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.45))
    }
}

/// Small pill for state and filters.
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
            Text(text).font(Font.aomCaption(12))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(background ?? tint.opacity(0.10), in: Capsule())
    }
}
