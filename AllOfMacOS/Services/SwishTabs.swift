import AppKit

// Swish-style tab gestures over a window's tab bar, and macOS's own window
// tiling as an alternative to AOM's snapping engine.
//
// Evidence (Swish 1.13.3 settings text and strings, treated as data):
// - "Control tabs in native macOS windows like Finder & Preview as well as Safari,
//   Chrome, Firefox, Arc, Dia, Brave, Orion, Xcode, Visual Studio Code & UPDF."
//   "Support for Edge, Figma & Craft is currently not possible due to them not
//   implementing the Accessibility API correctly." Firefox: "does not implement
//   the Accessibility API required to detect tabs."
// - "Pinch in to close a tab." Chromium's tabs carry a custom accessibility
//   action whose name reads "Name:close tab\nTarget:0x0\nSelector:(null)".
// - "Tap and hold to detach a native tab into a new window", "Only works in
//   native windows and Safari": both offer AppKit's "Move Tab to New Window".
// - Native tiling: "Apps need to properly expose a 'Window → Move & Resize' menu
//   for Swish to invoke native tiling. Otherwise, Swish will fall back to its own
//   snapping engine." "only offers up to a 2×2 grid." "Windows need to be
//   activated before snapping."
// This is AOM's own implementation of that behaviour, not Swish code.
//
// Every Accessibility request is bounded by an `AXDeadline` set on the element
// being asked (never the system-wide one): these run on main, and one busy app
// must not stall the trackpad frames queued behind them.

// MARK: - Localised menu titles

/// AppKit's localised standard menu titles.
enum AppKitMenuTitles {
    static let moveTabToNewWindow = "Move Tab to New Window"
    static let closeTab = "Close Tab"
    /// May be absent from AppKit's table; then only the English title matches.
    static let close = "Close"
    static let window = "Window"
    static let moveAndResize = "Move & Resize"
    static let fill = "Fill"
    static let left = "Left", right = "Right", top = "Top", bottom = "Bottom"
    static let topLeft = "Top Left", topRight = "Top Right", bottomLeft = "Bottom Left", bottomRight = "Bottom Right"

    /// Every key the title-bar snap looks up.
    static let keys: [String] = [
        moveTabToNewWindow, closeTab, close, window, moveAndResize, fill,
        left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight,
    ]

    /// Titles some apps use for the same command that AppKit's table lacks:
    /// Safari's Japanese menu says "タブを新規ウインドウに移動" where AppKit
    /// says "タブを新しいウインドウに移動".
    static let extra: [String: Set<String>] = [
        moveTabToNewWindow: ["タブを新規ウインドウに移動"],
    ]

    /// Pure: each key's titles in every language of a loctable dictionary
    /// (`{languageCode: {englishKey: localizedTitle}}`), plus the key itself
    /// and `extra`. "LocProvenance" is bookkeeping, not a language.
    static func parse(_ table: [String: Any], keys: [String]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for key in keys {
            result[key] = Set([key]).union(extra[key] ?? [])
        }
        for (language, value) in table where language != "LocProvenance" {
            guard let strings = value as? [String: String] else { continue }
            for key in keys {
                guard let title = strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { continue }
                result[key, default: [key]].insert(title)
            }
        }
        return result
    }

    /// AppKit's table, read once. A static let is initialised atomically.
    private static let loaded: [String: Set<String>] = {
        guard let url = Bundle(for: NSApplication.self).url(forResource: "MenuCommands", withExtension: "loctable"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let table = plist as? [String: Any] else { return parse([:], keys: keys) }
        return parse(table, keys: keys)
    }()

    /// The titles for `key` in every language AppKit ships, or just the key
    /// plus `extra` when the table cannot be read.
    static func titles(_ key: String) -> Set<String> {
        loaded[key] ?? Set([key]).union(extra[key] ?? [])
    }

    /// Pure: whether a menu title names `titles`, exactly after trimming
    /// whitespace and a trailing "…" or "..." (items that open a dialog carry
    /// one); case-insensitive.
    static func matches(_ title: String?, _ titles: Set<String>) -> Bool {
        guard let title else { return false }
        let wanted = normalized(title)
        guard !wanted.isEmpty else { return false }
        return titles.contains { normalized($0) == wanted }
    }

    private static func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("…") { text.removeLast() } else if text.hasSuffix("...") { text.removeLast(3) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Bounded Accessibility reads

/// Reads that each wait at most what the deadline allows.
private enum SwishTabAX {
    static func copy(_ element: AXUIElement, _ attribute: String, _ deadline: AXDeadline) -> CFTypeRef? {
        guard deadline.allow(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// Several attributes in one request. Missing ones come back as an AXValue
    /// of the error type or CFNull; both read as nil (none of the attributes
    /// asked for here is itself an AXValue).
    static func multiple(_ element: AXUIElement, _ attributes: [String], _ deadline: AXDeadline) -> [CFTypeRef?] {
        let empty = [CFTypeRef?](repeating: nil, count: attributes.count)
        guard deadline.allow(element) else { return empty }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == attributes.count else { return empty }
        return list.map { value -> CFTypeRef? in
            let type = CFGetTypeID(value)
            return type == AXValueGetTypeID() || type == CFNullGetTypeID() ? nil : value
        }
    }

    static func string(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    static func bool(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        guard type == CFBooleanGetTypeID() || type == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func int(_ value: CFTypeRef?) -> Int? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        guard type == CFBooleanGetTypeID() || type == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// At most `limit` children: a menu or tab bar is never larger, and a
    /// runaway list must not turn into hundreds of requests.
    static func children(_ element: AXUIElement, _ deadline: AXDeadline, limit: Int) -> [AXUIElement] {
        guard let value = copy(element, kAXChildrenAttribute, deadline),
              CFGetTypeID(value) == CFArrayGetTypeID(), let list = value as? [AnyObject] else { return [] }
        return list.prefix(limit).compactMap { Self.element($0) }
    }

    static func perform(_ element: AXUIElement, _ action: String, _ deadline: AXDeadline) -> Bool {
        guard deadline.allow(element) else { return false }
        return AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// A radio-button tab is selected when its value is 1; other tab buttons
    /// report AXSelected.
    static func isSelected(_ tab: AXUIElement, _ deadline: AXDeadline) -> Bool {
        let values = multiple(tab, [kAXValueAttribute, kAXSelectedAttribute], deadline)
        return int(values[0]) == 1 || bool(values[1]) == true
    }

    static func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// Raises the window and activates its app: macOS acts on the active
    /// window ("Windows need to be activated before snapping"). False when the
    /// app is gone or is AOM itself. A refused activation is not a failure:
    /// the menu search that follows still finds out whether the item is there.
    @MainActor static func bringForward(window: AXUIElement, pid: pid_t, _ deadline: AXDeadline) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        _ = perform(window, kAXRaiseAction, deadline)
        AXUIElementSetMessagingTimeout(window, 0)
        if app.isHidden { app.unhide() }
        _ = app.activate(options: [])
        return true
    }
}

// MARK: - Bounded menu search

/// Bounded search of one app's menu bar through its own application element.
/// `ActionExtended.pressEditMenuItem` walks every menu with no limit; this
/// walk stops at the budget and reads each item in a single request.
enum AXMenuSearch {
    /// Pure: the index of the first item whose title matches and is enabled.
    static func firstEnabled(_ items: [(title: String?, enabled: Bool)], titles: Set<String>) -> Int? {
        items.firstIndex { $0.enabled && AppKitMenuTitles.matches($0.title, titles) }
    }

    /// The enabled menu item reached by `path` in the app's menu bar: path[0]
    /// names a top-level menu (nil = try every top-level menu, in order), the
    /// following entries name items, each a submenu of the one before (an
    /// item's submenu is its first AXMenu child). Only path[0] may be nil.
    /// Each request is bounded by 0.25 s and the whole walk by `budget`; nil
    /// when not found, disabled or out of time. The returned element has its
    /// timeout reset to 0.
    static func item(pid: pid_t, path: [Set<String>?], budget: TimeInterval = 0.6) -> AXUIElement? {
        guard pid > 0, let head = path.first, head != nil || path.count > 1 else { return nil }
        let deadline = AXDeadline(perRequest: 0.25, budget: budget)
        let app = AXUIElementCreateApplication(pid)
        guard let bar = SwishTabAX.element(SwishTabAX.copy(app, kAXMenuBarAttribute, deadline)) else { return nil }
        let tops = SwishTabAX.children(bar, deadline, limit: 40)
        let candidates: [AXUIElement]
        if let titles = head {
            // Menu bar items are always enabled; only their titles matter.
            let entries = tops.map { top -> (title: String?, enabled: Bool) in
                (SwishTabAX.string(SwishTabAX.copy(top, kAXTitleAttribute, deadline)), true)
            }
            candidates = firstEnabled(entries, titles: titles).map { [tops[$0]] } ?? []
        } else {
            candidates = tops
        }
        for top in candidates {
            guard !deadline.isSpent else { return nil }
            if let found = descend(from: top, through: path.dropFirst(), deadline) {
                AXUIElementSetMessagingTimeout(found, 0)
                return found
            }
        }
        return nil
    }

    private static func descend(from start: AXUIElement, through steps: ArraySlice<Set<String>?>,
                                _ deadline: AXDeadline) -> AXUIElement? {
        var current = start
        for step in steps {
            guard let titles = step else { return nil }
            let menu = SwishTabAX.children(current, deadline, limit: 4).first {
                SwishTabAX.string(SwishTabAX.copy($0, kAXRoleAttribute, deadline)) == kAXMenuRole
            }
            guard let menu else { return nil }
            let items = SwishTabAX.children(menu, deadline, limit: 150)
            let entries = items.map { item -> (title: String?, enabled: Bool) in
                let values = SwishTabAX.multiple(item, [kAXTitleAttribute, kAXEnabledAttribute], deadline)
                return (SwishTabAX.string(values[0]), SwishTabAX.bool(values[1]) ?? false)
            }
            guard let index = firstEnabled(entries, titles: titles) else { return nil }
            current = items[index]
        }
        return current
    }

    /// AXPress, bounded to 0.5 s. A reply that times out (`.cannotComplete`)
    /// counts as pressed: the request reached the app, and AppKit apps often
    /// reply only after the command has run, so reporting failure would make
    /// the caller act a second time.
    @discardableResult static func press(_ item: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(item, 0.5)
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        AXUIElementSetMessagingTimeout(item, 0)
        return result == .success || result == .cannotComplete
    }
}

// MARK: - Tabs

/// Swish's tab gestures.
enum SwishTabs {
    /// How an app draws its tabs, after Swish's list.
    enum Family: String, CaseIterable, Equatable {
        case native, safari, chromium, arc, orion, xcode, vscode, updf, firefox, unsupported
    }

    private static let families: [String: Family] = {
        let groups: [(Family, [String])] = [
            (.safari, ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]),
            (.chromium, ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
                         "com.google.Chrome.canary", "com.brave.Browser", "com.brave.Browser.beta",
                         "com.brave.Browser.nightly", "com.vivaldi.Vivaldi"]),
            (.arc, ["company.thebrowser.Browser", "company.thebrowser.dia"]),
            (.orion, ["com.kagi.kagimacOS"]),
            (.xcode, ["com.apple.dt.Xcode"]),
            (.vscode, ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
            (.updf, ["com.superace.updf.mac"]),
            (.firefox, ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]),
            // Swish: "not implementing the Accessibility API correctly".
            (.unsupported, ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
                            "com.microsoft.edgemac.Canary", "com.figma.Desktop", "com.lukilabs.lukiapp"]),
        ]
        var map: [String: Family] = [:]
        for (family, ids) in groups { for id in ids { map[id.lowercased()] = family } }
        return map
    }()

    /// By bundle ID, case-insensitively. Anything else draws AppKit window
    /// tabs (Finder, Preview, TextEdit, Terminal, Mail…).
    static func family(bundleID: String?) -> Family {
        guard let bundleID else { return .native }
        return families[bundleID.lowercased()] ?? .native
    }

    struct Support: Equatable { let close: Bool; let detach: Bool }

    /// Detach needs AppKit's "Move Tab to New Window", which only native
    /// windows and Safari offer ("Only works in native windows and Safari").
    static func support(_ family: Family) -> Support {
        switch family {
        case .native, .safari: return Support(close: true, detach: true)
        case .chromium, .arc, .orion, .xcode, .vscode, .updf: return Support(close: true, detach: false)
        case .firefox, .unsupported: return Support(close: false, detach: false)
        }
    }

    /// Human-readable list for settings and notes.
    static let supportSummary = "Finder, Preview and other native tabs, Safari: close and detach; "
        + "Chrome, Brave, Vivaldi, Arc, Dia, Orion, Xcode, VS Code, UPDF: close; "
        + "Firefox, Edge, Figma, Craft: not supported"

    /// Pure: walking from the element under the pointer up to its window
    /// (`chain[0]` is the hit element, each next one its parent), the index of
    /// the tab: an element with subrole AXTabButton, or an AXRadioButton whose
    /// parent is an AXTabGroup. The walk stops at the first AXWindow.
    static func tabIndex(_ chain: [(role: String?, subrole: String?)]) -> Int? {
        for index in chain.indices {
            let entry = chain[index]
            if entry.role == "AXWindow" { return nil }
            if entry.subrole == "AXTabButton" { return index }
            if entry.role == "AXRadioButton", index + 1 < chain.count, chain[index + 1].role == "AXTabGroup" {
                return index
            }
        }
        return nil
    }

    /// Pure: whether a child of a tab is its close button: an AXButton with
    /// subrole AXCloseButton, or labelled with a localised "Close Tab" or
    /// "Close", or starting with "Close" (VS Code: "Close (⌘W)").
    static func isCloseButton(role: String?, subrole: String?, labels: [String?], closeTitles: Set<String>) -> Bool {
        guard role == "AXButton" else { return false }
        if subrole == "AXCloseButton" { return true }
        return labels.contains { label in
            guard let label else { return false }
            return AppKitMenuTitles.matches(label, closeTitles)
                || label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("close")
        }
    }

    /// How to close a tab, best first.
    enum CloseMethod: Equatable { case closeButton, action(String), commandW, none }

    /// Pure: its close button; else an accessibility action that mentions
    /// "close tab" (Chromium's custom action); else ⌘W, but only while the tab
    /// is selected in the focused window of the frontmost app, because ⌘W
    /// closes whatever is selected there; else none.
    static func closeMethod(hasCloseButton: Bool, actions: [String], selected: Bool,
                            windowFocused: Bool, appFrontmost: Bool) -> CloseMethod {
        closeMethod(hasCloseButton: hasCloseButton, actions: actions, descriptions: [],
                    selected: selected, windowFocused: windowFocused, appFrontmost: appFrontmost)
    }

    /// Pure, as above, where `descriptions[i]` (when present) is the
    /// description of `actions[i]`: an action whose name does not mention
    /// "close tab" but whose description does is still the close action.
    static func closeMethod(hasCloseButton: Bool, actions: [String], descriptions: [String?], selected: Bool,
                            windowFocused: Bool, appFrontmost: Bool) -> CloseMethod {
        if hasCloseButton { return .closeButton }
        for (index, name) in actions.enumerated() {
            let description = index < descriptions.count ? descriptions[index] : nil
            if mentionsCloseTab(name) || mentionsCloseTab(description) { return .action(name) }
        }
        return selected && windowFocused && appFrontmost ? .commandW : .none
    }

    private static func mentionsCloseTab(_ text: String?) -> Bool {
        text?.lowercased().contains("close tab") ?? false
    }

    /// Pure: whether detaching makes sense: the family supports it and the
    /// tab group has at least two tabs (a lone tab already is its window).
    static func canDetach(family: Family, tabCount: Int) -> Bool {
        support(family).detach && tabCount >= 2
    }

    /// What a gesture over a tab does (3.3.3, F02).
    enum TabGesture: Equatable { case close, detach, unsupported }

    /// Pure: a pinch in over a tab closes it where the app's tabs can be
    /// closed, and does nothing at all where they cannot (never the window
    /// with all its tabs). Nil: not a tab gesture (a pinch out still toggles
    /// full screen, as on the title bar).
    static func gesture(pinch: SwishSnap.Pinch, family: Family) -> TabGesture? {
        guard pinch == .in else { return nil }
        return support(family).close ? .close : .unsupported
    }

    /// Closes `tab` (in `window` of `pid`) and says how; `.none` when nothing
    /// could be done. Bounded: 0.25 s per request, 0.8 s in all. ⌘W goes
    /// straight to the app's process, never to another one.
    @MainActor static func close(tab: AXUIElement, window: AXUIElement, pid: pid_t) -> CloseMethod {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return .none }
        let deadline = AXDeadline(perRequest: 0.25, budget: 0.8)
        defer {
            AXUIElementSetMessagingTimeout(tab, 0)
            AXUIElementSetMessagingTimeout(window, 0)
        }
        let closeTitles = AppKitMenuTitles.titles(AppKitMenuTitles.closeTab)
            .union(AppKitMenuTitles.titles(AppKitMenuTitles.close))

        // A close button inside the tab: native, Safari, Chrome, VS Code.
        for child in SwishTabAX.children(tab, deadline, limit: 16) {
            let values = SwishTabAX.multiple(child, [kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute,
                                                     kAXTitleAttribute, kAXHelpAttribute], deadline)
            let strings = values.map { SwishTabAX.string($0) }
            guard isCloseButton(role: strings[0], subrole: strings[1], labels: Array(strings[2...]),
                                closeTitles: closeTitles) else { continue }
            if SwishTabAX.perform(child, kAXPressAction, deadline) { return .closeButton }
            break
        }

        // Custom actions: Chromium names them "Name:close tab\nTarget:…".
        // Standard AX actions (AXPress, AXShowMenu…) never close a tab, so only
        // the others are asked for a description.
        var names: [String] = []
        var descriptions: [String?] = []
        if deadline.allow(tab) {
            var list: CFArray?
            if AXUIElementCopyActionNames(tab, &list) == .success { names = Array((list as? [String] ?? []).prefix(16)) }
        }
        for name in names {
            guard !name.hasPrefix("AX"), deadline.allow(tab) else { descriptions.append(nil); continue }
            var description: CFString?
            let ok = AXUIElementCopyActionDescription(tab, name as CFString, &description) == .success
            descriptions.append(ok ? description.map { $0 as String } : nil)
        }

        let selected = SwishTabAX.isSelected(tab, deadline)
        let app = AXUIElementCreateApplication(pid)
        let focused = SwishTabAX.element(SwishTabAX.copy(app, kAXFocusedWindowAttribute, deadline))
        let windowFocused = focused.map { CFEqual($0, window) } ?? false
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid

        let method = closeMethod(hasCloseButton: false, actions: names, descriptions: descriptions,
                                 selected: selected, windowFocused: windowFocused, appFrontmost: frontmost)
        switch method {
        case .action(let name):
            if SwishTabAX.perform(tab, name, deadline) { return method }
            // The action refused; ⌘W is still right while the tab is selected.
            let fallback = closeMethod(hasCloseButton: false, actions: [], selected: selected,
                                       windowFocused: windowFocused, appFrontmost: frontmost)
            return fallback == .commandW && postCommandW(to: pid) ? .commandW : .none
        case .commandW:
            return postCommandW(to: pid) ? .commandW : .none
        case .closeButton, .none:
            return .none
        }
    }

    /// ⌘W (keycode 13) straight to the app's process, tagged so AOM's own
    /// monitors ignore it, as `postNewWindow(to:)` does for ⌘N.
    private static func postCommandW(to pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 13, keyDown: down) else { return false }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticInput.selfTag)
            event.postToPid(pid)
        }
        return ActionPermissions.canPostEvents
    }

    /// How many tabs the tab's group holds (its parent's children with role
    /// AXRadioButton or subrole AXTabButton), bounded; 0 when unknown.
    @MainActor static func tabCount(of tab: AXUIElement) -> Int {
        let deadline = AXDeadline(perRequest: 0.25, budget: 0.5)
        defer { AXUIElementSetMessagingTimeout(tab, 0) }
        guard let group = SwishTabAX.element(SwishTabAX.copy(tab, kAXParentAttribute, deadline)) else { return 0 }
        var count = 0
        for child in SwishTabAX.children(group, deadline, limit: 200) {
            let values = SwishTabAX.multiple(child, [kAXRoleAttribute, kAXSubroleAttribute], deadline)
            if SwishTabAX.string(values[0]) == "AXRadioButton" || SwishTabAX.string(values[1]) == "AXTabButton" {
                count += 1
            }
        }
        return deadline.isSpent ? 0 : count
    }

    /// How far a tab detach got (N333-05).
    enum DetachOutcome: Equatable {
        /// Move Tab to New Window was pressed.
        case pressed
        /// `mayContinue()` said no: a newer request, AOM or the app paused,
        /// the screen locked.
        case cancelled
        /// The tab could not be selected: the press failed, or the tab still
        /// does not read as selected after it.
        case notSelected
        /// The window could not be brought forward (its app is gone or is AOM).
        case notActivated
        /// The app has no enabled Move Tab to New Window item.
        case noMenuItem
        /// Right before the press, the tab was no longer the selected one, or
        /// its window no longer the app's focused or main window.
        case targetChanged
        /// The press itself failed.
        case pressFailed
    }

    /// Swish's detach ("Tap and hold to detach a native tab into a new window"):
    /// selects the tab, brings its window forward, presses the app's own
    /// "Move Tab to New Window" (it acts on the selected tab of the active
    /// window), then waits for the new window to take focus. `mayContinue()`
    /// (the caller's gate: the same request, AOM and the app not paused, the
    /// screen not locked) is asked before selecting, after the activation
    /// delay, right before pressing and before reporting.
    /// N333-05: a tab that cannot be selected stops the detach, and right
    /// before the press the tab must still be the selected one and its window
    /// the app's focused or main window, so the menu never moves another tab
    /// (`SwishTabDetachSteps`).
    @MainActor static func detach(tab: AXUIElement, window: AXUIElement, pid: pid_t,
                                  mayContinue: @escaping @MainActor () -> Bool,
                                  completion: @escaping @MainActor (WindowManager.Target?) -> Void) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { completion(nil); return }
        let name = SwishTabAX.appName(pid)
        // Selecting and activating share one budget, as before; the checks
        // right before the press have their own (`detachTargetHolds`).
        let start = AXDeadline(perRequest: 0.25, budget: 0.6)
        let steps = SwishTabDetachSteps<AXUIElement>(
            mayContinue: mayContinue,
            tabSelected: {
                defer { AXUIElementSetMessagingTimeout(tab, 0) }
                return SwishTabAX.isSelected(tab, start)
            },
            selectTab: {
                defer { AXUIElementSetMessagingTimeout(tab, 0) }
                return SwishTabAX.perform(tab, kAXPressAction, start)
            },
            bringForward: {
                // The window the tab shows in now: a native tab that was just
                // selected may have a window of its own.
                let front = SwishTabAX.element(SwishTabAX.copy(tab, kAXWindowAttribute, start)) ?? window
                AXUIElementSetMessagingTimeout(tab, 0)
                return SwishTabAX.bringForward(window: front, pid: pid, start)
            },
            targetHolds: { SwishTabs.detachTargetHolds(tab: tab, window: window, pid: pid) },
            findItem: {
                let titles = AppKitMenuTitles.titles(AppKitMenuTitles.moveTabToNewWindow)
                return AXMenuSearch.item(pid: pid, path: [AppKitMenuTitles.titles(AppKitMenuTitles.window), titles],
                                         budget: 0.4)
                    ?? AXMenuSearch.item(pid: pid, path: [nil, titles], budget: 0.6)
            },
            press: { AXMenuSearch.press($0) },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            })
        steps.run { outcome in
            switch outcome {
            case .pressed:
                GestureLog.shared.logFromAnyThread("Detach tab: pressed Move Tab to New Window in \(name)", level: .action)
                let until = ProcessInfo.processInfo.systemUptime + 1.5
                SwishTabs.pollNewWindow(pid: pid, old: window, until: until, name: name,
                                        mayContinue: mayContinue, completion: completion)
                return
            case .cancelled:
                GestureLog.shared.logFromAnyThread("Detach tab cancelled", level: .detect)
            case .targetChanged:
                GestureLog.shared.logFromAnyThread("Detach tab cancelled: the tab or its window changed in \(name)",
                                                   level: .detect)
            case .notSelected:
                GestureLog.shared.logFromAnyThread("Detach tab: could not select the tab in \(name)", level: .error)
            case .notActivated:
                GestureLog.shared.logFromAnyThread("Detach tab: could not activate \(name)", level: .error)
            case .noMenuItem:
                GestureLog.shared.logFromAnyThread("Detach tab: no enabled Move Tab to New Window item in \(name)",
                                                   level: .error)
            case .pressFailed:
                GestureLog.shared.logFromAnyThread("Detach tab: Move Tab to New Window failed in \(name)", level: .error)
            }
            completion(nil)
        }
    }

    /// Right before the press (N333-05): the tab is still the selected one
    /// and its window is the app's focused or main window. Bounded: 0.25 s
    /// per request, 0.5 s in all; anything unreadable counts as changed.
    @MainActor private static func detachTargetHolds(tab: AXUIElement, window: AXUIElement, pid: pid_t) -> Bool {
        let deadline = AXDeadline(perRequest: 0.25, budget: 0.5)
        defer { AXUIElementSetMessagingTimeout(tab, 0) }
        guard SwishTabAX.isSelected(tab, deadline) else { return false }
        let tabWindow = SwishTabAX.element(SwishTabAX.copy(tab, kAXWindowAttribute, deadline))
        let app = AXUIElementCreateApplication(pid)
        let front = SwishTabAX.multiple(app, [kAXFocusedWindowAttribute, kAXMainWindowAttribute], deadline)
        return windowInFront(focused: SwishTabAX.element(front[0]), main: SwishTabAX.element(front[1]),
                             window: window, tabWindow: tabWindow, same: { CFEqual($0, $1) })
    }

    /// Pure (N333-05): whether the app's focused or main window, the one its
    /// menu commands act on, is the tab's window: the window the gesture
    /// found, or the one the tab reports now (a native tab that was just
    /// selected may have a window of its own). `same` compares two windows.
    static func windowInFront<Window>(focused: Window?, main: Window?, window: Window, tabWindow: Window?,
                                      same: (Window, Window) -> Bool) -> Bool {
        let tabWindows = [window] + (tabWindow.map { [$0] } ?? [])
        return [focused, main].contains { front in
            guard let front else { return false }
            return tabWindows.contains { same(front, $0) }
        }
    }

    /// Every 0.1 s until `until`: the app's focused window, once it is a
    /// standard window other than the one the tab left.
    @MainActor private static func pollNewWindow(pid: pid_t, old: AXUIElement, until: TimeInterval, name: String,
                                                 mayContinue: @escaping @MainActor () -> Bool,
                                                 completion: @escaping @MainActor (WindowManager.Target?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                let deadline = AXDeadline(perRequest: 0.25, budget: 0.25)
                let app = AXUIElementCreateApplication(pid)
                if let focused = SwishTabAX.element(SwishTabAX.copy(app, kAXFocusedWindowAttribute, deadline)),
                   !CFEqual(focused, old),
                   SwishTabAX.string(SwishTabAX.copy(focused, kAXSubroleAttribute, deadline)) == kAXStandardWindowSubrole {
                    AXUIElementSetMessagingTimeout(focused, 0)
                    guard mayContinue() else {
                        GestureLog.shared.logFromAnyThread("Detach tab cancelled", level: .detect)
                        completion(nil); return
                    }
                    GestureLog.shared.logFromAnyThread("Detach tab: new window in \(name)", level: .action)
                    completion(WindowManager.Target(window: focused, pid: pid)); return
                }
                guard ProcessInfo.processInfo.systemUptime < until else {
                    GestureLog.shared.logFromAnyThread("Detach tab: no new window appeared in \(name)", level: .error)
                    completion(nil); return
                }
                SwishTabs.pollNewWindow(pid: pid, old: old, until: until, name: name, mayContinue: mayContinue, completion: completion)
            }
        }
    }
}

// MARK: - Detaching a tab, step by step (N333-05)

/// A tab detach as its steps in order, each a closure, so the checks around
/// the menu press can be tested without Accessibility. 3.3.3 went on when the
/// tab's selection failed and, right before pressing Move Tab to New Window,
/// asked only about the pause: a selection that did not take, or another tab
/// or window chosen in the app meanwhile, let the menu move another tab.
/// Main thread only.
struct SwishTabDetachSteps<Item> {
    /// The caller's gate (the same request, AOM and the app not paused, the
    /// screen not locked): asked before selecting, after the activation
    /// delay, and again right before pressing (the menu search may take up
    /// to a second).
    var mayContinue: @MainActor () -> Bool
    /// Whether the tab is the selected one of its group, read now.
    var tabSelected: @MainActor () -> Bool
    /// Presses the tab to select it; false when the request failed.
    var selectTab: @MainActor () -> Bool
    /// Raises the tab's window and activates its app; false when the app is
    /// gone or is AOM.
    var bringForward: @MainActor () -> Bool
    /// Right before the press: the tab is still the selected one and its
    /// window is still the app's focused or main window.
    var targetHolds: @MainActor () -> Bool
    /// The app's enabled Move Tab to New Window item, or nil.
    var findItem: @MainActor () -> Item?
    /// Presses the item; false when the request failed.
    var press: @MainActor (Item) -> Bool
    /// Runs `work` on main after `delay` seconds.
    var after: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    /// The moment given to the activation, so the menu acts on this window.
    static var activationDelay: TimeInterval { 0.15 }

    /// Runs the steps; `completion` gets how far they went. Nothing is
    /// pressed unless every check passed.
    @MainActor func run(_ completion: @escaping @MainActor (SwishTabs.DetachOutcome) -> Void) {
        guard mayContinue() else { completion(.cancelled); return }
        // A tab that is not selected yet is pressed, and must then read as selected.
        if !tabSelected() {
            guard selectTab(), tabSelected() else { completion(.notSelected); return }
        }
        guard bringForward() else { completion(.notActivated); return }
        let steps = self
        after(Self.activationDelay) {
            guard steps.mayContinue() else { completion(.cancelled); return }
            guard let item = steps.findItem() else { completion(.noMenuItem); return }
            guard steps.mayContinue() else { completion(.cancelled); return }
            guard steps.targetHolds() else { completion(.targetChanged); return }
            completion(steps.press(item) ? .pressed : .pressFailed)
        }
    }
}

// MARK: - Native tiling

/// macOS's own window tiling (Window › Move & Resize), Swish's "Native Window
/// Tiling". macOS offers halves, quarters and Fill only ("up to a 2×2 grid").
enum NativeTiling {
    /// com.apple.WindowManager, read-only. A missing key means on, macOS's default.
    struct SystemOptions: Equatable { var margins: Bool; var edgeDrag: Bool; var topEdgeDrag: Bool }

    static func parse(margins: Any?, edgeDrag: Any?, topEdgeDrag: Any?) -> SystemOptions {
        SystemOptions(margins: flag(margins), edgeDrag: flag(edgeDrag), topEdgeDrag: flag(topEdgeDrag))
    }

    private static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return true
    }

    static func systemOptions() -> SystemOptions {
        func read(_ key: String) -> Any? {
            CFPreferencesCopyAppValue(key as CFString, "com.apple.WindowManager" as CFString)
        }
        return parse(margins: read("EnableTiledWindowMargins"), edgeDrag: read("EnableTilingByEdgeDrag"),
                     topEdgeDrag: read("EnableTopTilingByEdgeDrag"))
    }

    /// Pure: Swish's mirror of System Settings › Desktop & Dock › Windows
    /// ("Drag Windows to Edge: Enabled | Top only | Sides only | Off"), from
    /// "Drag windows to screen edges to tile" (`edgeDrag`) and "Drag windows
    /// to menu bar to fill screen" (`topEdgeDrag`). Read-only: AOM never
    /// writes com.apple.WindowManager.
    static func dragToEdgeLabel(_ options: SystemOptions) -> String {
        switch (options.edgeDrag, options.topEdgeDrag) {
        case (true, true): return "Enabled"
        case (false, true): return "Top only"
        case (true, false): return "Sides only"
        case (false, false): return "Off"
        }
    }

    /// Pure: the settings line about the system's tile margins ("Grid
    /// Spacing 8 px" in Swish's popover).
    static func marginsLabel(_ options: SystemOptions) -> String {
        options.margins ? "\(Int(margin)) pt" : "Off"
    }

    /// The Move & Resize item macOS offers for a place: the halves, the
    /// quarters and Fill for maximize; nil for anything else (thirds, sixths,
    /// ninths, centre, almost maximize), which AOM's own engine snaps.
    static func menuKey(for place: SwishSnap.Place) -> String? {
        guard case .grid(let cell) = place, let layout = cell.layout else { return nil }
        switch layout {
        case .leftHalf: return AppKitMenuTitles.left
        case .rightHalf: return AppKitMenuTitles.right
        case .topHalf: return AppKitMenuTitles.top
        case .bottomHalf: return AppKitMenuTitles.bottom
        case .topLeft: return AppKitMenuTitles.topLeft
        case .topRight: return AppKitMenuTitles.topRight
        case .bottomLeft: return AppKitMenuTitles.bottomLeft
        case .bottomRight: return AppKitMenuTitles.bottomRight
        case .maximize: return AppKitMenuTitles.fill
        default: return nil
        }
    }

    /// The gap macOS keeps around tiles while margins are on (Swish's tiling
    /// popover: "Grid Spacing 8 px").
    static let margin: CGFloat = 8

    /// Pure, for the preview: the place's cell of `visible` (top-left
    /// coordinates), inset by `margin` at the display's edges and by half of
    /// it along edges shared with another tile, so two tiles sit `margin`
    /// apart; the bare cell when margins are off. Nil for places macOS
    /// cannot tile.
    static func previewFrame(place: SwishSnap.Place, visible: CGRect, options: SystemOptions) -> CGRect? {
        guard menuKey(for: place) != nil else { return nil }
        let cell = SwishSnap.targetFrame(place: place, visible: visible, margin: 0)
        guard options.margins else { return cell }
        func inset(_ edge: CGFloat, _ displayEdge: CGFloat) -> CGFloat {
            abs(edge - displayEdge) < 0.5 ? margin : margin / 2
        }
        let left = inset(cell.minX, visible.minX), right = inset(cell.maxX, visible.maxX)
        let top = inset(cell.minY, visible.minY), bottom = inset(cell.maxY, visible.maxY)
        return CGRect(x: cell.minX + left, y: cell.minY + top,
                      width: max(0, cell.width - left - right), height: max(0, cell.height - top - bottom))
    }

    /// Tiles `target` the way macOS does: brings the window forward (macOS
    /// tiles the active window), then after 0.15 s presses Window › Move &
    /// Resize › <item>, or Window › <item> (where Fill also sits).
    /// completion(true) once pressed; false when the app has no such enabled
    /// item (the caller falls back to AOM's engine) or `mayContinue()` was false.
    @MainActor static func tile(_ target: WindowManager.Target, key: String,
                                mayContinue: @escaping @MainActor () -> Bool,
                                completion: @escaping @MainActor (Bool) -> Void) {
        let pid = target.pid
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier, mayContinue() else { completion(false); return }
        let deadline = AXDeadline(perRequest: 0.25, budget: 0.4)
        guard SwishTabAX.bringForward(window: target.window, pid: pid, deadline) else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                let window = AppKitMenuTitles.titles(AppKitMenuTitles.window)
                let titles = AppKitMenuTitles.titles(key)
                let item = AXMenuSearch.item(pid: pid, path: [window, AppKitMenuTitles.titles(AppKitMenuTitles.moveAndResize), titles],
                                             budget: 0.4)
                    ?? AXMenuSearch.item(pid: pid, path: [window, titles], budget: 0.3)
                guard let item else {
                    GestureLog.shared.logFromAnyThread("Native tiling: no enabled \(key) item in \(SwishTabAX.appName(pid))",
                                                       level: .detect)
                    completion(false); return
                }
                guard mayContinue() else { completion(false); return }
                let pressed = AXMenuSearch.press(item)
                if pressed {
                    GestureLog.shared.logFromAnyThread("Native tiling: \(key) in \(SwishTabAX.appName(pid))", level: .action)
                }
                completion(pressed)
            }
        }
    }
}
