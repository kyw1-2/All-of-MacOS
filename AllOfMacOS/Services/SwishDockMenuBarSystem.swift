import AppKit
import ApplicationServices

// The menu bar's parts and two system services the Dock and menu-bar
// gestures use (3.3.3): what lies under a point of the menu bar, scrolling
// the front window to the top, and the macOS app switcher (⌘-Tab).

/// Where on the menu bar a point lies. Swish: "Menubar gestures work on the
/// empty area between menu and icons", and "You can also invoke gestures on
/// the app's menu, right next to the  symbol".
enum MenuBarSpot: Equatable {
    /// Between the menus and the status items, or past them.
    case empty
    /// The frontmost app's own menu: its name, next to the Apple menu.
    case appMenu(pid_t)
    /// The Apple menu or another of the frontmost app's menus.
    case menuTitle
    /// A status item (menu extra) of any app, AOM's own included.
    case statusItem
    /// No answer in time, or no Accessibility: the 3.3.2 behaviour (the empty area).
    case unknown
}

/// Tells the menu bar's parts apart. On macOS 27 the window server draws the
/// whole menu bar, status items included, in one window (observed on 27.2:
/// one "Menubar" window at layer 24 and no status-item windows), so only
/// Accessibility knows: the menu titles are AXMenuBarItems of the frontmost
/// app, each status item an AXMenuBarItem with the subrole AXMenuExtra of the
/// app that owns it (MenuBarAgent for the system's), and the empty area the
/// frontmost app's AXMenuBar itself. Only the system-wide element hit-tests
/// across those owners, so the request runs on a background queue and main
/// waits for it at most `wait`; two fingers landing in the top band start it
/// early (`prefetch`). Its timeout is never set: on the system-wide element
/// that would be the timeout of every Accessibility call in AOM (AXUIElement.h).
enum MenuBarProbe {
    /// Pure: what the element a hit-test found means. `index`: the item's
    /// place among its menu bar's items (0 the Apple menu, 1 the app's menu).
    static func classify(role: String?, subrole: String?, owner: pid_t, frontmost: pid_t?, index: Int?) -> MenuBarSpot {
        if subrole == "AXMenuExtra" { return .statusItem }
        switch role {
        case "AXMenuBarItem":
            guard let frontmost, owner == frontmost, index == 1 else { return .menuTitle }
            return .appMenu(owner)
        case nil:
            return .unknown
        default:
            // The frontmost app's AXMenuBar between its items, or nothing of
            // the menu bar's at all (a hidden menu bar over the desktop).
            return .empty
        }
    }

    /// One hit-test, answered from the background queue.
    private final class Request: @unchecked Sendable {
        let point: CGPoint
        let started: TimeInterval
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: MenuBarSpot?

        init(point: CGPoint, started: TimeInterval) {
            self.point = point
            self.started = started
        }

        var answer: MenuBarSpot? {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func finish(_ spot: MenuBarSpot) {
            lock.lock()
            value = spot
            lock.unlock()
            done.signal()
        }
    }

    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.menubar-probe", qos: .userInteractive)
    @MainActor private static var latest: Request?

    /// Starts the hit-test for an AppKit point, so `spot(at:)` finds it done.
    @MainActor static func prefetch(at point: CGPoint) {
        _ = request(at: point)
    }

    /// The part of the menu bar under an AppKit point; `.unknown` when the
    /// hit-test has not answered within `wait`.
    @MainActor static func spot(at point: CGPoint, wait: TimeInterval = 0.12) -> MenuBarSpot {
        let request = request(at: point)
        if let answer = request.answer { return answer }
        guard request.done.wait(timeout: .now() + wait) == .success else { return .unknown }
        request.done.signal()
        return request.answer ?? .unknown
    }

    @MainActor private static func request(at point: CGPoint) -> Request {
        let now = ProcessInfo.processInfo.systemUptime
        if let latest, hypot(latest.point.x - point.x, latest.point.y - point.y) <= 6, now - latest.started < 1 {
            return latest
        }
        let request = Request(point: point, started: now)
        latest = request
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let target = CGPoint(x: point.x, y: top - point.y)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async { request.finish(hitTest(target, frontmost: frontmost)) }
        return request
    }

    /// The hit-test itself (Accessibility coordinates), off the main thread.
    private static func hitTest(_ point: CGPoint, frontmost: pid_t?) -> MenuBarSpot {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return .unknown }
        // Later requests go to the element found, each bounded.
        AXUIElementSetMessagingTimeout(hit, 0.2)
        var owner: pid_t = 0
        AXUIElementGetPid(hit, &owner)
        let role = AX.string(hit, kAXRoleAttribute)
        let subrole = AX.string(hit, kAXSubroleAttribute)
        var index: Int?
        if role == "AXMenuBarItem", subrole != "AXMenuExtra", let parent = AX.element(hit, kAXParentAttribute) {
            AXUIElementSetMessagingTimeout(parent, 0.2)
            index = AX.children(parent).firstIndex { CFEqual($0, hit) }
        }
        return classify(role: role, subrole: subrole, owner: owner, frontmost: frontmost, index: index)
    }
}

/// Swish's menubarScrollToTop (an identifier in Swish 1.13 that its settings
/// never show): the front window's main scroll area back to the top, through
/// Accessibility: its vertical scroll bar's value set to 0. Nothing is typed,
/// so the selection and the insertion point stay where they are.
enum ScrollToTop {
    enum Outcome: Equatable { case scrolled, alreadyAtTop, noScrollArea, failed }

    /// Pure: which of the scroll areas (Accessibility frames) to scroll: the
    /// largest whose column holds the pointer, else the largest.
    static func choose(_ frames: [CGRect], pointerX: CGFloat?) -> Int? {
        func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
        let indices = Array(frames.indices)
        if let x = pointerX,
           let best = indices.filter({ frames[$0].minX <= x && x <= frames[$0].maxX })
            .max(by: { area(frames[$0]) < area(frames[$1]) }) {
            return best
        }
        return indices.max { area(frames[$0]) < area(frames[$1]) }
    }

    /// The focused window of `pid`: its scroll areas found breadth-first
    /// (each request 0.2 s, all of it `budget`, at most 300 elements), the
    /// chosen one's vertical scroll bar set to 0.
    @MainActor static func scrollFocusedWindow(of pid: pid_t, pointerX: CGFloat?, budget: TimeInterval = 0.4) -> Outcome {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return .failed }
        let limit = AXDeadline(perRequest: 0.2, budget: budget)
        let app = AXUIElementCreateApplication(pid)
        guard limit.allow(app),
              let window = AX.element(app, kAXFocusedWindowAttribute) ?? (limit.allow(app) ? AX.element(app, kAXMainWindowAttribute) : nil)
        else { return .failed }
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var areas: [(bar: AXUIElement, frame: CGRect)] = []
        var visited = 0
        while !queue.isEmpty, visited < 300, !limit.isSpent {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard limit.allow(element), let role = AX.string(element, kAXRoleAttribute) else { continue }
            if role == kAXScrollAreaRole as String {
                if limit.allow(element), let bar = AX.element(element, kAXVerticalScrollBarAttribute),
                   let frame = frame(of: element, limit: limit) {
                    areas.append((bar, frame))
                }
                continue   // what a scroll area holds is its content
            }
            guard depth < 10, limit.allow(element) else { continue }
            queue.append(contentsOf: AX.children(element).prefix(48).map { (element: $0, depth: depth + 1) })
        }
        guard let pick = choose(areas.map(\.frame), pointerX: pointerX) else { return .noScrollArea }
        let bar = areas[pick].bar
        AXUIElementSetMessagingTimeout(bar, 0.25)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &value) == .success,
           let number = value as? NSNumber, number.doubleValue <= 0.0001 {
            return .alreadyAtTop
        }
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: 0.0)) == .success
            ? .scrolled : .failed
    }

    private static func frame(of element: AXUIElement, limit: AXDeadline) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard limit.allow(element), AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              limit.allow(element), AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
            return nil
        }
        return CGRect(origin: origin, size: extent)
    }
}

/// Swish's "Tap, hold and scroll to invoke the ⌘-tab app switcher": AOM holds
/// a synthetic ⌘ for the touch and steps with Tab (⇧Tab back); lifting lets
/// ⌘ go, which takes the selection, and a cancel presses Escape first. The
/// events are tagged so AOM's own monitors ignore them, and posted at the HID
/// tap like the Space shortcut.
enum AppSwitcherKeys {
    private static let command: UInt16 = 55
    private static let tab: UInt16 = 48
    private static let escape: UInt16 = 53

    /// ⌘ down, then Tab: macOS shows its app switcher with the next app selected.
    static func begin() -> Bool {
        guard ActionPermissions.canPostEvents, commandKey(down: true) else { return false }
        return SyntheticInput.key(tab, flags: .maskCommand, tap: .cghidEventTap)
    }

    /// Tab (forward) or ⇧Tab (back), ⌘ still held.
    @discardableResult
    static func step(forward: Bool) -> Bool {
        SyntheticInput.key(tab, flags: forward ? .maskCommand : [.maskCommand, .maskShift], tap: .cghidEventTap)
    }

    /// Lets ⌘ go: the switcher takes its selection, or, without `commit`,
    /// Escape closes it first and nothing switches.
    static func end(commit: Bool) {
        if !commit { _ = SyntheticInput.key(escape, flags: .maskCommand, tap: .cghidEventTap) }
        _ = commandKey(down: false)
    }

    private static func commandKey(down: Bool) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: down) else { return false }
        event.type = .flagsChanged
        event.flags = down ? .maskCommand : []
        return SyntheticInput.post(event, tap: .cghidEventTap)
    }
}
