import AppKit
import XCTest
@testable import AllOfMacOS

/// The 3.4.13 menu keeps everyday commands on the root; secondary controls
/// are grouped under More without removing the features from the app.
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
        XCTAssertEqual(headers, ["Capture", "Clipboard"],
                       "Idle Windows/Productivity sections must not occupy the status menu")
        XCTAssertFalse(items.contains { $0.hasPrefix("All of MacOS v") }, "The version moved to Settings › About")
    }

    func testEveryCommandIsStillReachable() {
        let menu = AppDelegate().makeStatusMenu()
        let items = titles(menu)
        // Top level: capture, clipboard, audio, automation and app entry points.
        for title in ["Capture Area", "Capture Window", "Capture Fullscreen", "Capture Text (OCR)", "Record Screen",
                      "All Capture Tools", "Clipboard Shelf", "Keep Awake", "App Audio Engine",
                      "Automation", "Open All of MacOS", "Settings…", "More"] {
            XCTAssertTrue(items.contains(title), "Missing \(title)")
        }
        for title in ["Windows", "Productivity", "Left Half", "Right Half", "Maximize", "Center",
                      "Window Switcher", "Paste Stack", "Pause Clipboard History", "Resume Clipboard History"] {
            XCTAssertFalse(items.contains(title), "\(title) must not clutter the root menu")
        }
        let audio = menu.items.first { $0.title == "App Audio Engine" }
        XCTAssertNotNil(audio?.action, "The audio state must be directly actionable")
        XCTAssertFalse(items.contains("Paste Next in Stack"), "Paste Next remains off the menu bar")
        // The occasional controls moved into More, still one level down.
        let more = menu.items.first { $0.title == "More" }?.submenu.map(titles) ?? []
        for title in ["Clipboard Tools", "Productivity Tools", "Drag to Snap",
                      "Floating Menus & Widgets…", "Show Cheat Sheet", "Gesture HUD",
                      "Test HUD Overlay", "Restart All of MacOS"] {
            XCTAssertTrue(more.contains(title), "More is missing \(title)")
        }
        XCTAssertFalse(more.contains("App Audio Engine"), "Audio is now an everyday toggle")
        let clipboardTools = menu.items.first { $0.title == "More" }?.submenu?.items
            .first { $0.title == "Clipboard Tools" }?.submenu.map(titles) ?? []
        XCTAssertEqual(clipboardTools.count, 3)
        XCTAssertTrue(clipboardTools.contains("Paste Stack"))
        XCTAssertTrue(clipboardTools.contains("Paste Next Clipboard Item"))
        XCTAssertTrue(more.contains("App Audio Mixer…"), "Mixer is reachable under More, not at the root")
        XCTAssertTrue(clipboardTools.contains { $0 == "Pause Clipboard History" || $0 == "Resume Clipboard History" })
        let productivityMenu = menu.items.first { $0.title == "More" }?.submenu?.items
            .first { $0.title == "Productivity Tools" }?.submenu
        XCTAssertNotNil(productivityMenu?.delegate, "Productivity must populate lazily on opening the submenu")
        XCTAssertEqual(productivityMenu.map(titles), ["Open to Load Tools"],
                       "Opening the root menu must not eagerly build every module")
        if let productivityMenu {
            AOMProductivityMenuDelegate.shared.menuNeedsUpdate(productivityMenu)
            let toolTitles = titles(productivityMenu)
            XCTAssertTrue(toolTitles.contains("Measure Screen"), "Ruler is still reachable")
            XCTAssertTrue(toolTitles.contains("Show Drop Shelf"), "Files shelf is still reachable")
            XCTAssertTrue(toolTitles.contains("Mute Microphone"), "Mic controls are still reachable")
            XCTAssertFalse(toolTitles.contains("Open to Load Tools"))
        }
        // The HUD test is a developer check: an ⌥ Option alternate of Gesture HUD.
        let hudTest = menu.items.first { $0.title == "More" }?.submenu?.items.first { $0.title == "Test HUD Overlay" }
        XCTAssertEqual(hudTest?.isAlternate, true)
        XCTAssertEqual(hudTest?.keyEquivalentModifierMask, [.option])
        XCTAssertTrue(more.contains { $0.hasPrefix("Pause AOM") }, "Pause AOM moved into More")
        // The full CleanShot-ordered capture menu is still one level down.
        let capture = menu.items.first { $0.title == "All Capture Tools" }?.submenu.map(titles) ?? []
        XCTAssertEqual(Array(capture.prefix(3)), ["All-In-One", "Capture Area", "Capture Previous Area"])
    }

    func testOnlyLiveProductivityStateGetsTopLevelAttention() {
        XCTAssertEqual(AOMMenuBarPriority.visibleTools(focusRunning: false, microphoneMuted: false), [])
        XCTAssertEqual(AOMMenuBarPriority.visibleTools(focusRunning: true, microphoneMuted: false),
                       [.focusSession])
        XCTAssertEqual(AOMMenuBarPriority.visibleTools(focusRunning: false, microphoneMuted: true),
                       [.mutedMicrophone])
        XCTAssertEqual(AOMMenuBarPriority.visibleTools(focusRunning: true, microphoneMuted: true),
                       [.focusSession, .mutedMicrophone])
    }

    func testTogglesShowTheirState() {
        let menu = AppDelegate().makeStatusMenu()
        let engine = menu.items.first { $0.title == "Automation" }
        XCTAssertNotNil(engine?.action)
        XCTAssertEqual(engine?.state, .on, "A fresh AppDelegate has no paused engine")
    }
}
