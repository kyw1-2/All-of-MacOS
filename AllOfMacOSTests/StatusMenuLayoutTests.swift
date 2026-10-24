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
        XCTAssertEqual(headers, ["Capture", "Clipboard", "System", "Automation"])
        XCTAssertFalse(items.contains { $0.hasPrefix("All of MacOS v") }, "The version moved to Settings › About")
    }

    func testEveryCommandIsStillReachable() {
        let menu = AppDelegate().makeStatusMenu()
        let items = titles(menu)
        for title in ["Capture Area", "Capture Window", "Capture Fullscreen", "Capture Text (OCR)", "Record Screen",
                      "All Capture Tools", "Clipboard Shelf", "Paste Stack", "Paste Next in Stack",
                      "Gestures & Shortcuts", "Drag to Snap", "Open All of MacOS", "Settings…", "More"] {
            XCTAssertTrue(items.contains(title), "Missing \(title)")
        }
        XCTAssertTrue(items.contains { $0 == "Pause Clipboard History" || $0 == "Resume Clipboard History" })
        XCTAssertTrue(items.contains { $0.hasPrefix("Pause AOM") })
        let more = menu.items.first { $0.title == "More" }?.submenu.map(titles) ?? []
        for title in ["Floating Menus & Widgets…", "Show Cheat Sheet", "Gesture HUD", "Test HUD Overlay", "Restart All of MacOS"] {
            XCTAssertTrue(more.contains(title), "More is missing \(title)")
        }
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
