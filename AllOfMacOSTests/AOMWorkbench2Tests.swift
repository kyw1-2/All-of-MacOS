import XCTest
@testable import AllOfMacOS

/// Native Workbench 2 (AOM-7.16.1 design binary review, D01–D32): the shared
/// layout, width and selection rules.
final class AOMWorkbench2Tests: XCTestCase {
    private let listRange: ClosedRange<Double> = 240...360

    // D04: stored widths from old builds or hand edits never reach layout as is.
    func testStoredWidthIsSanitized() {
        XCTAssertEqual(AOMPaneWidth.sanitized(.nan, range: listRange, fallback: 280), 280)
        XCTAssertEqual(AOMPaneWidth.sanitized(.infinity, range: listRange, fallback: 280), 280)
        XCTAssertEqual(AOMPaneWidth.sanitized(-50, range: listRange, fallback: 280), 280)
        XCTAssertEqual(AOMPaneWidth.sanitized(0, range: listRange, fallback: 280), 280)
        XCTAssertEqual(AOMPaneWidth.sanitized(9_000, range: listRange, fallback: 280), 360)
        XCTAssertEqual(AOMPaneWidth.sanitized(100, range: listRange, fallback: 280), 240)
        XCTAssertEqual(AOMPaneWidth.sanitized(300, range: listRange, fallback: 280), 300)
        XCTAssertEqual(AOMPaneWidth.sanitized(.nan, range: listRange, fallback: .nan), 240, "a bad fallback still lands in range")
    }

    // D02/D04: a narrow window draws the list narrower; the stored width comes back when it widens.
    func testEffectiveWidthShrinksWithoutForgettingTheStoredWidth() {
        let stored = 350.0
        let narrow = AOMPaneWidth.effective(stored: stored, range: listRange, fallback: 280, available: 700, reserved: 428)
        XCTAssertEqual(narrow, 272)
        let narrower = AOMPaneWidth.effective(stored: stored, range: listRange, fallback: 280, available: 500, reserved: 428)
        XCTAssertEqual(narrower, 240, "never below the list minimum")
        let wide = AOMPaneWidth.effective(stored: stored, range: listRange, fallback: 280, available: 1_400, reserved: 428)
        XCTAssertEqual(wide, 350, "the user's width returns")
        XCTAssertEqual(AOMPaneWidth.effective(stored: stored, range: listRange, fallback: 280, available: 0, reserved: 428), 350,
                       "before the first measurement the stored width is used")
    }

    // D04: a drag starts from what is on screen and stops at the window's room.
    func testDragStartsFromTheDisplayedWidth() {
        XCTAssertEqual(AOMPaneWidth.dragged(start: 272, delta: 10, range: listRange), 282)
        XCTAssertEqual(AOMPaneWidth.dragged(start: 272, delta: 60, range: listRange, maximum: 300), 300)
        XCTAssertEqual(AOMPaneWidth.dragged(start: 272, delta: -100, range: listRange), 240)
        XCTAssertEqual(AOMPaneWidth.dragged(start: 272, delta: .nan, range: listRange), 272)
        XCTAssertEqual(AOMPaneWidth.dragged(start: 272, delta: 10, range: listRange, maximum: 100), 240,
                       "a maximum below the range keeps the range minimum")
    }

    // D02: 20 pt of hysteresis; the minimum holds while side by side.
    func testSideBySideHysteresis() {
        let minimum: CGFloat = 740
        XCTAssertTrue(AOMWorkbenchPolicy.sideBySide(available: 740, minimum: minimum, current: true))
        XCTAssertFalse(AOMWorkbenchPolicy.sideBySide(available: 739, minimum: minimum, current: true))
        XCTAssertFalse(AOMWorkbenchPolicy.sideBySide(available: 755, minimum: minimum, current: false), "inside the band it stays")
        XCTAssertTrue(AOMWorkbenchPolicy.sideBySide(available: 760, minimum: minimum, current: false))
        XCTAssertTrue(AOMWorkbenchPolicy.sideBySide(available: 0, minimum: minimum, current: true), "no measurement keeps the arrangement")
    }

    // D03: 30 round trips across the threshold flip exactly once each way per trip, never inside the band.
    func testResizeRoundTripsDontFlapInsideTheBand() {
        var sideBySide = true
        var flips = 0
        for _ in 0..<30 {
            for width in stride(from: CGFloat(800), through: 700, by: -5) {
                let next = AOMWorkbenchPolicy.sideBySide(available: width, minimum: 740, current: sideBySide)
                if next != sideBySide { flips += 1; sideBySide = next }
            }
            for width in stride(from: CGFloat(700), through: 800, by: 5) {
                let next = AOMWorkbenchPolicy.sideBySide(available: width, minimum: 740, current: sideBySide)
                if next != sideBySide { flips += 1; sideBySide = next }
            }
            // Jitter inside the band changes nothing.
            for width: CGFloat in [745, 752, 741, 758, 744] {
                XCTAssertEqual(AOMWorkbenchPolicy.sideBySide(available: width, minimum: 740, current: sideBySide), sideBySide)
            }
        }
        XCTAssertEqual(flips, 60)
        XCTAssertTrue(sideBySide)
    }

    // D02: 980 × 600 with the sidebar open leaves about 744 pt; the inspector
    // never takes the detail's minimum.
    func testMinimumWindowKeepsTheDetailMinimum() {
        let available: CGFloat = 980 - 236
        let arrangement = AOMWorkbenchArrangement.resolve(available: available, listMinimum: 240, detailMinimum: 420,
                                                          inspectorMinimum: 260, inspectorRequested: true, current: .listDetail)
        XCTAssertEqual(arrangement, .listDetail, "no room for an inspector column at the minimum window")
        let wide = AOMWorkbenchArrangement.resolve(available: 1_320 - 236, listMinimum: 240, detailMinimum: 420,
                                                   inspectorMinimum: 260, inspectorRequested: true, current: .listDetail)
        XCTAssertEqual(wide, .listDetailInspector)
        let notAsked = AOMWorkbenchArrangement.resolve(available: 1_320 - 236, listMinimum: 240, detailMinimum: 420,
                                                       inspectorMinimum: 260, inspectorRequested: false, current: .listDetail)
        XCTAssertEqual(notAsked, .listDetail)
        let tiny = AOMWorkbenchArrangement.resolve(available: 600, listMinimum: 240, detailMinimum: 420,
                                                   inspectorMinimum: 260, inspectorRequested: true, current: .listDetail)
        XCTAssertEqual(tiny, .drillIn)
        for width in stride(from: CGFloat(600), through: 1_600, by: 7) {
            for current in [AOMWorkbenchArrangement.drillIn, .listDetail, .listDetailInspector] {
                let result = AOMWorkbenchArrangement.resolve(available: width, listMinimum: 240, detailMinimum: 420,
                                                             inspectorMinimum: 260, inspectorRequested: true, current: current)
                if result == .listDetailInspector {
                    XCTAssertGreaterThanOrEqual(width - 240 - 420 - 2 * AOMWorkbenchPolicy.dividerAllowance, 260, "width \(width)")
                }
                if result != .drillIn {
                    XCTAssertGreaterThanOrEqual(width, 240 + 420 + AOMWorkbenchPolicy.dividerAllowance, "width \(width)")
                }
            }
        }
    }

    func testInspectorHysteresis() {
        // room = available − 240 − 420 − 16
        XCTAssertTrue(AOMWorkbenchPolicy.inspectorFits(available: 936, list: 240, detailMinimum: 420,
                                                       inspectorMinimum: 260, current: true))
        XCTAssertFalse(AOMWorkbenchPolicy.inspectorFits(available: 935, list: 240, detailMinimum: 420,
                                                        inspectorMinimum: 260, current: true))
        XCTAssertFalse(AOMWorkbenchPolicy.inspectorFits(available: 950, list: 240, detailMinimum: 420,
                                                        inspectorMinimum: 260, current: false))
        XCTAssertTrue(AOMWorkbenchPolicy.inspectorFits(available: 956, list: 240, detailMinimum: 420,
                                                       inspectorMinimum: 260, current: false))
        XCTAssertFalse(AOMWorkbenchPolicy.inspectorFits(available: 0, list: 240, detailMinimum: 420,
                                                        inspectorMinimum: 260, current: true))
    }

    // D03/D05: a search never moves the selection to another row.
    func testSelectionNeverRetargetsUnderASearch() {
        let all = ["a", "b", "c"]
        XCTAssertEqual(AOMStableSelection.reconcile("b", visible: all, autoSelectFirst: false), "b")
        XCTAssertNil(AOMStableSelection.reconcile("b", visible: ["a", "c"], autoSelectFirst: false),
                     "hidden by a search: nothing selected, not a")
        XCTAssertEqual(AOMStableSelection.reconcile("b", visible: ["a", "c"], autoSelectFirst: true), "a",
                       "a scope the user switched to highlights its first row")
        XCTAssertEqual(AOMStableSelection.reconcile(nil as String?, visible: all, autoSelectFirst: true), "a")
        XCTAssertNil(AOMStableSelection.reconcile(nil as String?, visible: all, autoSelectFirst: false))
        XCTAssertNil(AOMStableSelection.reconcile("a", visible: [], autoSelectFirst: true))
    }

    func testActionTargetRequiresAVisibleRow() {
        XCTAssertEqual(AOMStableSelection.actionTarget("b", visible: ["a", "b"]), "b")
        XCTAssertNil(AOMStableSelection.actionTarget("b", visible: ["a"]), "filtered or deleted")
        XCTAssertNil(AOMStableSelection.actionTarget(nil as String?, visible: ["a"]))
    }

    // D06: the header doesn't say what the sentence or the toolbar says.
    func testHeaderDedup() {
        XCTAssertNil(AOMHeaderDedup.pill(title: "Files is on", status: "On"))
        XCTAssertEqual(AOMHeaderDedup.pill(title: "Folder Rules is on", status: "2 errors"), "2 errors")
        XCTAssertNil(AOMHeaderDedup.pill(title: "Recording the screen", status: "Recording"))
        XCTAssertNil(AOMHeaderDedup.pill(title: "Files is on", status: "  "))
        XCTAssertNil(AOMHeaderDedup.subtitle("Folder Rules", toolbarTitle: "Folder Rules", toolbarSubtitle: nil))
        XCTAssertNil(AOMHeaderDedup.subtitle("3 of 5 rules on.", toolbarTitle: "Folder Rules", toolbarSubtitle: "3 of 5 rules on"))
        XCTAssertEqual(AOMHeaderDedup.subtitle("Watching 2 folders", toolbarTitle: "Folder Rules", toolbarSubtitle: "3 of 5 rules on"),
                       "Watching 2 folders")
        XCTAssertNil(AOMHeaderDedup.subtitle(nil, toolbarTitle: "Files", toolbarSubtitle: nil))
    }

    // D01: the diagnostics controls don't use the inspector's name or symbol.
    func testDiagnosticsIsNotCalledInspector() {
        for name in [AOMDiagnosticsNames.menu, AOMDiagnosticsNames.console, AOMDiagnosticsNames.touchVisualizer] {
            let words = name.lowercased().split(separator: " ").map(String.init)
            XCTAssertTrue(Set(words).isDisjoint(with: AOMDiagnosticsNames.inspectorWords), name)
        }
        XCTAssertNotEqual(AOMDiagnosticsNames.symbol, "sidebar.right")
        XCTAssertNotEqual(AOMDiagnosticsNames.symbol, "sidebar.trailing")
    }
}
