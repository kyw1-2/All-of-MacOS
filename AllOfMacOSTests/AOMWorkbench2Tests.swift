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

/// D27: a Folder Rules preview made for an older version of the rule.
final class AOMWorkbench2FolderRulesTests: XCTestCase {
    func testPreviewFreshness() {
        let rule = FolderRule(folderID: UUID(), name: "Images", conditions: [.kind(.image)],
                              actions: [FolderRuleAction(kind: .moveToTrash)])
        XCTAssertFalse(FolderRulesPreviewFreshness.isStale(previewFor: rule, draft: rule))
        var renamed = rule
        renamed.name = "Pictures"
        renamed.isEnabled = true
        XCTAssertFalse(FolderRulesPreviewFreshness.isStale(previewFor: rule, draft: renamed), "name and switch don't change the answer")
        var edited = rule
        edited.includeSubfolders = true
        XCTAssertTrue(FolderRulesPreviewFreshness.isStale(previewFor: rule, draft: edited))
        var noActions = rule
        noActions.actions = []
        XCTAssertTrue(FolderRulesPreviewFreshness.isStale(previewFor: rule, draft: noActions))
        let other = FolderRule(folderID: rule.folderID, name: "Images", conditions: [.kind(.image)])
        XCTAssertTrue(FolderRulesPreviewFreshness.isStale(previewFor: rule, draft: other), "another rule")
        XCTAssertFalse(FolderRulesPreviewFreshness.isStale(previewFor: nil, draft: rule))
    }
}

/// D31: a settings search result leads to its own pane and row.
final class AOMWorkbench2SettingsTests: XCTestCase {
    func testRevealTarget() {
        let general = SettingsSearchReveal.target(category: .general, rowID: "launchAtLogin", sheetOpen: false)
        XCTAssertEqual(general, SettingsSearchReveal.Target(category: .general, rowID: "launchAtLogin"))
        XCTAssertNil(SettingsSearchReveal.target(category: .general, rowID: "launchAtLogin", sheetOpen: true),
                     "never moves the pane under an open sheet")
        let permissions = SettingsSearchReveal.target(category: .permissions, rowID: "accessibility", sheetOpen: false)
        XCTAssertEqual(permissions?.category, .permissions)
        XCTAssertNil(permissions?.rowID, "dashboard panes open at the top")
    }
}

/// Review follow-ups: the resolver is what the pages call, so its edge cases
/// are the pages' edge cases.
final class AOMWorkbench2FollowUpTests: XCTestCase {
    // P0-3: a list dragged wider closes the inspector; narrower reopens it with hysteresis.
    func testInspectorFollowsTheDrawnListWidth() {
        let available: CGFloat = 1_000
        let narrowList = AOMWorkbenchArrangement.resolve(available: available, listMinimum: 240, detailMinimum: 420,
                                                         inspectorMinimum: 260, inspectorRequested: true,
                                                         current: .listDetail, list: 240)
        XCTAssertEqual(narrowList, .listDetailInspector)
        let wideList = AOMWorkbenchArrangement.resolve(available: available, listMinimum: 240, detailMinimum: 420,
                                                       inspectorMinimum: 260, inspectorRequested: true,
                                                       current: .listDetailInspector, list: 340)
        XCTAssertEqual(wideList, .listDetail, "1000 − 340 − 420 − 16 = 224 < 260")
        let back = AOMWorkbenchArrangement.resolve(available: available, listMinimum: 240, detailMinimum: 420,
                                                   inspectorMinimum: 260, inspectorRequested: true,
                                                   current: .listDetail, list: 300)
        XCTAssertEqual(back, .listDetail, "264 pt is inside the 20 pt band: stays closed")
        XCTAssertEqual(AOMWorkbenchArrangement.resolve(available: available, listMinimum: 240, detailMinimum: 420,
                                                       inspectorMinimum: 260, inspectorRequested: true,
                                                       current: .listDetail, list: 100), .listDetailInspector,
                       "a list below its minimum counts as the minimum")
    }

    // P0-2: Automation's table needs 420 pt, the list 300.
    func testAutomationTableMinimumSwitchesEarlier() {
        let width: CGFloat = 860   // 300 + 440 + 8 = 748 fits, 420 + 440 + 8 = 868 doesn't
        let list = AOMWorkbenchArrangement.resolve(available: width, listMinimum: 300, detailMinimum: 440,
                                                   inspectorMinimum: 260, inspectorRequested: false, current: .listDetail)
        let table = AOMWorkbenchArrangement.resolve(available: width, listMinimum: 420, detailMinimum: 440,
                                                    inspectorMinimum: 260, inspectorRequested: false, current: .listDetail)
        XCTAssertEqual(list, .listDetail)
        XCTAssertEqual(table, .drillIn)
        XCTAssertEqual(AOMWorkbenchArrangement.resolve(available: 0, listMinimum: 420, detailMinimum: 440,
                                                       inspectorMinimum: 260, inspectorRequested: false, current: .drillIn),
                       .drillIn, "no measurement keeps the arrangement")
    }

    // P1-6: picked Folder Rules items don't run while the preview refreshes or is stale.
    func testFolderRulesRunSelectedGate() {
        XCTAssertTrue(FolderRulesPreviewFreshness.canRun(picked: 2, loading: false, stale: false))
        XCTAssertFalse(FolderRulesPreviewFreshness.canRun(picked: 2, loading: true, stale: false))
        XCTAssertFalse(FolderRulesPreviewFreshness.canRun(picked: 2, loading: false, stale: true))
        XCTAssertFalse(FolderRulesPreviewFreshness.canRun(picked: 0, loading: false, stale: false))
    }

    // P1-7: the control a revealed setting focuses.
    func testRevealFocusPicksTheTopLeadingControlInsideTheRow() {
        let row = CGRect(x: 0, y: 100, width: 600, height: 44)
        let frames = [CGRect(x: 500, y: 110, width: 40, height: 22),   // switch on the row's line
                      CGRect(x: 20, y: 200, width: 80, height: 22),    // another row, above
                      CGRect(x: 300, y: 110, width: 120, height: 22)]  // pop-up on the same line, leading
        XCTAssertEqual(AOMRevealFocus.pick(frames, in: row), 2)
        XCTAssertNil(AOMRevealFocus.pick([CGRect(x: 20, y: 200, width: 80, height: 22)], in: row))
        XCTAssertNil(AOMRevealFocus.pick([], in: row))
    }
}

/// D21: the monitor canvas draws the real arrangement and zones in the usable area.
final class AOMWorkbench2MonitorCanvasTests: XCTestCase {
    func testTwoDisplaysSideBySideFitAndFlip() {
        let main = AOMMonitorInfo(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949), isMain: true)
        let external = AOMMonitorInfo(id: 2, name: "Studio", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                      visibleFrame: CGRect(x: 1512, y: 80, width: 2560, height: 1335), isMain: false)
        let placed = AOMMonitorCanvasGeometry.layout([main, external], in: CGSize(width: 420, height: 180), padding: 8)
        XCTAssertEqual(placed.count, 2)
        let union = placed[0].frame.union(placed[1].frame)
        XCTAssertLessThanOrEqual(union.maxX, 420 - 8 + 0.001)
        XCTAssertGreaterThanOrEqual(union.minX, 8 - 0.001)
        XCTAssertLessThanOrEqual(union.maxY, 180 - 8 + 0.001)
        XCTAssertEqual(placed[0].frame.maxX, placed[1].frame.minX, accuracy: 0.001, "edges touch as arranged")
        XCTAssertEqual(placed[0].frame.maxY, placed[1].frame.maxY, accuracy: 0.001, "bottom-aligned in AppKit stays bottom-aligned")
        // The menu bar is at the top of the drawn display (y down).
        XCTAssertGreaterThan(placed[0].visibleFrame.minY, placed[0].frame.minY)
        XCTAssertEqual(placed[0].visibleFrame.maxY, placed[0].frame.maxY, accuracy: 0.001)
        // The Dock at the bottom of the external display.
        XCTAssertLessThan(placed[1].visibleFrame.maxY, placed[1].frame.maxY)
        XCTAssertTrue(AOMMonitorCanvasGeometry.layout([], in: CGSize(width: 420, height: 180), padding: 8).isEmpty)
        XCTAssertTrue(AOMMonitorCanvasGeometry.layout([main], in: CGSize(width: 10, height: 10), padding: 8).isEmpty)
    }

    func testZonesStayInsideTheUsableArea() {
        let visible = CGRect(x: 10, y: 20, width: 200, height: 100)
        XCTAssertEqual(AOMMonitorCanvasGeometry.zone(x: 0.5, y: 0, width: 0.5, height: 1, in: visible),
                       CGRect(x: 110, y: 20, width: 100, height: 100))
        let overflow = AOMMonitorCanvasGeometry.zone(x: 0.8, y: 0.9, width: 0.5, height: 0.5, in: visible)
        XCTAssertEqual(overflow.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(overflow.maxY, visible.maxY, accuracy: 0.001)
        let bad = AOMMonitorCanvasGeometry.zone(x: .nan, y: -1, width: 2, height: 5, in: visible)
        XCTAssertEqual(bad, visible)
        let reserved = AOMMonitorCanvasGeometry.reserved(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                         visible: CGRect(x: 0, y: 70, width: 1512, height: 879))
        XCTAssertEqual(reserved.top, 33)
        XCTAssertEqual(reserved.bottom, 70)
        XCTAssertEqual(reserved.leading, 0)
    }
}

/// D25: the Files inspector's path.
final class AOMWorkbench2FilesTests: XCTestCase {
    func testBreadcrumbsCollapseHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let crumbs = FilesBreadcrumb.crumbs(for: URL(fileURLWithPath: "/Users/someone/Downloads/report.pdf"), home: home)
        XCTAssertEqual(crumbs.map(\.name), ["~", "Downloads", "report.pdf"])
        XCTAssertEqual(crumbs.first?.url.path, "/Users/someone")
        let outside = FilesBreadcrumb.crumbs(for: URL(fileURLWithPath: "/Volumes/Backup/a.zip"), home: home)
        XCTAssertEqual(outside.map(\.name), ["/", "Volumes", "Backup", "a.zip"])
        XCTAssertEqual(FilesBreadcrumb.crumbs(for: URL(fileURLWithPath: "/"), home: home).map(\.name), ["/"])
    }
}

/// D27: per-condition verdicts, with "can't tell" for unreadable PDFs.
final class AOMWorkbench2FolderVerdictTests: XCTestCase {
    func testVerdicts() {
        let conditions = [FolderRuleCondition.kind(.image), FolderRuleCondition(attribute: .pdfText, values: ["청구서"])]
        XCTAssertEqual(FolderRulesVerdict.conditions(conditions, results: [true, false], state: .noMatch), [.match, .noMatch])
        XCTAssertEqual(FolderRulesVerdict.conditions(conditions, results: [true, false], state: .needsReview("Scanned PDF")),
                       [.match, .unknown])
        XCTAssertEqual(FolderRulesVerdict.conditions(conditions, results: [true], state: .willRun), [.match, .unknown],
                       "a missing result is unknown, never a match")
        XCTAssertEqual(FolderRulesVerdict.overall(.noMatch), .noMatch)
        XCTAssertEqual(FolderRulesVerdict.overall(.needsReview("x")), .unknown)
        XCTAssertEqual(FolderRulesVerdict.overall(.willRun), .match)
    }
}

/// D14: one status for the automation editor, problems first.
final class AOMWorkbench2AutomationStatusTests: XCTestCase {
    func testStatusOrder() {
        XCTAssertEqual(AOMAutomationEditorStatus.resolve(isEnabled: true, stepCount: 2, inputProblem: nil, stepsProblem: nil), .ready)
        XCTAssertEqual(AOMAutomationEditorStatus.resolve(isEnabled: false, stepCount: 2, inputProblem: nil, stepsProblem: nil), .off)
        XCTAssertEqual(AOMAutomationEditorStatus.resolve(isEnabled: true, stepCount: 0, inputProblem: nil, stepsProblem: nil), .noSteps)
        XCTAssertEqual(AOMAutomationEditorStatus.resolve(isEnabled: true, stepCount: 0, inputProblem: "needs a modifier", stepsProblem: nil),
                       .invalidInput("needs a modifier"), "an input problem comes first")
        XCTAssertEqual(AOMAutomationEditorStatus.resolve(isEnabled: false, stepCount: 1, inputProblem: nil, stepsProblem: "empty group"),
                       .invalidSteps("empty group"), "a broken step outranks off")
        XCTAssertEqual(AOMAutomationEditorStatus.invalidSteps("x").tone, .warning)
    }
}
