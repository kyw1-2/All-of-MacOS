import AppKit
import SwiftUI

// AOM design kit: chrome (glass), page chrome, cards with titles, mode
// buttons, scope bars and tiling diagrams. Values come from AOMTokens.swift.
//
// - Content layer: one opaque canvas, opaque cards with a hairline, colour only
//   for interaction, status and module identity badges.
// - Functional layer: the system sidebar and toolbar, plus floating chrome
//   (palette, HUDs, Quick Access, shelf, toasts) through `aomChrome`: system
//   Liquid Glass on macOS 26+, an AppKit material before. Never glass on glass,
//   never a hand-made blur, never an extra shadow on glass.

// MARK: - Floating surfaces

/// The role a floating surface plays; it picks the fallback material.
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

/// The one look shared by every piece of floating chrome (c.4).
/// - macOS 26+: system Liquid Glass in the given shape, which follows the
///   Liquid Glass slider, Reduce Transparency and Increase Contrast by itself.
///   `.interactive()` only when the chrome itself is clickable.
/// - macOS 14–25: the AppKit material with a 0.5 pt hairline; Reduce
///   Transparency or Increase Contrast get an opaque raised surface with a
///   1 pt border.
struct AOMChromeSurface: ViewModifier {
    var radius: CGFloat = AOMRadius.panel
    var interactive = false
    var role: AOMFloatingRole = .panel
    /// Floats over the app's own window (palette, toast) rather than in a panel
    /// of its own, so the fallback blur samples the window, not the desktop.
    var inWindow = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityShowBorders) private var showBorders

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .overlay {
                    if showBorders { shape.strokeBorder(AOMColor.hairline, lineWidth: 1).allowsHitTesting(false) }
                }
        } else if reduceTransparency || contrast == .increased {
            content
                .background(AOMColor.raised, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline, lineWidth: 1)
                    .allowsHitTesting(false))
        } else {
            content
                .background(VisualEffectBackground(material: role.fallbackMaterial,
                                                   blendingMode: inWindow ? .withinWindow : .behindWindow,
                                                   state: .active))
                .clipShape(shape)
                .overlay(shape.strokeBorder(AOMColor.hairline, lineWidth: 0.5).allowsHitTesting(false))
                // Panels of their own already get the window shadow; chrome
                // floating inside the main window gets the overlay level.
                .aomElevation(inWindow ? .overlay : .raised, enabled: inWindow)
        }
    }
}

/// Every floating panel (shelf, history, Quick Access, palette, HUDs,
/// recording bar, capture toolbar) uses this; it renders `AOMChromeSurface`.
struct AOMFloatingSurface: ViewModifier {
    var role: AOMFloatingRole = .panel
    var radius: CGFloat = AOMRadius.panel
    /// Floats over the app's own window (palette, welcome) rather than in a
    /// panel of its own.
    var inWindow = false

    func body(content: Content) -> some View {
        content.modifier(AOMChromeSurface(radius: radius, interactive: false, role: role, inWindow: inWindow))
    }
}

extension View {
    /// Functional layer: system glass on macOS 26+, a material before. Never
    /// use on content (cards, tiles, rows, forms).
    func aomChrome(radius: CGFloat = AOMRadius.panel, interactive: Bool = false,
                   role: AOMFloatingRole = .panel, inWindow: Bool = true) -> some View {
        modifier(AOMChromeSurface(radius: radius, interactive: interactive, role: role, inWindow: inWindow))
    }

    /// Inner thumbnails and buttons: concentric with the card on macOS 26+,
    /// the fixed `control` radius before.
    @ViewBuilder func aomInnerClip() -> some View {
        if #available(macOS 26.0, *) {
            clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(AOMRadius.control)), isUniform: true))
        } else {
            clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
        }
    }

    /// Primary action: the system prominent style (Liquid Glass tinted on
    /// macOS 26). Use for the one action a page or sheet exists for.
    @ViewBuilder func aomPrimaryButton() -> some View {
        buttonStyle(.borderedProminent)
    }

    /// A button on floating chrome (HUDs, Quick Access, pins). macOS 26
    /// renders real glass; earlier systems the bordered style. Buttons inside
    /// cards and forms stay `.bordered` / `.borderedProminent`.
    @ViewBuilder func aomGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Groups nearby custom glass so it samples and morphs as one surface.
    /// Keep `spacing` at or below the stack spacing (R46).
    @ViewBuilder func aomGlassGroup(spacing: CGFloat = AOMSpace.x2) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// The one top-edge treatment for every page: the automatic scroll edge
    /// effect under the toolbar (macOS 26+).
    @ViewBuilder func aomScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.automatic, for: .top)
        } else {
            self
        }
    }

    /// The page title in the window toolbar. Context belongs in the page
    /// header (`AOMPageHeader`), not in a toolbar subtitle (d.9).
    func aomPage(_ title: String, subtitle: String? = nil) -> some View {
        modifier(AOMPageChrome(title: title, subtitle: subtitle))
    }

    /// Floating chrome (panels, HUDs, bars) in the shared AOM material.
    func aomFloatingSurface(_ role: AOMFloatingRole = .panel, radius: CGFloat = AOMRadius.panel,
                            inWindow: Bool = false) -> some View {
        modifier(AOMFloatingSurface(role: role, radius: radius, inWindow: inWindow))
    }
}

/// The page title for a main-window page. The canvas belongs to the shell
/// (`AOMMainShell`); the subtitle is no longer shown in the toolbar.
struct AOMPageChrome: ViewModifier {
    let title: String
    let subtitle: String?
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
    }
}

/// A circular icon button for floating chrome (HUDs, Quick Access, pins).
struct AOMFloatingIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        AOMFloatingIconButtonBody(configuration: configuration, size: size, destructive: destructive)
    }
}

private struct AOMFloatingIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    let destructive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(destructive ? AOMColor.dangerText : Color.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(.regularMaterial))
            .overlay(Circle().strokeBorder(AOMColor.hairline, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .aomAnimation(.quick, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

// MARK: - Content cards

/// A titled card (3.x API). Renders the one section pattern: the title sits
/// above the card (Section style, sentence case), with an optional detail and a
/// trailing accessory such as `AOMCardLink("View All")`; the content sits in an
/// opaque card; the optional footer is a strip inside the card's bottom edge.
/// New code uses `AOMSection` directly.
struct AOMSectionCard<Accessory: View, Content: View, Footer: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = AOMTheme.textSecondary
    var detail: String?
    var contentPadding: CGFloat = AOMSpace.cardPadding
    /// Grow to the height offered (cards sharing a grid row line up).
    var fillsHeight = false
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: String, fillsHeight: Bool = false, symbol: String? = nil, tint: Color = AOMTheme.textSecondary,
         detail: String? = nil, contentPadding: CGFloat = AOMSpace.cardPadding,
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
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            AOMSectionTitle(title, detail: detail) { accessory }
            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(contentPadding)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                if fillsHeight { Spacer(minLength: 0) }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .aomCard(padding: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// The trailing link of a section title ("View All ›", "Show All ⌄").
struct AOMCardLink: View {
    let title: String
    /// `chevron.right` for links that open a page (the default),
    /// `chevron.down`/`chevron.up` for Show All / Show Less, nil for none.
    var symbol: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String? = "chevron.right", action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x0_5) {
                Text(title)
                if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
            }
            .font(AOMFont.callout.weight(.medium))
            .foregroundStyle(hovering ? AOMColor.text : AOMColor.textSecondary)
            .padding(.horizontal, AOMSpace.x2)
            .frame(minHeight: AOMIcon.row + AOMSpace.x0_5)
            .background(hovering ? AOMColor.track : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .help(title)
    }
}

/// A footer strip inside a card: the card's action and a quiet hint.
struct AOMCardFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            AOMRowDivider(inset: 0, trailingInset: 0)
            HStack(spacing: AOMSpace.x2) {
                leading
                Spacer(minLength: AOMSpace.x2)
                trailing
            }
            .padding(.horizontal, AOMSpace.rowInset)
            .frame(minHeight: AOMSize.rowStandard + AOMSpace.x0_5)
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
                    HStack(spacing: AOMSpace.x1 + 1) {
                        Image(systemName: symbol).font(AOMFont.body.weight(.medium))
                            .symbolRenderingMode(.hierarchical).foregroundStyle(tint)
                        Text(title).font(AOMFont.caption.weight(.medium)).lineLimit(1)
                    }
                    Image(systemName: symbol).font(AOMFont.body.weight(.medium))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(tint)
                }
                .frame(maxWidth: .infinity, minHeight: AOMSize.rowStandard - 2)
                .contentShape(Rectangle())
            } else {
                VStack(spacing: AOMSpace.x0_5 + 1) {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                        .frame(height: 18)
                    Text(title)
                        .font(AOMFont.caption.weight(.medium))
                        .foregroundStyle(AOMTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.92)
                        .truncationMode(.tail)
                    Text(shortcut ?? " ")
                        .font(AOMFont.badge)
                        .foregroundStyle(AOMTheme.textTertiary)
                        .lineLimit(1)
                        .opacity(shortcut == nil ? 0 : 1)
                }
                .padding(.horizontal, AOMSpace.x1)
                .padding(.vertical, AOMSpace.x1 + AOMSpace.x0_5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.well))
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

/// Filters for the content below as a row of quiet capsules; the selected
/// one carries the accent. Counts read as part of the label, so "Trackpad 7"
/// answers what the filter holds before it is chosen. Scrolls sideways when
/// space runs out instead of truncating.
struct AOMScopeBar<ID: Hashable>: View {
    let items: [AOMScopeItem<ID>]
    @Binding var selection: ID
    var accessibilityLabel: String = "Filter"

    /// Full labels when they fit; then glyph-and-count chips (the selected one
    /// keeps its title, the rest name themselves in a tooltip and to
    /// VoiceOver); only then a sideways scroll that fades at its trailing edge,
    /// so a cut-off chip never reads as the last one.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
            ScrollView(.horizontal, showsIndicators: false) {
                row(compact: true).padding(.trailing, AOMSpace.l)
            }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: AOMSpace.x1) {
            ForEach(items) { item in
                AOMScopeChip(item: item, selected: item.id == selection,
                             compact: compact && item.id != selection && (item.symbol != nil || item.dot != nil)) {
                    selection = item.id
                }
            }
        }
        .padding(.vertical, 1)
        .fixedSize()
    }
}

private struct AOMScopeChip<ID: Hashable>: View {
    let item: AOMScopeItem<ID>
    let selected: Bool
    /// Glyph and count only; the title moves to the tooltip.
    var compact = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Increase Contrast and Differentiate Without Color outline the selected
    /// chip, so selection is not carried by a tint alone (WCAG 1.4.11).
    private var outlined: Bool { selected && (contrast == .increased || differentiateWithoutColor) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x1 + 1) {
                if let dot = item.dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                } else if let symbol = item.symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                if !compact { Text(item.title).lineLimit(1) }
                if let count = item.count {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.accentColor.opacity(0.75) : AOMTheme.textTertiary)
                }
            }
            .font(AOMFont.caption.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.accentColor : (hovering ? AOMTheme.text : AOMTheme.textSecondary))
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: 22)
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
        .help(compact ? item.title : "")
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .aomAnimation(.quick, value: selected)
        .accessibilityLabel(item.count.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Window layouts

/// The geometry of a tiling layout inside a normalised screen, shared by the
/// Window Tiling page, its previews and the Workspace.
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

/// A miniature screen with the layout's region filled: the visual name of a
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
                screen.fill(AOMColor.sunken)
                screen.strokeBorder(highlighted ? Color.accentColor.opacity(0.6)
                                                : (contrast == .increased ? AOMColor.strongLine : AOMColor.hairline),
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
        .aomAnimation(.quick, value: highlighted)
        .accessibilityHidden(true)
    }
}
