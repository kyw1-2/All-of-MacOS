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

/// How far the front app's menus reach (File, Edit … on the left).
enum MenuBarAppMenus {
    @MainActor
    static func maxX(on screen: NSScreen) -> CGFloat {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return screen.frame.minX + 400 }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else {
            return screen.frame.minX + 400
        }
        var children: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement], let last = items.last else { return screen.frame.minX + 400 }
        var position: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, extent = CGSize.zero
        // swiftlint:disable force_cast
        if AXUIElementCopyAttributeValue(last, kAXPositionAttribute as CFString, &position) == .success, let position {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(last, kAXSizeAttribute as CFString, &size) == .success, let size {
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        }
        // swiftlint:enable force_cast
        return origin.x + extent.width - screen.frame.minX
    }
}

/// What lies under a point of the menu bar (Accessibility hit test).
enum MenuBarHitTest {
    private static let systemWide = AXUIElementCreateSystemWide()

    private static func role(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// True when the point (AppKit coordinates) is menu bar space with no
    /// item or app menu under it. Unknown answers count as not empty.
    static func isEmpty(at point: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(primary - point.y), &element)
        // Over nothing at all (the empty bar belongs to no app's tree).
        guard result == .success, let element else { return result == .noValue }
        var parent: CFTypeRef?
        var parentRole: String?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent {
            parentRole = role(parent as! AXUIElement) // swiftlint:disable:this force_cast
        }
        return MenuBarTriggerPolicy.isEmptySpace(role: role(element), parentRole: parentRole)
    }
}

/// Bartender's ways to show hidden icons without aiming at ❮, plus the
/// ⌘-drag and wide-display rules. Global mouse monitors only watch; the
/// click or scroll still reaches the menu bar.
@MainActor
final class MenuBarTriggers {
    static let shared = MenuBarTriggers()

    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
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
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .scrollWheel, .mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { event in
            let type = event.type, flags = event.modifierFlags, delta = event.scrollingDeltaY + event.scrollingDeltaX
            MainActor.assumeIsolated { MenuBarTriggers.shared.handle(type, flags: flags, scroll: delta) }
        }) { monitors.append(monitor) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarTriggers.shared.applyWideRule() }
        }
        applyWideRule()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        hoverWork?.cancel()
        hoverHideWork?.cancel()
        revealedByHover = false
        arranging = false
        wideHold = false
    }

    private static func band(containing point: CGPoint) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        let band = MenuBarTriggerPolicy.band(screen: screen.frame, visibleMaxY: screen.visibleFrame.maxY)
        return band.contains(point) ? band : nil
    }

    private func handle(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags, scroll: CGFloat) {
        let hider = MenuBarHider.shared
        guard hider.isRunning else { return }
        let point = NSEvent.mouseLocation
        let inBar = Self.band(containing: point) != nil
        switch type {
        case .leftMouseDown:
            if inBar, flags.contains(.command), MenuBarPrefs.commandDragShowsAll { beginArranging(); return }
            guard inBar, MenuBarPrefs.showOnEmptyClick, !flags.contains(.command) else { return }
            // Let the click land first; then ask what was under it.
            DispatchQueue.main.async {
                guard MenuBarHitTest.isEmpty(at: point) else { return }
                MenuBarHider.shared.toggleFromTrigger()
            }
        case .leftMouseUp:
            if arranging { endArranging() }
        case .scrollWheel:
            guard inBar, MenuBarPrefs.showOnScroll, abs(scroll) > 0.5 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastScroll > 0.6 else { return }
            lastScroll = now
            // Scrolling down (or right) shows, up (or left) hides — as in Bartender.
            if scroll < 0 { hider.revealFromTrigger() } else { hider.hideFromTrigger() }
        case .mouseMoved, .leftMouseDragged:
            guard MenuBarPrefs.showOnHover else { return }
            if inBar { pointerInBar(point) } else { pointerLeftBar() }
        default:
            break
        }
    }

    private func pointerInBar(_ point: CGPoint) {
        hoverHideWork?.cancel()
        hoverHideWork = nil
        guard MenuBarHider.shared.isCollapsed, hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            let now = NSEvent.mouseLocation
            guard Self.band(containing: now) != nil, MenuBarHider.shared.isCollapsed,
                  NSEvent.pressedMouseButtons == 0, MenuBarHitTest.isEmpty(at: now) else { return }
            self.revealedByHover = true
            MenuBarHider.shared.revealFromTrigger()
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
            // Still away, and no menu or popover of a shown icon open.
            guard Self.band(containing: NSEvent.mouseLocation) == nil, !MenuBarHider.isMenuBarBusy() else {
                if Self.band(containing: NSEvent.mouseLocation) == nil { self.pointerLeftBar() }
                return
            }
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
