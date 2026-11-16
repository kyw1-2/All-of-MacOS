import AppKit
import SwiftUI

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

/// The bar under every page. Observes the selected page only.
struct AOMActionBar: View {
    let appState: AppState
    let paletteKeys: String
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var navigation = AOMNavigation.shared
    @Environment(\.openSettings) private var openSettings
    @State private var showsActions = false

    var body: some View {
        let tab = navigation.selected
        HStack(spacing: AOMSpace.x2) {
            AOMAppIcon(tab, size: AOMIcon.identityBar)
            Text(tab.title)
                .font(AOMFont.callout.weight(.semibold))
                .foregroundStyle(AOMColor.text)
                .lineLimit(1)
                .fixedSize()
            Text(tab.tagline)
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: AOMSpace.x3)
            // Related tools: marks only, names in the tooltip, so the bar
            // stays one quiet line at every width.
            HStack(spacing: AOMSpace.x1) {
                ForEach(AOMActionBarModel.related(to: tab)) { other in
                    Button { appState.selectedMainTab = other } label: {
                        AOMAppIcon(other, size: AOMIcon.identityBar)
                            .padding(AOMSpace.x0_5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(other.title) — \(other.tagline)")
                    .accessibilityLabel("Open \(other.title)")
                }
            }
            AOMDivider(axis: .vertical).frame(height: AOMSpace.x4)
            Button { showsActions.toggle() } label: {
                HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    Text("Actions").font(AOMFont.callout.weight(.medium))
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(showsActions ? AOMColor.text : AOMColor.textSecondary)
                .padding(.horizontal, AOMSpace.x2)
                .padding(.vertical, AOMSpace.x1)
                .background(showsActions ? AOMColor.rowPressed : Color.clear,
                            in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Actions for \(tab.title)")
            .popover(isPresented: $showsActions, arrowEdge: .top) {
                AOMActionPanel(title: tab.title,
                               sections: AOMActionBarModel.sections(
                                   for: tab, appState: appState, paletteKeys: paletteKeys,
                                   openPalette: { showingCommandPalette = true },
                                   openSettings: { openSettings() }),
                               dismiss: { showsActions = false })
            }
            Button { showingCommandPalette = true } label: {
                HStack(spacing: AOMSpace.x1 + AOMSpace.x0_5) {
                    Text("Search").font(AOMFont.callout.weight(.medium))
                    AOMKeycap(text: paletteKeys)
                }
                .foregroundStyle(AOMColor.textSecondary)
                .padding(.leading, AOMSpace.x2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search all tools, settings and commands")
        }
        .padding(.horizontal, AOMSpace.x3)
        .frame(height: AOMSize.actionBarHeight)
        .background(.bar)
        .overlay(alignment: .top) { AOMDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.title) actions")
        .onAppear {
            // Isolated previews can open the panel for review (`--aom-preview-actions`).
            if PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-actions") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showsActions = true }
            }
        }
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
                if let keys = action.shortcut, !keys.isEmpty {
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
