import XCTest
import AppKit
@testable import AllOfMacOS

// Swish's Dock and menu-bar gestures (3.3.2). The pure parts — the state
// machine, Dock item matching, the newest-first unminimize stack and the app
// walk — run in `SwishParityTests`; the menu-bar and Dock actions run through
// the shared service in `PortedFeatureTests` against a fake desktop, so no
// real window, app or display is ever touched.

/// Two fingers centred on (x, y) in TouchPoint's pad units (y grows toward
/// the top of the pad), `spread` apart.
private func two(_ x: Float, _ y: Float, spread: Float = 0.12) -> [TouchPoint] {
    [TouchPoint(id: 1, x: x - spread / 2, y: y, size: 0.1), TouchPoint(id: 2, x: x + spread / 2, y: y, size: 0.1)]
}

// MARK: - Pure

extension SwishParityTests {
    func testUtilityTapsAndDoubleTaps() {
        var recognizer = UtilityGestureRecognizer()
        XCTAssertNil(recognizer.feed(two(0.5, 0.5), at: 0))
        XCTAssertEqual(recognizer.feed([], at: 0.10), .tap)
        XCTAssertNil(recognizer.feed(two(0.5, 0.5), at: 0.22))
        XCTAssertEqual(recognizer.feed([], at: 0.30), .doubleTap, "second lift 0.2 s after the first")
        XCTAssertNil(recognizer.feed(two(0.5, 0.5), at: 0.40))
        XCTAssertEqual(recognizer.feed([], at: 0.45), .tap, "a third tap starts over")
        // Too slow to be a tap (0.18 s), and taps 0.5 s apart stay single.
        XCTAssertNil(recognizer.feed(two(0.5, 0.5), at: 5))
        XCTAssertNil(recognizer.feed([], at: 5.25))
        _ = recognizer.feed(two(0.5, 0.5), at: 10)
        XCTAssertEqual(recognizer.feed([], at: 10.1), .tap)
        _ = recognizer.feed(two(0.5, 0.5), at: 10.5)
        XCTAssertEqual(recognizer.feed([], at: 10.6), .tap)
        // Travelling 0.065 of the pad is no tap; neither is one with a third finger.
        _ = recognizer.feed(two(0.5, 0.5), at: 20)
        _ = recognizer.feed(two(0.57, 0.5), at: 20.05)
        XCTAssertNil(recognizer.feed([], at: 20.1))
        _ = recognizer.feed(two(0.5, 0.5), at: 30)
        _ = recognizer.feed(two(0.5, 0.5) + [TouchPoint(id: 3, x: 0.8, y: 0.5, size: 0.1)], at: 30.03)
        XCTAssertNil(recognizer.feed([], at: 30.1))
        // A clock that went backwards never makes a double tap.
        _ = recognizer.feed(two(0.5, 0.5), at: 40)
        XCTAssertEqual(recognizer.feed([], at: 40.1), .tap)
        _ = recognizer.feed(two(0.5, 0.5), at: 39)
        XCTAssertEqual(recognizer.feed([], at: 39.1), .tap)
    }

    func testUtilityTapAndHold() {
        var recognizer = UtilityGestureRecognizer()
        var events: [UtilityGestureRecognizer.Event] = []
        var t = 0.0
        for _ in 0..<31 { if let event = recognizer.feed(two(0.5, 0.5), at: t) { events.append(event) }; t += 1.0 / 60 }
        XCTAssertEqual(events, [.holdBegan], "0.45 s still is a tap and hold")
        XCTAssertTrue(recognizer.isHeld)
        XCTAssertEqual(recognizer.feed([], at: t), .holdReleased, "lifting without moving")
        // Hold, then swipe: the swipe is held and the lift releases nothing.
        t = 10
        events = []
        for _ in 0..<31 { if let event = recognizer.feed(two(0.5, 0.5), at: t) { events.append(event) }; t += 1.0 / 60 }
        if let event = recognizer.feed(two(0.38, 0.5), at: t) { events.append(event) }
        XCTAssertEqual(events, [.holdBegan, .swipe(.left, held: true, chain: 1)])
        XCTAssertNil(recognizer.feed([], at: t + 0.05))
        // Moving after the hold without swiping is no release.
        t = 20
        for _ in 0..<31 { _ = recognizer.feed(two(0.5, 0.5), at: t); t += 1.0 / 60 }
        _ = recognizer.feed(two(0.5, 0.57), at: t)
        XCTAssertNil(recognizer.feed([], at: t + 0.05))
        // A rest shorter than the hold time is neither a hold nor a tap.
        t = 30
        for _ in 0..<20 { XCTAssertNil(recognizer.feed(two(0.5, 0.5), at: t)); t += 1.0 / 60 }
        XCTAssertNil(recognizer.feed([], at: t))
    }

    func testUtilitySwipesChainWithinOneTouch() {
        var recognizer = UtilityGestureRecognizer()
        XCTAssertNil(recognizer.feed(two(0.5, 0.5), at: 0))
        XCTAssertNil(recognizer.feed(two(0.58, 0.5), at: 0.03), "0.08 is not far enough")
        XCTAssertEqual(recognizer.feed(two(0.61, 0.51), at: 0.05), .swipe(.right, held: false, chain: 1))
        XCTAssertNil(recognizer.feed(two(0.73, 0.51), at: 0.10), "chained swipes are at least 0.15 s apart")
        XCTAssertEqual(recognizer.feed(two(0.74, 0.51), at: 0.25), .swipe(.right, held: false, chain: 2))
        XCTAssertEqual(recognizer.feed(two(0.62, 0.51), at: 0.45), .swipe(.left, held: false, chain: 3),
                       "the other way chains too")
        XCTAssertNil(recognizer.feed([], at: 0.5), "a touch that swiped is no tap")
        // TouchPoint y grows toward the top of the pad.
        _ = recognizer.feed(two(0.5, 0.5), at: 10)
        XCTAssertEqual(recognizer.feed(two(0.5, 0.62), at: 10.05), .swipe(.up, held: false, chain: 1))
        _ = recognizer.feed([], at: 10.1)
        _ = recognizer.feed(two(0.5, 0.5), at: 11)
        XCTAssertEqual(recognizer.feed(two(0.51, 0.38), at: 11.05), .swipe(.down, held: false, chain: 1))
        _ = recognizer.feed([], at: 11.1)
        // Too diagonal for a ratio of 1.6: nothing.
        _ = recognizer.feed(two(0.5, 0.5), at: 12)
        XCTAssertNil(recognizer.feed(two(0.62, 0.42), at: 12.05))
        _ = recognizer.feed([], at: 12.1)
    }

    func testUtilityPinchOutAndIn() {
        var recognizer = UtilityGestureRecognizer()
        _ = recognizer.feed(two(0.5, 0.5, spread: 0.08), at: 0)
        XCTAssertNil(recognizer.feed(two(0.5, 0.5, spread: 0.10), at: 0.03))
        XCTAssertEqual(recognizer.feed(two(0.5, 0.5, spread: 0.12), at: 0.06), .pinchOut(held: false), "1.5 × the spread")
        XCTAssertNil(recognizer.feed(two(0.5, 0.5, spread: 0.2), at: 0.09), "once per touch")
        XCTAssertNil(recognizer.feed(two(0.65, 0.5, spread: 0.2), at: 0.3), "a pinch never turns into a swipe")
        XCTAssertNil(recognizer.feed([], at: 0.35))
        // Pinch in (the Dock quit): below 0.62 of a spread of more than 0.08.
        _ = recognizer.feed(two(0.5, 0.5, spread: 0.30), at: 1)
        XCTAssertEqual(recognizer.feed(two(0.5, 0.5, spread: 0.15), at: 1.1), .pinchIn(held: false))
        _ = recognizer.feed([], at: 1.2)
        // Fingers that land close together cannot pinch in, and a swipe that
        // drifts apart is still a swipe.
        _ = recognizer.feed(two(0.5, 0.5, spread: 0.06), at: 2)
        XCTAssertNil(recognizer.feed(two(0.5, 0.5, spread: 0.03), at: 2.1))
        _ = recognizer.feed([], at: 2.2)
        _ = recognizer.feed(two(0.5, 0.5, spread: 0.10), at: 3)
        XCTAssertEqual(recognizer.feed(two(0.63, 0.5, spread: 0.14), at: 3.05), .swipe(.right, held: false, chain: 1))
        XCTAssertNil(recognizer.feed(two(0.63, 0.5, spread: 0.20), at: 3.3), "no pinch after a swipe")
        _ = recognizer.feed([], at: 3.4)
    }

    /// Swish's hold-still cancel: 2 s without moving spends the touch; with
    /// the cancel off a long rest is no tap and hold any more.
    func testUtilityHoldStillCancel() {
        var recognizer = UtilityGestureRecognizer()
        var events: [UtilityGestureRecognizer.Event] = []
        var t = 0.0
        for _ in 0...126 { if let event = recognizer.feed(two(0.5, 0.5), at: t) { events.append(event) }; t += 1.0 / 60 }
        XCTAssertEqual(events, [.holdBegan, .holdCancelled])
        XCTAssertTrue(recognizer.isSpent)
        XCTAssertNil(recognizer.feed(two(0.36, 0.5), at: t), "a spent touch swipes nothing")
        XCTAssertNil(recognizer.feed(two(0.36, 0.5, spread: 0.3), at: t + 0.05), "nor pinches")
        XCTAssertNil(recognizer.feed([], at: t + 0.1), "nor releases a hold")
        XCTAssertFalse(recognizer.isSpent, "the next touch starts fresh")
        // Moving keeps the touch alive however long it lasts.
        t = 10
        events = []
        for step in 0..<200 {
            let x: Float = step % 30 < 15 ? 0.5 : 0.52
            if let event = recognizer.feed(two(x, 0.5), at: t) { events.append(event) }
            t += 1.0 / 60
        }
        XCTAssertFalse(events.contains(.holdCancelled))
        _ = recognizer.feed([], at: t)
        // Off: the rest is harmless and the hold lapses, so the swipe is a plain one.
        recognizer.tuning.holdCancel = 0
        t = 20
        events = []
        for _ in 0...126 { if let event = recognizer.feed(two(0.5, 0.5), at: t) { events.append(event) }; t += 1.0 / 60 }
        XCTAssertEqual(events, [.holdBegan])
        XCTAssertFalse(recognizer.isHeld, "lapsed after 2 s")
        XCTAssertEqual(recognizer.feed(two(0.36, 0.5), at: t), .swipe(.left, held: false, chain: 1))
    }

    func testDockItemsMatchByBundleURLThenIdentifierThenName() {
        typealias Item = DockItemMatcher.Item
        typealias Candidate = DockItemMatcher.Candidate
        let safari = Candidate(pid: 1, name: "Safari", bundleID: "com.apple.Safari",
                               bundleURL: URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
                               isRegular: true)
        let notes = Candidate(pid: 2, name: "Notes", bundleID: "com.apple.Notes",
                              bundleURL: URL(fileURLWithPath: "/System/Applications/Notes.app"), isRegular: true)
        let otherNotes = Candidate(pid: 3, name: "Notes", bundleID: "com.example.notes",
                                   bundleURL: URL(fileURLWithPath: "/Applications/Notes.app"), isRegular: true)
        let helper = Candidate(pid: 4, name: "Mail", bundleID: "com.apple.mail.helper", bundleURL: nil, isRegular: false)
        let apps = [helper, otherNotes, notes, safari]
        var asked = 0
        func match(_ item: Item, bundleID: String? = nil) -> pid_t? {
            DockItemMatcher.match(item, in: apps) { asked += 1; return bundleID }
        }
        // The bundle URL decides, even when another app has the same name;
        // case and a trailing slash do not matter, and nothing is read from disk.
        XCTAssertEqual(match(Item(title: "Notes", url: URL(string: "file:///System/Applications/notes.app/"),
                                  subrole: "AXApplicationDockItem")), 2)
        XCTAssertEqual(asked, 0)
        // Seen through another path (Safari's cryptex): the bundle identifier.
        XCTAssertEqual(match(Item(title: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
                             bundleID: "com.apple.Safari"), 1)
        XCTAssertEqual(asked, 1)
        // No URL: the name, among regular apps only.
        XCTAssertEqual(match(Item(title: "Safari", url: nil)), 1)
        XCTAssertNil(match(Item(title: "Mail", url: nil)), "a background helper is no Dock app")
        // Folders, the Trash and minimized windows are not apps; an app that
        // is not running matches nothing.
        XCTAssertNil(match(Item(title: "Downloads", url: URL(fileURLWithPath: "/Users/me/Downloads"), subrole: "AXFolderDockItem")))
        XCTAssertNil(match(Item(title: "Trash", url: nil, subrole: "AXTrashDockItem")))
        XCTAssertNil(match(Item(title: "Notes", url: nil, subrole: "AXMinimizedWindowDockItem")))
        XCTAssertNil(match(Item(title: "Pages", url: URL(fileURLWithPath: "/Applications/Pages.app")), bundleID: "com.apple.iWork.Pages"))
    }

    func testMinimizedWindowsComeBackNewestFirst() {
        var stack = MinimizedWindowStack()
        let a = GestureWindow(id: "1:a", pid: 1), b = GestureWindow(id: "1:b", pid: 1), c = GestureWindow(id: "2:c", pid: 2)
        var minimized: Set<String> = ["1:a", "1:b", "2:c"]
        stack.push([(a, nil)], source: .dock)
        stack.push([(b, nil)], source: .dock)
        stack.push([(c, nil)], source: .dock)
        XCTAssertEqual(stack.takeNewest(of: 1) { minimized.contains($0.id) }, b, "the last one AOM minimized")
        XCTAssertEqual(stack.takeNewest(of: 1) { minimized.contains($0.id) }, a)
        XCTAssertNil(stack.takeNewest(of: 1) { minimized.contains($0.id) })
        XCTAssertEqual(stack.entries.map(\.window), [c], "other apps keep theirs")
        // Restored some other way: skipped. Minimized again: to the front.
        stack.push([(a, nil)], source: .dock)
        stack.push([(b, nil)], source: .dock)
        stack.push([(a, nil)], source: .dock)
        XCTAssertEqual(stack.entries.map(\.window), [a, b, c])
        minimized.remove("1:a")
        XCTAssertEqual(stack.takeNewest(of: 1) { minimized.contains($0.id) }, b)
        // All of an app, newest first.
        minimized = ["1:a", "1:b"]
        stack.push([(a, nil), (b, nil)], source: .dock)
        XCTAssertEqual(stack.takeAll(of: 1) { minimized.contains($0.id) }, [b, a])
        // The menu bar's batches: the newest batch with windows on this screen, then any.
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900), right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        var menu = MinimizedWindowStack()
        let w1 = GestureWindow(id: "5:1", pid: 5), w2 = GestureWindow(id: "5:2", pid: 5), w3 = GestureWindow(id: "6:3", pid: 6)
        let all: Set<String> = ["5:1", "5:2", "6:3"]
        menu.push([(w1, left), (w2, left)], source: .menuBar)
        menu.push([(w3, right)], source: .menuBar)
        menu.push([(GestureWindow(id: "7:9", pid: 7), left)], source: .dock)
        XCTAssertEqual(Set(menu.takeMenuBarBatch(on: left) { all.contains($0.id) }.map(\.id)), ["5:1", "5:2"])
        XCTAssertEqual(menu.takeMenuBarBatch(on: left) { all.contains($0.id) }, [], "the Dock's own are not the menu bar's")
        XCTAssertEqual(menu.takeMenuBarBatch(on: nil) { all.contains($0.id) }, [w3])
        // A batch the user already restored is passed over.
        var stale = MinimizedWindowStack()
        stale.push([(w1, left)], source: .menuBar)
        stale.push([(w2, left)], source: .menuBar)
        XCTAssertEqual(stale.takeMenuBarBatch(on: left) { $0.id == "5:1" }, [w1])
    }

    func testTheMenuBarAppWalkGoesBackThroughRecentApps() {
        var walk = AppCycle(frontmost: 1, recent: [3, 2, 9], running: [1, 2, 3, 4])
        XCTAssertEqual(walk.order, [1, 3, 2, 4], "frontmost, recently used, the rest; 9 quit")
        XCTAssertEqual(walk.step(previous: true), 3, "left: the app used before this one")
        XCTAssertEqual(walk.step(previous: true), 2)
        XCTAssertEqual(walk.step(previous: false), 3)
        var next = AppCycle(frontmost: 1, recent: [3], running: [1, 2, 3])
        XCTAssertEqual(next.step(previous: false), 2, "right: from the far end")
        var away = AppCycle(frontmost: 99, recent: [3], running: [1, 3])
        XCTAssertEqual(away.order, [3, 1])
        XCTAssertEqual(away.step(previous: true), 3, "AOM in front: the most recent app first")
        var empty = AppCycle(frontmost: nil, recent: [], running: [])
        XCTAssertNil(empty.step(previous: true))
        var windows = WindowCycle(pid: 1, windows: [GestureWindow(id: "a", pid: 1), GestureWindow(id: "b", pid: 1)])
        XCTAssertEqual(windows.current?.id, "a")
        XCTAssertEqual(windows.step(forward: true)?.id, "b")
        XCTAssertEqual(windows.step(forward: true)?.id, "a", "wraps")
        XCTAssertEqual(windows.step(forward: false)?.id, "b")
    }
}

// MARK: - The actions, through the service's seams

/// Everything the gestures may touch, in memory. Records what was asked.
@MainActor
private final class FakeGestureDesktop: GestureDesktop {
    var names: [pid_t: String] = [:]
    var windowsByApp: [pid_t: [GestureWindow]] = [:]
    var frames: [String: CGRect] = [:]
    var minimizedIDs = Set<String>()
    var focused: [pid_t: GestureWindow] = [:]
    var frontmost: pid_t?
    var screenList: [(frame: CGRect, visible: CGRect)] = [
        (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 25, width: 1440, height: 875)),
        (CGRect(x: 1440, y: 0, width: 1920, height: 1080), CGRect(x: 1440, y: 25, width: 1920, height: 1055))
    ]
    var pointerScreen: Int? = 0
    var cycle = AppCycle(frontmost: nil, recent: [], running: [])
    var originals: [String: CGRect] = [:]
    var cells: [String: CustomSnapZone.Layout] = [:]
    var switcherIsShowing = false
    var switcherOffset = 0
    var log: [String] = []

    func add(_ id: String, pid: pid_t, frame: CGRect, minimized: Bool = false) -> GestureWindow {
        let window = GestureWindow(id: id, pid: pid)
        windowsByApp[pid, default: []].append(window)
        frames[id] = frame
        if minimized { minimizedIDs.insert(id) }
        return window
    }

    func isFrontmost(_ pid: pid_t) -> Bool { frontmost == pid }
    func appName(_ pid: pid_t) -> String? { names[pid] }
    func activate(_ pid: pid_t) -> Bool { log.append("activate \(pid)"); frontmost = pid; return true }
    func hide(_ pid: pid_t) -> Bool { log.append("hide \(pid)"); return true }
    func hideOthers(keeping pid: pid_t) -> Bool { log.append("hideOthers \(pid)"); return true }
    func postNewWindow(to pid: pid_t) -> Bool { log.append("⌘N \(pid)"); return true }
    func appCycle() -> AppCycle { cycle }
    func showSwitcher() { log.append("switcher"); switcherIsShowing = true }
    func scrollSwitcher(by offset: Int) -> Bool {
        guard switcherIsShowing else { return false }
        switcherOffset += offset
        return true
    }
    func confirmSwitcher() { log.append("confirm \(switcherOffset)"); switcherIsShowing = false }
    func windows(of pid: pid_t) -> [GestureWindow] { windowsByApp[pid] ?? [] }
    func focusedWindow(of pid: pid_t) -> GestureWindow? { focused[pid] }
    func visibleWindows() -> [(window: GestureWindow, frame: CGRect)] {
        windowsByApp.keys.sorted().flatMap { pid in
            (windowsByApp[pid] ?? []).compactMap { window -> (window: GestureWindow, frame: CGRect)? in
                guard !minimizedIDs.contains(window.id), let frame = frames[window.id] else { return nil }
                return (window: window, frame: frame)
            }
        }
    }
    func isMinimized(_ window: GestureWindow) -> Bool { minimizedIDs.contains(window.id) }
    func setMinimized(_ window: GestureWindow, _ minimized: Bool) -> Bool {
        log.append("\(minimized ? "min" : "unmin") \(window.id)")
        if minimized { minimizedIDs.insert(window.id) } else { minimizedIDs.remove(window.id) }
        return true
    }
    func raise(_ window: GestureWindow) -> Bool { log.append("raise \(window.id)"); return true }
    func screens() -> [(frame: CGRect, visible: CGRect)] { screenList }
    func screenIndex(containing point: CGPoint) -> Int? { pointerScreen }
    func move(_ window: GestureWindow, to frame: CGRect, anchorIn visible: CGRect?,
              completion: @escaping (CGRect?) -> Void) {
        log.append("move \(window.id) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        frames[window.id] = frame
        originals.removeValue(forKey: window.id)
        completion(frame)
    }
    func unsnapFrame(for window: GestureWindow, current: CGRect) -> CGRect? { originals[window.id] }
    func snappedCell(for window: GestureWindow, current: CGRect) -> CustomSnapZone.Layout? { cells[window.id] }
    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect,
                           layout: CustomSnapZone.Layout) {
        log.append("record \(window.id) \(layout.rawValue)")
    }
    var snapMargin: CGFloat { 0 }
    var snapThirds: Bool { false }
}

/// Installs the fake desktop and every seam on the shared service, and puts
/// the real ones back in `restore()`.
@MainActor
private final class UtilityHarness {
    let service = TrackpadUtilityGestures.shared
    let desktop: FakeGestureDesktop
    var flags: NSEvent.ModifierFlags = []
    var inTopBand = true
    var dockTarget: NSRunningApplication?
    private(set) var announced: [String] = []
    private(set) var spaces: [Bool] = []
    private(set) var dockLookups = 0
    var t: Double
    private static var clock: Double = 50_000

    init(_ desktop: FakeGestureDesktop) {
        self.desktop = desktop
        Self.clock += 1_000
        t = Self.clock
        service.observe(points: [], timestamp: t)
        service.desktop = desktop
        service.minimized = MinimizedWindowStack()
        service.cursorLocation = { CGPoint(x: 700, y: 895) }
        service.cursorInTopBand = { [unowned self] _ in self.inTopBand }
        service.windowUnderPointer = { _ in nil }
        service.isScreenLocked = { false }
        service.isAllowed = { true }
        service.holdCancelSeconds = { 2 }
        service.modifierFlags = { [unowned self] in self.flags }
        service.announce = { [unowned self] title, _ in self.announced.append(title) }
        service.haptic = {}
        service.switchSpace = { [unowned self] in self.spaces.append($0) }
        service.dockApp = { [unowned self] in self.dockLookups += 1; return self.dockTarget }
        for key in [TrackpadUtilityGestures.dockGesturesKey, TrackpadUtilityGestures.menuBarGesturesKey,
                    TrackpadUtilityGestures.spacesEnabledKey, TrackpadUtilityGestures.dockQuitEnabledKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func restore() {
        service.observe(points: [], timestamp: t + 10)
        service.desktop = SystemGestureDesktop.shared
        service.minimized = MinimizedWindowStack()
        service.cursorLocation = { NSEvent.mouseLocation }
        service.cursorInTopBand = { TrackpadUtilityGestures.cursorInTopBand($0) }
        service.windowUnderPointer = { DockLookup.windowUnder($0) }
        service.isScreenLocked = { ScreenLock.isLocked }
        service.isAllowed = { AutomationGate.allows(.trackpad) }
        service.holdCancelSeconds = { TitleBarWindowSnap.holdCancelSeconds() }
        service.modifierFlags = { NSEvent.modifierFlags }
        service.announce = { title, detail in TrackpadUtilityGestures.showHUD(title, detail) }
        service.haptic = { TrackpadUtilityGestures.tapHaptic() }
        service.switchSpace = { _ in }
        service.dockApp = { TrackpadUtilityGestures.shared.dockAppUnderCursor() }
    }

    func frame(_ points: [TouchPoint], after delay: Double = 1.0 / 60) {
        t += delay
        service.observe(points: points, timestamp: t)
    }

    /// One touch: lands, travels (dx, dy) in one frame, lifts.
    func swipe(_ dx: Float, _ dy: Float, pause: Double = 1) {
        frame(two(0.5, 0.5), after: pause)
        frame(two(0.5 + dx, 0.5 + dy), after: 0.05)
        frame([], after: 0.05)
    }

    func doubleTap(pause: Double = 1) {
        frame(two(0.5, 0.5), after: pause)
        frame([], after: 0.08)
        frame(two(0.5, 0.5), after: 0.07)
        frame([], after: 0.08)
    }

    /// Lands and rests half a second: a tap and hold.
    func hold(pause: Double = 1) {
        frame(two(0.5, 0.5), after: pause)
        for _ in 0..<30 { frame(two(0.5, 0.5)) }
    }
}

extension PortedFeatureTests {
    func testMenuBarSwipeDownMinimizesThisScreenThenEveryScreenAndSwipeUpBringsThemBack() {
        let desktop = FakeGestureDesktop()
        let a1 = desktop.add("10:1", pid: 10, frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let a2 = desktop.add("10:2", pid: 10, frame: CGRect(x: 800, y: 200, width: 500, height: 400))
        let b1 = desktop.add("11:1", pid: 11, frame: CGRect(x: 1600, y: 100, width: 800, height: 600))
        let harness = UtilityHarness(desktop)
        defer { harness.restore() }

        harness.swipe(0, -0.12)                    // down, once: this screen
        XCTAssertEqual(desktop.minimizedIDs, [a1.id, a2.id])
        harness.swipe(0, -0.12, pause: 0.3)        // down again within a second: every screen
        XCTAssertEqual(desktop.minimizedIDs, [a1.id, a2.id, b1.id])
        XCTAssertEqual(harness.announced.prefix(2), ["Minimized 2 Windows", "Minimized 1 Window"])

        harness.swipe(0, 0.12, pause: 3)           // up, once: this screen's newest batch
        XCTAssertEqual(desktop.minimizedIDs, [b1.id])
        harness.swipe(0, 0.12, pause: 0.3)         // up again: every screen
        XCTAssertEqual(desktop.minimizedIDs, [])
        harness.swipe(0, 0.12, pause: 3)
        XCTAssertEqual(harness.announced.last, "Nothing to Unminimize")
        // ⇧ minimizes every screen at once.
        harness.flags = [.shift]
        harness.swipe(0, -0.12, pause: 3)
        XCTAssertEqual(desktop.minimizedIDs, [a1.id, a2.id, b1.id])
        XCTAssertEqual(harness.spaces, [], "vertical swipes never switch Spaces")
    }

    func testMenuBarDoubleTapUnsnapsWhatTheSnapPlacedOnThisScreen() {
        let desktop = FakeGestureDesktop()
        let snapped = desktop.add("20:1", pid: 20, frame: CGRect(x: 0, y: 25, width: 720, height: 875))
        _ = desktop.add("20:2", pid: 20, frame: CGRect(x: 300, y: 300, width: 500, height: 400))
        let elsewhere = desktop.add("21:1", pid: 21, frame: CGRect(x: 1440, y: 25, width: 960, height: 1055))
        desktop.originals = [snapped.id: CGRect(x: 200, y: 200, width: 500, height: 300),
                             elsewhere.id: CGRect(x: 1600, y: 200, width: 700, height: 500)]
        let harness = UtilityHarness(desktop)
        defer { harness.restore() }

        harness.doubleTap()
        XCTAssertEqual(desktop.log.filter { $0.hasPrefix("move") }, ["move 20:1 200,200 500x300"],
                       "only the window AOM snapped, only on this screen")
        XCTAssertEqual(harness.announced.last, "Unsnapped 1 Window")
        harness.doubleTap()
        XCTAssertEqual(harness.announced.last, "No Snapped Windows")
        harness.flags = [.shift]
        harness.doubleTap()
        XCTAssertEqual(desktop.log.filter { $0.hasPrefix("move") }.last, "move 21:1 1600,200 700x500", "⇧: every screen")
        // Two taps far apart are no double tap.
        desktop.originals[snapped.id] = CGRect(x: 10, y: 10, width: 400, height: 300)
        harness.frame(two(0.5, 0.5), after: 1)
        harness.frame([], after: 0.08)
        harness.frame(two(0.5, 0.5), after: 0.5)
        harness.frame([], after: 0.08)
        XCTAssertNotEqual(desktop.log.last, "move 20:1 10,10 400x300")
    }

    func testMenuBarCommandSwipeMovesSnappedWindowsToTheDisplayThatWay() {
        let desktop = FakeGestureDesktop()
        let half = desktop.add("30:1", pid: 30, frame: CGRect(x: 0, y: 25, width: 720, height: 875))
        _ = desktop.add("30:2", pid: 30, frame: CGRect(x: 300, y: 300, width: 500, height: 400))
        let quarter = desktop.add("31:1", pid: 31, frame: CGRect(x: 720, y: 25, width: 700, height: 420))
        desktop.cells[quarter.id] = .topRight   // the snap's history knows this one
        let harness = UtilityHarness(desktop)
        defer { harness.restore() }

        harness.flags = [.command]
        harness.swipe(0.16, 0)
        XCTAssertEqual(desktop.log.filter { $0.hasPrefix("move") },
                       ["move 30:1 1440,25 960x1055", "move 31:1 2400,25 960x527"],
                       "each keeps its cell on the display to the right; the free window stays")
        XCTAssertEqual(desktop.log.filter { $0.hasPrefix("record") },
                       ["record \(half.id) \(CustomSnapZone.Layout.leftHalf.rawValue)",
                        "record \(quarter.id) \(CustomSnapZone.Layout.topRight.rawValue)"])
        XCTAssertEqual(harness.spaces, [], "⌘ turns the Space swipe into the display move")
        harness.swipe(-0.16, 0)
        XCTAssertEqual(harness.announced.last, "No Display ←")
        // Without ⌘ the same swipe switches Spaces as always.
        harness.flags = []
        harness.swipe(0.16, 0)
        XCTAssertEqual(harness.spaces, [true])
    }

    func testMenuBarTapHoldSwipesSwitchAppsAndLiftingOpensTheSwitcher() {
        let desktop = FakeGestureDesktop()
        desktop.cycle = AppCycle(frontmost: 40, recent: [41, 42], running: [40, 41, 42, 43])
        desktop.frontmost = 40
        desktop.names = [41: "Mail", 42: "Notes", 43: "Music"]
        let harness = UtilityHarness(desktop)
        defer { harness.restore() }

        harness.hold()
        harness.frame(two(0.34, 0.5), after: 0.05)              // left: the previous app
        harness.frame(two(0.22, 0.5), after: 0.2)               // chained: the one before
        harness.frame(two(0.34, 0.5), after: 0.2)               // right: back again
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log, ["activate 41", "activate 42", "activate 41"])
        XCTAssertEqual(harness.announced, ["Mail", "Notes", "Mail"])
        XCTAssertEqual(harness.spaces, [], "a tap-and-hold swipe is no Space swipe")

        harness.hold()
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log.last, "switcher", "tap, hold and lift: the window switcher")
        // Tap, hold and scroll: the first scroll opens it, the next moves, lifting takes it.
        desktop.switcherIsShowing = false
        harness.hold()
        harness.frame(two(0.5, 0.38), after: 0.05)
        harness.frame(two(0.5, 0.26), after: 0.2)
        harness.frame([], after: 0.05)
        XCTAssertEqual(Array(desktop.log.suffix(2)), ["switcher", "confirm 1"])
        // A plain swipe still switches Spaces.
        harness.swipe(0.16, 0)
        XCTAssertEqual(harness.spaces, [true])
    }

    func testDockGesturesActOnTheAppUnderThePointer() throws {
        let app = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != getpid() })
        let pid = app.processIdentifier
        let desktop = FakeGestureDesktop()
        let d1 = desktop.add("\(pid):1", pid: pid, frame: CGRect(x: 0, y: 25, width: 600, height: 400))
        let d2 = desktop.add("\(pid):2", pid: pid, frame: CGRect(x: 100, y: 125, width: 600, height: 400))
        let d3 = desktop.add("\(pid):3", pid: pid, frame: CGRect(x: 200, y: 225, width: 600, height: 400))
        desktop.focused[pid] = d1
        desktop.frontmost = 1
        let harness = UtilityHarness(desktop)
        defer { harness.restore() }
        harness.inTopBand = false
        harness.dockTarget = app

        // Swipe down: the front window, then the next; up: newest first.
        harness.swipe(0, -0.12)
        harness.swipe(0, -0.12)
        XCTAssertEqual(desktop.minimizedIDs, [d1.id, d2.id])
        harness.swipe(0, 0.12)
        XCTAssertEqual(desktop.minimizedIDs, [d1.id], "the window AOM minimized last comes back first")
        harness.swipe(0, 0.12)
        XCTAssertEqual(desktop.minimizedIDs, [])
        harness.swipe(0, 0.12)
        XCTAssertEqual(harness.announced.last, "No Minimized Windows")
        // Without a remembered one, a window the app minimized itself.
        desktop.minimizedIDs = [d3.id]
        harness.swipe(0, 0.12)
        XCTAssertEqual(desktop.minimizedIDs, [])
        // ⇧: all of them, both ways.
        harness.flags = [.shift]
        harness.swipe(0, -0.12)
        XCTAssertEqual(desktop.minimizedIDs, [d1.id, d2.id, d3.id])
        harness.swipe(0, 0.12)
        XCTAssertEqual(desktop.minimizedIDs, [])
        harness.flags = []

        // Swipes left: bring the app forward with its front window, then step
        // forward through its windows; right steps back. One Dock lookup.
        desktop.frontmost = 1
        desktop.log = []
        let lookups = harness.dockLookups
        harness.frame(two(0.5, 0.5), after: 1)
        harness.frame(two(0.38, 0.5), after: 0.05)
        harness.frame(two(0.26, 0.5), after: 0.2)
        harness.frame(two(0.14, 0.5), after: 0.2)
        harness.frame(two(0.26, 0.5), after: 0.2)
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log.filter { $0.hasPrefix("raise") },
                       ["raise \(d1.id)", "raise \(d2.id)", "raise \(d3.id)", "raise \(d2.id)"])
        XCTAssertEqual(harness.dockLookups - lookups, 1, "the Dock item is resolved once per gesture")

        // Double tap hides the app (⇧: the others); pinch out sends ⌘N; tap,
        // hold and lift activates it with its front window.
        desktop.log = []
        harness.doubleTap()
        harness.flags = [.shift]
        harness.doubleTap()
        harness.flags = []
        harness.frame(two(0.5, 0.5, spread: 0.08), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.13), after: 0.05)
        harness.frame([], after: 0.05)
        harness.hold()
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log, ["hide \(pid)", "hideOthers \(pid)", "activate \(pid)", "⌘N \(pid)",
                                     "raise \(d1.id)", "activate \(pid)"])

        // Resting 2 s cancels: the swipe after it does nothing.
        desktop.log = []
        harness.frame(two(0.5, 0.5), after: 1)
        for _ in 0...126 { harness.frame(two(0.5, 0.5)) }
        harness.frame(two(0.5, 0.38), after: 0.05)
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log, [], "a hand resting on a Dock icon does nothing")

        // Never AOM itself.
        harness.dockTarget = NSRunningApplication.current
        desktop.windowsByApp[getpid()] = [GestureWindow(id: "own", pid: getpid())]
        harness.swipe(0, -0.12)
        harness.doubleTap()
        XCTAssertEqual(desktop.log, [])

        // Dock gestures off: nothing but the pinch to quit.
        UserDefaults.standard.set(false, forKey: TrackpadUtilityGestures.dockGesturesKey)
        defer { UserDefaults.standard.removeObject(forKey: TrackpadUtilityGestures.dockGesturesKey) }
        harness.dockTarget = app
        harness.swipe(0, -0.12)
        XCTAssertEqual(desktop.log, [])
    }

    func testDockAndMenuBarGestureSettingsDefaultOnAndCountAsStreamConsumers() {
        let service = TrackpadUtilityGestures.shared
        let keys = [TrackpadUtilityGestures.spacesEnabledKey, TrackpadUtilityGestures.dockQuitEnabledKey,
                    TrackpadUtilityGestures.dockGesturesKey, TrackpadUtilityGestures.menuBarGesturesKey,
                    TitleBarWindowSnap.enabledKey]
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        XCTAssertTrue(service.dockGesturesEnabled)
        XCTAssertTrue(service.menuBarGesturesEnabled)
        XCTAssertEqual(TrackpadUtilityGestures.dockGesturesKey, "AOMDockGestures")
        XCTAssertEqual(TrackpadUtilityGestures.menuBarGesturesKey, "AOMMenuBarGestures")
        keys.forEach { UserDefaults.standard.set(false, forKey: $0) }
        XCTAssertFalse(service.anyLayerEnabled)
        UserDefaults.standard.set(true, forKey: TrackpadUtilityGestures.dockGesturesKey)
        XCTAssertTrue(service.anyLayerEnabled, "the Dock gestures alone keep the trackpad stream up")
        UserDefaults.standard.set(false, forKey: TrackpadUtilityGestures.dockGesturesKey)
        UserDefaults.standard.set(true, forKey: TrackpadUtilityGestures.menuBarGesturesKey)
        XCTAssertTrue(service.anyLayerEnabled, "and so do the menu-bar gestures")
    }
}
