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

/// 7.10 (Bartender 7's General, Hotkeys and Layout panes): the pure parts.
@MainActor
final class AOM710BartenderTests: XCTestCase {
    func testItemHotkeyIDsRoundTrip() {
        let id = MenuBarHotkeys.itemID("com.example.app|menuextra.1", activation: .optionRightClick)
        XCTAssertTrue(id.hasPrefix(MenuBarHotkeys.prefix))
        let parsed = MenuBarHotkeys.parseItem(id)
        XCTAssertEqual(parsed?.activation, .optionRightClick)
        XCTAssertEqual(parsed?.key, "com.example.app|menuextra.1", "keys with dots and bars survive")
        XCTAssertNil(MenuBarHotkeys.parseItem(MenuBarHotkeys.Action.toggle.itemID), "the four pane keys are not item keys")
        XCTAssertNil(MenuBarHotkeys.parseItem(MenuBarHotkeys.prefix + "item.nonsense.key"))
        XCTAssertNil(MenuBarHotkeys.parseItem(MenuBarHotkeys.prefix + "item.leftClick."), "an empty key is refused")
    }

    func testNewAppsStartWhereThePillIs() {
        let stored: [String: MenuBarSection] = ["com.a": .hidden]
        let placed = MenuBarTriggerPolicy.sections(running: ["com.a", "com.b", "com.c", "com.apple.controlcenter"], stored: stored,
                                                   seen: ["com.a", "com.b"], newItems: .alwaysHidden)
        XCTAssertEqual(placed["com.c"], .alwaysHidden, "never seen → the pill's section")
        XCTAssertNil(placed["com.b"], "seen before and left Shown stays Shown")
        XCTAssertEqual(placed["com.a"], .hidden)
        XCTAssertNil(placed["com.apple.controlcenter"], "macOS's own items are never placed")
        XCTAssertEqual(MenuBarTriggerPolicy.sections(running: ["com.c"], stored: [:], seen: [], newItems: .hidden), [:],
                       "first run (nothing seen yet) places nothing")
        XCTAssertEqual(MenuBarTriggerPolicy.sections(running: ["com.c"], stored: [:], seen: ["x"], newItems: .shown), [:])
    }

    func testEmptySpaceAndBand() {
        XCTAssertTrue(MenuBarTriggerPolicy.isEmptySpace(role: "AXMenuBar", parentRole: "AXApplication"))
        XCTAssertTrue(MenuBarTriggerPolicy.isEmptySpace(role: nil, parentRole: nil))
        XCTAssertFalse(MenuBarTriggerPolicy.isEmptySpace(role: "AXMenuBarItem", parentRole: "AXMenuBar"))
        XCTAssertFalse(MenuBarTriggerPolicy.isEmptySpace(role: "AXImage", parentRole: "AXMenuExtra"), "an icon's picture is an item")
        let band = MenuBarTriggerPolicy.band(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleMaxY: 867)
        XCTAssertEqual(band.minY, 867)
        XCTAssertEqual(band.height, 33)
        XCTAssertEqual(MenuBarTriggerPolicy.band(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleMaxY: 900).height, 24,
                       "an auto-hidden menu bar still has a 24 pt band")
    }

    func testRoomAndWideDisplays() {
        XCTAssertTrue(MenuBarTriggerPolicy.hasRoom(hiddenWidth: 200, shownWidth: 300, available: 700))
        XCTAssertFalse(MenuBarTriggerPolicy.hasRoom(hiddenWidth: 400, shownWidth: 300, available: 700), "beside the notch there is no room")
        XCTAssertFalse(MenuBarTriggerPolicy.showsAll(screenWidth: 5000, threshold: 0), "0 is off")
        XCTAssertTrue(MenuBarTriggerPolicy.showsAll(screenWidth: 2560, threshold: 2560))
        XCTAssertFalse(MenuBarTriggerPolicy.showsAll(screenWidth: 1440, threshold: 2560))
    }

    func testPresetsReplaceByNameAndSort() {
        let a = MenuBarPresets.Preset(name: "Work", sections: ["com.a": .hidden])
        let b = MenuBarPresets.Preset(name: "Calm", sections: [:])
        let updated = MenuBarPresets.Preset(name: "work", sections: ["com.b": .alwaysHidden])
        let list = MenuBarPresets.upserting(updated, into: MenuBarPresets.upserting(b, into: [a]))
        XCTAssertEqual(list.map(\.name), ["Calm", "work"], "same name (any case) replaces, sorted")
        XCTAssertEqual(list.last?.sections, ["com.b": .alwaysHidden])
    }

    func testToggleIconsHaveTwoStates() {
        for icon in MenuBarPrefs.ToggleIcon.allCases {
            XCTAssertNotEqual(icon.symbols.collapsed, icon.symbols.expanded, "\(icon) shows whether icons are hidden")
            XCTAssertNotNil(NSImage(systemSymbolName: icon.symbols.collapsed, accessibilityDescription: nil), icon.symbols.collapsed)
            XCTAssertNotNil(NSImage(systemSymbolName: icon.symbols.expanded, accessibilityDescription: nil), icon.symbols.expanded)
        }
    }
}
