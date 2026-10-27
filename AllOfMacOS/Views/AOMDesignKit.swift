import AppKit
import SwiftUI

// AOM 3 design kit.
//
// One grammar for every surface, chosen from the references in
// docs/3.0.0-design-overhaul.md:
// - Content layer: a calm canvas with white cards, monochrome glyphs and
//   colour only for meaning, state and the one primary action (Apple HIG
//   Color/Materials, Linear 2026 "don't compete for attention").
// - Functional layer: the system sidebar, toolbar and floating chrome carry
//   the material — Liquid Glass on macOS 26+, the matching AppKit material
//   before (WWDC25 Meet Liquid Glass, Adopting Liquid Glass).
// - Every floating panel (shelf, history, Quick Access, palette, HUDs,
//   recording bar, capture toolbar) shares one material, edge and shadow
//   (Paste 6, CleanShot X 4.8 and BetterTouchTool 6 on Tahoe).

// MARK: - Radii

/// Corner radii by role. Nested shapes step down so corners stay concentric.
enum AOMRadius {
    /// Floating panels: shelf, history overlay, palette, welcome.
    static let panel: CGFloat = 20
    /// HUDs, toasts and the recording bar.
    static let hud: CGFloat = 16
    /// Control strips floating over the screen (capture toolbars).
    static let bar: CGFloat = 14
    /// Content cards on the canvas (grouped boxes).
    static let card: CGFloat = 12
    /// Tiles and thumbnails inside a card.
    static let tile: CGFloat = 9
    /// Inset wells, small thumbnails, swatches.
    static let well: CGFloat = 7
    /// Dense controls: chips' hover wash, small buttons.
    static let control: CGFloat = 6
}

// MARK: - Floating surfaces

/// The role a floating surface plays; it picks the material.
enum AOMFloatingRole {
    /// Panels people work in: the clipboard shelf, capture history, palette.
    case panel
    /// Short-lived status: HUDs, toasts, the recording bar.
    case hud
    /// Control strips floating over the screen: All-In-One, scrolling capture.
    case bar

    var fallbackMaterial: NSVisualEffectView.Material {
        switch self {
        case .panel: return .popover
        case .hud: return .hudWindow
        case .bar: return .popover
        }
    }
}

/// The one look shared by every floating surface. On macOS 26 and later it is
/// Liquid Glass over a light popover wash (the pairing the shelf already
/// proved readable); earlier systems get the AppKit material with a hairline
/// edge. Reduce Transparency and Increase Contrast fall back to an opaque
/// surface with a defined border.
struct AOMFloatingSurface: ViewModifier {
    var role: AOMFloatingRole = .panel
    var radius: CGFloat = AOMRadius.panel
    /// Floats over the app's own window (palette, welcome) rather than in a
    /// panel of its own, so the blur samples the window, not the desktop.
    var inWindow = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var blending: NSVisualEffectView.BlendingMode { inWindow ? .withinWindow : .behindWindow }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            // Liquid Glass alone draws edge, depth and adaptive tint. Large
            // panels people read in keep a faint wash for legibility over busy
            // wallpapers; small chrome is pure glass (WWDC25 "Meet Liquid Glass").
            content
                .background {
                    if role == .panel {
                        VisualEffectBackground(material: role.fallbackMaterial, blendingMode: blending, state: .active)
                            .opacity(0.3)
                            .clipShape(shape)
                    }
                }
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffectBackground(material: role.fallbackMaterial, blendingMode: blending, state: .active))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5).allowsHitTesting(false))
        }
    }
}

extension View {
    /// Primary action: the system prominent style (Liquid Glass tinted on
    /// macOS 26). Use for the one action a page or sheet exists for.
    @ViewBuilder func aomPrimaryButton() -> some View {
        buttonStyle(.borderedProminent)
    }

    /// A control floating over content (HUDs, Quick Access, pins). macOS 26
    /// renders real glass; earlier systems the bordered style.
    @ViewBuilder func aomGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Groups nearby custom glass so it samples and morphs as one surface.
    @ViewBuilder func aomGlassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Soft scroll-edge effect under the floating toolbar (macOS 26).
    @ViewBuilder func aomScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// One page grammar for every main-window destination: the system canvas,
    /// title and subtitle in the window toolbar, no in-content duplicate.
    func aomPage(_ title: String, subtitle: String? = nil) -> some View {
        modifier(AOMPageChrome(title: title, subtitle: subtitle))
    }

    /// Floating chrome (panels, HUDs, bars) in the shared AOM material.
    func aomFloatingSurface(_ role: AOMFloatingRole = .panel, radius: CGFloat = AOMRadius.panel,
                            inWindow: Bool = false) -> some View {
        modifier(AOMFloatingSurface(role: role, radius: radius, inWindow: inWindow))
    }
}

/// Title and subtitle for a main-window page. The canvas belongs to the shell
/// (`AOMMainShell`), so pages never stack a second behind-window material.
struct AOMPageChrome: ViewModifier {
    let title: String
    let subtitle: String?
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
    }
}

/// A circular icon button for floating chrome (HUDs, Quick Access, pins):
/// a quiet glass-friendly fill, a readable glyph, a press response.
struct AOMFloatingIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(destructive ? AOMTheme.danger : Color.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(.regularMaterial))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed && !AOMDesign.reduceMotion ? 0.94 : 1)
            .animation(AOMMotion.quick, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

// MARK: - Content cards

/// A titled card on the canvas: a header line (glyph, title, detail and a
/// trailing accessory such as "Open ›"), its content, and an optional footer
/// separated by space rather than rules ("structure felt, not seen").
struct AOMSectionCard<Accessory: View, Content: View, Footer: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = AOMTheme.textSecondary
    var detail: String?
    var contentPadding: CGFloat = AOMSpace.m
    /// Grow to the height offered (cards sharing a grid row line up).
    var fillsHeight = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: String, fillsHeight: Bool = false, symbol: String? = nil, tint: Color = AOMTheme.textSecondary,
         detail: String? = nil, contentPadding: CGFloat = AOMSpace.m,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.detail = detail
        self.contentPadding = contentPadding
        self.fillsHeight = fillsHeight
        self.accessory = accessory()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: AOMSpace.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(AOMType.headline)
                    .foregroundStyle(AOMTheme.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AOMType.caption)
                        .foregroundStyle(AOMTheme.textSecondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: AOMSpace.xs)
                accessory
            }
            .padding(.horizontal, AOMSpace.m)
            .padding(.top, AOMSpace.s + 2)
            .padding(.bottom, 2)
            content
                .padding(.horizontal, contentPadding)
                .padding(.top, AOMSpace.xs)
                .padding(.bottom, AOMSpace.m)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            if fillsHeight { Spacer(minLength: 0) }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .aomCardStyle(.paper, radius: AOMRadius.card, padding: 0, elevated: false)
        .accessibilityElement(children: .contain)
    }
}

/// The trailing "Open ›" link of a card header.
struct AOMCardLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .font(AOMType.caption.weight(.medium))
            .foregroundStyle(hovering ? AOMTheme.text : AOMTheme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(hovering ? AOMTheme.track : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(AOMMotion.quick, value: hovering)
        .help(title)
    }
}

/// A footer strip inside a card: the card's primary action and a quiet hint.
struct AOMCardFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            AOMDivider()
            HStack(spacing: AOMSpace.xs) {
                leading
                Spacer(minLength: AOMSpace.xs)
                trailing
            }
            .padding(.horizontal, AOMSpace.m)
            .frame(minHeight: 44)
        }
    }
}

// MARK: - Mode buttons

/// A launch button for one tool mode (capture modes, quick layouts): glyph
/// over a short label, its shortcut underneath. The whole tile is the target;
/// hover shows a quiet well and the press dims, so a row of them reads like
/// the system screenshot toolbar.
struct AOMModeButton: View {
    let title: String
    let symbol: String
    var tint: Color = AOMTheme.text
    var shortcut: String?
    var help: String?
    var compact: Bool = false
    let action: () -> Void

    init(_ title: String, symbol: String, tint: Color = AOMTheme.text, shortcut: String? = nil,
         help: String? = nil, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.shortcut = shortcut
        self.help = help
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if compact {
                // Never shrink the label below the 10 pt floor: when the title
                // does not fit, show the glyph alone (the title stays in the
                // tooltip and the VoiceOver label).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                            .symbolRenderingMode(.hierarchical).foregroundStyle(tint)
                        Text(title).font(AOMType.caption.weight(.medium)).lineLimit(1)
                    }
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(tint)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
            } else {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(height: 22)
                Text(title)
                    .font(AOMType.caption.weight(.medium))
                    .foregroundStyle(AOMTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
                    .truncationMode(.tail)
                Text(shortcut ?? " ")
                    .font(AOMType.micro)
                    .foregroundStyle(AOMTheme.textTertiary)
                    .lineLimit(1)
                    .opacity(shortcut == nil ? 0 : 1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.tile))
        .help(help ?? (shortcut.map { "\(title) (\($0))" } ?? title))
        .accessibilityLabel(title)
        .accessibilityHint(shortcut.map { "Shortcut \($0)" } ?? "")
    }
}

// MARK: - Scope bar

/// One choice in an `AOMScopeBar`.
struct AOMScopeItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var symbol: String?
    var count: Int?
    /// A coloured dot instead of a glyph (pinboards).
    var dot: Color?
}

/// Filters for the content below as a row of quiet capsules — the selected
/// one carries the accent. Counts read as part of the label, so "Trackpad 7"
/// answers what the filter holds before it is chosen. Scrolls sideways when
/// space runs out instead of truncating.
struct AOMScopeBar<ID: Hashable>: View {
    let items: [AOMScopeItem<ID>]
    @Binding var selection: ID
    var accessibilityLabel: String = "Filter"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    AOMScopeChip(item: item, selected: item.id == selection) { selection = item.id }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AOMScopeChip<ID: Hashable>: View {
    let item: AOMScopeItem<ID>
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Increase Contrast and Differentiate Without Color outline the selected
    /// chip, so selection is not carried by a 13% tint alone (WCAG 1.4.11).
    private var outlined: Bool { selected && (contrast == .increased || differentiateWithoutColor) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot = item.dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                } else if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                }
                Text(item.title).lineLimit(1)
                if let count = item.count {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.accentColor.opacity(0.75) : AOMTheme.textTertiary)
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.accentColor : (hovering ? AOMTheme.text : AOMTheme.textSecondary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                Capsule().fill(selected ? Color.accentColor.opacity(contrast == .increased ? 0.24 : 0.13)
                                        : (hovering ? AOMTheme.track : Color.clear))
            }
            .overlay {
                if outlined { Capsule().strokeBorder(Color.accentColor, lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(AOMMotion.quick, value: hovering)
        .animation(AOMMotion.quick, value: selected)
        .accessibilityLabel(item.count.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Status pill

/// A small state capsule: a dot and a few words ("Automation On", "REC").
struct AOMStatusPill: View {
    let text: String
    var tint: Color = AOMTheme.positive
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(filled ? Color.white : tint).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(AOMType.micro.weight(.semibold))
        .foregroundStyle(filled ? Color.white : AOMTheme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(AOMTheme.track), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Window layouts

/// The geometry of a tiling layout inside a normalised screen, shared by the
/// Window Tiling page, its previews and the Workspace card.
enum AOMTilingGeometry {
    static func rect(for layout: CustomSnapZone.Layout, in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch layout {
        case .leftHalf: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .rightHalf: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .topHalf: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottomHalf: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        case .maximize, .nextDisplay: return CGRect(x: 0, y: 0, width: w, height: h)
        case .center: return CGRect(x: w * 0.15, y: h * 0.15, width: w * 0.7, height: h * 0.7)
        case .topLeft: return CGRect(x: 0, y: 0, width: w / 2, height: h / 2)
        case .topRight: return CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)
        case .bottomLeft: return CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2)
        case .bottomRight: return CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)
        case .leftThird: return CGRect(x: 0, y: 0, width: w / 3, height: h)
        case .centerThird: return CGRect(x: w / 3, y: 0, width: w / 3, height: h)
        case .rightThird: return CGRect(x: w * 2 / 3, y: 0, width: w / 3, height: h)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: w * 2 / 3, height: h)
        case .rightTwoThirds: return CGRect(x: w / 3, y: 0, width: w * 2 / 3, height: h)
        }
    }

    /// Moves the front window into a layout, the way the Window menu would.
    @MainActor
    static func apply(_ layout: CustomSnapZone.Layout, completion: @escaping (Bool) -> Void = { _ in }) {
        let actionType: ActionType
        switch layout {
        case .leftHalf: actionType = .snapWindowLeft
        case .rightHalf: actionType = .snapWindowRight
        case .maximize: actionType = .maximizeWindow
        case .topHalf: actionType = .snapWindowTopHalf
        case .bottomHalf: actionType = .snapWindowBottomHalf
        case .topLeft: actionType = .snapWindowTopLeft
        case .topRight: actionType = .snapWindowTopRight
        case .bottomLeft: actionType = .snapWindowBottomLeft
        case .bottomRight: actionType = .snapWindowBottomRight
        case .center:
            var params = ActionParameters()
            params.snapX = 0.15
            params.snapY = 0.15
            params.snapWidth = 0.70
            params.snapHeight = 0.70
            WindowManager.shared.execute(.customSnapWindow, target: nil, parameters: params) { completion($0) }
            return
        case .leftThird: actionType = .snapWindowLeftThird
        case .centerThird: actionType = .snapWindowCenterThird
        case .rightThird: actionType = .snapWindowRightThird
        case .leftTwoThirds: actionType = .snapWindowLeftTwoThirds
        case .rightTwoThirds: actionType = .snapWindowRightTwoThirds
        case .nextDisplay: actionType = .moveWindowNextMonitorAndMaximize
        }
        ActionExecutor.executeAction(TriggerAction(actionType: actionType))
        completion(true)
    }
}

/// A miniature screen with the layout's region filled — the visual name of a
/// layout (Swish, Rectangle Pro and macOS's own tiling menu draw the same).
struct AOMLayoutDiagram: View {
    /// The window's region in a unit screen, origin at the top left.
    let region: CGRect
    /// Moves to the next display (drawn as an arrow over the region).
    var arrow = false
    var highlighted = false
    @Environment(\.colorSchemeContrast) private var contrast

    init(layout: CustomSnapZone.Layout, highlighted: Bool = false) {
        region = AOMTilingGeometry.rect(for: layout, in: CGSize(width: 1, height: 1))
        arrow = layout == .nextDisplay
        self.highlighted = highlighted
    }

    init(zone: CustomSnapZone, highlighted: Bool = false) {
        region = CGRect(x: zone.targetX, y: zone.targetY, width: zone.targetWidth, height: zone.targetHeight)
        arrow = zone.targetDisplay == "next"
        self.highlighted = highlighted
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let screen = RoundedRectangle(cornerRadius: max(3, size.height * 0.12), style: .continuous)
            let inset: CGFloat = max(2, size.height * 0.07)
            let inner = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
            let scaled = CGRect(x: region.minX * inner.width, y: region.minY * inner.height,
                                width: region.width * inner.width, height: region.height * inner.height)
                .insetBy(dx: 1, dy: 1)
            ZStack(alignment: .topLeading) {
                screen.fill(AOMTheme.cardAlt)
                screen.strokeBorder(highlighted ? Color.accentColor.opacity(0.6)
                                                : (contrast == .increased ? AOMTheme.textSecondary : AOMTheme.hairline),
                                    lineWidth: highlighted || contrast == .increased ? 1 : 0.5)
                RoundedRectangle(cornerRadius: max(2, size.height * 0.08), style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted || contrast == .increased ? 0.85 : 0.5))
                    .frame(width: max(0, scaled.width), height: max(0, scaled.height))
                    .offset(x: inset + scaled.minX, y: inset + scaled.minY)
                if arrow {
                    Image(systemName: "arrow.right")
                        .font(.system(size: max(8, size.height * 0.34), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size.width, height: size.height)
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .animation(AOMMotion.quick, value: highlighted)
        .accessibilityHidden(true)
    }
}
