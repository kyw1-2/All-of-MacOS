import SwiftUI
import XCTest
@testable import AllOfMacOS

/// AOM 6.0 "Calm": bounded page retention, contextual action-bar keys and
/// the button scale.
final class CalmRedesignTests: XCTestCase {
    typealias Host = AOMPageHost<EmptyView>

    func testLivePagesAreCappedAndKeepTheirOrder() {
        let order: [AOMMainTab] = [.home, .gestures, .snapping, .capture, .clipboard]
        var visited: [AOMMainTab] = []
        var recent: [AOMMainTab] = []
        for tab in order {
            visited = Host.live(selecting: tab, after: visited, recent: recent)
            recent.append(tab)
        }
        XCTAssertEqual(visited, order, "up to the cap nothing is evicted")
        // One more page evicts the least recently selected one (Workspace).
        visited = Host.live(selecting: .audio, after: visited, recent: recent)
        recent.append(.audio)
        XCTAssertEqual(visited, [.gestures, .snapping, .capture, .clipboard, .audio])
        // Revisiting a live page changes nothing; the selected page is never evicted.
        XCTAssertEqual(Host.live(selecting: .gestures, after: visited, recent: recent), visited)
        XCTAssertEqual(visited.count, AOMPageRetention.keepAlive)
    }

    func testRecentlySelectedPagesSurviveEviction() {
        let visited: [AOMMainTab] = [.home, .gestures, .snapping, .capture, .clipboard]
        // Workspace was selected most recently before Audio: Automation goes.
        let recent: [AOMMainTab] = [.gestures, .snapping, .capture, .clipboard, .home]
        XCTAssertEqual(Host.live(selecting: .audio, after: visited, recent: recent),
                       [.home, .snapping, .capture, .clipboard, .audio])
    }

    @MainActor
    func testBarActionKeysText() {
        let identity = AOMIdentity.neutral("play.fill")
        let test = AOMBarAction(id: "t", title: "Test", identity: identity, run: {},
                                key: SwiftUI.KeyboardShortcut(.return, modifiers: .command))
        XCTAssertEqual(test.keysText, "⌘↩")
        let delete = AOMBarAction(id: "d", title: "Delete", identity: identity, shortcut: "⌫", run: {})
        XCTAssertEqual(delete.keysText, "⌫")
        let copy = AOMBarAction(id: "c", title: "Copy", identity: identity, run: {},
                                key: SwiftUI.KeyboardShortcut("c", modifiers: [.command, .shift]))
        XCTAssertEqual(copy.keysText, "⇧⌘C")
    }

    func testButtonScaleGrowsWithControlSize() {
        let sizes: [ControlSize] = [.mini, .small, .regular, .large]
        let heights = sizes.map(AOMButtonMetrics.height)
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertEqual(Set(heights).count, heights.count)
        XCTAssertGreaterThanOrEqual(AOMButtonMetrics.height(.regular), 24)
    }

    @MainActor
    func testSubtitleStorePublishesOnlyChanges() {
        let store = AOMToolbarSubtitles.shared
        store.set("A", for: .files)
        let before = store.values
        store.set("A", for: .files)
        XCTAssertEqual(store.values, before)
        store.set("B", for: .files)
        XCTAssertEqual(store.values[.files], "B")
    }
}

/// AOM 6.1: status-first automation rows and the input rail.
final class AutomationStatusTests: XCTestCase {
    func testLastRunText() {
        let now = Date()
        XCTAssertNil(AOMAutomationRow.lastRunText(nil, now: now))
        XCTAssertEqual(AOMAutomationRow.lastRunText(now.addingTimeInterval(-20), now: now), "Ran just now")
        XCTAssertEqual(AOMAutomationRow.lastRunText(now.addingTimeInterval(-180), now: now), "Ran 3 min ago")
        XCTAssertEqual(AOMAutomationRow.lastRunText(now.addingTimeInterval(-7_200), now: now), "Ran 2 h ago")
        XCTAssertEqual(AOMAutomationRow.lastRunText(now.addingTimeInterval(-100_000), now: now), "Ran yesterday")
        XCTAssertEqual(AOMAutomationRow.lastRunText(now.addingTimeInterval(-3 * 86_400), now: now), "Ran 3 days ago")
    }

    @MainActor
    func testLastFiredIgnoresDetectionsWithoutARun() {
        let earlier = Date(timeIntervalSinceNow: -600)
        let later = Date(timeIntervalSinceNow: -60)
        let stats = GestureStatistics(testEvents: [
            GestureEvent(gesture: "4 Finger Tap", timestamp: earlier, fired: true),
            GestureEvent(gesture: "4 Finger Tap", timestamp: later, fired: false),
            GestureEvent(gesture: "Unused", timestamp: later, fired: false)
        ])
        XCTAssertNotNil(stats.lastFired("4 Finger Tap"))
        XCTAssertNil(stats.lastFired("Unused"))
        XCTAssertNil(stats.lastFired("Never seen"))
    }

    func testEveryInputKindHasARailEntry() {
        for category in TriggerCategory.inputCategories {
            XCTAssertFalse(AddTriggerSheet.railDetail(category).isEmpty, "\(category)")
            XCTAssertNotNil(NSImage(systemSymbolName: AddTriggerSheet.railSymbol(category), accessibilityDescription: nil))
        }
    }
}
