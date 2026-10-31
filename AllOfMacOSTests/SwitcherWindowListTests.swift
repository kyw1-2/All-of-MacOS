import XCTest
@testable import AllOfMacOS

/// Building the switcher's list from window-server and Accessibility
/// fixtures: on-screen order, minimized windows, hidden apps, windows in
/// other Spaces vouched for by the Window menu, and the windows that must
/// not appear (helpers, closed-but-kept windows, AOM's own).
final class SwitcherWindowListTests: XCTestCase {
    private func server(_ id: CGWindowID, pid: pid_t, title: String, x: CGFloat = 0, onScreen: Bool = true,
                        layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600)) -> SwitcherServerWindow {
        SwitcherServerWindow(windowID: id, pid: pid, title: title, frame: CGRect(origin: CGPoint(x: x, y: 40), size: size),
                             layer: layer, isOnScreen: onScreen, alpha: 1)
    }

    private func app(_ pid: pid_t, _ name: String, hidden: Bool = false, ax: [SwitcherAXWindow] = [],
                     windowMenu: [String] = []) -> SwitcherApp {
        SwitcherApp(pid: pid, name: name, bundleID: "test.\(name)", isHidden: hidden, axWindows: ax,
                    windowMenu: windowMenu.map { ($0, nil) })
    }

    private func ax(_ title: String, x: CGFloat = 0, minimized: Bool = false) -> SwitcherAXWindow {
        SwitcherAXWindow(title: title, frame: CGRect(x: x, y: 40, width: 800, height: 600), isMinimized: minimized, element: nil)
    }

    func testOrderAndStates() {
        let windows = [
            server(1, pid: 10, title: "Safari — Swift", x: 0),
            server(2, pid: 20, title: "", x: 100),                                   // title from Accessibility
            server(3, pid: 10, title: "Safari — Docs", x: 300, onScreen: false),     // minimized
            server(4, pid: 30, title: "Music", x: 0, onScreen: false),               // hidden app
            server(5, pid: 40, title: "Assignment 3.pages", onScreen: false),        // another Space
            server(6, pid: 40, title: "Settings", onScreen: false),                  // closed but kept: not in the Window menu
            server(7, pid: 10, title: "", onScreen: false),                          // untitled off-screen helper
            server(8, pid: 20, title: "Tooltip", size: CGSize(width: 90, height: 30)),  // too small
            server(9, pid: 20, title: "Menu", layer: 25),                            // not a normal window
            server(10, pid: 99, title: "AOM Window"),                                // not a listed app (AOM itself)
        ]
        let apps: [pid_t: SwitcherApp] = [
            10: app(10, "Safari", ax: [ax("Safari — Swift"), ax("Safari — Docs", x: 300, minimized: true)]),
            20: app(20, "Terminal", ax: [ax("~/Projects — zsh", x: 100)]),
            30: app(30, "Music", hidden: true, ax: [ax("Music")]),
            40: app(40, "Pages", windowMenu: ["Minimize", "Zoom", "Assignment 3.pages"]),
        ]
        let list = SwitcherWindowList.build(server: windows, apps: apps, recentApps: [20, 10, 40, 30])
        XCTAssertEqual(list.map(\.windowID), [1, 2, 4, 5, 3],
                       "on screen front to back, then hidden apps, other Spaces and minimized windows")
        XCTAssertEqual(list.map(\.state), [.normal, .normal, .hidden, .otherSpace, .minimized])
        XCTAssertEqual(list[1].title, "~/Projects — zsh", "a window without a server title takes the Accessibility one")
        XCTAssertEqual(list[0].appName, "Safari")
    }

    func testMinimizedWindowsOnlyAccessibilityKnowsAreKept() {
        let apps: [pid_t: SwitcherApp] = [10: app(10, "Preview", ax: [ax("Scan.pdf", minimized: true)])]
        let list = SwitcherWindowList.build(server: [], apps: apps, recentApps: [])
        XCTAssertEqual(list.map(\.title), ["Scan.pdf"])
        XCTAssertEqual(list.first?.state, .minimized)
        XCTAssertGreaterThan(list.first?.windowID ?? 0, SwitcherWindowList.syntheticIDBase)
    }

    func testOffScreenGroupsFollowAppRecency() {
        let windows = [
            server(1, pid: 10, title: "Old", onScreen: false),
            server(2, pid: 20, title: "Recent", onScreen: false),
        ]
        let apps: [pid_t: SwitcherApp] = [10: app(10, "A", windowMenu: ["Old"]), 20: app(20, "B", windowMenu: ["Recent"])]
        XCTAssertEqual(SwitcherWindowList.build(server: windows, apps: apps, recentApps: [20, 10]).map(\.title), ["Recent", "Old"])
    }

    func testRepeatedTitlesUseEachWindowMenuEntryOnce() {
        let windows = [
            server(1, pid: 10, title: "Untitled", onScreen: false),
            server(2, pid: 10, title: "Untitled", onScreen: false),
            server(3, pid: 10, title: "Untitled", onScreen: false),
        ]
        let apps: [pid_t: SwitcherApp] = [10: app(10, "TextEdit", windowMenu: ["Untitled", "Untitled"])]
        XCTAssertEqual(SwitcherWindowList.build(server: windows, apps: apps, recentApps: []).count, 2,
                       "two menu entries vouch for two windows, not three")
    }

    func testFrameMatchingTolerance() {
        XCTAssertTrue(SwitcherWindowList.close(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 2, y: -2, width: 101, height: 99)))
        XCTAssertFalse(SwitcherWindowList.close(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 10, y: 0, width: 100, height: 100)))
    }

    func testStateLabels() {
        XCTAssertNil(SwitcherWindowState.normal.label)
        XCTAssertEqual(SwitcherWindowState.minimized.label, "Minimized")
        XCTAssertEqual(SwitcherWindowState.otherSpace.label, "Other Space")
    }

    @MainActor
    func testControllerFiltersAndKeepsTheClickedCard() {
        let controller = WindowSwitcherController.shared
        var activated: [CGWindowID] = []
        controller.activateTarget = { activated.append($0.id) }
        defer {
            controller.activateTarget = { _ in }
            controller.query = ""
        }
        controller.items = [
            WindowSwitcherController.Item(id: 1, title: "GitHub", appName: "Chrome", icon: nil, axWindow: nil, pid: 1, thumbnail: nil),
            WindowSwitcherController.Item(id: 2, title: "카카오톡", appName: "KakaoTalk", icon: nil, axWindow: nil, pid: 2,
                                          thumbnail: nil, state: .minimized),
            WindowSwitcherController.Item(id: 3, title: "zsh", appName: "Terminal", icon: nil, axWindow: nil, pid: 3, thumbnail: nil),
        ]
        controller.query = "ㅋㅋ"
        XCTAssertEqual(controller.visibleItems.map(\.id), [2])
        XCTAssertEqual(controller.selectedIndex, 0, "a new search selects its best match")
        controller.query = ""
        XCTAssertEqual(controller.visibleItems.map(\.id), [1, 2, 3])
        controller.moveSelection(-1)
        XCTAssertEqual(controller.selectedIndex, 2, "moving left from the first card wraps")
        controller.selectAndConfirm(id: 2)
        XCTAssertEqual(activated, [2])
    }
}
