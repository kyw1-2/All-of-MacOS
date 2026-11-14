import AppKit
import SwiftUI

// AOM 3.3.3 components: one implementation per job (ux-refs-3.3.3 §b.5, e.1–e.7).
//
//   AOMPage            standard page scroll: canvas, 24 pt margins, 1200 pt max, 24 pt between sections
//   AOMPageHeader      status sentence · context line · status pill · trailing controls
//   AOMSection         section title above an opaque card, optional ⓘ and footer under the card
//   AOMSettingRow      label · optional secondary line · trailing control · optional ⓘ popover
//   AOMToggleRow       AOMSettingRow with a switch
//   AOMInfoButton      the ⓘ popover (≤ 3 sentences) that replaces caption walls
//   AOMStatusPill      glyph or dot + a few words in a semantic tone
//   AOMModuleBadge     module mark (neutral squircle, monochrome glyph)
//   AOMModuleTile      Workspace module tile: squircle, name, status line, one control, live count
//   AOMNotice          inline warning/error banner with one verb button
//   AOMEmptyState      ContentUnavailableView wrapper (AOMDesignSystem.swift)
//   aomDestructive()   the destructive button style (role + red label, never prominent)
//
// Each one owns its edge cases (long text, empty detail, disabled state,
// Increase Contrast, Show Borders, focus and VoiceOver), so pages compose them
// instead of restyling rows and headings locally.

// MARK: - Page

/// Isolated UI previews can open a page scrolled to its end
/// (`--aom-preview-scroll-bottom`), so long pages are reviewed in screenshots.
enum AOMPreviewHooks {
    static var scrollAnchor: UnitPoint? {
        PresetManager.isUIPreview && ProcessInfo.processInfo.arguments.contains("--aom-preview-scroll-bottom") ? .bottom : nil
    }
}

/// The standard page (e.1): one vertical scroll view on the canvas, content
/// at most 1200 pt wide (centred beyond) with 24 pt margins and 24 pt between sections.
/// The page name lives in the toolbar (`navigationTitle`), never repeated here.
struct AOMPage<Content: View>: View {
    var maxWidth: CGFloat = AOMSize.contentMaxWidth
    var spacing: CGFloat = AOMSpace.sectionGap
    @ViewBuilder var content: Content

    init(maxWidth: CGFloat = AOMSize.contentMaxWidth, spacing: CGFloat = AOMSpace.sectionGap,
         @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            // Lazy: a page builds only the sections on screen, so opening it
            // no longer creates every switch, pop-up and chart below the fold.
            LazyVStack(alignment: .leading, spacing: spacing) { content }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, AOMSpace.pageMargin)
                .padding(.top, AOMSpace.pageTop)
                .padding(.bottom, AOMSpace.x6)
                .frame(maxWidth: .infinity)
        }
        // Created without scrollers, so AOMScrollChromePolicy has nothing
        // to change (its change re-laid out the whole page a second later).
        .scrollIndicators(.never)
        .defaultScrollAnchor(AOMPreviewHooks.scrollAnchor)
        .aomScrollEdge()
        .background(AOMColor.pageBackground)
    }
}

/// The content column of a Settings sheet (Permissions, Shortcuts,
/// Backups): leading-aligned at `AOMSize.settingsColumn` with the page
/// margins, so switching sheets never moves the panes. Apply inside the
/// sheet's scroll view.
extension View {
    func aomSettingsSheetContent() -> some View {
        frame(maxWidth: AOMSize.settingsColumn, alignment: .leading)
            .padding(.horizontal, AOMSpace.pageMargin)
            .padding(.top, AOMSpace.x3)
            .padding(.bottom, AOMSpace.x6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Page header

/// A short status: words plus a tone (and optionally a glyph).
struct AOMStatus: Equatable {
    var text: String
    var tone: AOMTone
    var symbol: String?

    init(_ text: String, tone: AOMTone, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }
}

/// The one header for every module page. It sits on the glass, not in a
/// pane: the status sentence, one line of context, an optional status pill,
/// then the trailing controls (master switch, actions). `help` becomes the
/// title's tooltip.
struct AOMPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var status: AOMStatus?
    var help: String?
    /// Off modules show the badge without its hue.
    var active = true
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String, subtitle: String? = nil,
         status: AOMStatus? = nil, help: String? = nil, active: Bool = true,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.help = help
        self.active = active
        self.trailing = trailing()
    }

    var body: some View {
        // A title, not a badge: the status sentence in bold large type with
        // its context underneath, like the headers of Apple's own apps.
        HStack(alignment: .center, spacing: AOMSpace.x3) {
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                HStack(alignment: .center, spacing: AOMSpace.x2) {
                    Text(title)
                        .font(AOMFont.pageTitle)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityAddTraits(.isHeader)
                        .help(help ?? "")
                    if let status {
                        AOMStatusPill(status.text, tone: status.tone, symbol: status.symbol)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x3)
            HStack(spacing: AOMSpace.x2) { trailing }
                .fixedSize()
        }
        .padding(.horizontal, AOMSpace.x0_5)
        .padding(.bottom, AOMSpace.x1)
        .foregroundStyle(active ? AOMColor.text : AOMColor.textSecondary)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Section

/// A section title in sentence case with an optional count or detail in
/// secondary text and a trailing accessory such as `AOMCardLink("View All")`.
/// `help` becomes the title's tooltip.
struct AOMSectionTitle<Accessory: View>: View {
    let title: String
    var detail: String?
    var help: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, detail: String? = nil, help: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.help = help
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
            Text(title)
                .font(AOMFont.section)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .help(help ?? "")
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: AOMSpace.x2)
            accessory
        }
        .padding(.horizontal, AOMSpace.x0_5)
        .frame(minHeight: AOMSize.sectionTitleHeight)
    }
}

/// One section (e.2): the title sits above an opaque card (radius 12, surface
/// fill, hairline), 8 pt apart; the footer (at most 2 lines of Caption) sits
/// under the card. Use `padding: 0` (the default) when the card holds rows,
/// `AOMSpace.cardPadding` for free content. A card holds one topic and at most
/// 8 rows; never nest a card inside a card.
struct AOMSection<Content: View, Accessory: View>: View {
    var title: String?
    var detail: String?
    var help: String?
    var footer: String?
    var padding: CGFloat
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, detail: String? = nil, help: String? = nil, footer: String? = nil,
         padding: CGFloat = 0,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.help = help
        self.footer = footer
        self.padding = padding
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.titleGap) {
            if let title {
                AOMSectionTitle(title, detail: detail, help: help) { accessory }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Rows draw their divider on top; the first one is not drawn
                // (AOMDivider reads its place in this space).
                .environment(\.aomInSectionCard, true)
                .coordinateSpace(name: AOMSectionCardSpace.space)
                .aomCard(padding: padding)
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AOMSpace.x0_5)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// An inset hairline between rows of a card.
struct AOMRowDivider: View {
    var inset: CGFloat = AOMSpace.rowInset
    var trailingInset: CGFloat = AOMSpace.rowInset

    var body: some View {
        AOMDivider()
            .padding(.leading, inset)
            .padding(.trailing, trailingInset)
            .accessibilityHidden(true)
    }
}

// MARK: - Setting row

/// One settings row (e.3): optional 20 pt symbol, a title (Body, sentence
/// case, no colon), an optional one-line description (Caption), an optional ⓘ
/// with the longer explanation, and the control at the trailing edge. 32 pt
/// tall, 44 pt with a description (4 pt above and below, so a title with an ⓘ
/// over its caption still fits). Dependent options pass `indent: true` and
/// are disabled, not hidden, while their parent switch is off.
///
///     AOMSection("Title-bar snap", help: "…") {
///         AOMToggleRow("Title-bar snap", isOn: $enabled)
///         AOMSettingRow("Swipe sensitivity", help: "How far you swipe before a window moves.") {
///             Picker("Swipe sensitivity", selection: $sensitivity) { … }
///         }
///         .disabled(!enabled)
///     }
struct AOMSettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    var help: String?
    var indent = false
    /// Draw the inset hairline above the row (hidden automatically for the
    /// first row of an `AOMSection`).
    var showsDivider = true
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, symbol: String? = nil, indent: Bool = false,
         help: String? = nil, showsDivider: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.help = help
        self.indent = indent
        self.showsDivider = showsDivider
        self.control = control()
    }

    private var hasDetail: Bool { !(detail ?? "").isEmpty }
    private var leadingInset: CGFloat {
        (symbol == nil ? AOMSpace.rowInset : AOMSpace.rowSymbolInset) + (indent ? AOMSpace.x5 : 0)
    }

    var body: some View {
        HStack(alignment: .center, spacing: AOMSpace.x2) {
            if let symbol {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(width: AOMIcon.row)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: AOMSpace.x1) {
                    Text(title)
                        .font(AOMFont.body)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let help { AOMInfoButton(help, topic: title) }
                }
                if let detail, hasDetail {
                    Text(detail)
                        .font(AOMFont.callout)
                        .foregroundStyle(AOMColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: AOMSpace.x3)
            control
                .labelsHidden()
                .toggleStyle(AOMRowSwitchStyle())
                .fixedSize()
        }
        .padding(.leading, AOMSpace.rowInset + (indent ? AOMSpace.x5 : 0))
        .padding(.trailing, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x1)
        .frame(minHeight: hasDetail ? AOMSize.rowDetail : AOMSize.rowStandard)
        .overlay(alignment: .top) {
            if showsDivider { AOMRowDivider(inset: leadingInset) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// A settings row whose control is a switch.
struct AOMToggleRow: View {
    let title: String
    var detail: String?
    var symbol: String?
    var help: String?
    var indent = false
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, symbol: String? = nil, help: String? = nil,
         indent: Bool = false, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.help = help
        self.indent = indent
        self._isOn = isOn
    }

    var body: some View {
        AOMSettingRow(title, detail: detail, symbol: symbol, indent: indent, help: help) {
            Toggle(title, isOn: $isOn)
        }
    }
}

/// Switches in grouped rows are mini switches so rows keep control height (R24).
/// Checkboxes and other explicit styles set on the control itself still win.
struct AOMRowSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

/// An "Advanced" disclosure at the end of a page (b.7): one row that reveals
/// the rarely used rows in place.
struct AOMDisclosureRows<Content: View>: View {
    let title: String
    var detail: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    init(_ title: String = "Advanced", detail: String? = nil, isExpanded: Binding<Bool>,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AOMMotion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: AOMSpace.x2) {
                    Text(title).font(AOMFont.body).foregroundStyle(AOMColor.text)
                    if let detail {
                        Text(detail).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: AOMSpace.x2)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(AOMColor.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, AOMSpace.rowInset)
                .frame(minHeight: AOMSize.rowStandard)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { AOMRowDivider() }
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the options" : "Shows more options")
            if isExpanded {
                content
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Inline help

/// The ⓘ button: opens a popover with at most a few sentences of help, in
/// the same place on every row, section and page header (e.4, R142).
/// 3.4: the glyph takes the text style of the label beside it (`textStyle`,
/// Body by default) instead of a fixed size, so it matches a Headline section
/// title, a Body row and a Callout footer alike.
struct AOMInfoButton: View {
    let text: String
    var topic: String?
    var textStyle: Font = AOMFont.body
    @State private var shown = false
    @State private var hovering = false

    init(_ text: String, topic: String? = nil, textStyle: Font = AOMFont.body) {
        self.text = text
        self.topic = topic
        self.textStyle = textStyle
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: shown ? "info.circle.fill" : "info.circle")
                .font(textStyle)
                .imageScale(.medium)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovering || shown ? AOMColor.accent : AOMColor.textTertiary)
                .frame(width: AOMIcon.row, height: AOMIcon.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
        .help(topic.map { "About \($0)" } ?? "More information")
        .accessibilityLabel(topic.map { "About \($0)" } ?? "More information")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: AOMSize.helpPopoverWidth, alignment: .leading)
                .padding(AOMSpace.x3)
        }
    }
}

// MARK: - Status pill

/// A small state capsule: a glyph or dot and a few words ("On", "Paused",
/// "Rec", "Needs permission"), in the tone's text colour on a 12% wash. One
/// pill implementation for headers, tiles, sidebar badges and rows.
struct AOMStatusPill: View {
    let text: String
    var tone: AOMTone = .neutral
    var symbol: String?
    private var customTint: Color?
    private var filled = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// `.increased` inside a selected row of an active list: tone colours on
    /// the accent read poorly, so the pill turns white there, like Mail's counts.
    @Environment(\.backgroundProminence) private var prominence

    init(_ text: String, tone: AOMTone = .neutral, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    /// 3.x initializer.
    init(text: String, tint: Color = AOMTheme.positive, filled: Bool = false) {
        self.text = text
        self.customTint = tint
        self.filled = filled
    }

    var body: some View {
        let increased = contrast == .increased
        let onSelection = prominence == .increased
        let fill = onSelection ? Color.white : (customTint ?? tone.color)
        let label = onSelection ? Color.white : (customTint ?? tone.textColor)
        // A 13% wash disappears on dark sidebars and cards; dark mode gets 20%.
        let wash = increased || onSelection ? 0.22 : (scheme == .dark ? 0.2 : 0.13)
        HStack(spacing: AOMSpace.x1) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            } else if differentiateWithoutColor {
                Image(systemName: tone.symbol).imageScale(.small)
            } else {
                Circle().fill(filled ? Color.white : fill).frame(width: AOMIcon.dot, height: AOMIcon.dot)
            }
            Text(text).lineLimit(1)
        }
        .font(AOMFont.caption.weight(.semibold))
        .foregroundStyle(filled ? Color.white : label)
        .padding(.horizontal, AOMSpace.x2 - AOMSpace.x0_5)
        .frame(minHeight: AOMIcon.row)
        .background(filled ? AnyShapeStyle(fill) : AnyShapeStyle(fill.opacity(wash)), in: Capsule())
        .overlay {
            if increased { Capsule().strokeBorder(fill.opacity(0.9), lineWidth: 1) }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - Module badge and tile

/// A module or item mark: its SF Symbol in a quiet neutral squircle, the
/// way Finder, Xcode and System Information draw item icons. Colour is not
/// identity here (it marks interaction and status only), so a page of tiles
/// reads as one surface instead of a palette. An inactive mark dims its glyph.
struct AOMModuleBadge: View {
    let symbol: String
    var size: CGFloat = AOMIcon.tileBadge
    var active = true
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ module: AOMModule, size: CGFloat = AOMIcon.tileBadge, active: Bool = true) {
        self.symbol = module.symbol
        self.size = size
        self.active = active
    }

    init(symbol: String, size: CGFloat = AOMIcon.tileBadge, active: Bool = true) {
        self.symbol = symbol
        self.size = size
        self.active = active
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.squircle(size), style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: (size * 0.46).rounded(), weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(active ? AOMColor.text : AOMColor.textTertiary)
            .frame(width: size, height: size)
            .background(active ? AOMColor.sunken : AOMColor.track, in: shape)
            .overlay {
                if contrast == .increased { shape.strokeBorder(AOMColor.strongLine, lineWidth: 1) }
            }
            .accessibilityHidden(true)
    }
}

/// A Workspace module row: glyph, name over status, the live figure and the
/// module's switch.
struct AOMModuleTile<Control: View, MenuItems: View>: View {
    let module: AOMModule
    let metric: String
    var unit: String?
    let status: String
    var statusTone: AOMTone?
    var active = true
    var running = false
    let open: () -> Void
    @ViewBuilder var control: Control
    @ViewBuilder var menuItems: MenuItems
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ module: AOMModule, metric: String, unit: String? = nil, status: String, statusTone: AOMTone? = nil,
         active: Bool = true, running: Bool = false, open: @escaping () -> Void,
         @ViewBuilder control: () -> Control, @ViewBuilder menu: () -> MenuItems) {
        self.module = module
        self.metric = metric
        self.unit = unit
        self.status = status
        self.statusTone = statusTone
        self.active = active
        self.running = running
        self.open = open
        self.control = control()
        self.menuItems = menu()
    }

    /// Warning, danger and recording statuses carry their glyph and text colour.
    private var emphasisedTone: AOMTone? {
        guard let statusTone, statusTone != .neutral, statusTone != .success else { return nil }
        return statusTone
    }

    var body: some View {
        // A row in a frosted pane (System Settings): the glyph, the name over
        // its status, the live figure and the module's one control. The whole
        // row opens the page; the control keeps its own clicks.
        ZStack {
            Button(action: open) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.well))
            .accessibilityLabel(([module.title, [metric, unit].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "), status])
                .filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityHint("Opens \(module.title)")
            .help("\(module.title): \(status)")

            HStack(spacing: AOMSpace.x3) {
                Image(systemName: module.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(active ? AOMColor.text : AOMColor.textTertiary)
                    .symbolEffect(.pulse, options: .repeating, isActive: running && !reduceMotion)
                    .frame(width: 26)
                    .allowsHitTesting(false)
                lines
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                // The figure ends where the control slot begins, so figures
                // are trailing-aligned down a column; an empty metric (a
                // switch already says on or off) draws nothing.
                if !metric.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x0_5 + 1) {
                        Text(metric)
                            .font(AOMFont.bodyEmphasis.monospacedDigit())
                            .foregroundStyle(active ? AOMColor.text : AOMColor.textSecondary)
                            .contentTransition(.numericText())
                        if let unit {
                            Text(unit)
                                .font(AOMFont.caption)
                                .foregroundStyle(AOMColor.textSecondary)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                control
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .frame(width: AOMSize.moduleControlSlot, alignment: .trailing)
            }
            .padding(.horizontal, AOMSpace.x3)
        }
        .frame(height: AOMSize.moduleRowHeight)
        .contextMenu {
            Button("Open \(module.title)", action: open)
            menuItems
        }
        .accessibilityElement(children: .contain)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(module.title)
                .font(AOMFont.bodyEmphasis)
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
            HStack(spacing: AOMSpace.x1) {
                if let tone = emphasisedTone {
                    Image(systemName: tone.symbol)
                        .imageScale(.small)
                        .foregroundStyle(tone.color)
                        .accessibilityHidden(true)
                } else if active {
                    Circle()
                        .fill(AOMColor.success)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(status)
                    .font(AOMFont.caption)
                    .foregroundStyle(emphasisedTone?.textColor ?? AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityHidden(true)
    }
}

extension AOMModuleTile where MenuItems == EmptyView {
    init(_ module: AOMModule, metric: String, unit: String? = nil, status: String, statusTone: AOMTone? = nil,
         active: Bool = true, running: Bool = false, open: @escaping () -> Void,
         @ViewBuilder control: () -> Control) {
        self.init(module, metric: metric, unit: unit, status: status, statusTone: statusTone, active: active,
                  running: running, open: open, control: control, menu: { EmptyView() })
    }
}

// MARK: - Destructive button

/// Destructive actions (e.7): `role: .destructive`, the bordered style and a
/// red label, never the prominent style. They go last in their section.
struct AOMDestructiveButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: .destructive, action: configuration.trigger) { configuration.label }
            .buttonStyle(.bordered)
            .foregroundStyle(AOMColor.dangerText)
    }
}

extension View {
    /// `Button("Reset…", role: .destructive) { … }.aomDestructive()`
    func aomDestructive() -> some View { buttonStyle(AOMDestructiveButtonStyle()) }
}

// MARK: - List row

/// One list row in three slots: leading glyph, title over an optional
/// detail line, trailing value or control.
struct AOMListRow<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String?
    var dimmed = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(_ title: String, detail: String? = nil, dimmed: Bool = false,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.dimmed = dimmed
        self.leading = leading()
        self.trailing = trailing()
    }

    private var hasDetail: Bool { !(detail ?? "").isEmpty }

    var body: some View {
        // Hierarchical styles, not fixed label colors: List selection inverts
        // them to white on the accent fill, so selected rows stay readable.
        HStack(spacing: AOMSpace.x2) {
            leading
                .frame(width: AOMIcon.row)
                .foregroundStyle(dimmed ? .tertiary : .secondary)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(title)
                    .font(AOMType.rowTitle)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail, hasDetail {
                    Text(detail)
                        .font(AOMType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(minHeight: hasDetail ? AOMSize.rowDouble - AOMSpace.x2 : AOMSize.rowSingle - AOMSpace.x2)
        .padding(.vertical, AOMSpace.x1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Notice

/// The inline warning or error banner (e.6): a severity glyph, a `.primary`
/// sentence covering the problem and its consequence, an optional detail line
/// and one verb button, on the severity colour at 12%. Only shown when
/// something is wrong; at most two per page, at the top of the affected section.
struct AOMNotice<Actions: View>: View {
    enum Tone { case warning, error, info }
    let tone: Tone
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ tone: Tone, _ title: String, detail: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    private var semantic: AOMTone {
        switch tone {
        case .warning: return .warning
        case .error: return .danger
        case .info: return .info
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous)
        HStack(alignment: .center, spacing: AOMSpace.x2) {
            Image(systemName: semantic.symbol)
                .font(AOMFont.bodyEmphasis)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(semantic.color)
                .frame(width: AOMIcon.row)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                Text(title).font(AOMFont.bodyEmphasis).foregroundStyle(AOMColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: AOMSpace.x2) { actions }
                .buttonStyle(.bordered)
                .fixedSize()
        }
        // 10 pt above and below a regular button, the row inset at the sides.
        .padding(.horizontal, AOMSpace.rowInset)
        .padding(.vertical, AOMSpace.x2 + AOMSpace.x0_5)
        .background(semantic.wash(increasedContrast: contrast == .increased), in: shape)
        .overlay {
            if contrast == .increased { shape.strokeBorder(semantic.color.opacity(0.85), lineWidth: 1) }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Run status

/// The outcome of the last manual run, shown next to the button that ran it.
enum AOMRunState: Equatable {
    case idle
    case running
    case succeeded(Date)
    case failed(Date)
}

struct AOMRunStatusView: View {
    let state: AOMRunState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            switch state {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: AOMSpace.x1 + 2) {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(AOMTheme.textSecondary)
                }
            case .succeeded(let date):
                Label("Ran \(AOMRelativeTime.string(date, now: context.date).lowercased())", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AOMColor.successText)
            case .failed(let date):
                Label("Failed or stopped \(AOMRelativeTime.string(date, now: context.date).lowercased())",
                      systemImage: "xmark.circle.fill")
                    .foregroundStyle(AOMColor.dangerText)
            }
        }
        .font(AOMType.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shortcut text

/// A shortcut as separate key caps (⌥ P), for places where the trigger is
/// the thing being read.
struct AOMShortcutKeys: View {
    let shortcut: KeyboardShortcut
    /// Renders the caps white-on-transparent so they read inside a selected
    /// list row; plain key caps keep the chip look everywhere else.
    var onSelection = false

    var body: some View {
        let display = shortcut.displayString
        HStack(spacing: AOMSpace.x0_5 + 1) {
            ForEach(Array(Self.parts(display).enumerated()), id: \.offset) { _, part in
                AOMKeycap(text: part, onSelection: onSelection)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display)
    }

    /// Splits "⌃⌥P" into ["⌃", "⌥", "P"]; multi-letter keys stay whole.
    static func parts(_ display: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var result: [String] = []
        var rest = Substring(display)
        while let first = rest.first, modifiers.contains(first) {
            result.append(String(first))
            rest = rest.dropFirst()
        }
        if rest.hasPrefix("fn") {
            result.append("fn")
            rest = rest.dropFirst(2)
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }
}

// MARK: - Pane

extension View {
    /// The content pane background (the canvas), edge to edge.
    func aomPane() -> some View {
        background(AOMTheme.pane)
    }
}
