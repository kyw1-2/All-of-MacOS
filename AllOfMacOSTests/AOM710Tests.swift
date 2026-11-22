import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.10: hiding on macOS 27 through macOS's own allow-list, by app section.
@MainActor
final class AOM710Tests: XCTestCase {
    func testAllowListKeepsShownAppsAndAOM() {
        let running = ["com.raycast.macos", "com.openai.codex", "com.google.drivefs", "com.kyw.allofmacos", "com.apple.MenuBarAgent"]
        let sections: [String: MenuBarSection] = ["com.openai.codex": .hidden, "com.google.drivefs": .alwaysHidden]
        let collapsed = MenuBarSectionStore.allowed(running: running, sections: sections, hiding: [.hidden, .alwaysHidden], own: "com.kyw.allofmacos")
        XCTAssertEqual(collapsed, ["com.apple.MenuBarAgent", "com.kyw.allofmacos", "com.raycast.macos"])
        let expanded = MenuBarSectionStore.allowed(running: running, sections: sections, hiding: [.alwaysHidden], own: "com.kyw.allofmacos")
        XCTAssertTrue(expanded.contains("com.openai.codex"), "Hidden comes back with ❮")
        XCTAssertFalse(expanded.contains("com.google.drivefs"), "Always Hidden needs Show All")
        XCTAssertTrue(MenuBarSectionStore.allowed(running: [], sections: [:], hiding: [.hidden], own: "me").contains("me"),
                      "AOM's own chevron is always allowed")
    }

    func testSeedHidesWhatSatLeftOfTheChevronButNeverSystemItems() {
        let seed = MenuBarSectionStore.seed(items: [("com.raycast.macos", 900), ("com.openai.codex", 1500),
                                                     ("com.apple.MenuBarAgent", 800)], chevronMinX: 1000)
        XCTAssertEqual(seed, ["com.raycast.macos": .hidden])
    }

    func testNativeLocksSystemAndOwnItems() {
        let own: pid_t = 7
        func item(_ owner: String, pid: pid_t = 50) -> AOMMenuShelfItem {
            AOMMenuShelfItem(pid: pid, ownerBundleID: owner, ownerName: owner, title: "x", axIdentifier: "", ordinal: 0, siblings: 1)
        }
        XCTAssertNotNil(MenuBarLayoutPolicy.lockedReason(item("com.apple.MenuBarAgent"), ownPID: own, native: true))
        XCTAssertNotNil(MenuBarLayoutPolicy.lockedReason(item("com.kyw.allofmacos", pid: own), ownPID: own, native: true))
        XCTAssertNil(MenuBarLayoutPolicy.lockedReason(item("com.raycast.macos"), ownPID: own, native: true))
        XCTAssertNil(MenuBarLayoutPolicy.lockedReason(item("com.kyw.allofmacos", pid: own), ownPID: own, native: false))
    }

    func testBackgroundIsKeyedOutOfPictures() throws {
        // A 10 × 10 blue square with a white 4 × 4 glyph in the middle.
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.16, green: 0.38, blue: 0.68, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 3, y: 3, width: 4, height: 4))
        let clean = try XCTUnwrap(MenuBarItemImager.removeBackground(try XCTUnwrap(context.makeImage())))
        let rep = NSBitmapImageRep(cgImage: clean)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01, "the bar is gone")
        XCTAssertEqual(rep.colorAt(x: 5, y: 5)?.alphaComponent ?? 0, 1, accuracy: 0.01, "the glyph stays")
    }
}
