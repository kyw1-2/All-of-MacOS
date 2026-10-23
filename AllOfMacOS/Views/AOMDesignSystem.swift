import AppKit
import SwiftUI

// MARK: - Design tokens

/// One set of spacing, radius and surface rules for every AOM page, so
/// Automation, Window Tiling, Capture, Clipboard and Insights read as one
/// Apple-native app instead of five differently padded screens.
enum AOMDesign {
    /// Outer page margin and the gap between sections.
    static let pagePadding: CGFloat = AOMTheme.pagePadding
    static let sectionSpacing: CGFloat = AOMTheme.sectionSpacing
    static let gridSpacing: CGFloat = 14
    /// Continuous corner radii: large surfaces, tiles/cards, small controls.
    static let surfaceRadius: CGFloat = AOMTheme.cardRadius
    static let tileRadius: CGFloat = 14
    static let controlRadius: CGFloat = AOMTheme.controlRadius

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func animation(_ animation: Animation = .snappy(duration: 0.22)) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Pages draw no canvas of their own: the main shell owns one canvas, so every
/// page sits on the same calm surface.
struct AOMWorkspaceBackground: View {
    var body: some View { Color.clear }
}

private struct AOMHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Surfaces

/// Shared paper surface; `highlighted` draws an accent outline.
struct AOMSurface: ViewModifier {
    var radius: CGFloat = AOMDesign.surfaceRadius
    var padding: CGFloat? = 16
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .aomCardStyle(.paper, radius: radius, padding: padding, hovering: highlighted)
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(AOMTheme.blue.opacity(0.85), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func aomSurface(radius: CGFloat = AOMDesign.surfaceRadius, padding: CGFloat? = 16, highlighted: Bool = false) -> some View {
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

    /// Bottom floating confirmation, shared by every page (glass capsule,
    /// readable in light and dark mode, announced to VoiceOver).
    func aomToast(_ message: String?) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AOMTheme.ink.opacity(0.94), in: Capsule())
                    .overlay(Capsule().strokeBorder(AOMTheme.rim(), lineWidth: AOMTheme.rimWidth))
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
                    .onAppear { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
            }
        }
        .animation(AOMDesign.animation(.easeOut(duration: 0.2)), value: message)
    }
}

/// Toolbar button used by page headers: a white pill with a hairline.
struct AOMToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AOMToolbarButtonBody(configuration: configuration)
    }
}

private struct AOMToolbarButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(AOMTheme.text)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(hovering ? AOMTheme.cardAlt : AOMTheme.paper, in: shape)
            .overlay(shape.strokeBorder(AOMTheme.hairline, lineWidth: 0.75))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : AOMTheme.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - Section header

/// Section title with an optional caption and trailing accessory.
struct AOMSectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    var caption: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, systemImage: String? = nil, caption: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.caption = caption
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AOMTheme.textSecondary)
                    }
                    Text(title).font(AOMType.sectionTitle).tracking(-0.3).foregroundStyle(AOMTheme.text)
                }
                .accessibilityAddTraits(.isHeader)
                if let caption {
                    Text(caption).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Page header

/// A page heading: squircle badge, 26 pt title, 14 pt subtitle and native
/// controls. Controls move below the title when space is short.
struct AOMPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String, systemImage: String, tint: Color,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                heading
                Spacer(minLength: 12)
                trailing.controlSize(.regular).buttonStyle(AOMToolbarButtonStyle())
            }
            VStack(alignment: .leading, spacing: 14) {
                heading
                trailing.controlSize(.regular).buttonStyle(AOMToolbarButtonStyle())
            }
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(spacing: 14) {
            AOMIconBadge(systemImage: systemImage, tint: tint, size: 44, filled: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).aomPageTitle().lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(AOMType.subtitle).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
            }
        }
    }
}

/// Soft tinted symbol tile shared by cards and editors.
struct AOMIconTile: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        AOMIconBadge(systemImage: systemImage, tint: tint, size: size)
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

/// Summary figures as one integrated band — equal columns divided by
/// hairlines, the way Toss summarises assets and Screen Time heads its page —
/// instead of a row of separate cards. Columns with an action are buttons.
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
                    AOMDivider().padding(.horizontal, 14)
                }
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            AOMDivider(axis: .vertical).padding(.vertical, 18)
                        }
                        AOMStatCell(item: item).padding(6)
                    }
                    // Keep column widths equal on a short last row.
                    ForEach(0..<(perRow - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).padding(6)
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
                .buttonStyle(AOMRowButtonStyle(radius: 14))
                .help("Open \(item.title)")
        } else {
            content(navigates: false)
        }
    }

    private func content(navigates: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AOMIconBadge(systemImage: item.systemImage, tint: item.tint, size: 24, filled: true)
                Text(item.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AOMTheme.textSecondary)
                    .lineLimit(1)
                if navigates {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AOMTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.value)
                        .font(AOMType.metric(28))
                        .tracking(-0.4)
                        .monospacedDigit()
                        .foregroundStyle(AOMTheme.text)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit = item.unit {
                        Text(unit)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AOMTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AOMTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.value, item.unit, item.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(navigates ? .isButton : [])
    }
}

// MARK: - Metric tile

struct AOMMetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AOMIconBadge(systemImage: systemImage, tint: tint, size: 32)
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(AOMType.metric(32))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(AOMTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(AOMType.caption).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aomCardStyle(.paper, padding: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Quick action tile

/// A launch tile: squircle badge, title, hint. Large hit target, hover lift,
/// spring press, standard focus ring.
struct AOMActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AOMIconBadge(systemImage: systemImage, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AOMTheme.text).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        }
        .buttonStyle(AOMCardTileButtonStyle(style: .paper, radius: AOMDesign.tileRadius, padding: 12))
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }
}

// MARK: - Empty state

/// Native `ContentUnavailableView` that fills the space it is given, with an
/// optional primary action, so an empty page still guides the next step.
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
        } description: {
            Text(message)
        } actions: {
            actions
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
