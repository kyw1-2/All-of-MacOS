import AppKit
import Foundation

enum AOMAutomationLink: Equatable {
    case trigger(String), showMenu(String), editMenus, hideMenus
    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "aom",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        let items = parts.queryItems ?? []
        let host = parts.host?.lowercased()
        switch host {
        case "trigger", "trigger_named", "show-menu":
            guard items.count == 1, let item = items.first,
                  item.name == "name" || (host == "trigger_named" && item.name == "trigger_name"),
                  let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= 128 else { return nil }
            return host == "show-menu" ? .showMenu(value) : .trigger(value)
        case "edit-menus" where items.isEmpty: return .editMenus
        case "hide-menus" where items.isEmpty: return .hideMenus
        default: return nil
        }
    }
}

/// 7.6 (Codex SEC04): an aom://trigger link comes from another app or a web
/// page, so it runs a Named Trigger only with the user's say: Run Once,
/// Always Allow (remembered for that trigger, not its name), or Don't Run.
/// A trigger renamed to an allowed name isn't allowed; "Forget Link
/// Permissions" in the launcher makes every link ask again.
@MainActor
enum AOMLinkConsent {
    static let allowedKey = "AOMLinkAllowedTriggers.v1"

    enum Answer: Equatable { case once, always, no }

    static var allowed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: allowedKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: allowedKey) }
    }

    /// Pure: whether `id` may run without asking.
    static func mayRun(_ id: UUID, allowed: Set<String>) -> Bool { allowed.contains(id.uuidString) }

    /// Runs the Named Trigger a link names, asking first unless allowed.
    static func run(_ name: String, ask: (Trigger) -> Answer = askUser) {
        let candidates = ActionExecutor.namedTriggerCandidates(name)
        guard candidates.count == 1, let trigger = candidates.first else {
            GestureHUD.shared.show(title: candidates.isEmpty ? "No Named Trigger" : "Two Named Triggers Match",
                                   detail: candidates.isEmpty ? "A link asked for “\(name)”." : "Rename one of the triggers called “\(name)”.")
            return
        }
        if !mayRun(trigger.id, allowed: allowed) {
            switch ask(trigger) {
            case .no: return
            case .always: allowed.insert(trigger.id.uuidString)
            case .once: break
            }
        }
        ActionExecutor.executeNamedTrigger(name)
    }

    static func askUser(_ trigger: Trigger) -> Answer {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A link asks to run “\(trigger.name)”"
        alert.informativeText = "aom:// links can come from other apps and web pages. Run it only if you opened this link yourself. Always Allow is remembered for this automation; Forget Link Permissions in the launcher undoes it."
        alert.addButton(withTitle: "Run Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Don't Run")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .once
        case .alertSecondButtonReturn: return .always
        default: return .no
        }
    }

    static func forgetAll() {
        let count = allowed.count
        allowed = []
        GestureHUD.shared.show(title: "Link Permissions Forgotten",
                               detail: count == 0 ? "No automation was allowed from links." : "\(count) automation\(count == 1 ? "" : "s") will ask again when a link runs \(count == 1 ? "it" : "them").")
    }
}
