import AppKit
import SwiftUI

// AOM 6.0 note: the bar is now *contextual* (both 5.0 reviews: "a page sign,
// not a context tool"). A page publishes what is selected and what can be
// done to it with `aomBarContext`; the bar shows that title and its actions
// as buttons with their shortcuts, and keeps the page-wide Actions panel and
// Search on the right. Related-tool marks left the bar (they are in Actions).
//
// AOM 5.0 action bar, after Raycast's bottom bar ("A fresh look and feel",
// 2022): the left half says where you are — the page's identity mark, its
// name and what it is for — and the right half says what you can do now,
// each with its shortcut, so shortcuts are learned by being seen. It
// replaces 4.0's "Related tools" strip: related tools are still one click
// away, now as identity marks, beside an Actions panel (the page's quick
// actions, navigation and AOM-wide commands) and the way into ⌘K.

/// One row of the Actions panel.
struct AOMBarAction: Identifiable {
    let id: String
    let title: String
    let identity: AOMIdentity
    var shortcut: String?
    let run: @MainActor () -> Void
    /// A key the bar binds while this action is shown (contexts only).
    var key: SwiftUI.KeyboardShortcut? = nil

    /// The keys as text ("⌘↩"), from `key` when it is set.
    var keysText: String? {
        guard let key else { return shortcut }
        var text = ""
        if key.modifiers.contains(.control) { text += "⌃" }
        if key.modifiers.contains(.option) { text += "⌥" }
        if key.modifiers.contains(.shift) { text += "⇧" }
        if key.modifiers.contains(.command) { text += "⌘" }
        switch key.key {
        case .return: text += "↩"
        case .delete: text += "⌫"
        case .space: text += "Space"
        default: text += String(key.key.character).uppercased()
        }
        return text
    }
}

/// What a page says about its current selection: a title ("Trackpad: 4
/// Finger Tap") and what can be done to it, the first being the primary.
struct AOMBarContext {
    var title: String?
    var actions: [AOMBarAction] = []
}

/// Each live page's context, written by the page itself.
@MainActor
final class AOMBarContexts: ObservableObject {
    static let shared = AOMBarContexts()
    @Published private(set) var contexts: [AOMMainTab: AOMBarContext] = [:]
    /// Bumped on every write, so the bar re-renders though contexts hold closures.
    @Published private(set) var revision = 0

    func set(_ context: AOMBarContext?, for tab: AOMMainTab) {
        contexts[tab] = context
        revision &+= 1
    }
}

extension View {
    /// Publishes the page's selection context to the action bar whenever
    /// `id` changes (pass what the context depends on: the selected item's
    /// id and the states its actions show).
    func aomBarContext<ID: Equatable>(id: ID, _ make: @escaping () -> AOMBarContext?) -> some View {
        modifier(AOMBarContextWriter(id: id, make: make))
    }
}

private struct AOMBarContextWriter<ID: Equatable>: ViewModifier {
    let id: ID
    let make: () -> AOMBarContext?
    @Environment(\.aomPageTab) private var tab

    func body(content: Content) -> some View {
        content
            .onAppear { publish() }
            .onChange(of: id) { _, _ in publish() }
            .onDisappear {
                guard let tab else { return }
                DispatchQueue.main.async { AOMBarContexts.shared.set(nil, for: tab) }
            }
    }

    private func publish() {
        guard let tab else { return }
        let context = make()
        DispatchQueue.main.async { AOMBarContexts.shared.set(context, for: tab) }
    }
}

/// A titled group of rows in the Actions panel.
struct AOMBarActionSection: Identifiable {
    let title: String
    let actions: [AOMBarAction]
    var id: String { title }
}

enum AOMActionBarModel {
    /// The quick actions that belong to a page, in their Workspace order.
    static func quickActions(for tab: AOMMainTab) -> [WorkspaceQuickActionKind] {
        WorkspaceQuickActionKind.allCases.filter { $0.module.tab == tab }
    }

    /// Tools in the same task family, in sidebar order.
    static func related(to tab: AOMMainTab) -> [AOMMainTab] {
        guard let group = AOMFeatureGroup.allCases.first(where: { $0.tabs.contains(tab) }) else {
            // Workspace: the first tool of every family.
            return AOMFeatureGroup.allCases.compactMap(\.tabs.first)
        }
        return group.tabs.filter { $0 != tab }
    }

    @MainActor
    static func sections(for tab: AOMMainTab, appState: AppState, paletteKeys: String,
                         openPalette: @escaping () -> Void,
                         openSettings: @escaping () -> Void) -> [AOMBarActionSection] {
        var sections: [AOMBarActionSection] = []
        let quick = quickActions(for: tab).map { kind in
            AOMBarAction(id: kind.layoutID, title: kind.title,
                         identity: AOMIdentity(symbol: kind.symbol, color: kind.module.hue),
                         shortcut: kind.shortcut, run: { kind.run() })
        }
        if !quick.isEmpty { sections.append(AOMBarActionSection(title: "Run", actions: quick)) }
        let go = related(to: tab).map { other in
            AOMBarAction(id: "go." + other.rawValue, title: "Open \(other.title)", identity: other.identity,
                         shortcut: other.shortcutKey.map { "⌘\($0.character)" },
                         run: { appState.selectedMainTab = other })
        }
        if !go.isEmpty { sections.append(AOMBarActionSection(title: "Go to", actions: go)) }
        let engineOn = appState.globalEnabled
        sections.append(AOMBarActionSection(title: "All of MacOS", actions: [
            AOMBarAction(id: "aom.search", title: "Search Everything", identity: .neutral("magnifyingglass"),
                         shortcut: paletteKeys, run: openPalette),
            AOMBarAction(id: "aom.pause", title: engineOn ? "Pause AOM" : "Resume AOM",
                         identity: engineOn ? .neutral("pause.fill") : AOMIdentity(symbol: "play.fill", color: AOMColor.success),
                         run: { appState.toggleGlobalEnabled() }),
            AOMBarAction(id: "aom.settings", title: "Settings", identity: .neutral("gearshape.fill"),
                         shortcut: "⌘,", run: openSettings)
        ]))
        return sections
    }
}

/// 7.15 (mock-up M03, Nova/Linear, HIG Toolbars): the page's Actions and
/// Search live in the window toolbar; this bar appears under the page only
/// while a selection offers actions (up to three, with their keys), so no
/// page repeats its own title, tagline, Actions and Search at the bottom.
struct AOMActionBar: View {
    let appState: AppState
    let paletteKeys: String
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var navigation = AOMNavigation.shared
    @ObservedObject private var contexts = AOMBarContexts.shared

    var body: some View {
        let tab = navigation.selected
        if let context = contexts.contexts[tab], !context.actions.isEmpty {
            HStack(spacing: AOMSpace.x2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AOMColor.accent)
                    .accessibilityHidden(true)
                Text(context.title ?? "Selection")
                    .font(AOMFont.callout.weight(.semibold))
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AOMSpace.x3)
                ForEach(Array(context.actions.prefix(3).enumerated()), id: \.element.id) { index, action in
                    AOMBarButton(title: action.title, keys: action.keysText, primary: index == 0,
                                 key: action.key, run: action.run)
                }
            }
            .padding(.horizontal, AOMSpace.x3)
            .frame(height: AOMSize.actionBarHeight)
            .background(.bar)
            .overlay(alignment: .top) { AOMDivider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(context.title ?? tab.title) actions")
        }
    }
}

/// 7.15: Search and Actions in the toolbar — the same command palette and
/// the same action panel the bottom bar used to open, reachable with the
/// sidebar hidden.
struct AOMToolbarActions: View {
    let appState: AppState
    let paletteKeys: String
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var navigation = AOMNavigation.shared
    @ObservedObject private var contexts = AOMBarContexts.shared
    @Environment(\.openSettings) private var openSettings
    @State private var showsActions = false

    var body: some View {
        let tab = navigation.selected
        let context = contexts.contexts[tab]
        HStack(spacing: AOMSpace.x1) {
            Button { showsActions.toggle() } label: { Label("Actions", systemImage: "ellipsis.circle") }
                .help("Every action for \(tab.title)")
                .popover(isPresented: $showsActions, arrowEdge: .bottom) {
                    AOMActionPanel(title: context?.title ?? tab.title,
                                   sections: panelSections(tab: tab, context: context),
                                   dismiss: { showsActions = false })
                }
            Button { showingCommandPalette = true } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search all tools, settings and commands (\(paletteKeys))")
        }
        .onAppear {
            // Isolated previews can open the panel for review (`--aom-preview-actions`).
            if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-actions") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showsActions = true }
            }
        }
    }

    private func panelSections(tab: AOMMainTab, context: AOMBarContext?) -> [AOMBarActionSection] {
        var sections = AOMActionBarModel.sections(for: tab, appState: appState, paletteKeys: paletteKeys,
                                                  openPalette: { showingCommandPalette = true },
                                                  openSettings: { openSettings() })
        if let context, !context.actions.isEmpty {
            sections.insert(AOMBarActionSection(title: context.title ?? "Selection", actions: context.actions), at: 0)
        }
        return sections
    }
}

/// A button in the bar: a word and its keys, the primary one tinted.
private struct AOMBarButton: View {
    let title: String
    let keys: String?
    let primary: Bool
    var chevron = false
    var highlighted = false
    var key: SwiftUI.KeyboardShortcut? = nil
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                Text(title)
                    .font(AOMFont.callout.weight(primary ? .semibold : .medium))
                    .foregroundStyle(primary ? AOMColor.accent : (hovering || highlighted ? AOMColor.text : AOMColor.textSecondary))
                if chevron {
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AOMColor.textTertiary)
                }
                if let keys, !keys.isEmpty { AOMKeycap(text: keys) }
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: 24)
            .background(hovering || highlighted ? AOMColor.rowHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: AOMRadius.control + 1, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key)
        .onHover { hovering = $0 }
        .aomAnimation(.quick, value: hovering)
    }
}

/// The Actions popover: grouped rows with identity marks and shortcut
/// keycaps; ↑↓ move, ↩ runs, Esc closes (Raycast's Action Panel).
struct AOMActionPanel: View {
    let title: String
    let sections: [AOMBarActionSection]
    let dismiss: () -> Void
    @State private var selected = 0
    @State private var hovered: String?
    @FocusState private var focused: Bool

    private var flat: [AOMBarAction] { sections.flatMap(\.actions) }

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            Text("Actions for \(title)")
                .font(AOMFont.caption.weight(.semibold))
                .foregroundStyle(AOMColor.textSecondary)
                .padding(.horizontal, AOMSpace.x2)
                .padding(.top, AOMSpace.x1)
            ForEach(sections) { section in
                if section.id != sections.first?.id { Divider().padding(.vertical, AOMSpace.x1) }
                Text(section.title)
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textTertiary)
                    .padding(.horizontal, AOMSpace.x2)
                ForEach(section.actions) { action in
                    row(action, index: flat.firstIndex { $0.id == action.id } ?? 0)
                }
            }
        }
        .padding(AOMSpace.x2)
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selected = min(selected + 1, flat.count - 1); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.return) { run(flat[selected]); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ action: AOMBarAction, index: Int) -> some View {
        let isSelected = index == selected
        return Button { run(action) } label: {
            HStack(spacing: AOMSpace.x2) {
                AOMAppIcon(action.identity, size: AOMIcon.identityRow)
                Text(action.title)
                    .font(AOMFont.body)
                    .foregroundStyle(isSelected ? Color.white : AOMColor.text)
                    .lineLimit(1)
                Spacer(minLength: AOMSpace.x2)
                if let keys = action.keysText, !keys.isEmpty {
                    Text(keys)
                        .font(AOMFont.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : AOMColor.textSecondary)
                }
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: AOMSize.rowStandard - 4)
            .background(isSelected ? AOMColor.selection : (hovered == action.id ? AOMColor.rowHover : .clear),
                        in: RoundedRectangle(cornerRadius: AOMRadius.well, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? action.id : (hovered == action.id ? nil : hovered)
            if inside { selected = index }
        }
    }

    private func run(_ action: AOMBarAction) {
        dismiss()
        // After the popover closes, so a capture never includes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action.run() }
    }
}
