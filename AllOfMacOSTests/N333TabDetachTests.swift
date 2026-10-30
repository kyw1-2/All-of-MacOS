import XCTest
@testable import AllOfMacOS

/// N333-05 (3.3.3 re-audit): a tab detach went on when selecting the tab
/// failed, and right before pressing Move Tab to New Window it asked only
/// about the pause, so a selection that did not take, or another tab or
/// window chosen in the app during the 0.15 s, let the menu move another tab.
/// `SwishTabDetachSteps` runs here against an app kept in memory: no
/// Accessibility, windows, menus or real tabs.
@MainActor
final class N333TabDetachTests: XCTestCase {
    /// One app with a tab group, in memory: which tab is selected, which
    /// windows are its focused and main ones, and what the detach asked for.
    @MainActor
    private final class TabApp {
        var selected = "A"
        var focused: String? = "W1"
        var main: String? = "W1"
        /// The window a tab reports now, where it is not the one the gesture found.
        var tabWindow: [String: String] = [:]
        /// AXPress on a tab reaches the app, and then really selects it.
        var pressReaches = true
        var pressSelects = true
        var activates = true
        var hasMenuItem = true
        /// The caller's gate: the same request, nothing paused, not locked.
        var allowed = true
        /// The pause comes on while the menu is being searched.
        var pauseDuringSearch = false
        private(set) var gateAsks = 0
        private(set) var log: [String] = []
        private(set) var later: [@MainActor () -> Void] = []
        private(set) var outcome: SwishTabs.DetachOutcome?

        func detach(tab: String, window: String = "W1") {
            let steps = SwishTabDetachSteps<String>(
                mayContinue: { self.gateAsks += 1; return self.allowed },
                tabSelected: { self.selected == tab },
                selectTab: {
                    self.log.append("select \(tab)")
                    guard self.pressReaches else { return false }
                    if self.pressSelects { self.selected = tab }
                    return true
                },
                bringForward: { self.log.append("raise"); return self.activates },
                targetHolds: {
                    // What `SwishTabs.detachTargetHolds` reads, from memory.
                    self.selected == tab
                        && SwishTabs.windowInFront(focused: self.focused, main: self.main, window: window,
                                                   tabWindow: self.tabWindow[tab], same: { $0 == $1 })
                },
                findItem: {
                    self.log.append("search")
                    if self.pauseDuringSearch { self.allowed = false }
                    return self.hasMenuItem ? "Move Tab to New Window" : nil
                },
                press: { self.log.append("press \($0)"); return true },
                after: { delay, work in
                    XCTAssertEqual(delay, 0.15, accuracy: 1e-9)
                    self.later.append(work)
                })
            steps.run { self.outcome = $0 }
        }

        /// The activation delay passes.
        func waitForActivation() {
            let work = later
            later = []
            work.forEach { $0() }
        }

        var pressed: Bool { log.contains { $0.hasPrefix("press") } }
    }

    // MARK: A selection that fails stops the detach

    func testAFailedSelectionNeverActivatesOrPressesTheMenu() {
        let app = TabApp()
        app.pressReaches = false
        app.detach(tab: "B")
        XCTAssertEqual(app.outcome, .notSelected)
        XCTAssertEqual(app.log, ["select B"], "no activation, no menu search")
        XCTAssertTrue(app.later.isEmpty, "nothing waits for the activation")
        XCTAssertFalse(app.pressed)
    }

    func testASelectionThatDoesNotTakeStopsTheDetach() {
        let app = TabApp()
        app.pressSelects = false        // the press reached the app, A is still selected
        app.detach(tab: "B")
        XCTAssertEqual(app.outcome, .notSelected, "the tab is read again after the press")
        XCTAssertEqual(app.log, ["select B"])
        XCTAssertEqual(app.selected, "A")
        XCTAssertFalse(app.pressed, "Move Tab to New Window would have moved tab A")
    }

    // MARK: Another tab or window chosen during the delay

    func testAnotherTabSelectedDuringTheDelayStopsThePress() {
        let app = TabApp()
        app.detach(tab: "B")
        XCTAssertNil(app.outcome, "waiting for the activation")
        XCTAssertEqual(app.selected, "B")
        app.selected = "C"              // the user clicks tab C meanwhile
        app.waitForActivation()
        XCTAssertEqual(app.outcome, .targetChanged)
        XCTAssertEqual(app.log, ["select B", "raise", "search"])
        XCTAssertFalse(app.pressed)
    }

    func testAnotherWindowOfTheAppInFrontDuringTheDelayStopsThePress() {
        let app = TabApp()
        app.selected = "B"
        app.detach(tab: "B")
        app.focused = "W2"              // another window of the same app is chosen
        app.main = "W2"
        app.waitForActivation()
        XCTAssertEqual(app.outcome, .targetChanged, "B is still selected, but in a window in the back")
        XCTAssertFalse(app.pressed)
    }

    func testANewerRequestOrAPauseDuringTheDelayStopsThePress() {
        let app = TabApp()
        app.detach(tab: "B")
        app.allowed = false             // a newer detach, a pause, the screen locked
        app.waitForActivation()
        XCTAssertEqual(app.outcome, .cancelled)
        XCTAssertEqual(app.log, ["select B", "raise"], "not even the menu is searched")
        XCTAssertFalse(app.pressed)

        // Paused while the menu search runs (it may take up to a second).
        let late = TabApp()
        late.pauseDuringSearch = true
        late.detach(tab: "B")
        late.waitForActivation()
        XCTAssertEqual(late.outcome, .cancelled)
        XCTAssertEqual(late.log, ["select B", "raise", "search"])
        XCTAssertEqual(late.gateAsks, 3, "asked again right before the press")
        XCTAssertFalse(late.pressed)
    }

    func testAPauseBeforeAnythingDoesNothingAtAll() {
        let app = TabApp()
        app.allowed = false
        app.detach(tab: "B")
        XCTAssertEqual(app.outcome, .cancelled)
        XCTAssertEqual(app.log, [])
        XCTAssertEqual(app.selected, "A", "the tab is not even selected")
    }

    // MARK: The normal path

    func testTheNormalPathSelectsActivatesWaitsChecksAndPresses() {
        let app = TabApp()
        app.detach(tab: "B")
        app.waitForActivation()
        XCTAssertEqual(app.outcome, .pressed)
        XCTAssertEqual(app.log, ["select B", "raise", "search", "press Move Tab to New Window"])
        XCTAssertEqual(app.gateAsks, 3, "before selecting, after the delay, right before the press")
    }

    func testASelectedTabIsNotPressedAgain() {
        let app = TabApp()
        app.selected = "B"
        app.detach(tab: "B")
        app.waitForActivation()
        XCTAssertEqual(app.outcome, .pressed)
        XCTAssertEqual(app.log, ["raise", "search", "press Move Tab to New Window"])
    }

    func testANativeTabShownInAWindowOfItsOwnStillDetaches() {
        let app = TabApp()
        app.detach(tab: "B")
        // AppKit window tabs are windows: tab B may now report, and focus, W1b.
        app.tabWindow["B"] = "W1b"
        app.focused = "W1b"
        app.main = "W1b"
        app.waitForActivation()
        XCTAssertEqual(app.outcome, .pressed)
    }

    func testNoMenuItemOrAFailedActivationPressesNothing() {
        let noItem = TabApp()
        noItem.hasMenuItem = false
        noItem.detach(tab: "B")
        noItem.waitForActivation()
        XCTAssertEqual(noItem.outcome, .noMenuItem)
        XCTAssertFalse(noItem.pressed)

        let gone = TabApp()
        gone.activates = false
        gone.detach(tab: "B")
        XCTAssertEqual(gone.outcome, .notActivated)
        XCTAssertTrue(gone.later.isEmpty)
        XCTAssertFalse(gone.pressed)
    }

    // MARK: Which window the menu acts on

    func testTheTabsWindowMustBeTheAppsFocusedOrMainWindow() {
        func inFront(focused: String?, main: String?, tabWindow: String? = nil) -> Bool {
            SwishTabs.windowInFront(focused: focused, main: main, window: "W1", tabWindow: tabWindow,
                                    same: { $0 == $1 })
        }
        XCTAssertTrue(inFront(focused: "W1", main: "W1"))
        XCTAssertTrue(inFront(focused: "Inspector", main: "W1"), "a panel in front: menu commands reach the main window")
        XCTAssertTrue(inFront(focused: nil, main: "W1"), "an app without a focused window answer")
        XCTAssertTrue(inFront(focused: "W1b", main: "W1b", tabWindow: "W1b"), "the window the tab reports now")
        XCTAssertFalse(inFront(focused: "W2", main: "W2"), "another window of the app")
        XCTAssertFalse(inFront(focused: "W2", main: "W2", tabWindow: "W3"))
        XCTAssertFalse(inFront(focused: nil, main: nil), "nothing readable counts as changed")
    }
}
