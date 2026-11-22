import AppKit

/// 7.4 (Ice, Hidden Bar): two menu bar items, a chevron and a divider left
/// of it. Items you ⌘-drag left of the divider are hidden: collapsing widens
/// the divider until they leave the screen; the chevron brings them back,
/// and they hide again after a while. Other apps' items are never moved by
/// AOM; only its own divider changes width.
@MainActor
final class MenuBarHider: NSObject {
    static let shared = MenuBarHider()

    static let rehideKey = "AOMMenuBarHider.rehideSeconds"
    /// Set once items were hidden, so a relaunch hides them again and the
    /// first start leaves the menu bar as it was.
    static let usedKey = "AOMMenuBarHider.used"
    /// Wide enough to push everything left of it off the widest display.
    static let collapsedLength: CGFloat = 10_000
    static let dividerLength: CGFloat = 12

    private var toggle: NSStatusItem?
    private var divider: NSStatusItem?
    /// 7.6 (Codex M04): the optional second divider; items left of it stay
    /// hidden when the chevron shows the others, until ⌥-click shows all.
    private var always: NSStatusItem?
    static let alwaysKey = "AOMMenuBarHider.alwaysSection"
    static var alwaysSectionOn: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysKey) }
    }
    /// Shown everything (⌥-click), not only the "when needed" section.
    private(set) var showsAll = false
    /// The check that the chevron stayed on its display (cancelled by any change).
    private var visibilityCheck: DispatchWorkItem?
    private(set) var isCollapsed = false
    /// 7.8 (Codex HB-01): the countdown to hiding again, checked twice a
    /// second; it starts over while the menu bar is in use.
    private var rehideTimer: Timer?
    private var rehideDeadline: TimeInterval = 0
    /// 7.6 (Codex MB04): the delayed collapse after a start, cancelled by stop.
    private var startCollapse: DispatchWorkItem?

    /// Seconds before shown items hide again; 0 keeps them shown.
    static var rehideSeconds: Double {
        get { UserDefaults.standard.object(forKey: rehideKey) as? Double ?? 15 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: rehideKey) }
    }

    func start() {
        guard toggle == nil else { return }
        // Items are added right to left, so the chevron comes first and the
        // divider lands on its left.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "AOMMenuBarHiderToggle"
        toggle.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show hidden menu bar items")
        toggle.button?.target = self
        toggle.button?.action = #selector(clicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggle.button?.toolTip = "Hidden menu bar items · ⌘-drag an item left of the divider to hide it · ⌥-click shows all · right-click for options"
        let divider = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        divider.autosaveName = "AOMMenuBarHiderDivider"
        divider.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Menu Bar Hider divider")
        divider.button?.imageScaling = .scaleProportionallyDown
        divider.button?.appearsDisabled = true
        divider.button?.toolTip = "Items left of this line hide"
        self.toggle = toggle
        self.divider = divider
        if Self.alwaysSectionOn { addAlwaysDivider() }
        isCollapsed = false
        updateAppearance()
        if UserDefaults.standard.bool(forKey: Self.usedKey) {
            let work = DispatchWorkItem { [weak self] in self?.collapse(quiet: true) }
            startCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        } else {
            GestureHUD.shared.show(title: "Menu Bar Hider", detail: "⌘-drag the items to hide left of the new divider, then click the chevron.")
        }
    }

    /// The chevron's picture and VoiceOver text always follow the real state.
    private func updateAppearance() {
        toggle?.button?.image = isCollapsed
            ? NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show hidden menu bar items")
            : NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Hide menu bar items")
        toggle?.button?.setAccessibilityLabel(isCollapsed ? "Show hidden menu bar items" : "Hide menu bar items")
    }

    func stop() {
        startCollapse?.cancel()
        startCollapse = nil
        cancelRehide()
        visibilityCheck?.cancel()
        for item in [toggle, divider, always].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        always = nil
        showsAll = false
        toggle = nil
        divider = nil
        isCollapsed = false
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showOptions(); return }
        if NSEvent.modifierFlags.contains(.option) { expand(all: true); return }
        if isCollapsed { expand() } else { collapse() }
    }

    // MARK: Always-hidden section (Codex M04)

    /// Pure: the two lengths for a state. Collapsed: the first divider
    /// pushes everything left of it away (the second goes with it).
    /// Expanded: the second divider pushes its side away. All: both narrow.
    static func lengths(collapsed: Bool, showsAll: Bool, hasAlways: Bool) -> (divider: CGFloat, always: CGFloat?) {
        guard hasAlways else { return (collapsed ? collapsedLength : dividerLength, nil) }
        if collapsed { return (collapsedLength, dividerLength) }
        return (dividerLength, showsAll ? dividerLength : collapsedLength)
    }

    /// Pure: the second divider works only while it sits left of the first,
    /// which sits left of the chevron.
    static func canUseAlways(alwaysMinX: CGFloat?, dividerMinX: CGFloat?, toggleMinX: CGFloat?) -> Bool {
        guard let alwaysMinX, let dividerMinX, let toggleMinX else { return false }
        return alwaysMinX < dividerMinX && dividerMinX < toggleMinX
    }

    private func addAlwaysDivider() {
        guard always == nil else { return }
        // A new item lands left of AOM's existing ones; its position is remembered.
        let item = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        item.autosaveName = "AOMMenuBarHiderAlways"
        item.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Always-hidden divider")
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.appearsDisabled = true
        item.button?.alphaValue = 0.55
        item.button?.toolTip = "Items left of this fainter line stay hidden until you ⌥-click the chevron"
        always = item
    }

    func setAlwaysSection(_ on: Bool) {
        Self.alwaysSectionOn = on
        if on {
            addAlwaysDivider()
            // Both dividers show, held open, so the new one can be ⌘-dragged (Gemini 7.6).
            expand(all: true, holdOpen: true)
            GestureHUD.shared.show(title: "Always-Hidden Section", detail: "⌘-drag items left of the new fainter divider; they stay hidden until you ⌥-click the chevron. Click the chevron when you're done.")
        } else {
            if let always { NSStatusBar.system.removeStatusItem(always) }
            always = nil
            apply()
        }
    }

    private func showOptions() {
        let menu = NSMenu()
        let section = NSMenuItem(title: "Always-Hidden Section", action: #selector(toggleAlwaysSection), keyEquivalent: "")
        section.target = self
        section.state = Self.alwaysSectionOn ? .on : .off
        menu.addItem(section)
        let all = NSMenuItem(title: "Show Everything (⌥-Click)", action: #selector(showEverything), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        let hold = NSMenuItem(title: "Keep Open Until I Click", action: #selector(keepOpen), keyEquivalent: "")
        hold.target = self
        hold.isEnabled = !isCollapsed
        menu.addItem(hold)
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Menu Bar…", action: #selector(openManagement), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Hide Again After", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for seconds in [0.0, 10, 15, 30, 60] {
            let entry = NSMenuItem(title: seconds == 0 ? "Never" : "\(Int(seconds)) Seconds", action: #selector(pickRehide(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = seconds
            entry.state = Self.rehideSeconds == seconds ? .on : .off
            menu.addItem(entry)
        }
        toggle?.menu = menu
        toggle?.button?.performClick(nil)
        toggle?.menu = nil
    }

    @objc private func toggleAlwaysSection() { setAlwaysSection(!Self.alwaysSectionOn) }
    @objc private func openManagement() { MenuBarNavigation.open() }
    @objc private func showEverything() { expand(all: true) }
    @objc private func keepOpen() { cancelRehide() }
    @objc private func pickRehide(_ sender: NSMenuItem) { setRehideSeconds(sender.representedObject as? Double ?? 15) }

    func setRehideSeconds(_ seconds: Double) {
        Self.rehideSeconds = seconds
        if !isCollapsed { expand(all: showsAll) } // update the active timeout too
    }

    /// Sets both lengths for the state, then checks the chevron is still on a
    /// display; if the second section pushed it off, that section is turned
    /// off and the menu bar goes back to one section.
    private func apply() {
        guard let divider else { return }
        var hasAlways = always != nil
        if hasAlways, !isCollapsed, !showsAll,
           !Self.canUseAlways(alwaysMinX: always?.button?.window?.frame.minX, dividerMinX: divider.button?.window?.frame.minX,
                              toggleMinX: toggle?.button?.window?.frame.minX) {
            hasAlways = false
            GestureHUD.shared.show(title: "Always-Hidden Section", detail: "⌘-drag the fainter divider left of the first one; until then everything shows.")
        }
        let lengths = Self.lengths(collapsed: isCollapsed, showsAll: showsAll, hasAlways: hasAlways)
        divider.length = lengths.divider
        divider.button?.image = lengths.divider == Self.collapsedLength ? nil
            : NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Menu Bar Hider divider")
        if let always {
            always.length = lengths.always ?? Self.dividerLength
            always.button?.image = always.length == Self.collapsedLength ? nil
                : NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Always-hidden divider")
        }
        updateAppearance()
        visibilityCheck?.cancel()
        guard always != nil, lengths.always == Self.collapsedLength else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.always != nil, !self.isCollapsed, !self.showsAll else { return }
            guard !Self.chevronVisible(self.toggle?.button?.window) else { return }
            self.setAlwaysSection(false)
            GestureHUD.shared.show(title: "Always-Hidden Section Off", detail: "On this display it pushed the chevron off the menu bar, so AOM went back to one section.")
        }
        visibilityCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    /// The chevron is on its own display's menu bar and not behind the notch.
    private static func chevronVisible(_ window: NSWindow?) -> Bool {
        guard let window, let screen = window.screen else { return false }
        let frame = window.frame
        guard screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        if let notch = GestureHUD.notchRect(screen), notch.intersects(frame) { return false }
        return true
    }

    /// Pure: collapsing is safe only while the divider sits left of the
    /// chevron; otherwise widening it would push the chevron away too.
    static func canCollapse(dividerMinX: CGFloat?, toggleMinX: CGFloat?) -> Bool {
        guard let dividerMinX, let toggleMinX else { return false }
        return dividerMinX < toggleMinX
    }

    func collapse(quiet: Bool = false) {
        startCollapse = nil
        guard let toggle, let divider, !isCollapsed else { return }
        let dividerX = divider.button?.window?.frame.minX
        let toggleX = toggle.button?.window?.frame.minX
        guard Self.canCollapse(dividerMinX: dividerX, toggleMinX: toggleX) else {
            if !quiet || dividerX != nil {
                GestureHUD.shared.show(title: "Menu Bar Hider", detail: "⌘-drag the divider back to the left of the chevron, then click the chevron.")
            }
            updateAppearance()
            return
        }
        cancelRehide()
        UserDefaults.standard.set(true, forKey: Self.usedKey)
        isCollapsed = true
        showsAll = false
        apply()
        _ = divider
    }

    func expand(all: Bool = false, holdOpen: Bool = false) {
        guard toggle != nil, divider != nil else { return }
        startCollapse?.cancel()
        startCollapse = nil
        isCollapsed = false
        showsAll = all
        apply()
        cancelRehide()
        if holdOpen { return }
        let seconds = Self.rehideSeconds
        guard seconds > 0 else { return }
        rehideDeadline = ProcessInfo.processInfo.systemUptime + seconds
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarHider.shared.tickRehide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rehideTimer = timer
    }

    private func cancelRehide() {
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    /// Hides again once the countdown ran out with nobody using the menu bar:
    /// the pointer on it, a menu open (theirs or another app's) or a mouse
    /// button held (a ⌘-drag) restart it from the full time.
    private func tickRehide() {
        guard !isCollapsed, toggle != nil else { cancelRehide(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let busy = MenuBarRehidePolicy.isBusy(pointerInMenuBar: Self.pointerInMenuBar(),
                                               menuOpen: Self.menuIsOpen(),
                                               buttonsDown: NSEvent.pressedMouseButtons != 0)
        rehideDeadline = MenuBarRehidePolicy.deadline(now: now, current: rehideDeadline, busy: busy, seconds: Self.rehideSeconds)
        if MenuBarRehidePolicy.shouldCollapse(now: now, deadline: rehideDeadline, busy: busy) {
            cancelRehide()
            collapse()
        }
    }

    private static func pointerInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return point.y >= screen.frame.maxY - height
    }

    /// Any app's menu on screen (menus sit at the pop-up menu window level).
    private static func menuIsOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == level }
    }
}

/// Pure (Codex HB-01): when the shown items hide again.
enum MenuBarRehidePolicy {
    static func isBusy(pointerInMenuBar: Bool, menuOpen: Bool, buttonsDown: Bool) -> Bool {
        pointerInMenuBar || menuOpen || buttonsDown
    }

    /// While busy the countdown restarts from the full time.
    static func deadline(now: TimeInterval, current: TimeInterval, busy: Bool, seconds: Double) -> TimeInterval {
        busy ? max(current, now + seconds) : current
    }

    static func shouldCollapse(now: TimeInterval, deadline: TimeInterval, busy: Bool) -> Bool {
        !busy && now >= deadline
    }
}
