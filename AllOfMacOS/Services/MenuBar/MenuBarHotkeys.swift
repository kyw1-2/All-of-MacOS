import AppKit
import ApplicationServices

// AOM 7.10 — Bartender's Hotkeys pane (HotKeysPreferences.nib): keys to show
// hidden items, show all, Quick Search, navigate with the keyboard, and a
// key per menu bar item with how it is clicked ("Left Click", "Right Click",
// "Left Click with Option key", "Right Click with Option key", "None - just
// show"). They are AOM's Carbon launcher hot keys (PaletteHotkeyStore): no
// extra permission, refused with the owner's name when a key is taken.

enum MenuBarHotkeys {
    static let prefix = "menubar.hotkey."

    /// The four keys of the pane's top half.
    enum Action: String, CaseIterable, Identifiable {
        case toggle, showAll, search, navigate
        var id: String { rawValue }
        var itemID: String { MenuBarHotkeys.prefix + rawValue }
        var title: String {
            switch self {
            case .toggle: return "Show hidden menu bar items"
            case .showAll: return "Show all menu bar items"
            case .search: return "Quick Search menu bar items"
            case .navigate: return "Keyboard navigate"
            }
        }
        var detail: String {
            switch self {
            case .toggle: return "Like clicking ❮"
            case .showAll: return "Always Hidden too"
            case .search: return "Type a name, ↩ opens it"
            case .navigate: return "The Bar with ← → and ↩"
            }
        }
        var symbol: String {
            switch self {
            case .toggle: return "chevron.left"
            case .showAll: return "chevron.left.2"
            case .search: return "magnifyingglass"
            case .navigate: return "keyboard"
            }
        }
    }

    /// How an item's hot key clicks it.
    enum Activation: String, CaseIterable, Identifiable, Codable {
        case leftClick, rightClick, optionLeftClick, optionRightClick, justShow
        var id: String { rawValue }
        var title: String {
            switch self {
            case .leftClick: return "Left Click"
            case .rightClick: return "Right Click"
            case .optionLeftClick: return "Left Click with Option key"
            case .optionRightClick: return "Right Click with Option key"
            case .justShow: return "None - just show"
            }
        }
    }

    /// Pure: an item key's id holds how it clicks and which item.
    static func itemID(_ key: String, activation: Activation) -> String {
        prefix + "item." + activation.rawValue + "." + key
    }

    static func parseItem(_ id: String) -> (activation: Activation, key: String)? {
        let head = prefix + "item."
        guard id.hasPrefix(head) else { return nil }
        let rest = id.dropFirst(head.count)
        guard let dot = rest.firstIndex(of: "."), let activation = Activation(rawValue: String(rest[..<dot])) else { return nil }
        let key = String(rest[rest.index(after: dot)...])
        return key.isEmpty ? nil : (activation, key)
    }

    // MARK: Firing

    @MainActor
    static func fire(_ binding: PaletteHotkey) {
        let hider = MenuBarHider.shared
        if let item = parseItem(binding.itemID) { activate(key: item.key, activation: item.activation, title: binding.title); return }
        switch Action(rawValue: String(binding.itemID.dropFirst(prefix.count))) {
        case .toggle:
            guard hider.isRunning else { GestureHUD.shared.show(title: "Menu Bar", detail: "Turn on Hide icons in Menu Bar › General."); return }
            hider.toggleFromTrigger()
        case .showAll:
            if hider.isCollapsed { hider.revealFromTrigger(includeAlways: true) } else { hider.expand(all: true) }
        case .search:
            AOMMenuShelfController.shared.show()
        case .navigate:
            MenuBarStripController.shared.show(includeAlways: false)
        case nil:
            break
        }
    }

    /// Shows the item if it is hidden, then clicks it the chosen way.
    @MainActor
    static func activate(key: String, activation: Activation, title: String) {
        let model = MenuBarLayoutModel.shared
        guard let entry = model.items.first(where: { $0.item.stableKey == key || $0.imageKey == key }) else {
            // Not read yet this session: read the menu bar, then try once more.
            if !model.busy { model.refresh(quietly: true, reveal: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let again = MenuBarLayoutModel.shared.items.first(where: { $0.item.stableKey == key || $0.imageKey == key }) else {
                    GestureHUD.shared.show(title: title, detail: "Isn't in the menu bar right now.")
                    return
                }
                perform(again, activation: activation)
            }
            return
        }
        perform(entry, activation: activation)
    }

    @MainActor
    private static func perform(_ entry: MenuBarLayoutItem, activation: Activation) {
        MenuBarHider.shared.reveal(entry.item, section: entry.section) {
            switch activation {
            case .justShow: break
            case .leftClick: AOMMenuShelfController.shared.activate(entry.item, retry: "Press the key again.")
            default: MenuBarClick.post(entry.item, activation: activation)
            }
        }
    }
}

/// A real click on an item where it is now (right click, ⌥-click): its
/// place is read again first, since showing it may have moved it.
enum MenuBarClick {
    @MainActor
    static func post(_ item: AOMMenuShelfItem, activation: MenuBarHotkeys.Activation) {
        let apps = AOMMenuShelfPolicy.orderedApps(NSWorkspace.shared.runningApplications.filter { $0.processIdentifier == item.pid })
        DispatchQueue.global(qos: .userInitiated).async {
            let live = AOMMenuShelfProbe.snapshot(apps: apps, deadline: 1.0).items.filter { $0.pid == item.pid }
            let fresh = item.stableKey.flatMap { key in live.first { $0.stableKey == key } }
                ?? live.first { $0.ordinal == item.ordinal && $0.siblings == item.siblings }
            guard let frame = fresh?.frame ?? item.frame, frame.width > 0 else { return }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let right = activation == .rightClick || activation == .optionRightClick
            let option = activation == .optionLeftClick || activation == .optionRightClick
            let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
            let button: CGMouseButton = right ? .right : .left
            let original = CGEvent(source: nil)?.location
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                if option { event?.flags = .maskAlternate }
                // Tagged, so AOM's own monitors (the menu bar triggers) ignore it.
                SyntheticInput.post(event, tap: .cghidEventTap)
                usleep(40_000)
            }
            if let original { CGWarpMouseCursorPosition(original) }
        }
    }
}
