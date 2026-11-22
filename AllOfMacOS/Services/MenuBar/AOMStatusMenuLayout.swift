import AppKit
import Combine

// 7.8 (Codex spec ME-01…03, AC-01…03): AOM's own menu bar icon, arranged by
// the person. A click opens the panel (its quick commands: which, in what
// order, 1–4 a row); a right-click or ⌥-click opens the menu (commands,
// separators, one level of groups, menu bar items under names of their
// own). Edits are a draft until Apply; nothing runs while editing. The
// system part — Edit Menu…, All Commands (the full 7.7 menu) and Quit —
// is always there, so a menu emptied by mistake can be put back.

/// A command the panel and the menu can hold.
struct AOMMenuCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// The group the editor lists it under.
    let category: String
    /// A checkmark in the menu (a switch that is on now); nil: no state.
    var isOn: (@MainActor () -> Bool)? = nil
    let run: @MainActor () -> Void
}

@MainActor
enum AOMMenuCommandCatalog {
    static let menuItemPrefix = "item:"

    /// Every command, in the editor's order.
    static func all() -> [AOMMenuCommand] {
        var commands: [AOMMenuCommand] = WorkspaceQuickActionKind.allCases.map { kind in
            AOMMenuCommand(id: kind.layoutID, title: kind.title, symbol: kind.symbol, category: category(kind.module)) { kind.run() }
        }
        commands += [
            AOMMenuCommand(id: "aom.launcher", title: "Open Launcher", symbol: "magnifyingglass", category: "All of MacOS") {
                AOMLauncherController.shared.show()
            },
            AOMMenuCommand(id: "aom.window", title: "Open All of MacOS", symbol: "macwindow", category: "All of MacOS") {
                AppDelegate.current?.showMainWindow()
            },
            AOMMenuCommand(id: "aom.settings", title: "Settings…", symbol: "gearshape", category: "All of MacOS") {
                AppDelegate.current?.openSettingsWindow()
            },
            AOMMenuCommand(id: "aom.engine", title: "Automation", symbol: "bolt", category: "Automation",
                           isOn: { AppDelegate.current?.appState?.globalEnabled ?? true }) {
                AppDelegate.current?.appState?.toggleGlobalEnabled()
            },
            AOMMenuCommand(id: "aom.hud", title: "Gesture HUD", symbol: "rectangle.on.rectangle", category: "Automation",
                           isOn: { UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true }) {
                let on = UserDefaults.standard.object(forKey: "AOMHUDEnabled") as? Bool ?? true
                UserDefaults.standard.set(!on, forKey: "AOMHUDEnabled")
            },
            AOMMenuCommand(id: "aom.cheatSheet", title: "Show Cheat Sheet", symbol: "list.bullet.rectangle", category: "Automation") {
                GestureHUD.shared.toggleCheatSheet()
            },
            AOMMenuCommand(id: "clip.stack", title: "Paste Stack", symbol: "square.stack.3d.down.right", category: "Clipboard") {
                ClipboardPanelController.shared.showStack()
            },
            AOMMenuCommand(id: "clip.pause", title: "Clipboard History", symbol: "pause.circle", category: "Clipboard",
                           isOn: { !ClipboardStore.shared.paused }) {
                ClipboardStore.shared.paused.toggle()
            },
            AOMMenuCommand(id: "focus.awake", title: "Keep Awake", symbol: "cup.and.saucer", category: "Focus",
                           isOn: { KeepAwakeService.shared.isActive }) {
                let service = KeepAwakeService.shared
                if service.isActive { service.stop() } else { service.start(minutes: nil, keepDisplay: false) }
            },
            AOMMenuCommand(id: "win.snap", title: "Drag to Snap", symbol: "rectangle.split.2x2", category: "Windows",
                           isOn: { AppDelegate.current?.appState?.currentPreset.snappingEnabled ?? false }) {
                if let appState = AppDelegate.current?.appState { appState.setSnappingEnabled(!appState.currentPreset.snappingEnabled) }
            },
            AOMMenuCommand(id: "bar.shelf", title: "Menu Bar Shelf", symbol: "rectangle.topthird.inset.filled", category: "Menu Bar") {
                AOMMenuShelfController.shared.toggle()
            },
            AOMMenuCommand(id: "bar.strip", title: "Menu Bar Strip", symbol: "menubar.rectangle", category: "Menu Bar") {
                MenuBarStripController.shared.toggle()
            },
            AOMMenuCommand(id: "bar.revealAll", title: "Show All Hidden Icons", symbol: "chevron.left.2", category: "Menu Bar") {
                MenuBarHider.shared.expand(all: true)
            },
        ]
        if #available(macOS 14.2, *) {
            commands += [
                AOMMenuCommand(id: "audio.engine", title: "App Audio Engine", symbol: "speaker.wave.2", category: "Audio",
                               isOn: { AppAudioEngine.shared.isEnabled }) {
                    AppAudioEngine.shared.isEnabled.toggle()
                },
                AOMMenuCommand(id: "audio.mixer", title: "App Audio Mixer…", symbol: "slider.horizontal.3", category: "Audio") {
                    AppAudioMixerService.shared.showPanel()
                },
            ]
        }
        // AC-01: saved Scenes, by their id.
        for scene in SceneStore.shared.scenes {
            commands.append(AOMMenuCommand(id: "scene:\(scene.id.uuidString)", title: scene.name, symbol: "sparkles.rectangle.stack",
                                           category: "Scenes") {
                if let current = SceneStore.shared.scenes.first(where: { $0.id == scene.id }) { SceneRunner.shared.run(current) }
            })
        }
        // MB-02: menu bar items people named, opened by their lasting key.
        for (key, alias) in AOMMenuBarAliasStore.shared.aliases.sorted(by: { $0.key < $1.key }) {
            let fallback = String(key.split(separator: "|").last ?? "Item").replacingOccurrences(of: "sys:", with: "")
                .replacingOccurrences(of: "ax:", with: "").replacingOccurrences(of: "desc:", with: "")
            commands.append(AOMMenuCommand(id: menuItemPrefix + key, title: alias.name ?? fallback, symbol: alias.symbol ?? "menubar.rectangle",
                                           category: "Menu bar items") {
                AOMMenuShelfController.shared.open(stableKey: key)
            })
        }
        return commands
    }

    static func category(_ module: AOMModule) -> String {
        switch module {
        case .capture: return "Capture"
        case .clipboard: return "Clipboard"
        case .files: return "Files"
        case .focus: return "Focus"
        case .audio: return "Audio"
        case .tiling: return "Windows"
        default: return "All of MacOS"
        }
    }

    static func index() -> [String: AOMMenuCommand] {
        Dictionary(all().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The arrangement, saved as JSON (AC-03: version, revision, ids, names and
/// order; never a pid, a position or a live value).
struct AOMStatusMenuLayout: Codable, Equatable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case command, separator, group }
        var id = UUID()
        var kind: Kind
        var command: String?
        /// A name of the person's for a command, or a group's title.
        var title: String?
        /// A group's commands and separators (one level).
        var children: [Entry]?

        static func command(_ id: String, title: String? = nil) -> Entry { Entry(kind: .command, command: id, title: title) }
        static var separator: Entry { Entry(kind: .separator) }
        static func group(_ title: String, _ children: [Entry] = []) -> Entry { Entry(kind: .group, title: title, children: children) }
    }

    var version = Self.currentVersion
    var revision = 0
    /// The right-click menu; nil until the person applies one (the 7.7 menu shows).
    var menu: [Entry]?
    /// The panel's quick commands; nil follows Workspace's quick actions.
    var panel: [String]?
    /// Quick commands in one row of the panel (1–4); the rest go under More.
    var panelPerRow = 3

    /// Pure (ME-02): what is drawn — no separator first, last or twice in a
    /// row, no empty group, nothing whose command no longer exists.
    static func normalized(_ entries: [Entry], known: Set<String>) -> [Entry] {
        var out: [Entry] = []
        for entry in entries {
            switch entry.kind {
            case .command:
                guard let id = entry.command, known.contains(id) else { continue }
                out.append(entry)
            case .separator:
                guard let last = out.last, last.kind != .separator else { continue }
                out.append(entry)
            case .group:
                var group = entry
                group.children = normalized((entry.children ?? []).filter { $0.kind != .group }, known: known)
                guard !(group.children ?? []).isEmpty else { continue }
                out.append(group)
            }
        }
        while out.last?.kind == .separator { out.removeLast() }
        return out
    }

    /// Pure: clamps a stored per-row count.
    static func clampedPerRow(_ value: Int) -> Int { min(4, max(1, value)) }

    /// ME-03: the first menu, from what the person already arranged —
    /// Workspace's quick actions in their order, then the switches the 7.7
    /// menu kept on top, then the window and Settings.
    @MainActor static func starter(quickActions: [WorkspaceQuickActionKind]) -> [Entry] {
        var entries: [Entry] = quickActions.map { .command($0.layoutID) }
        entries.append(.separator)
        entries += ["focus.awake", "aom.engine"].map { .command($0) }
        if #available(macOS 14.2, *) { entries.insert(.command("audio.engine"), at: entries.count - 1) }
        entries.append(.separator)
        entries += ["aom.window", "aom.settings"].map { .command($0) }
        return entries
    }
}

@MainActor
final class AOMStatusMenuStore: ObservableObject {
    static let shared = AOMStatusMenuStore()
    nonisolated static let key = "AOMStatusMenuLayout"

    @Published private(set) var layout: AOMStatusMenuLayout
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AOMStatusMenuLayout.self, from: data),
           decoded.version <= AOMStatusMenuLayout.currentVersion {
            layout = decoded
        } else {
            layout = AOMStatusMenuLayout()
        }
    }

    enum SaveResult: Equatable { case saved, conflict, failed }

    /// Saves a whole draft at once (ME-02). A draft started from an older
    /// revision is refused, so two open editors can't overwrite each other.
    @discardableResult
    func save(_ draft: AOMStatusMenuLayout, basedOn revision: Int) -> SaveResult {
        guard revision == layout.revision else { return .conflict }
        var next = draft
        next.version = AOMStatusMenuLayout.currentVersion
        next.revision = layout.revision + 1
        next.panelPerRow = AOMStatusMenuLayout.clampedPerRow(next.panelPerRow)
        guard let data = try? JSONEncoder().encode(next) else { return .failed }
        defaults.set(data, forKey: Self.key)
        layout = next
        return .saved
    }

    /// Back to the 7.7 menu and Workspace's quick actions.
    func restoreDefaults() {
        var next = AOMStatusMenuLayout()
        next.revision = layout.revision + 1
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        layout = next
    }

    /// The panel's quick commands now (AC-02).
    func panelCommands() -> [AOMMenuCommand] {
        let index = AOMMenuCommandCatalog.index()
        if let ids = layout.panel {
            return ids.compactMap { index[$0] }
        }
        return AOMWorkspaceLayout.shared.visibleQuickActions.compactMap { index[$0.layoutID] }
    }
}

/// Turns entries into menu items. A command item runs its closure through
/// this target, after the menu has closed.
@MainActor
final class AOMMenuCommandTarget: NSObject {
    static let shared = AOMMenuCommandTarget()

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let run = sender.representedObject as? AOMMenuRunBox else { return }
        DispatchQueue.main.async { run.run() }
    }

    func items(for entries: [AOMStatusMenuLayout.Entry], index: [String: AOMMenuCommand]) -> [NSMenuItem] {
        let known = Set(index.keys)
        return AOMStatusMenuLayout.normalized(entries, known: known).compactMap { entry in
            switch entry.kind {
            case .separator:
                return .separator()
            case .command:
                guard let id = entry.command, let command = index[id] else { return nil }
                return item(command, title: entry.title)
            case .group:
                let group = NSMenuItem(title: entry.title ?? "Group", action: nil, keyEquivalent: "")
                group.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu(title: entry.title ?? "Group")
                for child in items(for: entry.children ?? [], index: index) { submenu.addItem(child) }
                group.submenu = submenu
                return group
            }
        }
    }

    func item(_ command: AOMMenuCommand, title: String? = nil) -> NSMenuItem {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? command.title
        let item = NSMenuItem(title: name, action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
        item.representedObject = AOMMenuRunBox(command.run)
        if let isOn = command.isOn { item.state = isOn() ? NSControl.StateValue.on : NSControl.StateValue.off }
        return item
    }
}

final class AOMMenuRunBox: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}
