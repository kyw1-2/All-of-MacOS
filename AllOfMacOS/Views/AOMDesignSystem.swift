import AppKit
import SwiftUI

// MARK: - Design tokens (3.x aliases)

/// One set of spacing, radius and surface rules for every AOM page. These are
/// aliases of AOMTokens.swift, kept for existing call sites.
enum AOMDesign {
    /// Outer page margin and the gap between sections.
    static let pagePadding: CGFloat = AOMSpace.pageMargin
    static let sectionSpacing: CGFloat = AOMSpace.sectionGap
    static let gridSpacing: CGFloat = AOMSpace.tileGap
    /// Continuous corner radii: large surfaces, tiles/cards, small controls.
    static let surfaceRadius: CGFloat = AOMRadius.card
    static let tileRadius: CGFloat = AOMRadius.card
    static let controlRadius: CGFloat = AOMRadius.control

    static var reduceMotion: Bool { AOMMotion.systemReduceMotion }
    static func animation(_ animation: Animation = AOMMotion.quickCurve) -> Animation? {
        AOMMotion.resolve(animation, reduceMotion: reduceMotion)
    }
}

/// The shell's one canvas: every page sits on the same opaque surface
/// (#FFFFFF / #282828), edge to edge under the toolbar, so the system draws
/// the toolbar glass and scroll-edge effect over it. No translucent window,
/// no behind-window material (c.4).
struct AOMWorkspaceBackground: View {
    var body: some View {
        AOMColor.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

private struct AOMHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Surfaces

/// Shared card surface; `highlighted` draws an accent outline.
struct AOMSurface: ViewModifier {
    var radius: CGFloat = AOMDesign.surfaceRadius
    var padding: CGFloat? = AOMSpace.cardPadding
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .aomCardStyle(.paper, radius: radius, padding: padding)
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(AOMColor.accent.opacity(0.85), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func aomSurface(radius: CGFloat = AOMDesign.surfaceRadius, padding: CGFloat? = AOMSpace.cardPadding,
                    highlighted: Bool = false) -> some View {
        modifier(AOMSurface(radius: radius, padding: padding, highlighted: highlighted))
    }

    /// Reports this view's laid-out height, so a page can size its sheet to
    /// end exactly at the bottom margin below a header of any height.
    func aomReadHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: AOMHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(AOMHeightPreferenceKey.self) { value in
            if abs(height.wrappedValue - value) > 0.5 { height.wrappedValue = value }
        }
    }

    /// Bottom floating confirmation shared by every page: a glass capsule
    /// (floating chrome), announced to VoiceOver.
    func aomToast(_ message: String?) -> some View {
        modifier(AOMToastPresenter(message: message))
    }
}

private struct AOMToastPresenter: ViewModifier {
    let message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(AOMFont.body.weight(.medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(AOMColor.success, AOMColor.text)
                        .labelStyle(AOMToastLabelStyle())
                        .padding(.horizontal, AOMSpace.x4)
                        .padding(.vertical, AOMSpace.x3 - 2)
                        .aomChrome(radius: 22, role: .hud, inWindow: true)
                        .padding(.bottom, AOMSpace.x5)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                        .onAppear {
                            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                                 userInfo: [.announcement: message,
                                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                        }
                }
            }
            .aomAnimation(.standard, value: message)
    }
}

/// Toast label: the check in the success colour, the sentence in `.primary`.
private struct AOMToastLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AOMSpace.x2) {
            configuration.icon.foregroundStyle(AOMColor.success)
            configuration.title.foregroundStyle(AOMColor.text)
        }
    }
}

/// Toolbar-style bordered button (kept for older call sites).
struct AOMToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AOMToolbarButtonBody(configuration: configuration)
    }
}

private struct AOMToolbarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous)
        configuration.label
            .font(AOMFont.body.weight(.medium))
            .foregroundStyle(AOMTheme.text)
            .padding(.horizontal, AOMSpace.x3 - 2)
            .frame(height: 26)
            .background(configuration.isPressed ? AOMColor.track : (hovering ? AOMColor.sunken : .clear), in: shape)
            .overlay(shape.strokeBorder(AOMColor.hairline, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .aomAnimation(.quick, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - Stat strip

/// One figure in an `AOMStatStrip`.
struct AOMStatItem: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    var unit: String?
    var detail: String?
    let systemImage: String
    var tint: Color = AOMTheme.blue
    var action: (() -> Void)?
}

/// Summary figures as one integrated band: equal columns divided by
/// hairlines instead of a row of separate cards. Columns with an action are
/// buttons.
struct AOMStatStrip: View {
    let items: [AOMStatItem]
    /// Figures per row; `nil` keeps them all on one row.
    var columns: Int?

    var body: some View {
        let perRow = max(1, columns ?? items.count)
        let rows = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 {
                    AOMDivider().padding(.horizontal, AOMSpace.x4)
                }
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            AOMDivider(axis: .vertical).padding(.vertical, AOMSpace.x4)
                        }
                        AOMStatCell(item: item).padding(AOMSpace.x1)
                    }
                    // Keep column widths equal on a short last row.
                    ForEach(0..<(perRow - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).padding(AOMSpace.x1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AOMStatCell: View {
    let item: AOMStatItem

    var body: some View {
        if let action = item.action {
            Button(action: action) { content(navigates: true) }
                .buttonStyle(AOMRowButtonStyle(radius: AOMRadius.card))
                .help("Open \(item.title)")
        } else {
            content(navigates: false)
        }
    }

    private func content(navigates: Bool) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x2) {
            HStack(spacing: AOMSpace.x1 + 2) {
                Image(systemName: item.systemImage)
                    .imageScale(.small)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(AOMFont.callout.weight(.medium))
                    .foregroundStyle(AOMTheme.textSecondary)
                    .lineLimit(1)
                if navigates {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(AOMTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x1 + 1) {
                    Text(item.value)
                        .font(AOMFont.metricLarge)
                        .foregroundStyle(AOMTheme.text)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit = item.unit {
                        Text(unit)
                            .font(AOMFont.callout.weight(.medium))
                            .foregroundStyle(AOMTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(AOMSpace.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.value, item.unit, item.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(navigates ? .isButton : [])
    }
}

// MARK: - Quick action tile

/// A launch tile: glyph, title, hint. Large hit target, hover wash, press dim,
/// standard focus ring.
struct AOMActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AOMSpace.x3) {
                AOMIconBadge(systemImage: systemImage, tint: tint, size: 24, filled: true)
                VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                    Text(title).font(AOMType.bodyEmphasis).foregroundStyle(AOMTheme.text).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        }
        .buttonStyle(AOMCardTileButtonStyle(style: .paper, radius: AOMDesign.tileRadius, padding: AOMSpace.x3))
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }
}

// MARK: - Empty state

/// Native `ContentUnavailableView` that fills the space it is given (e.5):
/// the system's 40 pt hierarchical symbol, a title, one sentence and at most
/// one primary action.
struct AOMEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder var actions: Actions

    init(_ title: String, systemImage: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text(message)
        } actions: {
            // Narrow columns (the Automation list) must stack the actions
            // instead of clipping them: try one row first, fall back to a
            // leading-aligned column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AOMSpace.x2) { actions }
                VStack(alignment: .leading, spacing: AOMSpace.x2) { actions }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toast state

/// Shared transient-message timer used by the pages' `aomToast`.
@MainActor
final class AOMToastModel: ObservableObject {
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    func show(_ text: String, seconds: Double = 2) {
        task?.cancel()
        message = text
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

// MARK: - Relative time

enum AOMRelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func string(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "Just now") }
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

extension Color {
    /// A darker shade for gradients (macOS 14 has no `Color.mix`).
    func aomDarker(_ amount: CGFloat) -> Color {
        let base = NSColor(self).usingColorSpace(.deviceRGB) ?? .gray
        return Color(nsColor: base.blended(withFraction: amount, of: .black) ?? base)
    }
}
