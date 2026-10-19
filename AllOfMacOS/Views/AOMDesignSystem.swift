import AppKit
import SwiftUI

// MARK: - Design tokens

/// One set of spacing, radius and surface rules for every AOM page, so
/// Gestures, Window Tiling, Capture, Clipboard and Insights read as one
/// Apple-native app instead of five differently padded screens.
enum AOMDesign {
    /// Outer page margin and the gap between sections.
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
    static let gridSpacing: CGFloat = 12
    /// Continuous corner radii: large surfaces, tiles/cards, small controls.
    static let surfaceRadius: CGFloat = 16
    static let tileRadius: CGFloat = 12
    static let controlRadius: CGFloat = 7

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func animation(_ animation: Animation = .snappy(duration: 0.22)) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// A static canvas: no live backdrop sampling, per-frame work or animated blur.
struct AOMWorkspaceBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(alignment: .top) {
                if !reduceTransparency && contrast != .increased {
                    LinearGradient(colors: [Color.accentColor.opacity(scheme == .dark ? 0.055 : 0.035), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 360)
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Surfaces

/// A grouped surface (System Settings / Finder inspector style): content
/// background, hairline separator, no decorative shadow. Adapts to light,
/// dark and Increase Contrast.
struct AOMSurface: ViewModifier {
    var radius: CGFloat = AOMDesign.surfaceRadius
    var padding: CGFloat? = 14
    var highlighted = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.48),
                                  lineWidth: highlighted ? 1.5 : (contrast == .increased ? 1 : 0.5))
            }
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
                    Label(title, systemImage: systemImage).font(.headline)
                } else {
                    Text(title).font(.headline)
                }
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
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
                trailing.controlSize(.regular)
            }
            VStack(alignment: .leading, spacing: 14) {
                heading
                trailing.controlSize(.regular)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .bold)).tracking(-0.5)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Rounded, colour-filled SF Symbol tile in the System Settings style.
struct AOMIconTile: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
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
        HStack(spacing: 12) {
            AOMIconTile(systemImage: systemImage, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aomSurface(radius: AOMDesign.tileRadius, padding: 12)
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
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 23, weight: .medium)).foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(hovering ? 0.09 : 0.035))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
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
