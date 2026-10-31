import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

/// The menu bar countdown's title and menu, and the Focus page rendering
/// in the isolated test environment. No status item is ever created here:
/// the isolated controller refuses to make one.
@MainActor
final class FocusStatusItemTests: XCTestCase {
    private var world: FocusTestWorld!
    override func setUp() async throws { world = FocusTestWorld() }
    override func tearDown() async throws { world.cleanUp(); world = nil }

    func testTheCountdownTitleAndItsMenuFollowTheSession() throws {
        let session = world.makeSession()
        let controller = FocusStatusItemController(isolated: true)
        controller.attach(session)
        XCTAssertNil(FocusStatusItemController.title(timer: session.timer, now: world.clock.now), "nothing while idle")

        session.start()
        world.clock.advance(398)
        session.tick()
        XCTAssertEqual(FocusStatusItemController.title(timer: session.timer, now: world.clock.now), "18:22")
        controller.update()
        XCTAssertFalse(controller.isShowing, "an isolated controller never puts an item in the menu bar")

        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Focus · 18:22 left", "Pause", "Skip to Break", "Stop Focus", "Open Focus"])
        session.pause()
        controller.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "Resume" })
        session.resume()
        session.skip()
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first?.title, "Break · 5:00 left")
        XCTAssertTrue(menu.items.contains { $0.title == "Skip Break" })
        session.stop()
        controller.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.isEmpty, "no session, no menu")
    }

    func testTheFocusPageRendersInBothStates() throws {
        let env = FocusModule.environment
        XCTAssertTrue(env.isolated)
        func render() throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: FocusPage().frame(width: 1100, height: 2600))
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 2600)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        XCTAssertGreaterThan(try render().pixelsWide, 0)
        XCTAssertFalse(FocusModule.isSessionActive)
        env.session.start()
        XCTAssertTrue(FocusModule.isSessionActive)
        defer {
            env.session.stop()
            XCTAssertFalse(FocusModule.isSessionActive)
        }
        XCTAssertGreaterThan(try render().pixelsHigh, 0, "a running session renders too")
        XCTAssertFalse(env.statusItem.isShowing)
        XCTAssertEqual(AOMModuleStatusBoard.focus.isOn, true, "the Workspace tile is on while a session runs")
    }

    func testTheHUDContentSizesItself() {
        let host = NSHostingView(rootView: FocusHUDView(symbol: "timer", title: "Focus: 18 min left", detail: "Messages is hidden"))
        let size = host.fittingSize
        XCTAssertGreaterThan(size.width, 150)
        XCTAssertLessThanOrEqual(size.width, 320, "the HUD stays small")
        XCTAssertGreaterThan(size.height, 60)
    }
}
