import XCTest
import AppKit
@testable import AllOfMacOS

// 3.3.3 Dock, menu-bar and Mission Control gestures (review S01, S02, S04,
// S05, S06, F03, Mission Control, the menu bar's parts). Everything runs
// through the shared service's seams against an in-memory desktop: no real
// window, app or display is touched, and the counting quit seam never asks
// an app to quit.

/// Two fingers centred on (x, y) in TouchPoint's pad units, `spread` apart.
private func two(_ x: Float, _ y: Float, spread: Float = 0.12) -> [TouchPoint] {
    [TouchPoint(id: 1, x: x - spread / 2, y: y, size: 0.1), TouchPoint(id: 2, x: x + spread / 2, y: y, size: 0.1)]
}

private let thirdFinger = TouchPoint(id: 3, x: 0.8, y: 0.8, size: 0.1)
private let fourthFinger = TouchPoint(id: 4, x: 0.2, y: 0.2, size: 0.1)

// MARK: - Pure

final class SwishDock333Tests: XCTestCase {
    /// The review's reproduction (utility-third-finger-probe.swift): two
    /// fingers, a third, back to two, then a pinch or a swipe.
    func testAThirdFingerSpendsTheTouchUntilEveryFingerLifts() {
        var pinch = UtilityGestureRecognizer()
        XCTAssertNil(pinch.feed(two(0.5, 0.5, spread: 0.24), at: 0))
        XCTAssertNil(pinch.feed(two(0.5, 0.5, spread: 0.24) + [thirdFinger], at: 0.05))
        XCTAssertNil(pinch.feed(two(0.5, 0.5, spread: 0.10), at: 0.10), "3.3.2 pinched in here")
        XCTAssertTrue(pinch.isWaitingForLift)
        var swipe = UtilityGestureRecognizer()
        _ = swipe.feed(two(0.5, 0.5), at: 0)
        _ = swipe.feed(two(0.5, 0.5) + [thirdFinger], at: 0.05)
        XCTAssertNil(swipe.feed(two(0.65, 0.5), at: 0.10), "3.3.2 swiped right here")
        // No direction, no hold, no tap until every finger is off the pad.
        var events: [UtilityGestureRecognizer.Event] = []
        var t = 0.2
        for (dx, dy) in [(0.0, 0.15), (0.0, -0.15), (-0.15, 0.0), (0.15, 0.0)] as [(Float, Float)] {
            if let event = swipe.feed(two(0.5 + dx, 0.5 + dy), at: t) { events.append(event) }
            t += 0.2
        }
        for _ in 0..<60 { if let event = swipe.feed(two(0.5, 0.5), at: t) { events.append(event) }; t += 1.0 / 60 }
        if let event = swipe.feed([thirdFinger], at: t) { events.append(event) }
        if let event = swipe.feed(two(0.5, 0.5), at: t + 0.02) { events.append(event) }
        if let event = swipe.feed(two(0.5, 0.5, spread: 0.30), at: t + 0.05) { events.append(event) }
        XCTAssertEqual(events, [], "one finger left on the pad is not every finger lifted")
        XCTAssertNil(swipe.feed([], at: t + 0.1), "the lift itself is no tap")
        XCTAssertFalse(swipe.isWaitingForLift)
        // The next touch is a fresh one.
        _ = swipe.feed(two(0.5, 0.5), at: t + 1)
        XCTAssertEqual(swipe.feed(two(0.62, 0.5), at: t + 1.05), .swipe(.right, held: false, chain: 1))
    }

    func testFourFingersAndQuickTapsAfterThemActNoMore() {
        var recognizer = UtilityGestureRecognizer()
        // 2 → 4 → 2: 3.3.2 started a fresh touch here, which could pinch.
        _ = recognizer.feed(two(0.5, 0.5, spread: 0.30), at: 0)
        XCTAssertNil(recognizer.feed(two(0.5, 0.5, spread: 0.30) + [thirdFinger, fourthFinger], at: 0.05))
        XCTAssertNil(recognizer.feed(two(0.5, 0.5, spread: 0.30), at: 0.10))
        XCTAssertNil(recognizer.feed(two(0.5, 0.5, spread: 0.12), at: 0.15))
        XCTAssertNil(recognizer.feed([], at: 0.2))
        // A tap whose third finger came and went is no tap, and no first half of a double tap.
        _ = recognizer.feed(two(0.5, 0.5), at: 1)
        _ = recognizer.feed(two(0.5, 0.5) + [thirdFinger], at: 1.02)
        _ = recognizer.feed(two(0.5, 0.5), at: 1.04)
        XCTAssertNil(recognizer.feed([], at: 1.08))
        _ = recognizer.feed(two(0.5, 0.5), at: 1.2)
        XCTAssertEqual(recognizer.feed([], at: 1.28), .tap, "a single tap, not the second half of a double tap")
        // Three fingers landing at once, then two lifting off one by one.
        XCTAssertNil(recognizer.feed(two(0.5, 0.5) + [thirdFinger], at: 2))
        XCTAssertNil(recognizer.feed(two(0.5, 0.5), at: 2.02))
        XCTAssertNil(recognizer.feed(two(0.62, 0.5), at: 2.06))
        XCTAssertNil(recognizer.feed([], at: 2.1))
        // reset() frees spent fingers (another trackpad took over).
        _ = recognizer.feed(two(0.5, 0.5) + [thirdFinger], at: 3)
        recognizer.reset()
        XCTAssertFalse(recognizer.isWaitingForLift)
    }

    func testTheMenuBarRestorePlanCoversEveryMinimizedWindowOnThatScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900), right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let a = GestureWindow(id: "1:a", pid: 1), b = GestureWindow(id: "1:b", pid: 1)
        let c = GestureWindow(id: "2:c", pid: 2), d = GestureWindow(id: "3:d", pid: 3), e = GestureWindow(id: "4:e", pid: 4)
        var stack = MinimizedWindowStack()
        stack.push([(a, left)], source: .menuBar)
        stack.push([(b, left), (c, right)], source: .menuBar)
        stack.push([(e, left)], source: .dock)
        let minimizedNow: Set<String> = ["1:a", "1:b", "2:c", "3:d", "4:e"]
        let listed: [(window: GestureWindow, screen: CGRect?)] = [(d, left), (a, left), (e, left), (c, right)]
        // AOM's own first, newest first; then the rest of this screen's, each once.
        XCTAssertEqual(stack.planMenuBarRestore(listed: listed, on: left) { minimizedNow.contains($0.id) }.map(\.id),
                       ["1:b", "1:a", "3:d", "4:e"])
        XCTAssertEqual(stack.entries.count, 4, "planning takes nothing off the stack")
        XCTAssertEqual(stack.planMenuBarRestore(listed: listed, on: nil) { minimizedNow.contains($0.id) }.map(\.id),
                       ["2:c", "1:b", "1:a", "3:d", "4:e"], "every screen; the last of a batch is its newest")
        // A remembered window the user restored another way is dropped.
        _ = stack.planMenuBarRestore(listed: [], on: left) { $0.id != "1:a" }
        XCTAssertFalse(stack.entries.contains { $0.window == a })
    }

    func testMissionControlThumbnailsAndTheWindowsTheyStandFor() {
        typealias Node = MissionControlWindows.Node
        XCTAssertEqual(MissionControlWindows.bundleID(fromIdentifier: "com.apple.Safari.space.3"), "com.apple.Safari")
        XCTAssertEqual(MissionControlWindows.bundleID(fromIdentifier: "com.mitchellh.ghostty.space.12"), "com.mitchellh.ghostty")
        XCTAssertNil(MissionControlWindows.bundleID(fromIdentifier: "mc.spaces.add"))
        XCTAssertNil(MissionControlWindows.bundleID(fromIdentifier: "com.example.space.x"))
        XCTAssertNil(MissionControlWindows.bundleID(fromIdentifier: nil))
        // macOS 27 (WindowManager): thumbnails straight under mc.display, Spaces apart.
        let safari = Node(role: "AXButton", identifier: "com.apple.Safari.space.1", title: "Apple",
                          frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let notes = Node(role: "AXButton", identifier: "com.apple.Notes.space.1", title: "Groceries",
                         frame: CGRect(x: 600, y: 100, width: 300, height: 300))
        let spaces = Node(role: "AXGroup", identifier: "mc.spaces", children: [
            Node(role: "AXList", identifier: "mc.spaces.list", children: [
                Node(role: "AXButton", title: "Desktop 1", frame: CGRect(x: 0, y: 0, width: 200, height: 120))])])
        let display = Node(role: "AXGroup", identifier: "mc.display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                           children: [safari, notes, spaces])
        let found = MissionControlWindows.thumbnails(in: [display])
        XCTAssertEqual(found.map(\.title), ["Apple", "Groceries"])
        XCTAssertEqual(found.first?.bundleID, "com.apple.Safari")
        XCTAssertEqual(MissionControlWindows.thumbnail(at: CGPoint(x: 700, y: 200), in: found)?.title, "Groceries")
        XCTAssertNil(MissionControlWindows.thumbnail(at: CGPoint(x: 50, y: 50), in: found))
        // Earlier systems (the Dock): the children of mc.windows.
        let old = Node(role: "AXGroup", identifier: "mc", children: [
            Node(role: "AXGroup", identifier: "mc.display", children: [
                Node(role: "AXGroup", identifier: "mc.windows", children: [
                    Node(role: "AXButton", title: "Inbox", frame: CGRect(x: 10, y: 10, width: 300, height: 200))])])])
        XCTAssertEqual(MissionControlWindows.thumbnails(in: [old]).map(\.title), ["Inbox"])
        // One window, never a guess.
        typealias Candidate = MissionControlWindows.Candidate
        let candidates = [Candidate(pid: 7, bundleID: "com.apple.Safari", title: "Apple", index: 0),
                          Candidate(pid: 8, bundleID: "com.apple.Notes", title: "Apple", index: 0),
                          Candidate(pid: 8, bundleID: "com.apple.Notes", title: "Groceries", index: 1)]
        XCTAssertEqual(MissionControlWindows.match(found[0], among: candidates)?.pid, 7, "the app the thumbnail names")
        XCTAssertNil(MissionControlWindows.match(MissionControlThumbnail(title: "Apple", identifier: nil, frame: .zero),
                                                 among: candidates), "two apps have an 'Apple' window: no guess")
        XCTAssertNil(MissionControlWindows.match(MissionControlThumbnail(title: nil, identifier: "com.apple.Notes.space.1",
                                                                         frame: .zero), among: candidates))
    }

    func testTheMenuBarsPartsAndTheScrollAreaToScroll() {
        // Observed on macOS 27.2: status items are AXMenuExtra items of their
        // own apps; the menu titles and the empty area are the frontmost app's.
        XCTAssertEqual(MenuBarProbe.classify(role: "AXMenuBarItem", subrole: "AXMenuExtra", owner: 9, frontmost: 5, index: nil),
                       .statusItem)
        XCTAssertEqual(MenuBarProbe.classify(role: "AXMenuBarItem", subrole: "AXMenuExtra", owner: 5, frontmost: 5, index: 1),
                       .statusItem, "even the frontmost app's own status item")
        XCTAssertEqual(MenuBarProbe.classify(role: "AXMenuBarItem", subrole: nil, owner: 5, frontmost: 5, index: 1), .appMenu(5))
        XCTAssertEqual(MenuBarProbe.classify(role: "AXMenuBarItem", subrole: nil, owner: 5, frontmost: 5, index: 0), .menuTitle,
                       "the Apple menu")
        XCTAssertEqual(MenuBarProbe.classify(role: "AXMenuBarItem", subrole: nil, owner: 5, frontmost: 5, index: 3), .menuTitle)
        XCTAssertEqual(MenuBarProbe.classify(role: "AXMenuBar", subrole: nil, owner: 5, frontmost: 5, index: nil), .empty)
        XCTAssertEqual(MenuBarProbe.classify(role: nil, subrole: nil, owner: 0, frontmost: 5, index: nil), .unknown)
        // The scroll area under the pointer's column, else the largest.
        let sidebar = CGRect(x: 0, y: 50, width: 250, height: 800), content = CGRect(x: 250, y: 50, width: 1000, height: 800)
        XCTAssertEqual(ScrollToTop.choose([sidebar, content], pointerX: 100), 0)
        XCTAssertEqual(ScrollToTop.choose([sidebar, content], pointerX: 700), 1)
        XCTAssertEqual(ScrollToTop.choose([sidebar, content], pointerX: 2000), 1)
        XCTAssertEqual(ScrollToTop.choose([sidebar, content], pointerX: nil), 1)
        XCTAssertNil(ScrollToTop.choose([], pointerX: 10))
    }

    /// Source guards: the system-wide hit-test stays off the title-bar and
    /// Dock files (3.3.2) and the new menu-bar probe never sets its timeout.
    func testTheMenuBarProbeNeverTimesTheSystemWideElement() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AllOfMacOS/Services")
        let probe = try String(contentsOf: root.appendingPathComponent("SwishDockMenuBarSystem.swift"), encoding: .utf8)
        for line in probe.components(separatedBy: "\n") where line.contains("AXUIElementSetMessagingTimeout(") {
            XCTAssertFalse(line.contains("SystemWide"), line)
        }
        let dock = try String(contentsOf: root.appendingPathComponent("SwishDockMenuBarGestures.swift"), encoding: .utf8)
        XCTAssertFalse(dock.contains("AXUIElementCreateSystemWide"))
        let service = try String(contentsOf: root.appendingPathComponent("TrackpadUtilityGestures.swift"), encoding: .utf8)
        XCTAssertFalse(service.contains("AXUIElementCreateSystemWide"))
    }
}

// MARK: - The service, through its seams

/// Everything the gestures may touch, in memory. Records what was asked.
@MainActor
private final class Desktop333: GestureDesktop {
    var names: [pid_t: String] = [:]
    var windowsByApp: [pid_t: [GestureWindow]] = [:]
    var frames: [String: CGRect] = [:]
    var minimizedIDs = Set<String>()
    /// Windows whose unminimize fails (an app that refuses).
    var refusing = Set<String>()
    var focused: [pid_t: GestureWindow] = [:]
    var frontmost: pid_t?
    var screenList: [(frame: CGRect, visible: CGRect)] = [
        (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 25, width: 1440, height: 875)),
        (CGRect(x: 1440, y: 0, width: 1920, height: 1080), CGRect(x: 1440, y: 25, width: 1920, height: 1055))
    ]
    var cycle = AppCycle(frontmost: nil, recent: [], running: [])
    var switcherIsShowing = false
    var switcherOffset = 0
    var appSwitcherAvailable = true
    var scrollOutcome: ScrollToTop.Outcome = .scrolled
    var log: [String] = []

    @discardableResult
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
    func cancelSwitcher() { log.append("cancel switcher"); switcherIsShowing = false }
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
    func minimizedWindows() -> [(window: GestureWindow, frame: CGRect?)] {
        windowsByApp.keys.sorted().flatMap { pid in
            (windowsByApp[pid] ?? []).filter { minimizedIDs.contains($0.id) }.map { (window: $0, frame: frames[$0.id]) }
        }
    }
    func isMinimized(_ window: GestureWindow) -> Bool { minimizedIDs.contains(window.id) }
    func setMinimized(_ window: GestureWindow, _ minimized: Bool) -> Bool {
        log.append("\(minimized ? "min" : "unmin") \(window.id)")
        if !minimized, refusing.contains(window.id) { return false }
        if minimized { minimizedIDs.insert(window.id) } else { minimizedIDs.remove(window.id) }
        return true
    }
    func raise(_ window: GestureWindow) -> Bool { log.append("raise \(window.id)"); return true }
    func close(_ window: GestureWindow) -> Bool { log.append("close \(window.id)"); return true }
    func screens() -> [(frame: CGRect, visible: CGRect)] { screenList }
    func screenIndex(containing point: CGPoint) -> Int? { 0 }
    func move(_ window: GestureWindow, to frame: CGRect, anchorIn visible: CGRect?, completion: @escaping (CGRect?) -> Void) {
        log.append("move \(window.id)")
        frames[window.id] = frame
        completion(frame)
    }
    func unsnapFrame(for window: GestureWindow, current: CGRect) -> CGRect? { nil }
    func snappedCell(for window: GestureWindow, current: CGRect) -> CustomSnapZone.Layout? { nil }
    func recordDisplayMove(of window: GestureWindow, from start: CGRect, to actual: CGRect, layout: CustomSnapZone.Layout) {}
    var snapMargin: CGFloat { 0 }
    var snapThirds: Bool { false }
    func frontmostPID() -> pid_t? { frontmost }
    func beginAppSwitcher() -> Bool {
        guard appSwitcherAvailable else { return false }
        log.append("⌘⇥ begin")
        return true
    }
    func stepAppSwitcher(forward: Bool) -> Bool { log.append("⌘⇥ \(forward ? "next" : "back")"); return true }
    func endAppSwitcher(commit: Bool) { log.append("⌘⇥ \(commit ? "take" : "cancel")") }
    func scrollToTop(of pid: pid_t, pointerX: CGFloat?) -> ScrollToTop.Outcome {
        log.append("scroll to top \(pid)")
        return scrollOutcome
    }
}

/// Installs the in-memory desktop and every seam on the shared service, and
/// puts the real ones back in `restore()`.
@MainActor
private final class Harness333 {
    let service = TrackpadUtilityGestures.shared
    let desktop: Desktop333
    var flags: NSEvent.ModifierFlags = []
    var inTopBand = true
    var spot: MenuBarSpot = .empty
    var dockTarget: NSRunningApplication?
    var thumbnailWindow: GestureWindow?
    var paused = Set<pid_t>()
    var allowed = true
    var locked = false
    var chainAnswer = false
    private(set) var chained: [String] = []
    private(set) var quits: [pid_t] = []
    private(set) var announced: [String] = []
    private(set) var spaces: [Bool] = []
    private var later: [() -> Void] = []
    var t: Double
    private static var clock: Double = 900_000
    private let keys = [TrackpadUtilityGestures.dockGesturesKey, TrackpadUtilityGestures.menuBarGesturesKey,
                        TrackpadUtilityGestures.spacesEnabledKey, TrackpadUtilityGestures.dockQuitEnabledKey,
                        TrackpadUtilityGestures.dockDoublePinchKey, TrackpadUtilityGestures.appMenuGesturesKey,
                        TrackpadUtilityGestures.menuBarScrollToTopKey, TrackpadUtilityGestures.menuBarSwitcherKey,
                        TrackpadUtilityGestures.missionControlGesturesKey]

    init(_ desktop: Desktop333) {
        self.desktop = desktop
        Self.clock += 1_000
        t = Self.clock
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        service.observe(points: [], timestamp: t)
        service.cancelPending()
        service.desktop = desktop
        service.minimized = MinimizedWindowStack()
        service.cursorLocation = { CGPoint(x: 700, y: 895) }
        service.cursorInTopBand = { [unowned self] _ in self.inTopBand }
        service.windowUnderPointer = { _ in nil }
        service.isScreenLocked = { [unowned self] in self.locked }
        service.isAllowed = { [unowned self] in self.allowed }
        service.holdCancelSeconds = { 2 }
        service.modifierFlags = { [unowned self] in self.flags }
        service.announce = { [unowned self] title, _ in self.announced.append(title) }
        service.haptic = {}
        service.switchSpace = { [unowned self] in self.spaces.append($0) }
        service.dockApp = { [unowned self] in self.dockTarget }
        service.quitApplication = { [unowned self] in self.quits.append($0.processIdentifier) }
        service.isAppPaused = { [unowned self] in self.paused.contains($0) }
        service.chainWindow = { [unowned self] window in self.chained.append(window.id); return self.chainAnswer }
        service.menuBarSpot = { [unowned self] _ in self.spot }
        service.prefetchMenuBarSpot = { _ in }
        service.missionControlWindow = { [unowned self] _ in self.thumbnailWindow }
        service.schedule = { [unowned self] _, work in self.later.append(work) }
        service.now = { 1_000 }
    }

    func restore() {
        allowed = true
        locked = false
        service.observe(points: [], timestamp: t + 10)
        service.cancelPending()
        later = []
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
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
        service.quitApplication = { app in
            guard !PresetManager.isRunningTests else { return }
            TrackpadUtilityGestures.politeQuit(app)
        }
        service.isAppPaused = { pid in
            TriggerSuppression.shared.isPaused(forApp: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        }
        service.chainWindow = { _ in false }
        service.menuBarSpot = { MenuBarProbe.spot(at: $0) }
        service.prefetchMenuBarSpot = { MenuBarProbe.prefetch(at: $0) }
        service.missionControlWindow = { TrackpadUtilityGestures.liveMissionControlWindow(at: $0) }
        service.schedule = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        service.now = { ProcessInfo.processInfo.systemUptime }
    }

    /// Work scheduled for later, run by `drain()`.
    var pendingWork: Int { later.count }

    /// Runs the scheduled work, and the work it schedules in turn (bounded:
    /// the app switcher's watchdog re-arms itself while frames arrive).
    func drain(rounds: Int = 4) {
        for _ in 0..<rounds where !later.isEmpty {
            let work = later
            later = []
            work.forEach { $0() }
        }
    }

    func frame(_ points: [TouchPoint], after delay: Double = 1.0 / 60) {
        t += delay
        service.observe(points: points, timestamp: t)
    }

    func swipe(_ dx: Float, _ dy: Float, pause: Double = 1) {
        frame(two(0.5, 0.5), after: pause)
        frame(two(0.5 + dx, 0.5 + dy), after: 0.05)
        frame([], after: 0.05)
    }

    func pinch(in pinchIn: Bool, pause: Double = 1) {
        frame(two(0.5, 0.5, spread: pinchIn ? 0.30 : 0.08), after: pause)
        frame(two(0.5, 0.5, spread: pinchIn ? 0.12 : 0.14), after: 0.05)
        frame([], after: 0.05)
    }

    func tap(pause: Double = 1) {
        frame(two(0.5, 0.5), after: pause)
        frame([], after: 0.08)
    }

    func doubleTap(pause: Double = 1) {
        tap(pause: pause)
        tap(pause: 0.07)
    }

    func hold(pause: Double = 1) {
        frame(two(0.5, 0.5), after: pause)
        for _ in 0..<30 { frame(two(0.5, 0.5)) }
    }
}

/// Another app's process, so the per-app checks see a live app; the counting
/// quit seam never asks it anything.
@MainActor
private func someOtherApp() throws -> NSRunningApplication {
    try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != getpid() && $0.activationPolicy == .regular && !$0.isTerminated
    }, "a regular app besides the test runner")
}

@MainActor
final class SwishDock333ServiceTests: XCTestCase {
    // MARK: S02

    /// 2 → 3 → 2 → 0 on a Dock icon and on the menu bar: no pinch, swipe,
    /// hold, tap, Space switch or quit request (review S02's pass criteria).
    func testTwoThreeTwoFingersDoNothingOnTheDockOrTheMenuBar() throws {
        let app = try someOtherApp()
        let desktop = Desktop333()
        desktop.add("\(app.processIdentifier):1", pid: app.processIdentifier, frame: CGRect(x: 0, y: 25, width: 600, height: 400))
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.inTopBand = false
        harness.dockTarget = app
        // Pinch in after the third finger left.
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.30) + [thirdFinger], after: 0.03)
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 0.03)
        harness.frame(two(0.5, 0.5, spread: 0.10), after: 0.05)
        harness.frame([], after: 0.05)
        // Swipes every way, a rest long enough for a hold, then a lift.
        harness.frame(two(0.5, 0.5), after: 1)
        harness.frame(two(0.5, 0.5) + [thirdFinger, fourthFinger], after: 0.03)
        harness.frame(two(0.5, 0.5), after: 0.03)
        for (dx, dy) in [(0.0, -0.15), (0.0, 0.15), (-0.15, 0.0), (0.15, 0.0)] as [(Float, Float)] {
            harness.frame(two(0.5 + dx, 0.5 + dy), after: 0.2)
        }
        for _ in 0..<40 { harness.frame(two(0.5, 0.5)) }
        harness.frame([], after: 0.05)
        // A quick 2 → 3 → 2 tap.
        harness.frame(two(0.5, 0.5), after: 1)
        harness.frame(two(0.5, 0.5) + [thirdFinger], after: 0.02)
        harness.frame(two(0.5, 0.5), after: 0.02)
        harness.frame([], after: 0.03)
        harness.drain()
        XCTAssertEqual(desktop.log, [])
        XCTAssertEqual(harness.quits, [])
        // The menu bar: no Space switch, no minimize.
        harness.inTopBand = true
        harness.frame(two(0.4, 0.5), after: 1)
        harness.frame(two(0.4, 0.5) + [thirdFinger], after: 0.03)
        harness.frame(two(0.4, 0.5), after: 0.03)
        harness.frame(two(0.2, 0.5), after: 0.1)
        harness.frame(two(0.2, 0.3), after: 0.2)
        harness.frame([], after: 0.05)
        harness.drain()
        XCTAssertEqual(harness.spaces, [])
        XCTAssertEqual(desktop.log, [])
        // Then a clean swipe works again.
        harness.swipe(-0.16, 0)
        XCTAssertEqual(harness.spaces, [false])
    }

    /// The spent fingers stay the gesture's trackpad's: another trackpad's
    /// lift does not free them.
    func testAnotherTrackpadsLiftDoesNotFreeSpentFingers() {
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        let service = harness.service
        var t = harness.t + 1
        service.observe(points: two(0.4, 0.5), timestamp: t, device: 1)
        service.observe(points: two(0.4, 0.5) + [thirdFinger], timestamp: t + 0.02, device: 1)
        service.observe(points: two(0.4, 0.5), timestamp: t + 0.04, device: 1)
        service.observe(points: [], timestamp: t + 0.05, device: 2)            // device 2 lifts a thumb
        service.observe(points: two(0.22, 0.5), timestamp: t + 0.06, device: 1) // device 1 swipes on
        service.observe(points: [], timestamp: t + 0.1, device: 1)
        XCTAssertEqual(harness.spaces, [])
        t += 1
        harness.t = t
        harness.swipe(-0.16, 0)
        XCTAssertEqual(harness.spaces, [false], "the next touch is a fresh one")
    }

    /// A trackpad that went quiet with spent fingers hands the gesture over
    /// cleanly: the other trackpad's touch is not dropped frame after frame
    /// (the old order of `reset()` kept the quiet trackpad as the owner).
    func testAQuietTrackpadWithSpentFingersHandsTheGestureOver() {
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        let service = harness.service
        let t = harness.t + 1
        service.observe(points: two(0.4, 0.5), timestamp: t, device: 1)
        service.observe(points: two(0.4, 0.5) + [thirdFinger], timestamp: t + 0.02, device: 1)
        // Device 1 says nothing more; device 2 swipes left half a second later.
        service.observe(points: two(0.5, 0.5), timestamp: t + 0.5, device: 2)
        service.observe(points: two(0.42, 0.5), timestamp: t + 0.52, device: 2)
        service.observe(points: two(0.34, 0.5), timestamp: t + 0.54, device: 2)
        service.observe(points: [], timestamp: t + 0.56, device: 2)
        XCTAssertEqual(harness.spaces, [false])
        harness.t = t + 1
    }

    /// 3.3.3: a Dock pinch runs when its fingers lift at the earliest, so a
    /// third finger or the hold-still cancel before the lift takes it back,
    /// with or without the wait for a second pinch (S02 with the F03 wait).
    func testAThirdFingerOrARestAfterADockPinchTakesItBack() throws {
        let app = try someOtherApp()
        let pid = app.processIdentifier
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.inTopBand = false
        harness.dockTarget = app
        // Pinch in, keep the fingers down past the wait, then a third finger.
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.05)
        harness.drain()
        XCTAssertEqual(harness.quits, [], "not while the fingers are down")
        harness.frame(two(0.5, 0.5, spread: 0.12) + [thirdFinger], after: 0.05)
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.05)
        harness.frame([], after: 0.05)
        harness.drain()
        XCTAssertEqual(harness.quits, [], "the third finger took the pinch back")
        // Pinch in, then rest until the hold-still cancel: taken back too.
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.05)
        for _ in 0...126 { harness.frame(two(0.5, 0.5, spread: 0.12)) }
        harness.frame([], after: 0.05)
        harness.drain()
        XCTAssertEqual(harness.quits, [], "resting cancels the pinch")
        // Fingers down past the wait, then lifted: the quit runs at the lift.
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.05)
        harness.drain()
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.3)
        XCTAssertEqual(harness.quits, [])
        harness.frame([], after: 0.05)
        XCTAssertEqual(harness.quits, [pid])
        // Without the double pinch there is no wait, but still nothing before the lift.
        UserDefaults.standard.set(false, forKey: TrackpadUtilityGestures.dockDoublePinchKey)
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.05)
        XCTAssertEqual(harness.quits, [pid])
        harness.frame(two(0.5, 0.5, spread: 0.12) + [thirdFinger], after: 0.05)
        harness.frame([], after: 0.05)
        XCTAssertEqual(harness.quits, [pid], "a third finger took it back")
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.05)
        harness.frame([], after: 0.05)
        XCTAssertEqual(harness.quits, [pid, pid])
        // A lift long after the pinch (a lost lift frame) runs nothing.
        harness.frame(two(0.5, 0.5, spread: 0.30), after: 1)
        harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.05)
        for _ in 0..<5 { harness.frame(two(0.52, 0.5, spread: 0.12), after: 0.2); harness.frame(two(0.5, 0.5, spread: 0.12), after: 0.2) }
        harness.frame([], after: 0.05)
        XCTAssertEqual(harness.quits, [pid, pid], "lifted over 2 s after the pinch")
    }

    // MARK: S01

    func testTheDockPinchNeverQuitsAOMOrAPausedAppAndChecksAgainBeforeTheRequest() throws {
        let app = try someOtherApp()
        let pid = app.processIdentifier
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.inTopBand = false
        // AOM itself: nothing, not even a wait.
        harness.dockTarget = NSRunningApplication.current
        harness.pinch(in: true)
        XCTAssertEqual(harness.pendingWork, 0)
        harness.drain()
        XCTAssertEqual(harness.quits, [])
        // The target paused (not frontmost): nothing.
        harness.dockTarget = app
        harness.paused = [pid]
        harness.pinch(in: true)
        harness.drain()
        XCTAssertEqual(harness.quits, [])
        // Paused, AOM switched off or the screen locked between the pinch and
        // the request: nothing.
        harness.paused = []
        for change in [{ harness.paused = [pid] }, { harness.allowed = false }, { harness.locked = true }] {
            harness.pinch(in: true)
            change()
            harness.drain()
            harness.paused = []
            harness.allowed = true
            harness.locked = false
        }
        XCTAssertEqual(harness.quits, [])
        // Allowed: exactly one polite request, once the wait is over.
        harness.pinch(in: true)
        XCTAssertEqual(harness.quits, [], "a second pinch may still follow")
        harness.drain()
        XCTAssertEqual(harness.quits, [pid])
        // Without the double pinch the quit is immediate, still checked.
        UserDefaults.standard.set(false, forKey: TrackpadUtilityGestures.dockDoublePinchKey)
        harness.pinch(in: true)
        XCTAssertEqual(harness.quits, [pid, pid])
        harness.dockTarget = NSRunningApplication.current
        harness.pinch(in: true)
        XCTAssertEqual(harness.quits, [pid, pid])
    }

    // MARK: F03: pinch twice, chain

    func testPinchingTwiceMinimizesOrUnminimizesAllOfTheAppsWindowsAndChains() throws {
        let app = try someOtherApp()
        let pid = app.processIdentifier
        let desktop = Desktop333()
        let w1 = desktop.add("\(pid):1", pid: pid, frame: CGRect(x: 0, y: 25, width: 600, height: 400))
        let w2 = desktop.add("\(pid):2", pid: pid, frame: CGRect(x: 100, y: 125, width: 600, height: 400))
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.inTopBand = false
        harness.dockTarget = app
        // Pinch in twice: every window minimized, no quit.
        harness.pinch(in: true)
        harness.pinch(in: true, pause: 0.12)
        harness.drain()
        XCTAssertEqual(desktop.minimizedIDs, [w1.id, w2.id])
        XCTAssertEqual(harness.quits, [], "the second pinch replaced the quit")
        // Pinch out twice: every window back, the last chained, no ⌘N.
        harness.pinch(in: false)
        harness.pinch(in: false, pause: 0.12)
        harness.drain()
        XCTAssertEqual(desktop.minimizedIDs, [])
        XCTAssertFalse(desktop.log.contains("⌘N \(pid)"))
        XCTAssertEqual(harness.chained.count, 1, "unminimizing chains the window")
        // Two pinches far apart are two single pinches: the first quits when
        // the second comes, the second after its own wait.
        harness.pinch(in: true)
        harness.pinch(in: true, pause: 1)
        XCTAssertEqual(harness.quits, [pid])
        harness.drain()
        XCTAssertEqual(harness.quits, [pid, pid])
        // A single pinch out: activate, then ⌘N a moment later, checked again (S05).
        desktop.log = []
        harness.pinch(in: false)
        harness.drain(rounds: 1)
        XCTAssertEqual(desktop.log, ["activate \(pid)"])
        harness.paused = [pid]
        harness.drain()
        XCTAssertEqual(desktop.log, ["activate \(pid)"], "paused before the keys went out: no ⌘N")
        harness.paused = []
        harness.pinch(in: false)
        harness.drain()
        XCTAssertEqual(desktop.log.suffix(2), ["activate \(pid)", "⌘N \(pid)"])
    }

    func testDockGesturesOfferTheirWindowToTheTitleBarSnap() throws {
        let app = try someOtherApp()
        let pid = app.processIdentifier
        let desktop = Desktop333()
        let w1 = desktop.add("\(pid):1", pid: pid, frame: CGRect(x: 0, y: 25, width: 600, height: 400))
        let w2 = desktop.add("\(pid):2", pid: pid, frame: CGRect(x: 100, y: 125, width: 600, height: 400), minimized: true)
        desktop.focused[pid] = w1
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.inTopBand = false
        harness.dockTarget = app
        // Tap and hold, then lift: the front window.
        harness.hold()
        harness.frame([], after: 0.05)
        XCTAssertEqual(harness.chained, [w1.id])
        // Swipe up: the window brought back.
        harness.swipe(0, 0.12)
        XCTAssertEqual(harness.chained, [w1.id, w2.id])
        // Taken: the rest of the touch is the snap's, the Dock does nothing more.
        harness.chainAnswer = true
        desktop.frontmost = 1
        desktop.log = []
        harness.frame(two(0.5, 0.5), after: 1)
        harness.frame(two(0.38, 0.5), after: 0.05)   // first swipe: brings the app forward, chained
        harness.frame(two(0.26, 0.5), after: 0.2)    // would step to the next window
        harness.frame(two(0.5, 0.36), after: 0.2)    // would minimize
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log.filter { $0.hasPrefix("raise") }.count, 1)
        XCTAssertFalse(desktop.log.contains { $0.hasPrefix("min ") })
    }

    // MARK: S04, S06

    func testTheMenuBarSwipeUpRestoresEveryMinimizedWindowAndKeepsTheOnesItCouldNot() {
        let desktop = Desktop333()
        let ours = desktop.add("10:1", pid: 10, frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let theirs = desktop.add("11:1", pid: 11, frame: CGRect(x: 200, y: 200, width: 600, height: 400), minimized: true)
        let stubborn = desktop.add("12:1", pid: 12, frame: CGRect(x: 300, y: 300, width: 600, height: 400), minimized: true)
        let elsewhere = desktop.add("13:1", pid: 13, frame: CGRect(x: 1600, y: 100, width: 600, height: 400), minimized: true)
        desktop.refusing = [stubborn.id]
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.swipe(0, -0.12)                       // AOM minimizes `ours`
        XCTAssertTrue(desktop.minimizedIDs.contains(ours.id))
        // The app of AOM's window is paused afterwards (S04): no write to it.
        harness.paused = [10]
        harness.swipe(0, 0.12, pause: 3)
        XCTAssertFalse(desktop.log.contains("unmin \(ours.id)"))
        XCTAssertFalse(desktop.minimizedIDs.contains(theirs.id), "a window AOM did not minimize comes back too (S06)")
        XCTAssertTrue(desktop.minimizedIDs.contains(stubborn.id))
        XCTAssertTrue(desktop.minimizedIDs.contains(elsewhere.id), "this display only")
        XCTAssertEqual(harness.announced.last, "Restored 1 of 3 Windows")
        // Resumed and the app no longer refusing: the next swipe gets the rest.
        harness.paused = []
        desktop.refusing = []
        harness.swipe(0, 0.12, pause: 3)
        XCTAssertEqual(desktop.minimizedIDs, [elsewhere.id])
        XCTAssertEqual(harness.announced.last, "Restored 2 Windows")
        // Nothing left that this swipe can do; failures alone say so.
        desktop.refusing = [elsewhere.id]
        harness.swipe(0, 0.12, pause: 3)
        harness.swipe(0, 0.12, pause: 0.3)             // twice: every display
        XCTAssertEqual(harness.announced.suffix(2), ["Nothing to Unminimize", "Could Not Restore 1 Window"])
    }

    func testDelayedAndAsynchronousWorkChecksAgainWhenItRuns() throws {
        // A Mission Control pinch in waits for a second one; paused meanwhile: no close.
        let app = try someOtherApp()
        let pid = app.processIdentifier
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        UserDefaults.standard.set(true, forKey: TrackpadUtilityGestures.missionControlGesturesKey)
        harness.inTopBand = false
        harness.thumbnailWindow = GestureWindow(id: "\(pid):mc", pid: pid)
        harness.pinch(in: true)
        harness.allowed = false
        harness.drain()
        harness.allowed = true
        XCTAssertEqual(desktop.log, [])
        // The pause while fingers are down drops the waiting work too.
        harness.pinch(in: true)
        harness.frame(two(0.5, 0.5), after: 0.05)
        harness.allowed = false
        harness.frame(two(0.5, 0.5), after: 0.02)
        harness.allowed = true
        harness.frame(two(0.5, 0.5), after: 0.02)
        harness.frame([], after: 0.02)
        harness.drain()
        XCTAssertEqual(desktop.log, [])
    }

    // MARK: Mission Control

    func testMissionControlThumbnailGestures() throws {
        let app = try someOtherApp()
        let pid = app.processIdentifier
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.inTopBand = false
        let window = GestureWindow(id: "\(pid):mc", pid: pid)
        harness.thumbnailWindow = window
        // Off by default.
        harness.pinch(in: true)
        harness.drain()
        XCTAssertEqual(desktop.log, [])
        UserDefaults.standard.set(true, forKey: TrackpadUtilityGestures.missionControlGesturesKey)
        harness.pinch(in: true)
        XCTAssertEqual(desktop.log, [], "waits for a second pinch")
        harness.drain()
        XCTAssertEqual(desktop.log, ["close \(window.id)"])
        // Twice: the app is asked to quit instead; the window is not closed.
        harness.pinch(in: true)
        harness.pinch(in: true, pause: 0.12)
        harness.drain()
        XCTAssertEqual(harness.quits, [pid])
        XCTAssertEqual(desktop.log, ["close \(window.id)"])
        // Swipe down: minimize. A paused app or AOM's own window: nothing.
        harness.swipe(0, -0.12)
        XCTAssertEqual(desktop.log.last, "min \(window.id)")
        desktop.log = []
        harness.paused = [pid]
        harness.swipe(0, -0.12)
        harness.pinch(in: true)
        harness.drain()
        harness.paused = []
        harness.thumbnailWindow = GestureWindow(id: "own", pid: getpid())
        harness.pinch(in: true)
        harness.drain()
        XCTAssertEqual(desktop.log, [])
    }

    // MARK: The menu bar's parts, the app menu, scroll to top, the app switcher

    func testTheMenuBarsPartsDecideWhatAGestureDoes() throws {
        let app = try someOtherApp()
        let pid = app.processIdentifier
        let desktop = Desktop333()
        let w1 = desktop.add("\(pid):1", pid: pid, frame: CGRect(x: 0, y: 25, width: 600, height: 400))
        desktop.focused[pid] = w1
        let harness = Harness333(desktop)
        defer { harness.restore() }
        // Status items and menu titles: no menu-bar gesture (their own right-click).
        for spot in [MenuBarSpot.statusItem, .menuTitle] {
            harness.spot = spot
            harness.swipe(0, -0.12)
        }
        XCTAssertEqual(desktop.log, [])
        // No answer in time: the empty area, as in 3.3.2.
        harness.spot = .unknown
        harness.swipe(0, -0.12)
        XCTAssertEqual(desktop.log, ["min \(w1.id)"])
        // The app's menu: nothing unless the Application Menu option is on,
        // then the Dock's gestures for that app.
        desktop.minimizedIDs = []
        desktop.log = []
        harness.spot = .appMenu(pid)
        harness.swipe(0, -0.12, pause: 3)
        XCTAssertEqual(desktop.log, [])
        UserDefaults.standard.set(true, forKey: TrackpadUtilityGestures.appMenuGesturesKey)
        harness.swipe(0, -0.12, pause: 3)
        XCTAssertEqual(desktop.log, ["min \(w1.id)"], "the front window, as on its Dock icon")
        harness.pinch(in: true)
        harness.drain()
        XCTAssertEqual(harness.quits, [pid])
        harness.spot = .appMenu(getpid())
        harness.pinch(in: true)
        harness.drain()
        XCTAssertEqual(harness.quits, [pid], "never AOM's own menu")
        // The Space swipe is the top band's, whatever part it is on.
        harness.spot = .statusItem
        harness.swipe(0.16, 0)
        XCTAssertEqual(harness.spaces, [true])
    }

    func testATapOnTheEmptyMenuBarScrollsTheFrontWindowToTheTop() {
        let desktop = Desktop333()
        desktop.frontmost = 50
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.tap()
        harness.drain()
        XCTAssertEqual(desktop.log, [], "off by default")
        UserDefaults.standard.set(true, forKey: TrackpadUtilityGestures.menuBarScrollToTopKey)
        harness.tap()
        XCTAssertEqual(desktop.log, [], "waits to see whether it is a double tap")
        harness.drain()
        XCTAssertEqual(desktop.log, ["scroll to top 50"])
        // A double tap unsnaps instead (nothing snapped here) and scrolls nothing.
        desktop.log = []
        harness.doubleTap()
        harness.drain()
        XCTAssertEqual(desktop.log, [])
        XCTAssertEqual(harness.announced.last, "No Snapped Windows")
        // Paused for the front app, on a status item, or AOM paused before it runs: nothing.
        harness.paused = [50]
        harness.tap()
        harness.drain()
        harness.paused = []
        harness.spot = .statusItem
        harness.tap()
        harness.drain()
        harness.spot = .empty
        harness.tap()
        harness.allowed = false
        harness.drain()
        harness.allowed = true
        XCTAssertEqual(desktop.log, [])
        desktop.scrollOutcome = .noScrollArea
        harness.tap()
        harness.drain()
        XCTAssertEqual(harness.announced.last, "Nothing to Scroll")
    }

    func testTapHoldAndScrollCanHoldTheMacOSAppSwitcher() {
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        UserDefaults.standard.set(TrackpadUtilityGestures.SwitcherMode.apps.rawValue,
                                  forKey: TrackpadUtilityGestures.menuBarSwitcherKey)
        harness.hold()
        harness.frame(two(0.5, 0.38), after: 0.05)   // opens it
        harness.frame(two(0.5, 0.26), after: 0.2)    // next
        harness.frame(two(0.5, 0.38), after: 0.2)    // back
        harness.frame([], after: 0.05)               // lifting takes the selection
        XCTAssertEqual(desktop.log, ["⌘⇥ begin", "⌘⇥ next", "⌘⇥ back", "⌘⇥ take"])
        // A third finger lets it go without switching; so does a lost touch.
        desktop.log = []
        harness.hold()
        harness.frame(two(0.5, 0.38), after: 0.05)
        harness.frame(two(0.5, 0.38) + [thirdFinger], after: 0.05)
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log, ["⌘⇥ begin", "⌘⇥ cancel"])
        desktop.log = []
        harness.hold()
        harness.frame(two(0.5, 0.38), after: 0.05)
        harness.service.now = { 5_000 }              // the trackpad went quiet
        harness.drain()
        XCTAssertEqual(desktop.log, ["⌘⇥ begin", "⌘⇥ cancel"])
        harness.service.now = { 1_000 }
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log, ["⌘⇥ begin", "⌘⇥ cancel"], "let go once")
        // Not available (⌘ disables AOM): AOM's window switcher, as in 3.3.2.
        desktop.log = []
        desktop.appSwitcherAvailable = false
        harness.hold()
        harness.frame(two(0.5, 0.38), after: 0.05)
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log, ["switcher"])
    }

    func testAThirdFingerOrTheHoldStillCancelClosesTheWindowSwitcherWithoutSwitching() {
        let desktop = Desktop333()
        let harness = Harness333(desktop)
        defer { harness.restore() }
        harness.hold()
        harness.frame(two(0.5, 0.38), after: 0.05)   // opens the window switcher
        harness.frame(two(0.5, 0.26), after: 0.2)    // moves through it
        harness.frame(two(0.5, 0.26) + [thirdFinger], after: 0.05)
        harness.frame([], after: 0.05)
        XCTAssertEqual(desktop.log, ["switcher", "cancel switcher"])
    }
}
