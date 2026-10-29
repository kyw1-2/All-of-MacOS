import AppKit
import SwiftUI

// Feature surfaces (3.3.3 integration): the pieces the Clipboard, Capture,
// Insights and Settings views share on top of AOMComponents.swift, plus the
// few named sizes and colours those surfaces need that the shared scale in
// AOMTokens.swift does not cover. Everything else in those views uses the
// tokens directly.
//
//   AOMFilterChip        the AOMScopeBar chip look, for chips that also need a
//                        context menu, a drop target, an app icon or a clear ✕
//   aomInPanelCapsule()  a message capsule inside chrome that is already glass
//   aomMediaBadge()      a small label on top of a picture or a colour swatch

// MARK: - Feature sizes

enum AOMFeatureSize {
    /// Filter chips: the same height as the `AOMScopeBar` chips.
    static let chip: CGFloat = 26
    /// Pinboard and filter dots inside chips.
    static let chipDot: CGFloat = 7
    /// App icons inside chips.
    static let chipIcon: CGFloat = 14
    /// A source-app icon in a list row, a preview header or a menu item.
    static let appIcon: CGFloat = 16
    /// Colour swatches people pick from (pinboard colours, annotation colours).
    static let swatch: CGFloat = 20
    /// The outline that marks the selected swatch.
    static let swatchRing: CGFloat = 2
    /// Usage bars in lists (Insights › Most used).
    static let meter: CGFloat = 6
}

// MARK: - Feature colours

enum AOMFeatureColor {
    /// Search matches inside images and text: the system find highlight.
    static let findHighlight = Color(nsColor: .findHighlightColor)
    /// Dims a picture around a selected region (c.4 media overlays: 35% black).
    static let mediaDim = Color.black.opacity(0.35)
    /// Labels drawn straight on a picture or a colour swatch.
    static let onMedia = Color.white
    /// The soft shadow that keeps `onMedia` labels readable on light media.
    static let onMediaShadow = Color.black.opacity(0.2)
}

// MARK: - Filter chip

/// One filter choice as a quiet capsule, drawn like the `AOMScopeBar` chips:
/// the selected chip carries the accent wash and label, the others are
/// secondary and show a hover wash. Use it where a chip needs something
/// scope-bar items can't carry: a context menu, a drop target, an app icon or
/// a clear ✕. `filled` gives resting chips a track fill, so a grid of chips
/// (or chips on chrome) still reads as buttons.
struct AOMFilterChip: View {
    let title: String
    var symbol: String?
    var appIcon: NSImage?
    var dot: Color?
    var count: Int?
    let selected: Bool
    var filled: Bool
    /// The selected chip shows an ✕ (choosing it again clears the filter).
    var showsClear: Bool
    /// Full width in a grid cell.
    var expands: Bool
    var help: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    init(_ title: String, symbol: String? = nil, appIcon: NSImage? = nil, dot: Color? = nil, count: Int? = nil,
         selected: Bool, filled: Bool = false, showsClear: Bool = false, expands: Bool = false,
         help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.appIcon = appIcon
        self.dot = dot
        self.count = count
        self.selected = selected
        self.filled = filled
        self.showsClear = showsClear
        self.expands = expands
        self.help = help
        self.action = action
    }

    /// Increase Contrast and Differentiate Without Color outline the selected
    /// chip, so selection is not carried by a tint alone.
    private var outlined: Bool { selected && (contrast == .increased || differentiateWithoutColor) }

    private var restingFill: Color {
        if hovering { return filled ? AOMColor.sunken : AOMColor.track }
        return filled ? AOMColor.track : .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x1) {
                if let dot {
                    Circle().fill(dot).frame(width: AOMFeatureSize.chipDot, height: AOMFeatureSize.chipDot)
                } else if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFit()
                        .frame(width: AOMFeatureSize.chipIcon, height: AOMFeatureSize.chipIcon)
                        .accessibilityHidden(true)
                } else if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(title).lineLimit(1)
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.accentColor.opacity(0.75) : AOMColor.textTertiary)
                }
                if showsClear && selected {
                    Image(systemName: "xmark").imageScale(.small).accessibilityHidden(true)
                }
            }
            .font(AOMFont.callout.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.accentColor : (hovering ? AOMColor.text : AOMColor.textSecondary))
            .padding(.horizontal, AOMSpace.x3 - AOMSpace.x0_5)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(height: AOMFeatureSize.chip)
            .background {
                Capsule().fill(selected ? Color.accentColor.opacity(contrast == .increased ? 0.24 : 0.13) : restingFill)
            }
            .overlay {
                if outlined { Capsule().strokeBorder(Color.accentColor, lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .aomAnimation(.quick, value: selected)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Capsules and badges on chrome and media

extension View {
    /// A message capsule floating inside chrome that is already glass (the
    /// clipboard shelf, Quick Access, HUDs): an opaque raised capsule with a
    /// hairline, so glass never sits on glass (c.4).
    func aomInPanelCapsule() -> some View { modifier(AOMInPanelCapsule()) }

    /// A small label on top of a picture or a colour swatch (image size, a
    /// quick-paste number): an opaque raised plate with a hairline, cheaper
    /// to draw than a material in a scrolling shelf and readable on any media.
    func aomMediaBadge(radius: CGFloat = AOMRadius.keycap) -> some View { modifier(AOMMediaBadge(radius: radius)) }
}

private struct AOMInPanelCapsule: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(AOMColor.raised, in: Capsule())
            .overlay {
                Capsule().strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline,
                                       lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            .aomElevation(.raised)
    }
}

private struct AOMMediaBadge: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .foregroundStyle(AOMColor.text)
            .background(AOMColor.raised, in: shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? AOMColor.strongLine : AOMColor.hairline,
                                   lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}
