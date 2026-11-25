import XCTest
@testable import AllOfMacOS

final class AOMCalmWorkbenchTests: XCTestCase {
    func testCompactNavigationReturnsWithoutChangingSelection() {
        var path = AOMDrillInNavigation()
        XCTAssertFalse(path.showsDetail)
        path.selectionChanged(hasSelection: true)
        XCTAssertTrue(path.showsDetail)
        path.goBack()
        XCTAssertFalse(path.showsDetail)
        XCTAssertEqual(path.returnCount, 1)
        path.openDetail() // The same selection can be reopened without writing it.
        XCTAssertTrue(path.showsDetail)
        path.selectionChanged(hasSelection: false)
        XCTAssertFalse(path.showsDetail)
    }

    func testBothSplitThresholdsIncludeTheDrawnDivider() {
        for scale: CGFloat in [1, 2] {
            let divider = AOMResizeDivider.layoutWidth(displayScale: scale)
            XCTAssertEqual(divider, 6 + 1 / scale)
            func resolve(_ width: CGFloat, from current: AOMWorkbenchArrangement) -> AOMWorkbenchArrangement {
                AOMWorkbenchArrangement.resolve(available: width, listMinimum: 240, detailMinimum: 420,
                                                inspectorMinimum: 260, inspectorRequested: true,
                                                current: current, dividers: divider)
            }
            let two = 240 + 420 + divider
            let three = 240 + 420 + 260 + 2 * divider
            XCTAssertEqual(resolve(two, from: .listDetail), .listDetail)
            XCTAssertEqual(resolve(two - 0.25, from: .listDetail), .drillIn)
            XCTAssertEqual(resolve(three, from: .listDetailInspector), .listDetailInspector)
            XCTAssertEqual(resolve(three - 0.25, from: .listDetailInspector), .listDetail)
            XCTAssertEqual(resolve(three + AOMWorkbenchPolicy.hysteresis, from: .listDetail), .listDetailInspector)
        }
    }

    func testInspectorPreferenceIsScopedToTheModule() {
        XCTAssertEqual(AOMPaneWidth.inspectorKey(moduleID: "clipboard"), "AOMInspectorWidth.clipboard")
        XCTAssertNotEqual(AOMPaneWidth.inspectorKey(moduleID: "clipboard"), AOMPaneWidth.inspectorKey(moduleID: "textActions"))
    }

    func testInspectorStacksLongLabelsAndControls() {
        let readOnly = AOMInspectorRowLayout(labelWidth: 96, readOnly: true)
        XCTAssertFalse(readOnly.stacks(label: 75, available: 240))
        XCTAssertTrue(readOnly.stacks(label: 130, available: 240))
        XCTAssertTrue(readOnly.stacks(label: 75, available: 150))
        XCTAssertTrue(AOMInspectorRowLayout(labelWidth: 96, readOnly: false).stacks(label: 45, available: 340))
    }

    @MainActor
    func testActionOverflowPreservesOrderAndPutsDestructiveActionsLast() {
        func action(_ id: String) -> AOMBarAction {
            AOMBarAction(id: id, title: id, identity: .neutral("bolt"), run: {})
        }
        let leading = [action("copy"), action("copy-plain"), action("rename")]
        XCTAssertTrue(AOMActionBarModel.overflowActions(leading).isEmpty)
        var remove = action("remove-custom")
        remove.role = .destructive
        let overflow = AOMActionBarModel.overflowActions(leading + [action("clip.delete"), action("pin"), remove, action("unpin")])
        XCTAssertEqual(overflow.map(\.id), ["pin", "unpin", "clip.delete", "remove-custom"])
        XCTAssertEqual(overflow.suffix(2).map(\.buttonRole), [.destructive, .destructive])
    }

    func testEditorOnlyClaimsSavedAfterAcknowledgement() {
        let ready = AOMAutomationEditorStatus.ready
        XCTAssertEqual(ready.presentation(saveState: .unconfirmed).text, "On")
        XCTAssertEqual(ready.presentation(saveState: .pending).text, "Saving… · On")
        XCTAssertEqual(ready.presentation(saveState: .saved).text, "On · Saved")
        let failure = AOMAutomationEditorStatus.invalidSteps("Empty group").presentation(saveState: .failed("Disk full"))
        XCTAssertEqual(failure.tone, .danger)
        XCTAssertTrue(failure.text.contains("Disk full"))
        XCTAssertTrue(failure.text.contains("Empty group"))
    }
}
