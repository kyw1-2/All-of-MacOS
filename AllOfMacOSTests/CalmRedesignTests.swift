import SwiftUI
import XCTest
@testable import AllOfMacOS

/// AOM 6.0 "Calm": bounded page retention, contextual action-bar keys and
/// the button scale.
final class CalmRedesignTests: XCTestCase {
    typealias Host = AOMPageHost<EmptyView>

    func testLivePagesAreCappedAndKeepTheirOrder() {
        let order: [AOMMainTab] = [.home, .gestures, .snapping, .capture]
        var visited: [AOMMainTab] = []
        var recent: [AOMMainTab] = []
        for tab in order {
            visited = Host.live(selecting: tab, after: visited, recent: recent)
            recent.append(tab)
        }
        XCTAssertEqual(visited, order, "up to the cap nothing is evicted")
        // A fifth page evicts the least recently selected one (Workspace).
        visited = Host.live(selecting: .audio, after: visited, recent: recent)
        recent.append(.audio)
        XCTAssertEqual(visited, [.gestures, .snapping, .capture, .audio])
        // Revisiting a live page changes nothing; the selected page is never evicted.
        XCTAssertEqual(Host.live(selecting: .gestures, after: visited, recent: recent), visited)
        XCTAssertEqual(visited.count, AOMPageRetention.keepAlive)
    }

    func testRecentlySelectedPagesSurviveEviction() {
        let visited: [AOMMainTab] = [.home, .gestures, .snapping, .capture]
        // Workspace was selected most recently before Audio: Automation goes.
        let recent: [AOMMainTab] = [.gestures, .snapping, .capture, .home]
        XCTAssertEqual(Host.live(selecting: .audio, after: visited, recent: recent),
                       [.home, .snapping, .capture, .audio])
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
