import AppKit
import SwiftUI

// 7.8 (Codex spec ME-01…03): the editor for AOM's menu bar icon. One editor,
// three ways in — the icon's menu › Edit Menu…, the panel's pencil, and
// Menu Bar › AOM menu. Left: commands to add; middle: the order; right: the
// selected row's name and a preview. Clicking the preview only selects;
// nothing runs until Apply, which saves the whole draft at once.

/// Pure edits of a menu draft (one level of groups), for tests.
enum AOMMenuDraftOps {
    typealias Entry = AOMStatusMenuLayout.Entry

    /// Where an entry is: its index at the top, and in a group if it's inside one.
    static func locate(_ id: UUID, in entries: [Entry]) -> (top: Int, child: Int?)? {
        for (top, entry) in entries.enumerated() {
            if entry.id == id { return (top, nil) }
            if let child = entry.children?.firstIndex(where: { $0.id == id }) { return (top, child) }
        }
        return nil
    }

    /// Adds after the selection — inside its group when the selection is a
    /// group or in one — or at the end.
    static func insert(_ new: Entry, after selection: UUID?, in entries: [Entry]) -> [Entry] {
        var entries = entries
        guard let selection, let place = locate(selection, in: entries) else { entries.append(new); return entries }
        if new.kind != .group, let child = place.child {
            entries[place.top].children?.insert(new, at: child + 1)
        } else if new.kind != .group, entries[place.top].kind == .group {
            entries[place.top].children = (entries[place.top].children ?? []) + [new]
        } else {
            entries.insert(new, at: place.top + 1)
        }
        return entries
    }

    static func remove(_ id: UUID, from entries: [Entry]) -> [Entry] {
        var entries = entries
        guard let place = locate(id, in: entries) else { return entries }
        if let child = place.child { entries[place.top].children?.remove(at: child) } else { entries.remove(at: place.top) }
        return entries
    }

    /// Moves within its own list (the top level or its group) by `offset`.
    static func move(_ id: UUID, by offset: Int, in entries: [Entry]) -> [Entry] {
        var entries = entries
        guard let place = locate(id, in: entries) else { return entries }
        if let child = place.child, var children = entries[place.top].children {
            let target = child + offset
            guard children.indices.contains(target) else { return entries }
            children.swapAt(child, target)
            entries[place.top].children = children
        } else {
            let target = place.top + offset
            guard entries.indices.contains(target) else { return entries }
            entries.swapAt(place.top, target)
        }
        return entries
    }

    /// Into a group (at its end), or out to the top level after its group (nil).
    static func regroup(_ id: UUID, into group: UUID?, in entries: [Entry]) -> [Entry] {
        guard let place = locate(id, in: entries) else { return entries }
        let entry = place.child.map { entries[place.top].children![$0] } ?? entries[place.top]
        guard entry.kind != .group else { return entries }
        var out = remove(id, from: entries)
        if let group, let index = out.firstIndex(where: { $0.id == group && $0.kind == .group }) {
            out[index].children = (out[index].children ?? []) + [entry]
        } else {
            let after = place.child != nil ? place.top + 1 : out.count
            out.insert(entry, at: min(after, out.count))
        }
        return out
    }

    static func rename(_ id: UUID, to title: String, in entries: [Entry]) -> [Entry] {
        var entries = entries
        guard let place = locate(id, in: entries) else { return entries }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let child = place.child { entries[place.top].children?[child].title = value.isEmpty ? nil : value }
        else { entries[place.top].title = value.isEmpty ? nil : value }
        return entries
    }
}

/// Opens the editor in a window of its own (from the icon's menu or panel).
@MainActor
enum AOMMenuEditorNavigation {
    private static var window: NSWindow?

    static func open() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: AOMMenuEditorView(inWindow: true)
            .padding(16)
            .frame(minWidth: 900, minHeight: 560))
        let window = NSWindow(contentViewController: host)
        window.title = "Edit AOM Menu"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Menu Bar › AOM menu.
struct AOMMenuEditorSection: View {
    var body: some View {
        AOMSection("AOM menu", detail: "Click panel and right-click menu, in your order", padding: 14) {
            AOMMenuEditorView(inWindow: false)
        }
    }
}

struct AOMMenuEditorView: View {
    var inWindow: Bool
    @ObservedObject private var store = AOMStatusMenuStore.shared
    @ObservedObject private var aliases = AOMMenuBarAliasStore.shared
    @ObservedObject private var workspace = AOMWorkspaceLayout.shared

    enum Target: String, CaseIterable, Identifiable {
        case menu, panel
        var id: String { rawValue }
        var title: String { self == .menu ? "Right-click menu" : "Click panel" }
    }

    @State private var target: Target = .menu
    @State private var draft = AOMStatusMenuLayout()
    @State private var baseRevision = -1
    @State private var selection: UUID?
    @State private var panelSelection: String?
    @State private var search = ""
    @State private var message: String?
    /// The first menu (ME-03), made once per load so its rows keep their ids.
    @State private var starter: [AOMStatusMenuLayout.Entry] = []

    /// Read once per load (and when a menu bar item is renamed), not per row.
    @State private var catalog: [AOMMenuCommand] = []
    @State private var index: [String: AOMMenuCommand] = [:]

    private var menuEntries: [AOMStatusMenuLayout.Entry] {
        draft.menu ?? starter
    }

    private var followsWorkspace: Bool { draft.panel == nil }

    private var panelIDs: [String] {
        draft.panel ?? workspace.visibleQuickActions.map(\.layoutID)
    }

    /// What Apply would save differs from what is saved.
    private var isDirty: Bool {
        guard baseRevision >= 0 else { return false }
        var saved = store.layout
        saved.revision = 0
        var mine = draft
        mine.revision = 0
        return saved != mine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Edit", selection: $target) {
                    ForEach(Target.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if store.layout.revision != baseRevision, baseRevision >= 0 {
                    Label("Changed in another editor", systemImage: "exclamationmark.triangle")
                        .font(AOMFont.caption).foregroundStyle(AOMColor.warningText)
                    Button("Reload") { load() }.controlSize(.small)
                }
            }
            Text(target == .menu
                 ? "Right-click or ⌥-click AOM's icon. All Commands, Edit Menu… and Quit always follow your items."
                 : "Click AOM's icon. The first row of quick commands shows; the rest are under More.")
                .font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
            HStack(alignment: .top, spacing: 14) {
                commandList
                    .frame(width: 230)
                Group {
                    if target == .menu { menuOrder } else { panelOrder }
                }
                .frame(minWidth: 260, maxWidth: .infinity)
                inspector
                    .frame(width: 230)
            }
            // In the page (itself a scroll view) the columns get a height of
            // their own and scroll inside it; the window lets them grow.
            .frame(minHeight: 330, idealHeight: 420, maxHeight: inWindow ? .infinity : 420)
            footer
        }
        .onAppear { if baseRevision < 0 { load() } }
        .onReceive(aliases.$aliases) { _ in loadCatalog() }
    }

    // MARK: Columns

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
            TextField("Search commands", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
                    let shown = catalog.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.category.lowercased().contains(q) }
                    let categories = shown.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    ForEach(categories, id: \.self) { category in
                        Text(category).font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).padding(.top, 6)
                        ForEach(shown.filter { $0.category == category }) { command in
                            HStack(spacing: 8) {
                                Image(systemName: command.symbol).frame(width: 18).foregroundStyle(AOMColor.textSecondary)
                                Text(command.title).lineLimit(1)
                                Spacer(minLength: 4)
                                Button { add(command) } label: { Image(systemName: "plus.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .disabled(target == .panel && (followsWorkspace || panelIDs.contains(command.id)))
                                    .help(target == .panel && followsWorkspace ? "Turn off Follow Workspace to choose" : "Add")
                                    .accessibilityLabel("Add \(command.title)")
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { add(command) }
                        }
                    }
                    if aliases.aliases.isEmpty {
                        Text("Name a menu bar item in Menu bar items above to add it here.")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(AOMColor.sunken.opacity(0.5), in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
        }
    }

    private var menuOrder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your menu, in order").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(menuEntries) { entry in
                        orderRow(entry, indent: false)
                        if entry.kind == .group {
                            ForEach(entry.children ?? []) { child in orderRow(child, indent: true) }
                        }
                    }
                    if menuEntries.isEmpty {
                        Text("Empty: only All Commands, Edit Menu… and Quit will show.")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).padding(8)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: .infinity)
            .background(AOMColor.sunken.opacity(0.5), in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            HStack(spacing: 6) {
                Button { edit { AOMMenuDraftOps.insert(.group("New Group"), after: selection, in: $0) }
                         selection = menuEntries.last(where: { $0.kind == .group })?.id } label: { Label("Group", systemImage: "folder.badge.plus") }
                Button { edit { AOMMenuDraftOps.insert(.separator, after: selection, in: $0) } } label: { Label("Separator", systemImage: "minus") }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(selection == nil).help("Move up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(selection == nil).help("Move down")
                Button(role: .destructive) { removeSelected() } label: { Image(systemName: "trash") }
                    .disabled(selection == nil).help("Remove")
            }
            .controlSize(.small)
        }
    }

    private func orderRow(_ entry: AOMStatusMenuLayout.Entry, indent: Bool) -> some View {
        let selected = selection == entry.id
        return HStack(spacing: 8) {
            switch entry.kind {
            case .separator:
                Rectangle().fill(AOMColor.hairline).frame(height: 1).frame(maxWidth: .infinity)
                Text("Separator").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
            case .group:
                Image(systemName: "folder").frame(width: 18)
                Text(entry.title ?? "Group").fontWeight(.medium)
                Text("\(entry.children?.count ?? 0)").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                Spacer()
            case .command:
                let command = entry.command.flatMap { index[$0] }
                Image(systemName: command?.symbol ?? "questionmark.circle").frame(width: 18)
                    .foregroundStyle(command == nil ? AOMColor.warningText : AOMColor.textSecondary)
                Text(entry.title ?? command?.title ?? "Missing command").lineLimit(1)
                    .foregroundStyle(command == nil ? AOMColor.textTertiary : AOMColor.text)
                if entry.title != nil, let command { Text(command.title).font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).lineLimit(1) }
                Spacer()
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .padding(.leading, indent ? 22 : 0)
        .background(selected ? AOMColor.accent.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
        .onTapGesture { selection = entry.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var panelOrder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Follow Workspace's quick actions", isOn: Binding(get: { followsWorkspace }, set: { on in
                draft.panel = on ? nil : workspace.visibleQuickActions.map(\.layoutID)
            }))
            HStack {
                Text("Per row")
                Picker("Per row", selection: Binding(get: { AOMStatusMenuLayout.clampedPerRow(draft.panelPerRow) },
                                                      set: { draft.panelPerRow = $0 })) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(panelIDs.enumerated()), id: \.element) { offset, id in
                        let command = index[id]
                        HStack(spacing: 8) {
                            Image(systemName: command?.symbol ?? "questionmark.circle").frame(width: 18).foregroundStyle(AOMColor.textSecondary)
                            Text(command?.title ?? id).lineLimit(1)
                            Spacer()
                            Text(offset < AOMStatusMenuLayout.clampedPerRow(draft.panelPerRow) ? "Row" : "More")
                                .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .background(panelSelection == id ? AOMColor.accent.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
                        .onTapGesture { panelSelection = id }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: .infinity)
            .background(AOMColor.sunken.opacity(0.5), in: RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AOMRadius.control, style: .continuous))
            .opacity(followsWorkspace ? 0.6 : 1)
            HStack(spacing: 6) {
                Spacer()
                Button { movePanel(-1) } label: { Image(systemName: "arrow.up") }.help("Move up")
                Button { movePanel(1) } label: { Image(systemName: "arrow.down") }.help("Move down")
                Button(role: .destructive) {
                    if let id = panelSelection { draft.panel?.removeAll { $0 == id }; panelSelection = nil }
                } label: { Image(systemName: "trash") }.help("Remove")
            }
            .controlSize(.small)
            .disabled(followsWorkspace || panelSelection == nil)
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(target == .menu ? "Selected" : "Preview").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
            if target == .menu {
                if let id = selection, let place = AOMMenuDraftOps.locate(id, in: menuEntries) {
                    let entry = place.child.map { menuEntries[place.top].children![$0] } ?? menuEntries[place.top]
                    if entry.kind == .separator {
                        Text("A line between items").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                    } else {
                        TextField(entry.kind == .group ? "Group name" : (entry.command.flatMap { index[$0]?.title } ?? "Name"),
                                  text: Binding(get: { entry.title ?? "" },
                                                set: { value in edit { AOMMenuDraftOps.rename(id, to: value, in: $0) } }))
                            .textFieldStyle(.roundedBorder)
                        if entry.kind == .command {
                            let groups = menuEntries.filter { $0.kind == .group }
                            Picker("In group", selection: Binding(get: { place.child == nil ? nil : menuEntries[place.top].id },
                                                                  set: { group in edit { AOMMenuDraftOps.regroup(id, into: group, in: $0) } })) {
                                Text("None").tag(UUID?.none)
                                ForEach(groups) { group in Text(group.title ?? "Group").tag(UUID?.some(group.id)) }
                            }
                            .disabled(groups.isEmpty)
                        }
                    }
                } else {
                    Text("Select a row to rename it or put it in a group.").font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().padding(.vertical, 4)
                Text("Preview").font(AOMFont.caption.weight(.semibold)).foregroundStyle(AOMColor.textSecondary)
                menuPreview
            } else {
                panelPreview
            }
            Spacer(minLength: 0)
        }
    }

    /// The menu as it will be drawn; a click selects the row it came from.
    private var menuPreview: some View {
        let shown = AOMStatusMenuLayout.normalized(menuEntries, known: Set(index.keys))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { entry in
                switch entry.kind {
                case .separator: Divider().padding(.vertical, 3)
                case .group:
                    previewLine(entry.title ?? "Group", symbol: "folder", trailing: "chevron.right").onTapGesture { selection = entry.id }
                case .command:
                    let command = entry.command.flatMap { index[$0] }
                    previewLine(entry.title ?? command?.title ?? "", symbol: command?.symbol ?? "circle", trailing: nil)
                        .onTapGesture { selection = entry.id }
                }
            }
            if !shown.isEmpty { Divider().padding(.vertical, 3) }
            previewLine("All Commands", symbol: "ellipsis.circle", trailing: "chevron.right").opacity(0.6)
            previewLine("Edit Menu…", symbol: "slider.horizontal.below.rectangle", trailing: nil).opacity(0.6)
            Divider().padding(.vertical, 3)
            previewLine("Quit All of MacOS", symbol: "power", trailing: nil).opacity(0.6)
        }
        .padding(6)
        .background(AOMColor.overlaySurface, in: RoundedRectangle(cornerRadius: AOMRadius.control + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOMRadius.control + 2, style: .continuous).strokeBorder(AOMColor.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu preview")
    }

    private func previewLine(_ title: String, symbol: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 16)
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            if let trailing { Image(systemName: trailing).font(.system(size: 9, weight: .semibold)).foregroundStyle(AOMColor.textTertiary) }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var panelPreview: some View {
        let perRow = AOMStatusMenuLayout.clampedPerRow(draft.panelPerRow)
        let commands = panelIDs.compactMap { index[$0] }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(commands.prefix(perRow)) { command in
                    VStack(spacing: 4) {
                        Image(systemName: command.symbol).font(.system(size: 14, weight: .medium))
                        Text(command.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            if commands.count > perRow {
                Text("More: " + commands.dropFirst(perRow).map(\.title).joined(separator: ", "))
                    .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(3)
            }
        }
        .padding(8)
        .background(AOMColor.overlaySurface, in: RoundedRectangle(cornerRadius: AOMRadius.card, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Button("Restore Default") {
                store.restoreDefaults()
                load()
                message = "Back to the standard menu and Workspace's quick actions."
            }
            if let message { Text(message).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1) }
            Spacer()
            if isDirty { Text("Not applied").font(AOMFont.caption).foregroundStyle(AOMColor.warningText) }
            Button("Cancel") { load(); message = nil }.disabled(!isDirty)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty && draft.menu != nil)
        }
    }

    // MARK: Edits

    private func loadCatalog() {
        catalog = AOMMenuCommandCatalog.all()
        index = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func load() {
        loadCatalog()
        draft = store.layout
        starter = AOMStatusMenuLayout.starter(quickActions: workspace.visibleQuickActions)
        baseRevision = store.layout.revision
        selection = nil
        panelSelection = nil
    }

    private func edit(_ change: ([AOMStatusMenuLayout.Entry]) -> [AOMStatusMenuLayout.Entry]) {
        draft.menu = change(menuEntries)
    }

    private func add(_ command: AOMMenuCommand) {
        if target == .menu {
            let entry = AOMStatusMenuLayout.Entry.command(command.id)
            edit { AOMMenuDraftOps.insert(entry, after: selection, in: $0) }
            selection = entry.id
        } else if !followsWorkspace, !(draft.panel ?? []).contains(command.id) {
            draft.panel = (draft.panel ?? []) + [command.id]
            panelSelection = command.id
        }
    }

    private func move(_ offset: Int) {
        guard let id = selection else { return }
        edit { AOMMenuDraftOps.move(id, by: offset, in: $0) }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        edit { AOMMenuDraftOps.remove(id, from: $0) }
        selection = nil
    }

    private func movePanel(_ offset: Int) {
        guard let id = panelSelection, var list = draft.panel, let at = list.firstIndex(of: id) else { return }
        let to = at + offset
        guard list.indices.contains(to) else { return }
        list.swapAt(at, to)
        draft.panel = list
    }

    private func apply() {
        var next = draft
        if next.menu == nil { next.menu = menuEntries }
        switch store.save(next, basedOn: baseRevision) {
        case .saved:
            load()
            message = "Applied. Right-click AOM's icon to see it."
        case .conflict:
            message = "Another editor applied changes first — Reload, then edit again."
        case .failed:
            message = "Couldn't save; the previous menu stays."
        }
    }
}
