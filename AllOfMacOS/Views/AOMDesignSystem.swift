import AppKit
import SwiftUI

// MARK: - Design tokens (3.x aliases)

/// One set of spacing, radius and surface rules for every AOM page. These are
/// aliases of AOMTokens.swift, kept for existing call sites.
enum AOMDesign {
    static var reduceMotion: Bool { AOMMotion.systemReduceMotion }
    static func animation(_ animation: Animation = AOMMotion.quickCurve) -> Animation? {
        AOMMotion.resolve(animation, reduceMotion: reduceMotion)
    }
}

/// The shell's one canvas: every page sits on the same opaque neutral grey
/// (`AOMColor.canvas`), edge to edge under the toolbar, so the system draws
/// the toolbar glass and scroll-edge effect over it. Glass belongs to the
/// functional layer only (HIG Materials; WWDC25 219 "avoid glass on glass").
struct AOMWorkspaceBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AOMTranslucency.defaultsKey) private var translucent = AOMTranslucency.defaultOn
    @AppStorage(AOMTranslucency.levelKey) private var levelName = AOMTranslucency.Level.balanced.rawValue

    /// 6.5 (Raycast's window): the desktop seen through the window, a soft
    /// accent light from the top corner; the pages lay their canvas tint on
    /// top (`AOMColor.pageBackground`). The opaque canvas otherwise.
    var body: some View {
        Group {
            if translucent && !reduceTransparency && contrast != .increased {
                ZStack {
                    VisualEffectBackground(material: (AOMTranslucency.Level(rawValue: levelName) ?? .balanced).material,
                                           blendingMode: .behindWindow, state: .followsWindowActiveState)
                    RadialGradient(colors: [AOMColor.accent.opacity(colorScheme == .dark ? 0.16 : 0.09), .clear],
                                   center: .topTrailing, startRadius: 24, endRadius: 620)
                    RadialGradient(colors: [AOMBrand.start.opacity(colorScheme == .dark ? 0.10 : 0.05), .clear],
                                   center: .bottomLeading, startRadius: 24, endRadius: 520)
                }
            } else {
                AOMColor.canvas
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// 7.8 (Codex WIN-01): the page's canvas tint over the window's blur, as a
/// view that re-reads Translucent window and its level — so switching either
/// in Settings changes an open window at once (the shared dynamic colour was
/// resolved once and kept). Opaque with Reduce Transparency or Increase
/// Contrast; the user's own setting returns when those are turned off.
struct AOMPageTint: View {
    @AppStorage(AOMTranslucency.defaultsKey) private var translucent = AOMTranslucency.defaultOn
    @AppStorage(AOMTranslucency.levelKey) private var levelName = AOMTranslucency.Level.balanced.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = colorScheme == .dark
        let base = dark ? NSColor(srgbRed: 0.094, green: 0.094, blue: 0.102, alpha: 1)
                        : NSColor(srgbRed: 0.969, green: 0.965, blue: 0.953, alpha: 1)
        let alpha = AOMTranslucency.pageAlpha(enabled: translucent, reduceTransparency: reduceTransparency,
                                              increaseContrast: contrast == .increased, dark: dark,
                                              level: AOMTranslucency.Level(rawValue: levelName) ?? .balanced)
        Color(nsColor: base.withAlphaComponent(alpha))
            .accessibilityHidden(true)
    }
}

// MARK: - Surfaces

extension View {

    /// Bottom floating confirmation shared by every page: a glass capsule
    /// (floating chrome), announced to VoiceOver. Failures use `.danger` and
    /// say why; an item may offer one action ("Undo").
    func aomToast(_ model: AOMToastModel) -> some View {
        modifier(AOMToastModelPresenter(model: model))
    }
}

private struct AOMToastModelPresenter: ViewModifier {
    @ObservedObject var model: AOMToastModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message = model.message {
                    HStack(spacing: AOMSpace.x2) {
                        Image(systemName: model.tone.symbol)
                            .foregroundStyle(model.tone.color)
                            .accessibilityHidden(true)
                        Text(message)
                            .foregroundStyle(AOMColor.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let title = model.actionTitle {
                            Button(title) { model.performAction() }
                                .aomGlassButton()
                                .controlSize(.small)
                                // A hidden page's toast must not take ⌘Z.
                                .aomShortcut("z")
                        }
                    }
                    .font(AOMFont.body.weight(.medium))
                    .padding(.leading, AOMSpace.x3)
                    .padding(.trailing, model.actionTitle == nil ? AOMSpace.x3 : AOMSpace.x2)
                    .padding(.vertical, AOMSpace.x2 - 1)
                    .frame(maxWidth: AOMSize.toastMaxWidth)
                    .fixedSize(horizontal: true, vertical: false)
                    .aomChrome(radius: AOMRadius.panel, role: .hud, inWindow: true)
                    .padding(.bottom, AOMSpace.x4)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
                    .onAppear {
                        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                             userInfo: [.announcement: message,
                                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                    }
                }
            }
            .aomAnimation(.standard, value: model.message)
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
/// hairlines instead of a row of separate cards. Each cell is its label
/// (Caption, secondary) over the figure (Title 2 medium) and its unit
/// (Caption). Columns with an action are buttons.
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
                    AOMDivider().padding(.horizontal, AOMSpace.x3)
                }
                // Top-aligned: a cell with a detail line must not push its
                // neighbours' values down half a line.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            AOMDivider(axis: .vertical).padding(.vertical, AOMSpace.x3)
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
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            HStack(spacing: AOMSpace.x1 + 2) {
                Image(systemName: item.systemImage)
                    .imageScale(.small)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(AOMFont.caption)
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
                            .font(AOMFont.caption)
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
        .padding(.horizontal, AOMSpace.cardPadding)
        .padding(.vertical, AOMSpace.x2 + AOMSpace.x0_5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.value, item.unit, item.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(navigates ? .isButton : [])
    }
}

// MARK: - Empty state

/// An empty state centred in the space it is given (e.5), laid out like
/// `ContentUnavailableView` at the page's scale: a 28 pt hierarchical symbol,
/// the title in Body medium, one sentence in Callout secondary and at most
/// one action at regular size, about 130 pt tall in all.
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

    @Environment(\.aomPageTab) private var pageTab

    var body: some View {
        VStack(spacing: AOMSpace.x2) {
            if let pageTab {
                // 5.0: the empty page shows whose page it is, in its hue.
                AOMAppIcon(AOMIdentity(symbol: systemImage,
                                       color: pageTab.identity.isBrand ? AOMBrand.start : pageTab.identity.color),
                           size: AOMIcon.identityHero)
                    .padding(.bottom, AOMSpace.x0_5)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: AOMIcon.empty, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AOMColor.textSecondary)
                    .frame(height: AOMIcon.empty)
                    .accessibilityHidden(true)
            }
            VStack(spacing: AOMSpace.x1) {
                Text(title)
                    .font(pageTab == nil ? AOMFont.bodyEmphasis : AOMFont.title)
                    .foregroundStyle(AOMColor.text)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: AOMSize.readableText)
            // Narrow columns (the Automation list) must stack the actions
            // instead of clipping them: try one row first, fall back to a
            // leading-aligned column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AOMSpace.x2) { actions }
                VStack(alignment: .leading, spacing: AOMSpace.x2) { actions }
            }
            .controlSize(.regular)
            .padding(.top, AOMSpace.x1)
        }
        .padding(.horizontal, AOMSpace.pageMargin)
        .padding(.vertical, AOMSpace.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Toast state

/// Shared transient-message timer used by the pages' `aomToast`. 3.4: a
/// toast can carry a tone and one action ("Undo"), which keeps it on screen
/// longer (`AOMMotion.undoToastSeconds`) so the action can be reached.
@MainActor
final class AOMToastModel: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var tone: AOMTone = .success
    @Published private(set) var actionTitle: String?
    private(set) var action: (() -> Void)?
    private var task: Task<Void, Never>?

    func show(_ text: String, tone: AOMTone = .success, seconds: Double? = nil,
              actionTitle: String? = nil, action: (() -> Void)? = nil) {
        task?.cancel()
        self.tone = tone
        self.actionTitle = action == nil ? nil : (actionTitle ?? "Undo")
        self.action = action
        message = text
        let duration = seconds ?? (action == nil ? AOMMotion.toastSeconds : AOMMotion.undoToastSeconds)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Runs the toast's action (Undo) once and hides the toast.
    func performAction() {
        let run = action
        dismiss()
        run?()
    }

    func dismiss() {
        task?.cancel()
        message = nil
        actionTitle = nil
        action = nil
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
