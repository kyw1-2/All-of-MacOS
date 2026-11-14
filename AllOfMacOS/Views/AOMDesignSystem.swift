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

/// The main window's backdrop: a behind-window blur of the desktop (the
/// glass the sidebar is made of) under every page, so pages and their
/// frosted panes float on it. Reduce Transparency turns it opaque by itself.
struct AOMWorkspaceBackground: View {
    var body: some View {
        VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow, state: .followsWindowActiveState)
            .ignoresSafeArea()
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
                                .keyboardShortcut("z", modifiers: .command)
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
                    .font(AOMFont.caption.weight(.medium))
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
        .padding(AOMSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.value, item.unit, item.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(navigates ? .isButton : [])
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
