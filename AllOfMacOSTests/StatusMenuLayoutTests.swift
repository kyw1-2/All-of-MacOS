import AppKit
import XCTest
@testable import AllOfMacOS

/// The menu bar menu is grouped by tool, most-used block first, and keeps
/// every command it had before the regrouping.
@MainActor
final class StatusMenuLayoutTests: XCTestCase {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    func testSectionsLeadWithCaptureAndEndWithQuit() {
        let menu = AppDelegate().makeStatusMenu()
        let items = titles(menu)
        XCTAssertEqual(items.first, "Capture", "The capture block leads the menu")
        XCTAssertTrue(menu.items.first?.isSectionHeader == true)
        XCTAssertEqual(items.last, "Quit All of MacOS")
        let headers = menu.items.filter(\.isSectionHeader).map(\.title)
        XCTAssertEqual(headers, ["Capture", "Clipboard", "Windows"])
        XCTAssertFalse(items.contains { $0.hasPrefix("All of MacOS v") }, "The version moved to Settings › About")
    }

    func testEveryCommandIsStillReachable() {
        let menu = AppDelegate().makeStatusMenu()
        let items = titles(menu)
        // Top level: capture modes, clipboard, the new window snaps, the engine
        // toggle and the app entry points.
        for title in ["Capture Area", "Capture Window", "Capture Fullscreen", "Capture Text (OCR)", "Record Screen",
                      "All Capture Tools", "Clipboard Shelf", "Paste Stack",
                      "Left Half", "Right Half", "Maximize", "Center", "Window Switcher",
                      "Gestures & Shortcuts", "Open All of MacOS", "Settings…", "More"] {
            XCTAssertTrue(items.contains(title), "Missing \(title)")
        }
        XCTAssertFalse(items.contains("Paste Next in Stack"), "Paste Next moved out of the menu bar")
        XCTAssertTrue(items.contains { $0 == "Pause Clipboard History" || $0 == "Resume Clipboard History" })
        // The occasional controls moved into More, still one level down.
        let more = menu.items.first { $0.title == "More" }?.submenu.map(titles) ?? []
        for title in ["Drag to Snap", "Floating Menus & Widgets…", "Show Cheat Sheet",
                      "Gesture HUD", "Test HUD Overlay", "Restart All of MacOS"] {
            XCTAssertTrue(more.contains(title), "More is missing \(title)")
        }
        XCTAssertTrue(more.contains { $0.hasPrefix("Pause AOM") }, "Pause AOM moved into More")
        // The full CleanShot-ordered capture menu is still one level down.
        let capture = menu.items.first { $0.title == "All Capture Tools" }?.submenu.map(titles) ?? []
        XCTAssertEqual(Array(capture.prefix(3)), ["All-In-One", "Capture Area", "Capture Previous Area"])
    }

    func testTogglesShowTheirState() {
        let menu = AppDelegate().makeStatusMenu()
        let engine = menu.items.first { $0.title == "Gestures & Shortcuts" }
        XCTAssertNotNil(engine?.action)
        XCTAssertEqual(engine?.state, .on, "A fresh AppDelegate has no paused engine")
    }
}
