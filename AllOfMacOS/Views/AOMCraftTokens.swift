import AppKit
import SwiftUI

// MARK: - Dynamic Color & Warm Neutral Palette

enum AOMCraftColor {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// 불투명 웜 뉴트럴 메인 창 캔버스 (유리 금지)
    static let canvas = dynamic(
        light: NSColor(srgbRed: 0.969, green: 0.965, blue: 0.953, alpha: 1), // #F7F6F3
        dark:  NSColor(srgbRed: 0.094, green: 0.094, blue: 0.102, alpha: 1)  // #18181A
    )

    /// 1단계 밝은 불투명 본문 카드/그룹 표면
    static let surface = dynamic(
        light: NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1), // #FFFFFF
        dark:  NSColor(srgbRed: 0.133, green: 0.133, blue: 0.145, alpha: 1)  // #222225
    )

    /// 80ms 호버 필 전환용 (확대/이동 금지)
    static let rowHover = dynamic(
        light: NSColor.black.withAlphaComponent(0.045),
        dark:  NSColor.white.withAlphaComponent(0.065)
    )

    static let hairline = dynamic(
        light: NSColor.black.withAlphaComponent(0.08),
        dark:  NSColor.white.withAlphaComponent(0.09)
    )

    static let specularEdge = dynamic(
        light: NSColor.white.withAlphaComponent(0.55),
        dark:  NSColor.white.withAlphaComponent(0.14)
    )

    // 7.0 launcher ink: text over the frosted launcher stays readable on any
    // wallpaper. The system's tertiary label is ~26 % black in light mode,
    // too faint over glass; these hold ≥ 4.5:1 (primary, secondary) and
    // ≥ 3:1 (tertiary) on the launcher base below.
    static let ink = dynamic(light: NSColor.black.withAlphaComponent(0.88), dark: NSColor.white.withAlphaComponent(0.94))
    static let inkSecondary = dynamic(light: NSColor.black.withAlphaComponent(0.64), dark: NSColor.white.withAlphaComponent(0.68))
    static let inkTertiary = dynamic(light: NSColor.black.withAlphaComponent(0.50), dark: NSColor.white.withAlphaComponent(0.50))

    /// The launcher's own surface under its content: mostly opaque, so the
    /// glass shows at the rim and never behind the text.
    static let launcherBase = dynamic(
        light: NSColor(srgbRed: 0.984, green: 0.980, blue: 0.973, alpha: 0.86), // #FBFAF8
        dark:  NSColor(srgbRed: 0.110, green: 0.110, blue: 0.122, alpha: 0.86)  // #1C1C1F
    )
    static let launcherBaseOpaque = dynamic(
        light: NSColor(srgbRed: 0.984, green: 0.980, blue: 0.973, alpha: 1),
        dark:  NSColor(srgbRed: 0.110, green: 0.110, blue: 0.122, alpha: 1)
    )
    /// Raycast's neutral selection: a quiet fill, the text keeps its colours.
    static let selection = dynamic(light: NSColor.black.withAlphaComponent(0.075), dark: NSColor.white.withAlphaComponent(0.11))
    static let selectionEdge = dynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.08))
    /// Wells inside the launcher: the footer, code blocks, the question chip.
    static let well = dynamic(light: NSColor.black.withAlphaComponent(0.035), dark: NSColor.white.withAlphaComponent(0.05))
    static let codeWell = dynamic(
        light: NSColor(srgbRed: 0.949, green: 0.945, blue: 0.937, alpha: 1),
        dark:  NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
    )

    static let workbenchCanvas = Color(nsColor: NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)) // #141416
    static let overdriveAmber = Color(nsColor: NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1))  // #F59E0B
    static let overdriveHot   = Color(nsColor: NSColor(srgbRed: 0.937, green: 0.267, blue: 0.267, alpha: 1))  // #EF4444
}

// MARK: - AOM Corner Radii

enum AOMCraftRadius {
    static let launcherPanel: CGFloat = 26
    static let floatingPanel: CGFloat = 18
    static let actionPopover: CGFloat = 16
    static let card: CGFloat = 12
    static let row: CGFloat = 10
    static let control: CGFloat = 8
    static let keycap: CGFloat = 5
}

// MARK: - Event-Based Motion (Reduce Motion Aware)

enum AOMCraftMotion {
    static let hoverFill  = Animation.easeOut(duration: 0.08)
    static let stackPush  = Animation.snappy(duration: 0.18, extraBounce: 0)
    static let tabSlide   = Animation.spring(response: 0.22, dampingFraction: 0.86)
    static let inlineFold = Animation.smooth(duration: 0.22)
    static let shelfIn    = Animation.spring(response: 0.16, dampingFraction: 0.88)
    static let shelfOut   = Animation.easeIn(duration: 0.18)
    static let crossfade  = Animation.easeOut(duration: 0.10)

    static func resolve(_ curve: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : curve
    }
}

// MARK: - Strict 2-Layer Surface Modifiers

struct AOMFloatingGlassModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if reduceTransparency || contrast == .increased {
                content
                    .background(AOMCraftColor.surface, in: shape)
                    .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            } else if #available(macOS 26, *) {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.strokeBorder(AOMCraftColor.specularEdge, lineWidth: 0.5))
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(AOMCraftColor.specularEdge, lineWidth: 0.5))
            }
        }
    }
}

/// 7.0: the launcher panel. Glass (macOS 26) or a material underneath, the
/// mostly opaque launcher base on top of it, a 0.5 pt rim and a faint top
/// light. Reduce Transparency and Increase Contrast get the opaque base.
struct AOMLauncherSurfaceModifier: ViewModifier {
    let radius: CGFloat
    var inWindow = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let solid = reduceTransparency || contrast == .increased
        let based = content
            .background(solid ? AOMCraftColor.launcherBaseOpaque : AOMCraftColor.launcherBase, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color(nsColor: .separatorColor)
                        : AOMCraftColor.hairline,
                    lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                // The light catching the top edge.
                shape.strokeBorder(LinearGradient(colors: [AOMCraftColor.specularEdge, .clear],
                                                  startPoint: .top, endPoint: .center), lineWidth: 0.75)
                    .allowsHitTesting(false)
                    .opacity(solid ? 0 : 1)
            }
        Group {
            if solid {
                based
            } else if #available(macOS 26, *) {
                based.glassEffect(.regular, in: shape)
            } else {
                based.background(VisualEffectBackground(material: .popover, blendingMode: inWindow ? .withinWindow : .behindWindow,
                                                        state: .active).clipShape(shape))
            }
        }
    }
}

/// 본문 불투명 카드 (유리 광택 및 호버 확대 금지)
struct AOMContentSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background(AOMCraftColor.surface, in: shape)
            .overlay(
                shape.strokeBorder(
                    contrast == .increased ? Color(nsColor: .separatorColor) : AOMCraftColor.hairline,
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
            )
    }
}

/// 호버 시 80ms 배경 필만 전환 (확대/이동 절대 금지)
struct AOMCalmHoverModifier: ViewModifier {
    let radius: CGFloat
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isHovered ? AOMCraftColor.rowHover : Color.clear)
            )
            .animation(AOMCraftMotion.resolve(AOMCraftMotion.hoverFill, reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// Defers constructing content once. Measure frame timing in the host app.
struct AOMProgressiveHydration<Placeholder: View, Content: View>: View {
    @State private var hydrated = false
    let placeholder: () -> Placeholder
    let content: () -> Content

    init(@ViewBuilder placeholder: @escaping () -> Placeholder,
         @ViewBuilder content: @escaping () -> Content) {
        self.placeholder = placeholder
        self.content = content
    }

    var body: some View {
        Group {
            if hydrated {
                content()
            } else {
                placeholder()
            }
        }
        .task {
            guard !hydrated else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            hydrated = true
        }
    }
}

extension View {
    func aomFloatingGlass(radius: CGFloat = AOMCraftRadius.floatingPanel) -> some View {
        modifier(AOMFloatingGlassModifier(radius: radius))
    }

    func aomContentCard(radius: CGFloat = AOMCraftRadius.card, padding: CGFloat = 12) -> some View {
        modifier(AOMContentSurfaceModifier(radius: radius, padding: padding))
    }

    func aomLauncherSurface(radius: CGFloat = AOMCraftRadius.launcherPanel, inWindow: Bool = false) -> some View {
        modifier(AOMLauncherSurfaceModifier(radius: radius, inWindow: inWindow))
    }

    func aomCalmHover(radius: CGFloat = AOMCraftRadius.row) -> some View {
        modifier(AOMCalmHoverModifier(radius: radius))
    }
}

/// 7.0: what a page shows for the one frame before it is built — the
/// header and two cards as quiet wells (no shimmer, nothing moves).
struct AOMPageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AOMCraftColor.well).frame(width: 220, height: 22)
            RoundedRectangle(cornerRadius: AOMCraftRadius.card, style: .continuous).fill(AOMCraftColor.well).frame(height: 120)
            RoundedRectangle(cornerRadius: AOMCraftRadius.card, style: .continuous).fill(AOMCraftColor.well).frame(height: 220)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// 통일된 키캡 컴포넌트 (⌃⌥⇧⌘ 순서)
struct AOMCraftKeycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AOMCraftColor.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AOMCraftRadius.keycap, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AOMCraftRadius.keycap, style: .continuous)
                    .strokeBorder(AOMCraftColor.hairline, lineWidth: 0.5)
            )
    }
}
