import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

final class SidebarSummaryTests: XCTestCase {
    func testGlobalAndApplicationBadgesKeepDisabledGesturesAndGroupPrecedence() {
        let group = UUID()
        var global = Trigger(name: "Global", input: .trackpadGesture(.twoFingerSwipeUp))
        var emptyBundle = global; emptyBundle.appBundleID = ""; emptyBundle.isEnabled = false
        var application = global; application.appBundleID = "com.example.editor"
        var grouped = application; grouped.activationGroupID = group
        global.isEnabled = true
        let counts = AOMSidebarSummary(triggers: [global, emptyBundle, application, grouped])
        XCTAssertEqual(counts.enabled, 3)
        XCTAssertEqual(counts.global, 2)
        XCTAssertEqual(counts.applications, ["com.example.editor": 1])
        XCTAssertEqual(counts.groups, [group: 1])
    }

    func testSinglePassBadgesMatchIndependentScopeQueriesForLargePreset() {
        let group = UUID()
        let triggers = (0..<10_000).map { index in
            var trigger = Trigger(name: "Gesture \(index)", input: .trackpadGesture(.twoFingerSwipeUp))
            trigger.appBundleID = index % 5 == 0 ? nil : "app.\(index % 80)"
            trigger.activationGroupID = index % 7 == 0 ? group : nil
            trigger.isEnabled = index % 3 != 0
            return trigger
        }
        let start = CFAbsoluteTimeGetCurrent()
        let counts = AOMSidebarSummary(triggers: triggers)
        print("AOM 10,000-gesture sidebar aggregation: \(CFAbsoluteTimeGetCurrent() - start) seconds")
        XCTAssertEqual(counts.enabled, triggers.filter(\.isEnabled).count)
        XCTAssertEqual(counts.global, triggers.filter { $0.activationGroupID == nil && ($0.appBundleID?.isEmpty ?? true) }.count)
        XCTAssertEqual(counts.groups[group], triggers.filter { $0.activationGroupID == group }.count)
        for index in 0..<80 {
            XCTAssertEqual(counts.applications["app.\(index)"] ?? 0,
                           triggers.filter { $0.activationGroupID == nil && $0.appBundleID == "app.\(index)" }.count)
        }
    }
}

@MainActor
final class MainWindowMaterialTests: XCTestCase {
    func testMainChromeOnlyMirrorsTheAppearanceChoice() {
        let host = NSHostingView(rootView: Color.clear.background(AOMMainWindowChrome(appearance: "dark")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host; host.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        host.rootView = Color.clear.background(AOMMainWindowChrome(appearance: "light"))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.appearance?.name, .aqua)
        host.rootView = Color.clear.background(AOMMainWindowChrome(appearance: "system"))
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(window.appearance)
        // The title bar and toolbar stay the system's: SwiftUI owns the
        // toolbar (page tools) and the sidebar draws its own material.
        XCTAssertNil(window.toolbar, "The chrome must not install a toolbar of its own")
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .visible)
    }

    func testWindowMaterialConfiguresWhenHostAttachesAndReattaches() {
        let host = NSHostingView(rootView: Color.clear.background(TranslucentWindow()))
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        first.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(first.isOpaque)
        XCTAssertEqual(first.backgroundColor, .clear)
        XCTAssertTrue(first.titlebarAppearsTransparent)
        first.contentView = nil
        second.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(second.isOpaque)
        XCTAssertEqual(second.backgroundColor, .clear)
        XCTAssertTrue(second.titlebarAppearsTransparent)
    }
}
