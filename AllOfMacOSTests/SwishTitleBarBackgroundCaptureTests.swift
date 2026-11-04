import XCTest
@testable import AllOfMacOS

/// 3.4.12: a title-bar gesture on a window whose app is not in front. The
/// window server's record of the window under the pointer is what the capture
/// trusts, and the Accessibility window must be that very window (matched by
/// frame); a pinch in closes the window, two quick ones force quit the app, and
/// nothing that cannot be taken back runs on a window the hit-test did not
/// confirm. Pure: geometry, the pinch mapping and the app guards only — no
/// trackpad, Accessibility element or window is touched.
final class SwishTitleBarBackgroundCaptureTests: XCTestCase {
    // MARK: The window server's record vs the Accessibility window

    /// A background app can answer its own hit-test with the window it last
    /// had in front. The window the gesture acts on is the one the window
    /// server reported, so a frame that is not that window's is refused —
    /// within a point, which is all the window server's rounding takes.
    func testTheAccessibilityWindowMustBeTheWindowUnderThePointer() {
        let server = CGRect(x: 120, y: 60, width: 900, height: 620)
        XCTAssertTrue(SwishSnap.sameWindow(accessibilityFrame: server, windowServerBounds: server))
        XCTAssertTrue(SwishSnap.sameWindow(accessibilityFrame: server.offsetBy(dx: 0.5, dy: -0.5),
                                           windowServerBounds: server), "the window server rounds to whole points")
        XCTAssertFalse(SwishSnap.sameWindow(accessibilityFrame: CGRect(x: 140, y: 60, width: 900, height: 620),
                                            windowServerBounds: server), "another window, 20 points away")
        XCTAssertFalse(SwishSnap.sameWindow(accessibilityFrame: CGRect(x: 120, y: 90, width: 900, height: 620),
                                            windowServerBounds: server), "another window, 30 points down")
        XCTAssertFalse(SwishSnap.sameWindow(accessibilityFrame: CGRect(x: 120, y: 60, width: 895, height: 620),
                                            windowServerBounds: server), "another size is another window")
        XCTAssertFalse(SwishSnap.sameWindow(accessibilityFrame: .zero, windowServerBounds: server),
                       "a collapsed frame is no window")
        XCTAssertFalse(SwishSnap.sameWindow(accessibilityFrame: server, windowServerBounds: .zero),
                       "a window the window server did not place is no window")
    }

    // MARK: Where a gesture on a background window may start

    /// The title band of the window the window server reported: the top 30
    /// points, which is a title bar, and never the document below it.
    func testABackgroundTitleBarIsInTheWindowsTopBand() {
        let frame = CGRect(x: 100, y: 200, width: 1000, height: 700)
        XCTAssertTrue(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 500, y: 200), windowFrame: frame),
                      "the window's own top edge")
        XCTAssertTrue(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 500, y: 229), windowFrame: frame))
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 500, y: 231), windowFrame: frame),
                       "the content below the bar, where a swipe scrolls")
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 99, y: 205), windowFrame: frame),
                       "left of the window")
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 500, y: 199), windowFrame: frame),
                       "above the window")
        // The cheap pre-filter that asks the window server first agrees, so a
        // pointer in a document never reaches an Accessibility request at all.
        XCTAssertTrue(SwishSnap.inPreFilterBand(pointerY: 205, windowTop: 200, anywhere: false))
        XCTAssertTrue(SwishSnap.inPreFilterBand(pointerY: 300, windowTop: 200, anywhere: false),
                      "the toolbar and tab-bar band, where the hit-test decides")
        XCTAssertFalse(SwishSnap.inPreFilterBand(pointerY: 199, windowTop: 200, anywhere: false))
        XCTAssertTrue(SwishSnap.inPreFilterBand(pointerY: 800, windowTop: 200, anywhere: true),
                      "the Super modifier's whole-window gestures")
    }

    /// The frame-matched path (the hit-test was refused or named another
    /// window) starts from the band alone: the same decision the hit-test's
    /// toolbar and tab bar would have made, without the walk.
    func testAFrameMatchedCaptureStartsOnlyOnTheTitleBand() {
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: false, onTabBar: false, inTitleBand: true, anywhere: false))
        XCTAssertFalse(SwishSnap.isStartArea(onTitleBar: false, onTabBar: false, inTitleBand: false, anywhere: false),
                       "anywhere else on the window is nothing")
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: true, onTabBar: false, inTitleBand: false, anywhere: false),
                      "a toolbar the shallow probe found")
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: false, onTabBar: true, inTitleBand: false, anywhere: false),
                      "a tab bar the shallow probe found")
        XCTAssertTrue(SwishSnap.isStartArea(onTitleBar: false, onTabBar: false, inTitleBand: false, anywhere: true))
    }

    // MARK: Pinches

    /// One pinch in closes the window and waits for a second; the second quick
    /// pinch in is the user's explicit force quit. Everything that must not be
    /// force terminated falls back to the polite quit on the same gesture.
    func testPinchInClosesTheWindowAndTwoQuickOnesForceQuitIt() {
        func pinch(_ kind: SwishSnap.Pinch, second: Bool = false, held: Bool = false,
                   mayForceQuit: Bool = true, displays: Int = 1) -> String {
            let decision = SwishSnap.pinchAction(kind, second: second, held: held, modifiers: [],
                                                 displays: displays, mayForceQuit: mayForceQuit)
            return "\(decision.action)\(decision.waits ? " waits" : "")"
        }
        XCTAssertEqual(pinch(.in), "close waits", "one pinch in closes once the wait passes")
        XCTAssertEqual(pinch(.in, second: true), "forceQuitApp", "two quick pinches in")
        XCTAssertEqual(pinch(.in, second: true, mayForceQuit: false), "quitApp",
                       "a window the hit-test did not confirm, a protected app or a paused one")
        XCTAssertEqual(pinch(.in, held: true), "quitApp", "tap, hold and pinch in once, as before")
        XCTAssertEqual(pinch(.in, held: true, mayForceQuit: false), "quitApp")
        // Pinch out is untouched: full screen, and with two displays it waits
        // for a second pinch to move the window to the other one.
        XCTAssertEqual(pinch(.out), "toggleFullscreen")
        XCTAssertEqual(pinch(.out, displays: 2), "toggleFullscreen waits")
        XCTAssertEqual(pinch(.out, second: true, displays: 2), "fullscreenOnOtherScreen")
    }

    /// The second half of a "twice" gesture only completes a wait of the same
    /// app, and only an action that waits at all.
    func testOnlyTheWaitingActionOfTheSameAppIsCompleted() {
        XCTAssertEqual(SwishSnap.repeatingAction(pending: .close, pendingPid: 402, capturePid: 402), .close)
        XCTAssertEqual(SwishSnap.repeatingAction(pending: .toggleFullscreen, pendingPid: 402, capturePid: 402),
                       .toggleFullscreen)
        XCTAssertNil(SwishSnap.repeatingAction(pending: .close, pendingPid: 402, capturePid: 403),
                     "another app's window, however close the pointer is")
        XCTAssertNil(SwishSnap.repeatingAction(pending: .close, pendingPid: 0, capturePid: 402),
                     "nothing was waiting")
        XCTAssertNil(SwishSnap.repeatingAction(pending: .minimize, pendingPid: 402, capturePid: 402),
                     "a minimize does not wait for a second half")
        XCTAssertNil(SwishSnap.repeatingAction(pending: .forceQuitApp, pendingPid: 402, capturePid: 402),
                     "a force quit has no second half")
    }

    /// Two deliberate pinches take longer than a double tap, so the first half
    /// of a "twice" gesture waits longer than a double tap does — and not so
    /// long that a stale wait sits on the pad.
    func testTheSecondHalfOfATwiceGestureHasTimeToArrive() {
        XCTAssertGreaterThan(TitleBarWindowSnap.twiceWindow, TitleBarWindowSnap.repeatWindow)
        XCTAssertGreaterThanOrEqual(TitleBarWindowSnap.twiceWindow, 0.5)
        XCTAssertLessThanOrEqual(TitleBarWindowSnap.twiceWindow, 1)
    }

    // MARK: What must never be a target

    /// AOM's own windows, the Dock and Stage Manager (their "windows" are
    /// icons and thumbnails with gestures of their own), the menu bar's hosts
    /// and the login window are never a gesture's target, and Finder's windows
    /// snap like any other app's.
    func testAOMDockAndTheSystemAreNeverATarget() {
        XCTAssertTrue(SwishSnap.isProtectedGestureApp(bundleID: "com.kyw.allofmacos"))
        XCTAssertTrue(SwishSnap.isProtectedGestureApp(bundleID: "com.kyw.allofmacos.preview"))
        XCTAssertTrue(SwishSnap.isProtectedGestureApp(bundleID: "com.apple.dock"))
        XCTAssertTrue(SwishSnap.isProtectedGestureApp(bundleID: "com.apple.WindowManager"),
                      "Stage Manager's thumbnails")
        XCTAssertTrue(SwishSnap.isProtectedGestureApp(bundleID: "com.apple.loginwindow"))
        XCTAssertTrue(SwishSnap.isProtectedGestureApp(bundleID: "com.apple.controlcenter"))
        XCTAssertFalse(SwishSnap.isProtectedGestureApp(bundleID: "com.apple.Safari"))
        XCTAssertFalse(SwishSnap.isProtectedGestureApp(bundleID: "com.apple.finder"))
        XCTAssertFalse(SwishSnap.isProtectedGestureApp(bundleID: nil),
                       "an unnamed process is left to the other guards")
        XCTAssertFalse(SwishSnap.isProtectedGestureApp(bundleID: ""))
    }

    /// The HUD names the force quit as one, and the touch is spent after it:
    /// nothing follows a quit in the same touch.
    func testTheForceQuitIsNamedAndEndsTheTouch() {
        XCTAssertEqual(SwishSnap.title(for: .forceQuitApp, appName: "Safari"), "Force Quit Safari")
        XCTAssertEqual(SwishSnap.title(for: .forceQuitApp, appName: nil), "Force Quit App")
        XCTAssertNotEqual(SwishSnap.title(for: .forceQuitApp, appName: "Safari"),
                          SwishSnap.title(for: .quitApp, appName: "Safari"),
                          "a polite quit and a force quit are two different promises")
        XCTAssertFalse(SwishSnap.touchContinues(after: .forceQuitApp, waits: false))
    }
}