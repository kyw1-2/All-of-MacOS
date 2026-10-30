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
    /// A preview pane beside a list (Clipboard): shown from this page width,
    /// sized 42% of it within this range.
    static let previewPaneMinimumWidth: CGFloat = 640
    static let previewPane: ClosedRange<CGFloat> = 300...420
    static let previewPaneShare: CGFloat = 0.42
    /// The picture area of a gallery card (Clipboard › Gallery).
    static let galleryPreview: CGFloat = 144
    /// Finder file icons in previews and cards.
    static let fileIcon: CGFloat = 48
    static let fileIconLarge: CGFloat = 64
    /// Fixed-width sheets: a name and a colour; a short text or form.
    static let sheetCompact: CGFloat = 380
    static let sheetStandard: CGFloat = 460
    /// Shortcut recorder buttons keep one width while their label changes.
    static let recorderMinWidth: CGFloat = 130
    /// A short multi-line field inside a card (a list of bundle IDs).
    static let textEditorShort: CGFloat = 90
    /// A sheet that shows code or configuration (MCP connection snippets).
    static let sheetWide: CGFloat = 520
    /// Code snippets in a sheet: one command line, or a JSON block.
    static let snippetShort: CGFloat = 70
    static let snippetTall: CGFloat = 170
    /// The Paste Stack panel's column (Paste's PasteStack.storyboard width).
    static let stackPanelWidth: CGFloat = 264
    /// Editor bars (Annotate, recording editor): the window's traffic lights
    /// sit in the bar, so its first item starts after them.
    static let trafficLightsInset: CGFloat = 68
    /// Capsule buttons and controls in editor bars.
    static let barButtonWidth: CGFloat = 38
    static let barControlHeight: CGFloat = 32
    /// Colour dots in a palette row.
    static let swatchSmall: CGFloat = 16
    /// Tool and format popovers (Annotate › More Tool Options).
    static let toolPopoverWidth: CGFloat = 300
    /// Annotate › Text › Format: wide enough for "Background" beside its menu.
    static let formatPopoverWidth: CGFloat = 340
    /// Fixed widths for pickers in the editor bars, so the bar doesn't shift
    /// when a selection's name changes length.
    static let barPickerNarrow: CGFloat = 80
    static let barPicker: CGFloat = 110
    static let barPickerWide: CGFloat = 140
    /// Sliders in the editor bars.
    static let sliderShort: CGFloat = 70
    static let sliderStandard: CGFloat = 90
    static let sliderWide: CGFloat = 110
    /// The value label beside a bar slider ("100%", "12 pt").
    static let sliderValue: CGFloat = 36
    /// The clipboard shelf's search field and the strip of filter tokens in it.
    static let shelfSearchField: ClosedRange<CGFloat> = 160...400
    static let shelfTokenStrip: CGFloat = 190
    /// The shelf's Filters popover.
    static let shelfFilterPopover = CGSize(width: 440, height: 470)
    /// The recording editor window: fixed width, height follows the screen.
    static let recordingEditorWidth: CGFloat = 720
    static let recordingEditorHeight: ClosedRange<CGFloat> = 480...820
    static let recordingEditorScreenMargin: CGFloat = 120
    /// The video preview at the top of the recording editor.
    static let videoPreviewHeight: CGFloat = 260
    /// Slider rows in editor sections: the title column and the value column.
    static let editorRowTitle: CGFloat = 150
    static let editorRowValue: CGFloat = 64
    /// Numeric fields in an editor row (time, duration).
    static let numberField: CGFloat = 70
    /// Key pickers in Settings (Hyper key source, remap from / to).
    static let keyPicker: CGFloat = 170
    /// Quick Access: the Copy / Save pills and the inset of the hover controls
    /// (the capture overlay's hit areas; keep these exact).
    static let quickAccessPill: CGFloat = 110
    static let quickAccessPillCompact: CGFloat = 70
    static let quickAccessInset: CGFloat = 7
    static let quickAccessInsetCompact: CGFloat = 5
    /// Capture history: the search field and the strip of filters beside it.
    static let historySearchField: CGFloat = 190
    static let historyFilterStrip: CGFloat = 470
    /// The ⌘K palette's height (the width is `AOMSize.paletteWidth`).
    static let paletteHeight: CGFloat = 460
    /// The window switcher's thumbnails.
    static let switcherThumbnail = CGSize(width: 176, height: 112)
    /// The Copy Text HUD.
    static let textHUDWidth: CGFloat = 380
    /// The Live Touch Visualizer in the diagnostics drawer: under the console, or alone.
    static let touchVisualizer: CGFloat = 180
    static let touchVisualizerTall: CGFloat = 240
    /// The recognised-text editor window's text area.
    static let textEditorMin = CGSize(width: 360, height: 200)
    /// The window picker sheet and its thumbnails.
    static let windowPickerMin = CGSize(width: 520, height: 360)
    static let windowPickerThumbnail: CGFloat = 96
    /// The welcome overlay.
    static let welcomeWidth: CGFloat = 560
    /// Capture's mode buttons (Area, Window, Record…) in the launchpad grid.
    static let modeButtonMin: CGFloat = 108
    /// Small round badges on a capture thumbnail (Video, Pinned).
    static let thumbnailBadge: CGFloat = 20
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
    /// Copied rich text keeps its own colours, so previews of it sit on a
    /// white page in both appearances, as the source app showed it.
    static let documentPage = Color.white

    /// Round icon buttons over media (Quick Access, pinned screenshots): dark
    /// plates with a light edge, readable on any picture.
    static func mediaControl(pressed: Bool, hovering: Bool) -> Color {
        Color.black.opacity(pressed ? 0.75 : hovering ? 0.66 : 0.5)
    }
    static func mediaControlEdge(hovering: Bool) -> Color { Color.white.opacity(hovering ? 0.35 : 0.15) }
    /// Text buttons over media: light pills with dark text.
    static func mediaPill(pressed: Bool, hovering: Bool) -> Color {
        Color.white.opacity(pressed ? 0.70 : hovering ? 1 : 0.90)
    }
    static func mediaPillEdge(hovering: Bool) -> Color { Color.white.opacity(hovering ? 0.8 : 0.25) }
    static let mediaPillText = Color.black.opacity(0.85)
    /// The curtain over a capture while its hover controls show.
    static let mediaCurtain = Color.black.opacity(0.46)
    /// A pinned screenshot's optional border and shadow (the person's pin options).
    static let pinBorder = Color.primary.opacity(0.28)
    static let pinShadow = Color.black.opacity(0.32)
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

// MARK: - Card group on glass

/// A titled card of rows for content on glass (popovers, the welcome
/// overlay): the `AOMSection` look without its first-divider cover, which is
/// drawn past the card's rounded top corners and shows on glass. The first
/// row passes `showsDivider: false` instead.
struct AOMCardGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            if let title { AOMSectionTitle(title) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .aomCard(padding: 0)
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AOMSpace.x1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Preview hooks

/// Isolated UI previews (`--aom-ui-preview`) can show floating panels and
/// editor windows in the appearance under review. `AOMAppearance` styles the
/// main and Settings windows only; panels follow the system. With
/// `--aom-preview-panel-appearance` the whole preview app follows
/// `AOMAppearance` instead. Real launches never take this path.
enum AOMFeaturePreview {
    @MainActor static func applyPanelAppearance() {
        guard PresetManager.isUIPreview,
              ProcessInfo.processInfo.arguments.contains("--aom-preview-panel-appearance") else { return }
        let choice = UserDefaults.standard.string(forKey: "AOMAppearance") ?? "system"
        let appearance: NSAppearance? = choice == "dark" ? NSAppearance(named: .darkAqua)
            : choice == "light" ? NSAppearance(named: .aqua) : nil
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
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
