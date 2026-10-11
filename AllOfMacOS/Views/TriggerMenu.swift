import AppKit

/// The trigger list projected into the status menu, in the spirit of
/// BetterTouchTool's "Show Shortcuts in Context Menu".
///
/// The main window is the place to *edit* triggers; this is the place to
/// *recall* them. Opening the menu while an app is frontmost answers "what have
/// I bound here?" without switching windows, which is the question that comes
/// up while actually using the app.
///
/// The menu is rebuilt on every open, so the frontmost app and the current
/// enable state are read fresh each time.
@MainActor
enum TriggerMenu {

    /// How many triggers are listed before the list is cut off. A menu longer
    /// than this stops being readable, and the full list is one click away.
    private static let limit = 12

    /// Builds the trigger section, or nil when nothing is bound to the
    /// frontmost app and the section would be empty.
    static func build(from appState: AppState) -> NSMenuItem? {
        build(from: appState,
              frontBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              appName: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    /// The bundle is passed in rather than read from `NSWorkspace` so the
    /// selection can be exercised without depending on which app happens to be
    /// frontmost while the test runs.
    static func build(from appState: AppState,
                      frontBundleID: String?,
                      appName: String?) -> NSMenuItem? {
        let preset = appState.currentPreset

        // The frontmost app's own triggers, plus the global ones that also
        // apply there. Mirrors how TriggerResolver picks between the two.
        let appTriggers = frontBundleID.flatMap { bundle in
            preset.appTargets.first { $0.bundleID == bundle }
        }.map {
            preset.overviewTriggers(for: $0, groupID: nil, category: .all)
        } ?? []
        // A global target carries a nil bundleID, not an empty string.
        let globalTriggers = preset.appTargets.first { $0.isGlobal }.map {
            preset.overviewTriggers(for: $0, groupID: nil, category: .all)
        } ?? []

        let scoped = appTriggers + globalTriggers
        guard !scoped.isEmpty else { return nil }

        let title = appName ?? "Frontmost App"
        let section = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        // Grouped by input family so a trackpad binding and a keyboard binding
        // do not interleave, which is how the main window presents them too.
        let grouped = Dictionary(grouping: scoped) { $0.input.category }
        for category in TriggerCategory.inputCategories {
            guard let entries = grouped[category], !entries.isEmpty else { continue }
            if submenu.items.count > 0 { submenu.addItem(.separator()) }
            submenu.addItem(categoryHeader(category, count: entries.count))
            for trigger in entries.sorted(by: { $0.order < $1.order }).prefix(limit) {
                submenu.addItem(triggerItem(trigger, appState: appState))
            }
            if entries.count > limit {
                submenu.addItem(overflowItem(entries.count - limit))
            }
        }

        if appTriggers.isEmpty, !globalTriggers.isEmpty {
            // Say where these came from, so a global binding is not mistaken
            // for one this app defines.
            submenu.addItem(.separator())
            submenu.addItem(note("Global bindings — they apply in every app"))
        }

        section.submenu = submenu
        section.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        return section
    }

    // MARK: - Items

    private static func categoryHeader(_ category: TriggerCategory, count: Int) -> NSMenuItem {
        let item = NSMenuItem(title: category.rawValue, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: category.iconName, accessibilityDescription: nil)
        item.toolTip = "\(count) trigger\(count == 1 ? "" : "s")"
        return item
    }

    /// One binding. The title is the gesture; the action is what it runs.
    ///
    /// A disabled trigger is still listed but dimmed rather than hidden, so the
    /// menu shows what exists — hiding it would make an accidental disable look
    /// like a lost binding.
    private static func triggerItem(_ trigger: Trigger, appState: AppState) -> NSMenuItem {
        let summary = trigger.actions.first?.displayName ?? "No action"
        let more = trigger.actions.count > 1 ? " +\(trigger.actions.count - 1)" : ""
        let item = NSMenuItem(title: "\(trigger.displayName)  →  \(summary)\(more)",
                              action: #selector(TriggerMenuAction.toggleTrigger(_:)),
                              keyEquivalent: "")
        item.target = TriggerMenuAction.shared
        item.representedObject = TriggerRequest(triggerID: trigger.id, appState: appState)
        item.state = trigger.isEnabled ? .on : .off
        item.toolTip = trigger.actions.map(\.displayName).joined(separator: ", ")
        return item
    }

    private static func overflowItem(_ remaining: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "…and \(remaining) more", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// MARK: - Actions

/// Target for the trigger list. Toggling here is the quick "turn this off for a
/// moment" move; renaming and rewiring still happen in the main window.
@MainActor
final class TriggerMenuAction: NSObject {
    static let shared = TriggerMenuAction()

    @objc func toggleTrigger(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TriggerRequest,
              let appState = request.appState else { return }
        appState.setTriggerEnabled(!(sender.state == .on), triggerID: request.triggerID)
    }
}

/// The menu is rebuilt per open, so this is a value carrier rather than
/// retained state. `appState` is held weakly to avoid keeping it alive past the
/// menu that references it.
final class TriggerRequest: NSObject {
    let triggerID: UUID
    weak var appState: AppState?
    init(triggerID: UUID, appState: AppState) {
        self.triggerID = triggerID
        self.appState = appState
    }
}
