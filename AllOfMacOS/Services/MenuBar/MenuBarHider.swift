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
    fileprivate(set) var isCollapsed = false
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

    /// 7.10: macOS 27 — hide through macOS's own restriction, by app
    /// section (`MenuBarNativeHiding`); the long divider is for older systems.
    private(set) var native = false

    /// Pointer on the menu bar, any menu or menu-bar popover open, or a
    /// button held.
    static func isMenuBarBusy() -> Bool {
        // Cheapest first: the window list is read only when nothing else says busy.
        NSEvent.pressedMouseButtons != 0 || pointerInMenuBar() || menuIsOpen()
    }

    func start() {
        guard toggle == nil else { return }
        native = MenuBarNativeHiding.isAvailable
        // 7.10: Bartender's click / scroll / hover on empty menu bar space —
        // started once ❮ exists (Gemini 7.10: before it, nothing was installed).
        defer { MenuBarTriggers.shared.start() }
        if native { startNative(); return }
        // Items are added right to left, so the chevron comes first and the
        // divider lands on its left.
        let toggle = makeToggle(tip: "Hidden menu bar items · ⌘-drag an item left of the divider to hide it · ⌥-click shows all · right-click for options")
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
            let work = DispatchWorkItem { [weak self] in
                guard !MenuBarTriggers.shared.wideHold else { return }
                self?.collapse(quiet: true)
            }
            startCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        } else {
            GestureHUD.shared.show(title: "Menu Bar Hider", detail: "⌘-drag the items to hide left of the new divider, then click the chevron.")
        }
    }

    private func startNative() {
        toggle = makeToggle(tip: "Hidden menu bar icons · click to show or hide · ⌥-click shows all · right-click for options")
        // Know where the clock and every icon are without opening Settings
        // (the clock hand-off and item hotkeys need them; Gemini 7.10).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let model = MenuBarLayoutModel.shared
            if AXIsProcessTrusted(), model.items.isEmpty { model.refresh(quietly: true, reveal: false) }
        }
        isCollapsed = false
        updateAppearance()
        if UserDefaults.standard.bool(forKey: Self.usedKey) {
            let work = DispatchWorkItem { [weak self] in
                guard !MenuBarTriggers.shared.wideHold else { return }
                self?.collapse(quiet: true)
            }
            startCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    /// The chevron both hiding methods share.
    private func makeToggle(tip: String) -> NSStatusItem {
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "AOMMenuBarHiderToggle"
        toggle.button?.target = self
        toggle.button?.action = #selector(clicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggle.button?.toolTip = tip
        installHover(on: toggle.button)
        return toggle
    }

    fileprivate func checkChevronSurvived() {
        guard native, isCollapsed, MenuBarNativeHiding.shared.isHolding else { return }
        // A full-screen app or "automatically hide the menu bar" moves ❮ off
        // screen too; look again once the menu bar is back (Gemini 7.10).
        if let screen = NSScreen.screens.first, screen.visibleFrame.maxY >= screen.frame.maxY - 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MenuBarHider.shared.checkChevronSurvived() }
            return
        }
        guard !Self.chevronVisible(toggle?.button?.window) else { return }
        MenuBarNativeHiding.shared.release()
        isCollapsed = false
        updateAppearance()
        GestureHUD.shared.show(title: "Menu Bar", detail: "macOS hid AOM's own ❮ as well, so everything is shown again. Keep All of MacOS in /Applications.")
    }

    /// The sections hidden in each state (native).
    private var nativeHiddenSections: Set<MenuBarSection> {
        if isCollapsed { return [.hidden, .alwaysHidden] }
        return showsAll ? [] : [.alwaysHidden]
    }

    /// Re-applies the current state after a section changed in Settings.
    func reapply() {
        guard native, toggle != nil else { return }
        MenuBarNativeHiding.shared.hide(nativeHiddenSections)
    }

    /// The chevron's picture and VoiceOver text always follow the real state.
    fileprivate func updateAppearance() {
        let symbols = MenuBarPrefs.toggleIcon.symbols
        let image = isCollapsed
            ? NSImage(systemSymbolName: symbols.collapsed, accessibilityDescription: "Show hidden menu bar items")
            : NSImage(systemSymbolName: symbols.expanded, accessibilityDescription: "Hide menu bar items")
        // The dot is drawn smaller, like Bartender's own icon choices.
        toggle?.button?.image = MenuBarPrefs.toggleIcon == .dot
            ? image?.withSymbolConfiguration(.init(pointSize: 7, weight: .regular)) : image
        toggle?.button?.setAccessibilityLabel(isCollapsed ? "Show hidden menu bar items" : "Hide menu bar items")
    }

    func stop() {
        MenuBarTriggers.shared.stop()
        arrangingBefore = nil
        startCollapse?.cancel()
        startCollapse = nil
        hoverWork?.cancel()
        hoverWork = nil
        inspection = nil
        cancelRehide()
        visibilityCheck?.cancel()
        if native { MenuBarNativeHiding.shared.release() }
        for item in [toggle, divider, always].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        always = nil
        showsAll = false
        toggle = nil
        divider = nil
        isCollapsed = false
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showOptions(); return }
        // 7.9 (Bartender Bar): the hidden icons can open in a bar below instead;
        // ⌥ brings the Always Hidden ones too, in either place.
        let option = NSEvent.modifierFlags.contains(.option)
        if MenuBarStripController.shared.isVisible { MenuBarStripController.shared.dismiss(); return }
        if isCollapsed { revealFromTrigger(includeAlways: option); return }
        if option, !showsAll { expand(all: true); return }
        collapse()
    }

    /// Icon picture or hover choice changed in Settings.
    func refreshAppearance() { updateAppearance() }

    /// Brings one item into view, then runs `then` (Bartender's "show and
    /// click"): on macOS 27 only its app is let back for a while; otherwise
    /// its section shows (Always Hidden needs Show All) on the rehide timer.
    func reveal(_ item: AOMMenuShelfItem, section: MenuBarSection, then: @escaping @MainActor () -> Void) {
        if native, section != .shown, MenuBarNativeHiding.shared.isHolding {
            MenuBarNativeHiding.shared.showTemporarily(item.ownerBundleID) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { MainActor.assumeIsolated { then() } }
            }
            return
        }
        let needed = isRunning && ((section == .hidden && isCollapsed)
            || (section == .alwaysHidden && (isCollapsed || !showsAll)))
        if needed { expand(all: section == .alwaysHidden) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (needed ? 0.35 : 0)) { MainActor.assumeIsolated { then() } }
    }

    // MARK: 7.10 — Bartender's triggers

    /// A click on empty menu bar space: show if hidden, hide if shown.
    func toggleFromTrigger() {
        if MenuBarStripController.shared.isVisible { MenuBarStripController.shared.dismiss(); return }
        if isCollapsed { revealFromTrigger() } else { hideFromTrigger() }
    }

    /// Shows the hidden icons where the settings say: in the menu bar, or in
    /// the Bar — also when the menu bar has no room for them (Bartender:
    /// "the Bar will show these items instead").
    func revealFromTrigger(includeAlways: Bool = false) {
        guard isRunning else { return }
        // Already showing the Hidden ones: Show All adds Always Hidden (Gemini 7.10).
        if !isCollapsed { if includeAlways, !showsAll { expand(all: true) }; return }
        if Self.revealMode == .bar || (MenuBarPrefs.barWhenNoRoom && !hasRoomForHidden(includeAlways: includeAlways)) {
            MenuBarStripController.shared.show(includeAlways: includeAlways)
            return
        }
        expand(all: includeAlways)
    }

    func hideFromTrigger() {
        if MenuBarStripController.shared.isVisible { MenuBarStripController.shared.dismiss() }
        guard isRunning, !isCollapsed, !MenuBarTriggers.shared.wideHold else { return }
        collapse()
    }

    /// The hidden icons fit between the app's menus (or the notch) and the
    /// icons already shown. Widths come from the last read of the menu bar.
    func hasRoomForHidden(includeAlways: Bool) -> Bool {
        let model = MenuBarLayoutModel.shared
        guard let screen = NSScreen.main, !model.items.isEmpty else { return true }
        func width(_ entry: MenuBarLayoutItem) -> CGFloat {
            max(18, entry.item.frame?.width ?? model.images[entry.imageKey]?.size.width ?? 28)
        }
        let lanes = model.lanes
        let hidden = ((lanes[.hidden] ?? []) + (includeAlways ? lanes[.alwaysHidden] ?? [] : [])).reduce(0) { $0 + width($1) }
        let shown = (lanes[.shown] ?? []).reduce(0) { $0 + width($1) } + 30
        let available: CGFloat
        if let notch = GestureHUD.notchRect(screen) {
            available = screen.frame.maxX - notch.maxX
        } else {
            available = screen.frame.width - MenuBarAppMenus.maxX(on: screen)
        }
        return MenuBarTriggerPolicy.hasRoom(hiddenWidth: hidden, shownWidth: shown, available: available)
    }

    /// ⌘ pressed on the menu bar: every section shows while icons are dragged
    /// ("When ⌘+dragging menu bar items, show all sections").
    private var arrangingBefore: (collapsed: Bool, showsAll: Bool)?

    func showAllForArranging() {
        guard isRunning, arrangingBefore == nil, isCollapsed || !showsAll else { return }
        arrangingBefore = (isCollapsed, showsAll)
        expand(all: true, holdOpen: true)
    }

    func endArranging() {
        guard let before = arrangingBefore else { return }
        // Still dragging, or a menu is open: try again shortly.
        if NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MenuBarHider.shared.endArranging() }
            return
        }
        arrangingBefore = nil
        if before.collapsed { collapse(quiet: true) } else { expand(all: before.showsAll) }
        MenuBarLayoutModel.shared.refresh(quietly: true, reveal: false)
    }

    // MARK: 7.9 — Bartender Bar, hover, layout inspection

    enum RevealMode: String, CaseIterable, Identifiable {
        /// Hidden Bar: the items come back in the menu bar.
        case menuBar
        /// Bartender Bar: they show in a bar under the menu bar.
        case bar
        var id: String { rawValue }
        var title: String { self == .menuBar ? "In the menu bar" : "In a bar below" }
    }

    static let revealModeKey = "AOMMenuBarHider.revealMode"
    static var revealMode: RevealMode {
        get { RevealMode(rawValue: UserDefaults.standard.string(forKey: revealModeKey) ?? "") ?? .menuBar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: revealModeKey) }
    }

    /// Hover reveal (on ❮ or on empty menu bar space) — one setting, in `MenuBarPrefs`.
    static var hoverReveal: Bool {
        get { MenuBarPrefs.showOnHover }
        set { MenuBarPrefs.showOnHover = newValue; MenuBarTriggers.shared.reconfigure() }
    }

    /// "Hide again after" choices, shared by Settings and ❮'s menu.
    static let rehideChoices: [Double] = [0, 5, 10, 15, 30, 60]

    var isRunning: Bool { toggle != nil }
    /// Whether macOS draws the chevron now (the self-test checks AOM's own ❮ survives a hide).
    var chevronOnScreen: Bool { toggle?.button?.window?.occlusionState.contains(.visible) ?? false }
    /// The chevron's window (AppKit coordinates), to put the bar under it.
    var toggleWindowFrame: CGRect? { toggle?.button?.window?.frame }
    var hasAlwaysSection: Bool { always != nil }

    /// Where AOM's own items are, in Accessibility coordinates (top-left).
    func axFrames() -> (toggle: CGRect?, divider: CGRect?, always: CGRect?) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        func ax(_ item: NSStatusItem?) -> CGRect? {
            guard let frame = item?.button?.window?.frame, frame.width > 0 else { return nil }
            return MenuBarStripPolicy.axRect(frame, primaryHeight: height)
        }
        return (ax(toggle), ax(divider), ax(always))
    }

    /// The layout page reads every item: show all for a moment, then put
    /// the menu bar back as it was (`endInspection`).
    private var inspection: (collapsed: Bool, showsAll: Bool)?
    func revealForInspection() {
        guard isRunning else { return }
        if inspection == nil { inspection = (isCollapsed, showsAll) }
        if native { MenuBarNativeHiding.shared.release(); return }
        expand(all: true, holdOpen: true)
    }

    /// Back to how it was: hidden again, or shown with its timer running.
    func endInspection() {
        guard let before = inspection else { return }
        inspection = nil
        if native { MenuBarNativeHiding.shared.hide(nativeHiddenSections); return }
        if before.collapsed { collapse(quiet: true) } else { expand(all: before.showsAll) }
    }

    private var hoverWork: DispatchWorkItem?

    /// Hovering over the chevron for a moment reveals (Hidden Bar, Bartender).
    @objc(mouseEntered:) func hoverEntered(_ event: NSEvent) {
        guard Self.hoverReveal, isCollapsed else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCollapsed else { return }
            MenuBarTriggers.shared.revealByHover()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarPrefs.hoverShowDelay, execute: work)
    }

    @objc(mouseExited:) func hoverExited(_ event: NSEvent) {
        hoverWork?.cancel()
        hoverWork = nil
    }

    private func installHover(on button: NSStatusBarButton?) {
        guard let button else { return }
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: nil))
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

    func setAlwaysSection(_ on: Bool, announce: Bool = true) {
        Self.alwaysSectionOn = on
        // Native: the Always Hidden lane is a section apps are put in, no divider.
        if native { reapply(); return }
        if on {
            addAlwaysDivider()
            // Both dividers show, held open, so the new one can be ⌘-dragged (Gemini 7.6).
            expand(all: true, holdOpen: true)
            if announce {
                GestureHUD.shared.show(title: "Always-Hidden Section", detail: "⌘-drag items left of the new fainter divider; they stay hidden until you ⌥-click the chevron. Click the chevron when you're done.")
            }
        } else {
            if let always { NSStatusBar.system.removeStatusItem(always) }
            always = nil
            apply()
        }
    }

    /// Right-click on ❮ (Bartender's menu bar item menu).
    private func showOptions() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, on: Bool? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(isCollapsed ? "Show Hidden Icons" : "Hide Icons", #selector(toggleShown))
        add("Show All Icons (⌥-Click)", #selector(showEverything), enabled: isCollapsed || !showsAll)
        add("Search Menu Bar Icons…", #selector(searchIcons))
        add("Keep Shown Until I Hide Them", #selector(keepOpen), enabled: !isCollapsed)
        menu.addItem(.separator())
        add("Show Hidden Icons in a Bar Below", #selector(toggleRevealMode), on: Self.revealMode == .bar)
        add("Show When Hovering Over Empty Space", #selector(toggleHover), on: Self.hoverReveal)
        add("Show When Clicking Empty Space", #selector(toggleEmptyClick), on: MenuBarPrefs.showOnEmptyClick)
        if !native { add("Always-Hidden Section", #selector(toggleAlwaysSection), on: Self.alwaysSectionOn) }
        let rehide = NSMenuItem(title: "Hide Again After", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for seconds in Self.rehideChoices {
            let entry = NSMenuItem(title: seconds == 0 ? "Never" : "\(Int(seconds)) Seconds", action: #selector(pickRehide(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = seconds
            entry.state = Self.rehideSeconds == seconds ? .on : .off
            sub.addItem(entry)
        }
        rehide.submenu = sub
        menu.addItem(rehide)
        menu.addItem(.separator())
        add("Menu Bar Settings…", #selector(openManagement))
        add("Setup Guide…", #selector(openSetup))
        toggle?.menu = menu
        toggle?.button?.performClick(nil)
        toggle?.menu = nil
    }

    @objc private func toggleShown() { if isCollapsed { revealFromTrigger() } else { collapse() } }
    @objc private func searchIcons() { AOMMenuShelfController.shared.show() }
    @objc private func toggleEmptyClick() { MenuBarPrefs.showOnEmptyClick.toggle(); MenuBarTriggers.shared.reconfigure() }
    @objc private func openSetup() { MenuBarNavigation.open(setup: true) }
    @objc private func toggleAlwaysSection() { setAlwaysSection(!Self.alwaysSectionOn) }
    @objc private func toggleRevealMode() { Self.revealMode = Self.revealMode == .bar ? .menuBar : .bar }
    @objc private func toggleHover() { Self.hoverReveal.toggle() }
    @objc private func openManagement() { MenuBarNavigation.open() }
    @objc private func showEverything() { if isCollapsed { revealFromTrigger(includeAlways: true) } else { expand(all: true) } }
    @objc private func keepOpen() { cancelRehide() }
    @objc private func pickRehide(_ sender: NSMenuItem) { setRehideSeconds(sender.representedObject as? Double ?? 15) }

    func setRehideSeconds(_ seconds: Double) {
        Self.rehideSeconds = seconds
        // Update the active timeout too — not while a wide display shows everything.
        if !isCollapsed { expand(all: showsAll, holdOpen: MenuBarTriggers.shared.wideHold) }
    }

    /// Sets both lengths for the state, then checks the chevron is still on a
    /// display; if the second section pushed it off, that section is turned
    /// off and the menu bar goes back to one section.
    private func apply() {
        if native { updateAppearance(); return }
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
        if native {
            guard toggle != nil, !isCollapsed else { return }
            cancelRehide()
            UserDefaults.standard.set(true, forKey: Self.usedKey)
            isCollapsed = true
            showsAll = false
            updateAppearance()
            MenuBarNativeHiding.shared.hide([.hidden, .alwaysHidden]) { ok in
                guard !ok else {
                    // Fail-safe (measured on 27.3): if macOS hid AOM's own ❮ too
                    // (it moves a hidden item's window off screen), nothing could
                    // bring the icons back — so show everything again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        MainActor.assumeIsolated { MenuBarHider.shared.checkChevronSurvived() }
                    }
                    return
                }
                MainActor.assumeIsolated {
                    MenuBarHider.shared.isCollapsed = false
                    MenuBarHider.shared.updateAppearance()
                    GestureHUD.shared.show(title: "Menu Bar", detail: "macOS didn't accept the hide list; everything stays shown.")
                }
            }
            if !quiet, !MenuBarSectionStore.all.values.contains(where: { $0 != .shown }) {
                GestureHUD.shared.show(title: "Nothing to Hide Yet", detail: "Drag icons to Hidden in Menu Bar › Menu Bar Items.")
            }
            return
        }
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
        guard toggle != nil, divider != nil || native else { return }
        startCollapse?.cancel()
        startCollapse = nil
        isCollapsed = false
        showsAll = all
        apply()
        if native { MenuBarNativeHiding.shared.hide(nativeHiddenSections) }
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
        guard !isCollapsed, toggle != nil, !MenuBarTriggers.shared.wideHold else { cancelRehide(); return }
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

    fileprivate static func pointerInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        return MenuBarTriggerPolicy.band(screen: screen.frame, visibleMaxY: screen.visibleFrame.maxY).contains(point)
    }

    /// Any app's menu on screen (menus sit at the pop-up menu window level),
    /// or a popover or panel hanging from the menu bar — Control Center,
    /// 1Password, Stats (Gemini 7.9: those aren't menus and were hidden under
    /// the person using them).
    fileprivate static func menuIsOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let own = Int(ProcessInfo.processInfo.processIdentifier)
        // Each display's menu bar, in window-list coordinates (Gemini 7.10:
        // popovers on a display above or below the main one were missed).
        let primary = NSScreen.screens.first?.frame.maxY ?? 0
        let bars = NSScreen.screens.map { screen in
            (top: primary - screen.frame.maxY, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        return windows.contains { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer == level { return true }
            guard layer >= Int(CGWindowLevelForKey(.floatingWindow)), (window[kCGWindowOwnerPID as String] as? Int) != own,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let top = bounds["Y"] ?? 999, height = bounds["Height"] ?? 0
            return bars.contains { MenuBarRehidePolicy.hangsFromMenuBar(top: top - $0.top, height: height, menuBarHeight: $0.height) }
        }
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

    /// Pure: a window whose top edge meets the bottom of the menu bar and is
    /// taller than the bar itself (a status item's popover or panel).
    static func hangsFromMenuBar(top: CGFloat, height: CGFloat, menuBarHeight: CGFloat) -> Bool {
        top >= menuBarHeight - 2 && top <= menuBarHeight + 14 && height > menuBarHeight + 16
    }
}
