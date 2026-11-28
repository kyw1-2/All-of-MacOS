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
    /// Explicit role for new actions; legacy actions identify Delete by id.
    var role: ButtonRole? = nil

    var buttonRole: ButtonRole? {
        role ?? (id == "clip.delete" || id == "auto.delete" ? .destructive : nil)
    }

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

    /// 7.16 (GPT V04): which writer owns each page's context. A page torn
    /// down and rebuilt quickly (LRU eviction, reopen) must not have its new
    /// context cleared by the old writer's late `onDisappear`.
    private var owners: [AOMMainTab: UUID] = [:]

    func set(_ context: AOMBarContext?, for tab: AOMMainTab, writer: UUID? = nil) {
        if let writer { owners[tab] = writer }
        contexts[tab] = context
        revision &+= 1
    }

    /// Clears the page's context only if `writer` still owns it.
    func clear(_ tab: AOMMainTab, writer: UUID) {
        guard owners[tab] == writer else { return }
        owners[tab] = nil
        contexts[tab] = nil
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
    @State private var writer = UUID()

    func body(content: Content) -> some View {
        content
            .aomPageLifecycle(onActivate: { publish() }, onDeactivate: { clear() })
            .onChange(of: id) { _, _ in publish() }
    }

    private func publish() {
        guard let tab, AOMNavigation.shared.selected == tab else { return }
        let context = make()
        let writer = writer
        DispatchQueue.main.async {
            guard AOMNavigation.shared.selected == tab else { return }
            AOMBarContexts.shared.set(context, for: tab, writer: writer)
        }
    }

    private func clear() {
        guard let tab else { return }
        let writer = writer
        DispatchQueue.main.async { AOMBarContexts.shared.clear(tab, writer: writer) }
    }
}

/// A titled group of rows in the Actions panel.
struct AOMBarActionSection: Identifiable {
    let title: String
    let actions: [AOMBarAction]
    var id: String { title }
}

enum AOMActionBarModel {
    /// Preserve the relative order within each group.
    static func overflowActions(_ actions: [AOMBarAction]) -> [AOMBarAction] {
        let remaining = actions.dropFirst(3)
        return remaining.filter { $0.buttonRole != .destructive } + remaining.filter { $0.buttonRole == .destructive }
    }

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

/// The selected item's actions: three direct buttons with shortcuts, then More.
struct AOMActionBar: View {
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
                let revision = contexts.revision
                ForEach(Array(context.actions.prefix(3).enumerated()), id: \.element.id) { index, action in
                    AOMBarButton(title: action.title, keys: action.keysText,
                                 primary: index == 0 && action.buttonRole != .destructive,
                                 key: action.key, role: action.buttonRole) {
                        run(action, tab: tab, revision: revision)
                    }
                }
                let overflow = AOMActionBarModel.overflowActions(context.actions)
                if !overflow.isEmpty {
                    Menu {
                        ForEach(overflow) { action in
                            Button(action.title, role: action.buttonRole) {
                                run(action, tab: tab, revision: revision)
                            }
                            .keyboardShortcut(action.key)
                        }
                    } label: {
                        Label("More Actions", systemImage: "ellipsis").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuOrder(.fixed)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More Actions")
                    .accessibilityLabel("More Actions")
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

    private func run(_ action: AOMBarAction, tab: AOMMainTab, revision: Int) {
        guard navigation.selected == tab, contexts.revision == revision else { return }
        action.run()
    }
}

/// Keep the subscription here, so changing a row's selection doesn't rebuild
/// the shell. Omit the toolbar item itself when there's no selection context.
struct AOMSelectionToolbarItem: ToolbarContent {
    let appState: AppState
    let paletteKeys: String
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var navigation = AOMNavigation.shared
    @ObservedObject private var contexts = AOMBarContexts.shared

    var body: some ToolbarContent {
        if contexts.contexts[navigation.selected] != nil {
            ToolbarItem(placement: .automatic) {
                AOMToolbarActions(appState: appState, paletteKeys: paletteKeys,
                                  showingCommandPalette: $showingCommandPalette)
                    .id(navigation.selected)
            }
        }
    }
}

/// The selected item's action panel, reachable with the sidebar hidden.
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
        Button { showsActions.toggle() } label: { Label("Actions", systemImage: "ellipsis.circle") }
            .help("Every action for \(tab.title)")
            // Changing page closes the panel instead of showing another page's actions (V01/V04).
            .onChange(of: tab) { _, _ in showsActions = false }
            .popover(isPresented: $showsActions, arrowEdge: .bottom) {
                AOMActionPanel(title: context?.title ?? tab.title,
                               sections: panelSections(tab: tab, context: context),
                               dismiss: { showsActions = false },
                               canRun: { [revision = contexts.revision] action in
                                   guard navigation.selected == tab else { return false }
                                   if context?.actions.contains(where: { $0.id == action.id }) == true {
                                       return contexts.revision == revision
                                   }
                                   return panelSections(tab: tab, context: nil).flatMap(\.actions)
                                       .contains { $0.id == action.id && $0.title == action.title }
                               })
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
                                                  openPalette: { AOMLauncherController.shared.show() },
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
    var key: SwiftUI.KeyboardShortcut? = nil
    var role: ButtonRole? = nil
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: run) {
            HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                Text(title)
                    .font(AOMFont.callout.weight(primary ? .semibold : .medium))
                    .foregroundStyle(role == .destructive ? AOMColor.dangerText
                                     : primary ? AOMColor.accent : (hovering ? AOMColor.text : AOMColor.textSecondary))
                if let keys, !keys.isEmpty { AOMKeycap(text: keys) }
            }
            .padding(.horizontal, AOMSpace.x2)
            .frame(height: 24)
            .background(hovering ? AOMColor.rowHover : Color.clear,
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
    let canRun: @MainActor (AOMBarAction) -> Bool
    /// 7.16 (GPT V01): the selection is an action's id, not an index, so a
    /// list that shrinks while the panel is open can't run the wrong action
    /// or index past the end.
    @State private var selectedID: String?
    @State private var hovered: String?
    @FocusState private var focused: Bool

    /// The panel's actions in order, built once per render (V08: rows no
    /// longer search the whole list for their own index).
    private var flat: [AOMBarAction] { sections.flatMap(\.actions) }

    var body: some View {
        let actions = flat
        let current = AOMActionPanelSelection.resolve(selectedID, in: actions.map(\.id))
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            Text("Actions for \(title)")
                .font(AOMFont.caption.weight(.semibold))
                .foregroundStyle(AOMColor.textSecondary)
                .padding(.horizontal, AOMSpace.x2)
                .padding(.top, AOMSpace.x1)
            // V08: a long list scrolls inside a bounded panel, and the
            // keyboard selection is scrolled into view.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AOMSpace.x1) {
                        ForEach(sections) { section in
                            if section.id != sections.first?.id { Divider().padding(.vertical, AOMSpace.x1) }
                            Text(section.title)
                                .font(AOMFont.caption)
                                .foregroundStyle(AOMColor.textTertiary)
                                .padding(.horizontal, AOMSpace.x2)
                            ForEach(section.actions) { action in
                                row(action, isSelected: action.id == current).id(action.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .padding(AOMSpace.x2)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; selectedID = actions.first?.id }
        .onKeyPress(.downArrow) { step(1, in: actions, from: current); return .handled }
        .onKeyPress(.upArrow) { step(-1, in: actions, from: current); return .handled }
        .onKeyPress(.return) {
            // Resolved again at the moment of the key, by id.
            guard let id = AOMActionPanelSelection.resolve(selectedID, in: flat.map(\.id)),
                  let action = flat.first(where: { $0.id == id }) else { return .ignored }
            run(action)
            return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(title)")
    }

    private func step(_ offset: Int, in actions: [AOMBarAction], from current: String?) {
        selectedID = AOMActionPanelSelection.step(current, by: offset, in: actions.map(\.id))
    }

    private func row(_ action: AOMBarAction, isSelected: Bool) -> some View {
        Button { run(action) } label: {
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in
            hovered = inside ? action.id : (hovered == action.id ? nil : hovered)
        }
    }

    private func run(_ action: AOMBarAction) {
        dismiss()
        // After the popover closes, so a capture never includes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard canRun(action) else { return }
            action.run()
        }
    }
}

/// 7.16 (GPT V01): pure selection rules for the action panel.
enum AOMActionPanelSelection {
    /// A vanished explicit selection must never silently become another action.
    static func resolve(_ id: String?, in ids: [String]) -> String? {
        guard let id else { return ids.first }
        return ids.contains(id) ? id : nil
    }

    /// One step up or down, clamped at the ends.
    static func step(_ id: String?, by offset: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let index = resolve(id, in: ids).flatMap({ ids.firstIndex(of: $0) }) else { return ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}

