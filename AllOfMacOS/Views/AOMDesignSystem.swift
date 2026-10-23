import AppKit
import SwiftUI

// MARK: - Design tokens

/// One set of spacing, radius and surface rules for every AOM page, so
/// Gestures, Window Tiling, Capture, Clipboard and Insights read as one
/// Apple-native app instead of five differently padded screens.
enum AOMDesign {
    /// Outer page margin and the gap between sections.
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = AOMTheme.sectionSpacing
    static let gridSpacing: CGFloat = 10
    /// Continuous corner radii: large surfaces, tiles/cards, small controls.
    static let surfaceRadius: CGFloat = AOMTheme.cardRadius
    static let tileRadius: CGFloat = 10
    static let controlRadius: CGFloat = AOMTheme.controlRadius

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func animation(_ animation: Animation = .snappy(duration: 0.22)) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// A static canvas: no live backdrop sampling, per-frame work or animated blur.
struct AOMWorkspaceBackground: View {
    var body: some View {
        AOMAmbientBackground()
    }
}

// MARK: - Surfaces

/// Shared card surface with restrained elevation and an explicit outline
/// when Increase Contrast is enabled.
struct AOMSurface: ViewModifier {
    var radius: CGFloat = AOMDesign.surfaceRadius
    var padding: CGFloat? = 14
    var highlighted = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.50),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? AOMTheme.blue
                                  : (contrast == .increased ? AOMTheme.textSecondary : Color.white.opacity(scheme == .dark ? 0.20 : 0.60)),
                                  lineWidth: highlighted ? 1.5 : 0.9)
            }
            .shadow(color: AOMTheme.cardShadow, radius: 16, x: 0, y: 7)
    }
}

extension View {
    func aomSurface(radius: CGFloat = AOMDesign.surfaceRadius, padding: CGFloat? = 14, highlighted: Bool = false) -> some View {
        modifier(AOMSurface(radius: radius, padding: padding, highlighted: highlighted))
    }

    /// Bottom floating confirmation, shared by every page (material capsule,
    /// readable in light and dark mode, announced to VoiceOver).
    func aomToast(_ message: String?) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
                    .onAppear { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
            }
        }
        .animation(AOMDesign.animation(.easeOut(duration: 0.2)), value: message)
    }
}

// MARK: - Section header

/// Title + optional caption and trailing accessory, aligned to the grid.
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let systemImage {
                    Label(title, systemImage: systemImage).font(.aomHeadline(13))
                } else {
                    Text(title).font(.aomHeadline(13))
                }
                if let caption {
                    Text(caption).font(.aomCaption(11)).foregroundStyle(AOMTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Page header

/// A consistent page heading, live summary and native controls. Controls move
/// below the title when a compact detail column needs more room.
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
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { AOMTheme.divider.opacity(0.5).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 50, height: 50)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.8).foregroundStyle(AOMTheme.text)
                Text(subtitle).font(.aomBody(13.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(2)
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
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)

            .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(AOMTheme.textSecondary)
                Spacer(minLength: 4)
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(AOMTheme.textTertiary)
            }
            Text(value).font(.system(size: 26, weight: .medium, design: .rounded))
                .monospacedDigit().contentTransition(.numericText()).lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AOMTheme.cardAlt.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Quick action tile

/// A launch tile: icon, title, keyboard hint. Large hit target, hover
/// feedback, and the standard focus ring through `.buttonStyle(.plain)`.
struct AOMActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var subtitle: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AOMTheme.text).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(AOMTheme.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(hovering ? AOMTheme.cardAlt : AOMTheme.card,
                        in: RoundedRectangle(cornerRadius: AOMDesign.tileRadius))
            .contentShape(RoundedRectangle(cornerRadius: AOMDesign.tileRadius))
        }
        .buttonStyle(AOMCardButtonStyle())
        .onHover { hovering = $0 }
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
