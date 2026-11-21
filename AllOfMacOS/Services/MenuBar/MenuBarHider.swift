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
    private(set) var isCollapsed = false
    private var rehide: DispatchWorkItem?

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
        toggle.button?.toolTip = "Hidden menu bar items · ⌘-drag an item left of the divider to hide it"
        let divider = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        divider.autosaveName = "AOMMenuBarHiderDivider"
        divider.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Menu Bar Hider divider")
        divider.button?.imageScaling = .scaleProportionallyDown
        divider.button?.appearsDisabled = true
        divider.button?.toolTip = "Items left of this line hide"
        self.toggle = toggle
        self.divider = divider
        if UserDefaults.standard.bool(forKey: Self.usedKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.collapse() }
        } else {
            toggle.button?.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Hide menu bar items")
            GestureHUD.shared.show(title: "Menu Bar Hider", detail: "⌘-drag the items to hide left of the new divider, then click the chevron.")
        }
    }

    func stop() {
        rehide?.cancel()
        for item in [toggle, divider].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        toggle = nil
        divider = nil
        isCollapsed = false
    }

    @objc private func clicked() {
        if isCollapsed { expand() } else { collapse() }
    }

    /// Pure: collapsing is safe only while the divider sits left of the
    /// chevron; otherwise widening it would push the chevron away too.
    static func canCollapse(dividerMinX: CGFloat?, toggleMinX: CGFloat?) -> Bool {
        guard let dividerMinX, let toggleMinX else { return false }
        return dividerMinX < toggleMinX
    }

    func collapse() {
        guard let toggle, let divider, !isCollapsed else { return }
        let dividerX = divider.button?.window?.frame.minX
        let toggleX = toggle.button?.window?.frame.minX
        guard Self.canCollapse(dividerMinX: dividerX, toggleMinX: toggleX) else {
            GestureHUD.shared.show(title: "Menu Bar Hider", detail: "⌘-drag the divider back to the left of the chevron, then click the chevron.")
            return
        }
        rehide?.cancel()
        divider.length = Self.collapsedLength
        divider.button?.image = nil
        UserDefaults.standard.set(true, forKey: Self.usedKey)
        toggle.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show hidden menu bar items")
        isCollapsed = true
    }

    func expand() {
        guard let toggle, let divider else { return }
        divider.length = Self.dividerLength
        divider.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Menu Bar Hider divider")
        toggle.button?.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Hide menu bar items")
        isCollapsed = false
        rehide?.cancel()
        let seconds = Self.rehideSeconds
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        rehide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
