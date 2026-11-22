import AppKit
import ApplicationServices

// AOM 7.10 — Bartender 7's General and Advanced settings, after its own
// preference panes (GeneralPreferences.nib, AdvancedPreferences.nib, decoded on
// Oracle for DeepSeek report 07): what shows hidden icons (a click or a
// scroll on empty menu bar space, a hover with its two delays), whether they
// come back in a bar below, how long a temporarily shown icon stays, showing
// every section while ⌘-dragging, the Bar when the menu bar has no room, and
// a wide display showing everything.

/// Every menu bar setting Bartender keeps in its General and Advanced panes.
enum MenuBarPrefs {
    private static var defaults: UserDefaults { .standard }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? fallback
    }

    // "Show hidden menu bar items when:"
    static let clickEmptyKey = "AOMMenuBar.showOnEmptyClick"
    static var showOnEmptyClick: Bool {
        get { bool(clickEmptyKey, true) }
        set { defaults.set(newValue, forKey: clickEmptyKey) }
    }

    static let scrollKey = "AOMMenuBar.showOnScroll"
    static var showOnScroll: Bool {
        get { bool(scrollKey, false) }
        set { defaults.set(newValue, forKey: scrollKey) }
    }

    /// Hovering over empty menu bar space (the old "rest on ❮" setting carries over).
    static var showOnHover: Bool {
        get { defaults.bool(forKey: "AOMMenuBarHider.hoverReveal") }
        set { defaults.set(newValue, forKey: "AOMMenuBarHider.hoverReveal") }
    }

    static let hoverShowKey = "AOMMenuBar.hoverShowDelay"
    static var hoverShowDelay: Double {
        get { double(hoverShowKey, 0.3) }
        set { defaults.set(min(5, max(0, newValue)), forKey: hoverShowKey) }
    }

    static let hoverHideKey = "AOMMenuBar.hoverHideDelay"
    static var hoverHideDelay: Double {
        get { double(hoverHideKey, 1) }
        set { defaults.set(min(10, max(0, newValue)), forKey: hoverHideKey) }
    }

    // Bar
    static let barAtMouseKey = "AOMMenuBar.barAtMouse"
    static var barAtMouse: Bool {
        get { bool(barAtMouseKey, false) }
        set { defaults.set(newValue, forKey: barAtMouseKey) }
    }

    /// "Hide the bar when your pointer leaves it" and after how long.
    static let barLeaveKey = "AOMMenuBar.barLeaveDelay"
    static var barLeaveDelay: Double {
        get { double(barLeaveKey, 1) }
        set { defaults.set(min(10, max(0.3, newValue)), forKey: barLeaveKey) }
    }

    static let barAutohideKey = "AOMMenuBar.barAutohide"
    static var barAutohide: Bool {
        get { bool(barAutohideKey, true) }
        set { defaults.set(newValue, forKey: barAutohideKey) }
    }

    // Advanced
    /// "Delay before hiding temporarily shown menu bar items from the Bar."
    static let temporaryKey = "AOMMenuBar.temporaryShowSeconds"
    static var temporaryShowSeconds: Double {
        get { double(temporaryKey, 15) }
        set { defaults.set(min(120, max(1, newValue)), forKey: temporaryKey) }
    }

    /// "When ⌘+dragging menu bar items, show all sections."
    static let commandDragKey = "AOMMenuBar.commandDragShowsAll"
    static var commandDragShowsAll: Bool {
        get { bool(commandDragKey, true) }
        set { defaults.set(newValue, forKey: commandDragKey) }
    }

    /// "The hidden section cannot be expanded as there isn't room … the Bar
    /// will show these items instead."
    static let barWhenFullKey = "AOMMenuBar.barWhenNoRoom"
    static var barWhenNoRoom: Bool {
        get { bool(barWhenFullKey, true) }
        set { defaults.set(newValue, forKey: barWhenFullKey) }
    }

    /// "Show all menu bar items when active screen is bigger than …" (0 = off).
    static let wideKey = "AOMMenuBar.showAllWiderThan"
    static var showAllWiderThan: Double {
        get { double(wideKey, 0) }
        set { defaults.set(max(0, newValue), forKey: wideKey) }
    }

    /// The section a newly seen app's icons start in ("New Menu Bar Items" pill).
    static let newItemsKey = "AOMMenuBar.newItemsSection"
    static var newItemsSection: MenuBarSection {
        get { MenuBarSection(rawValue: defaults.string(forKey: newItemsKey) ?? "") ?? .shown }
        set { defaults.set(newValue.rawValue, forKey: newItemsKey) }
    }

    /// The Hider's own icon ("Bartender menu bar icon").
    enum ToggleIcon: String, CaseIterable, Identifiable {
        case chevron, ellipsis, dot, line
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chevron: return "Chevron"
            case .ellipsis: return "Dots"
            case .dot: return "Dot"
            case .line: return "Line"
            }
        }
        /// The picture while icons are hidden, and while they show.
        var symbols: (collapsed: String, expanded: String) {
            switch self {
            case .chevron: return ("chevron.left", "chevron.right")
            case .ellipsis: return ("ellipsis", "ellipsis.circle")
            case .dot: return ("circle.fill", "circle")
            case .line: return ("line.diagonal", "line.diagonal.arrow")
            }
        }
    }

    static let toggleIconKey = "AOMMenuBar.toggleIcon"
    static var toggleIcon: ToggleIcon {
        get { ToggleIcon(rawValue: defaults.string(forKey: toggleIconKey) ?? "") ?? .chevron }
        set { defaults.set(newValue.rawValue, forKey: toggleIconKey) }
    }

    /// The Setup guide was finished or dismissed ("Do not show this welcome message again").
    static let setupKey = "AOMMenuBar.setupDone"
    static var setupDone: Bool {
        get { defaults.bool(forKey: setupKey) }
        set { defaults.set(newValue, forKey: setupKey) }
    }

    /// Apps seen with menu bar icons, so a new one can start in `newItemsSection`.
    static let seenKey = "AOMMenuBar.seenApps"
    static var seenApps: Set<String> {
        get { Set(defaults.stringArray(forKey: seenKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: seenKey) }
    }
}

/// Pure decisions, kept out of the event monitors for the tests.
enum MenuBarTriggerPolicy {
    /// The menu bar's band on a screen (AppKit coordinates). A hidden menu bar
    /// (auto-hide) has no band in `visibleFrame`; the top 24 pt count then.
    static func band(screen: CGRect, visibleMaxY: CGFloat) -> CGRect {
        let height = max(24, screen.maxY - visibleMaxY)
        return CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
    }

    /// An Accessibility role under the pointer that is not an item: the bar
    /// itself, the app, nothing at all.
    static func isEmptySpace(role: String?, parentRole: String?) -> Bool {
        let itemRoles: Set<String> = ["AXMenuBarItem", "AXMenuExtra", "AXMenuItem", "AXButton", "AXImage", "AXStaticText"]
        if let role, itemRoles.contains(role) { return false }
        if let parentRole, ["AXMenuBarItem", "AXMenuExtra"].contains(parentRole) { return false }
        return true
    }

    /// Hidden icons fit when the space left for icons (right of the notch, or
    /// right of the app's menus) holds them beside the shown ones.
    static func hasRoom(hiddenWidth: CGFloat, shownWidth: CGFloat, available: CGFloat) -> Bool {
        hiddenWidth + shownWidth + 16 <= available
    }

    /// Show everything on a display at least this wide (0 = never).
    static func showsAll(screenWidth: CGFloat, threshold: Double) -> Bool {
        threshold > 0 && Double(screenWidth) >= threshold
    }

    /// Apps never placed by the user start where the "New Menu Bar Items" pill is.
    static func sections(running: [String], stored: [String: MenuBarSection], seen: Set<String>,
                         newItems: MenuBarSection) -> [String: MenuBarSection] {
        guard newItems != .shown, !seen.isEmpty else { return stored }
        var out = stored
        for bundle in running where out[bundle] == nil && !seen.contains(bundle) && !MenuBarSectionStore.systemOwners.contains(bundle) {
            out[bundle] = newItems
        }
        return out
    }
}

/// How far the front app's menus reach (File, Edit … on the left), cached
/// per front app for a few seconds: it is asked on every reveal.
enum MenuBarAppMenus {
    @MainActor private static var cache: (pid: pid_t, maxX: CGFloat, at: TimeInterval)?

    @MainActor
    static func maxX(on screen: NSScreen) -> CGFloat {
        let fallback = screen.frame.minX + 400
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return fallback }
        let now = ProcessInfo.processInfo.systemUptime
        if let cache, cache.pid == app.processIdentifier, now - cache.at < 5 { return cache.maxX }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let bar = AOMMenuShelfProbe.attribute(element, kAXMenuBarAttribute as CFString),
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              // swiftlint:disable:next force_cast
              let items = AOMMenuShelfProbe.attribute(bar as! AXUIElement, kAXChildrenAttribute as CFString) as? [AXUIElement],
              let last = items.last, let frame = AOMMenuShelfProbe.frame(last) else { return fallback }
        let value = frame.maxX - screen.frame.minX
        cache = (app.processIdentifier, value, now)
        return value
    }
}

/// What lies under a point of the menu bar (Accessibility hit test). Safe
/// off the main thread; every call is capped at a quarter second.
enum MenuBarHitTest {
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    private static func role(_ element: AXUIElement) -> String? {
        AOMMenuShelfProbe.attribute(element, kAXRoleAttribute as CFString) as? String
    }

    /// True when the point (Accessibility coordinates, top-left origin) is
    /// menu bar space with no item or app menu under it. Unknown answers
    /// count as not empty.
    static func isEmpty(atAX point: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        // Over nothing at all (the empty bar belongs to no app's tree).
        guard result == .success, let element else { return result == .noValue }
        let parent = AOMMenuShelfProbe.attribute(element, kAXParentAttribute as CFString)
        // swiftlint:disable:next force_cast
        let parentRole = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? role($0 as! AXUIElement) : nil }
        return MenuBarTriggerPolicy.isEmptySpace(role: role(element), parentRole: parentRole)
    }

    /// Asks off the main thread and answers on it.
    @MainActor
    static func whenEmpty(at point: CGPoint, then: @escaping @MainActor () -> Void) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let ax = CGPoint(x: point.x, y: primary - point.y)
        DispatchQueue.global(qos: .userInitiated).async {
            guard isEmpty(atAX: ax) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }
}

/// Bartender's ways to show hidden icons without aiming at ❮, plus the
/// ⌘-drag and wide-display rules. Global mouse monitors only watch; the
/// click or scroll still reaches the menu bar. Only the events a setting
/// needs are watched (pointer moves only while hover is on).
@MainActor
final class MenuBarTriggers {
    static let shared = MenuBarTriggers()

    private var monitor: Any?
    private var mask: NSEvent.EventTypeMask = []
    private var screenObserver: NSObjectProtocol?
    /// The menu bar band of each screen, refreshed when displays change.
    private var bands: [CGRect] = []
    private var hoverWork: DispatchWorkItem?
    private var hoverHideWork: DispatchWorkItem?
    /// Shown by a hover; hidden again when the pointer leaves the menu bar.
    private var revealedByHover = false
    /// ⌘-drag in progress with every section shown.
    private var arranging = false
    private var lastScroll: TimeInterval = 0
    /// Shown everything because the display is wide.
    private(set) var wideHold = false

    func start() {
        stop()
        readBands()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MenuBarTriggers.shared.readBands()
                MenuBarTriggers.shared.applyWideRule()
            }
        }
        reconfigure()
        applyWideRule()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        mask = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        hoverWork?.cancel()
        hoverHideWork?.cancel()
        revealedByHover = false
        arranging = false
        wideHold = false
    }

    /// Pure: the events the current settings need. Clicks are always
    /// watched while hiding (the clock hand-off needs them).
    static func mask(click: Bool, scroll: Bool, hover: Bool, commandDrag: Bool) -> NSEvent.EventTypeMask {
        var mask: NSEvent.EventTypeMask = [.leftMouseDown]
        if commandDrag { mask.insert(.leftMouseUp) }
        if scroll { mask.insert(.scrollWheel) }
        if hover { mask.formUnion([.mouseMoved, .leftMouseDragged]) }
        _ = click
        return mask
    }

    /// Re-installs the monitor when a setting changed what it must watch.
    func reconfigure() {
        guard MenuBarHider.shared.isRunning else { return }
        let wanted = Self.mask(click: MenuBarPrefs.showOnEmptyClick, scroll: MenuBarPrefs.showOnScroll,
                               hover: MenuBarPrefs.showOnHover, commandDrag: MenuBarPrefs.commandDragShowsAll)
        guard wanted != mask || monitor == nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        mask = wanted
        monitor = NSEvent.addGlobalMonitorForEvents(matching: wanted) { event in
            // AOM's own synthetic clicks (item hotkeys, ⌘-drag moves) are not the user's.
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SyntheticInput.selfTag { return }
            let type = event.type, flags = event.modifierFlags, delta = event.scrollingDeltaY + event.scrollingDeltaX
            MainActor.assumeIsolated { MenuBarTriggers.shared.handle(type, flags: flags, scroll: delta) }
        }
    }

    private func readBands() {
        bands = NSScreen.screens.map { MenuBarTriggerPolicy.band(screen: $0.frame, visibleMaxY: $0.visibleFrame.maxY) }
    }

    private func inBar(_ point: CGPoint) -> Bool { bands.contains { $0.contains(point) } }

    private func handle(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags, scroll: CGFloat) {
        let hider = MenuBarHider.shared
        guard hider.isRunning else { return }
        let point = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            guard inBar(point) else { return }
            if flags.contains(.command) {
                if MenuBarPrefs.commandDragShowsAll { beginArranging() }
                return
            }
            // macOS 27 ignores the clock while anything is hidden: hand it over.
            if MenuBarNativeHiding.shared.handleClockClick(at: point) { return }
            guard MenuBarPrefs.showOnEmptyClick else { return }
            MenuBarHitTest.whenEmpty(at: point) { MenuBarHider.shared.toggleFromTrigger() }
        case .leftMouseUp:
            if arranging { endArranging() }
        case .scrollWheel:
            guard abs(scroll) > 0.5, inBar(point) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastScroll > 0.6 else { return }
            lastScroll = now
            // Scrolling down (or right) shows, up (or left) hides — as in Bartender.
            if scroll < 0 { hider.revealFromTrigger() } else { hider.hideFromTrigger() }
        case .mouseMoved, .leftMouseDragged:
            if inBar(point) { pointerInBar() } else if revealedByHover || hoverWork != nil { pointerLeftBar() }
        default:
            break
        }
    }

    private func pointerInBar() {
        hoverHideWork?.cancel()
        hoverHideWork = nil
        guard MenuBarHider.shared.isCollapsed, hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            let now = NSEvent.mouseLocation
            guard self.inBar(now), MenuBarHider.shared.isCollapsed, NSEvent.pressedMouseButtons == 0 else { return }
            MenuBarHitTest.whenEmpty(at: now) {
                MenuBarTriggers.shared.revealedByHover = true
                MenuBarHider.shared.revealFromTrigger()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarPrefs.hoverShowDelay, execute: work)
    }

    private func pointerLeftBar() {
        hoverWork?.cancel()
        hoverWork = nil
        guard revealedByHover, hoverHideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverHideWork = nil
            guard !self.inBar(NSEvent.mouseLocation) else { return }
            // A menu or popover of a shown icon is open: look again shortly.
            guard !MenuBarHider.isMenuBarBusy() else { self.pointerLeftBar(); return }
            self.revealedByHover = false
            MenuBarHider.shared.hideFromTrigger()
        }
        hoverHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, MenuBarPrefs.hoverHideDelay), execute: work)
    }

    /// ⌘ held on the menu bar: every section shows so icons can be dragged.
    private func beginArranging() {
        guard !arranging else { return }
        arranging = true
        MenuBarHider.shared.showAllForArranging()
    }

    private func endArranging() {
        arranging = false
        // A moment for macOS to settle the drop, then back to how it was.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MenuBarHider.shared.endArranging()
        }
    }

    /// "Show all menu bar items when active screen is bigger than …".
    func applyWideRule() {
        let width = NSScreen.main?.frame.width ?? 0
        let wide = MenuBarTriggerPolicy.showsAll(screenWidth: width, threshold: MenuBarPrefs.showAllWiderThan)
        guard wide != wideHold else { return }
        wideHold = wide
        if wide { MenuBarHider.shared.expand(all: true, holdOpen: true) } else { MenuBarHider.shared.collapse(quiet: true) }
    }
}

/// Bartender's presets: a named copy of every app's section, applied over
/// the default layout and removable ("Remove Applied Preset").
enum MenuBarPresets {
    struct Preset: Codable, Equatable, Identifiable {
        var name: String
        var sections: [String: MenuBarSection]
        var id: String { name }
    }

    static let listKey = "AOMMenuBar.presets"
    static let appliedKey = "AOMMenuBar.appliedPreset"
    /// The default layout kept while a preset is applied.
    static let baseKey = "AOMMenuBar.presetBase"

    static var all: [Preset] {
        guard let data = UserDefaults.standard.data(forKey: listKey) else { return [] }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    private static func save(_ list: [Preset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: listKey)
    }

    static var applied: String? { UserDefaults.standard.string(forKey: appliedKey) }

    /// Pure: a new list with `preset` added or replacing one of the same name.
    static func upserting(_ preset: Preset, into list: [Preset]) -> [Preset] {
        var out = list.filter { $0.name.caseInsensitiveCompare(preset.name) != .orderedSame }
        out.append(preset)
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func saveCurrent(as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(upserting(Preset(name: trimmed, sections: MenuBarSectionStore.all), into: all))
    }

    @MainActor
    static func delete(_ name: String) {
        save(all.filter { $0.name != name })
        if applied == name { removeApplied() }
    }

    @MainActor
    static func apply(_ name: String) {
        guard let preset = all.first(where: { $0.name == name }) else { return }
        if applied == nil, let data = try? JSONEncoder().encode(MenuBarSectionStore.all) {
            UserDefaults.standard.set(data, forKey: baseKey)
        }
        MenuBarSectionStore.replaceAll(preset.sections)
        UserDefaults.standard.set(name, forKey: appliedKey)
        MenuBarLayoutModel.shared.reloadSections()
        MenuBarHider.shared.reapply()
    }

    @MainActor
    static func removeApplied() {
        guard applied != nil else { return }
        if let data = UserDefaults.standard.data(forKey: baseKey),
           let base = try? JSONDecoder().decode([String: MenuBarSection].self, from: data) {
            MenuBarSectionStore.replaceAll(base)
        }
        UserDefaults.standard.removeObject(forKey: appliedKey)
        UserDefaults.standard.removeObject(forKey: baseKey)
        MenuBarLayoutModel.shared.reloadSections()
        MenuBarHider.shared.reapply()
    }
}
