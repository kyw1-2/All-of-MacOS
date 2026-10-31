import AppKit
import SwiftUI
import XCTest
@testable import AllOfMacOS

/// 3.4 Workspace and shell logic (docs/design-3.4.0.md b.1, b.4, b.15):
/// the layout store, page history, grid columns, undo and toasts. Defaults go
/// to a throwaway suite that is removed afterwards.
@MainActor
final class Workspace340Tests: XCTestCase {
    /// A throwaway defaults suite, removed when the test ends.
    private func makeDefaults() -> UserDefaults {
        let name = "AOMWorkspace340Tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    // MARK: Layout store

    func testSavedOrderDropsUnknownIdsAndAppendsNewActions() {
        let order = AOMWorkspaceLayout.normalized(["dropShelf", "gone", "captureArea", "dropShelf"])
        XCTAssertEqual(Array(order.prefix(2)), [.dropShelf, .captureArea])
        XCTAssertEqual(order.count, WorkspaceQuickActionKind.allCases.count, "every action exactly once")
        XCTAssertEqual(Set(order), Set(WorkspaceQuickActionKind.allCases))
    }

    func testHidingAndMovingPersistAndResetRestoresTheDefault() {
        let defaults = makeDefaults()
        let layout = AOMWorkspaceLayout(defaults: defaults)
        XCTAssertTrue(layout.isDefault)
        layout.setHidden(AOMWorkspaceLayout.tileID(.audio), true)
        layout.setHidden(WorkspaceQuickActionKind.copyText.layoutID, true)
        layout.move(.windowSwitcher, before: .captureArea)
        XCTAssertFalse(layout.shows(.audio))
        XCTAssertFalse(layout.visibleQuickActions.contains(.copyText))
        XCTAssertEqual(layout.visibleQuickActions.first, .windowSwitcher)

        let reloaded = AOMWorkspaceLayout(defaults: defaults)
        XCTAssertEqual(reloaded.state, layout.state, "the layout survives a relaunch")

        layout.reset()
        XCTAssertTrue(layout.isDefault)
        XCTAssertNil(defaults.object(forKey: AOMWorkspaceLayout.hiddenKey), "the default layout stores nothing")
        XCTAssertNil(defaults.object(forKey: AOMWorkspaceLayout.quickActionsKey))
    }

    func testMoveByOneStepsOverHiddenActionsAndStopsAtTheEnds() {
        let defaults = makeDefaults()
        let layout = AOMWorkspaceLayout(defaults: defaults)
        layout.setHidden(WorkspaceQuickActionKind.captureWindow.layoutID, true)
        // Visible: captureArea, recordScreen, copyText, …
        XCTAssertFalse(layout.canMove(.captureArea, by: -1))
        layout.move(.recordScreen, by: -1)
        XCTAssertEqual(Array(layout.visibleQuickActions.prefix(2)), [.recordScreen, .captureArea])
        layout.move(.recordScreen, by: 1)
        XCTAssertEqual(Array(layout.visibleQuickActions.prefix(2)), [.captureArea, .recordScreen])
        let last = layout.visibleQuickActions.last!
        XCTAssertFalse(layout.canMove(last, by: 1))
        layout.move(last, by: 1)
        XCTAssertEqual(layout.visibleQuickActions.last, last)
    }

    func testChangesUndoAndRedoAsOneNamedStep() {
        let defaults = makeDefaults()
        let layout = AOMWorkspaceLayout(defaults: defaults)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        layout.change("Hide Tile", undoManager: undo) { $0.setHidden(AOMWorkspaceLayout.tileID(.capture), true) }
        undo.endUndoGrouping()
        XCTAssertFalse(layout.shows(.capture))
        XCTAssertEqual(undo.undoActionName, "Hide Tile")
        undo.undo()
        XCTAssertTrue(layout.shows(.capture), "undo shows the tile again")
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertFalse(layout.shows(.capture), "redo hides it again")
    }

    // MARK: History

    func testHistoryWalksBackAndForwardWithoutRecordingItsOwnMoves() {
        let history = AOMNavigationHistory()
        history.record(from: .home, to: .capture)
        history.record(from: .capture, to: .clipboard)
        XCTAssertEqual(history.back(from: .clipboard), .capture)
        history.record(from: .clipboard, to: .capture)   // the selection change Back caused
        XCTAssertEqual(history.backStack, [.home], "Back's own change is not a new visit")
        XCTAssertEqual(history.forwardTarget, .clipboard)
        XCTAssertEqual(history.forward(from: .capture), .clipboard)
        history.record(from: .capture, to: .clipboard)
        XCTAssertEqual(history.backStack, [.home, .capture])
        XCTAssertFalse(history.canGoForward)
        // A new visit clears Forward.
        _ = history.back(from: .clipboard)
        history.record(from: .clipboard, to: .capture)
        history.record(from: .capture, to: .focus)
        XCTAssertFalse(history.canGoForward)
    }

    func testHistoryIsBoundedAndSkipsTheRestoredLaunchPage() {
        let history = AOMNavigationHistory()
        history.skipRecording(.files)
        history.record(from: .home, to: .files)
        XCTAssertFalse(history.canGoBack, "restoring the last page is not a visit")
        for index in 0..<(AOMNavigationHistory.limit + 20) {
            history.record(from: index.isMultiple(of: 2) ? .files : .focus, to: index.isMultiple(of: 2) ? .focus : .files)
        }
        XCTAssertEqual(history.backStack.count, AOMNavigationHistory.limit)
    }

    // MARK: Grids

    func testModuleGridsAvoidRaggedRowsAtBothReviewSizes() {
        // 1000×680: about 732 pt of content; 1320×820: about 1050 pt.
        XCTAssertEqual(AOMHomeView.gridColumns(count: 6, width: 732, preferred: [3, 2]), 3)
        XCTAssertEqual(AOMHomeView.gridColumns(count: 6, width: 1050, preferred: [3, 2]), 3)
        XCTAssertEqual(AOMHomeView.gridColumns(count: 4, width: 1050, preferred: [4, 2]), 4)
        XCTAssertEqual(AOMHomeView.gridColumns(count: 4, width: 732, preferred: [4, 2]), 2)
        XCTAssertEqual(AOMHomeView.gridColumns(count: 6, width: 600, preferred: [3, 2]), 2)
        // Five visible tiles after hiding one: the most that fit.
        XCTAssertEqual(AOMHomeView.gridColumns(count: 5, width: 1050, preferred: [3, 2]), 4)
        XCTAssertEqual(AOMHomeView.gridColumns(count: 1, width: 1050, preferred: [3, 2]), 1)
    }

    // MARK: Feedback

    func testUndoToastRunsItsActionOnceAndStaysLonger() {
        let toast = AOMToastModel()
        var runs = 0
        toast.show("Tile hidden from Workspace", action: { runs += 1 })
        XCTAssertEqual(toast.actionTitle, "Undo")
        XCTAssertEqual(toast.tone, .success)
        toast.performAction()
        toast.performAction()
        XCTAssertEqual(runs, 1)
        XCTAssertNil(toast.message)
        toast.show("Couldn't move it", tone: .danger)
        XCTAssertNil(toast.actionTitle)
        XCTAssertEqual(toast.tone, .danger)
        XCTAssertGreaterThan(AOMMotion.undoToastSeconds, AOMMotion.toastSeconds)
    }

    func testUndoHelperRegistersRedo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        var value = 0
        undo.beginUndoGrouping()
        AOMUndo.perform("Add One", undoManager: undo, perform: { value += 1 }, revert: { value -= 1 })
        undo.endUndoGrouping()
        XCTAssertEqual(value, 1)
        undo.undo()
        XCTAssertEqual(value, 0)
        undo.redo()
        XCTAssertEqual(value, 1)
        undo.undo()
        XCTAssertEqual(value, 0)
    }

    func testPathRowShowsTheHomeFolderAsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(AOMPathRow<EmptyView>.displayPath(home.appendingPathComponent("Downloads/Invoices")), "~/Downloads/Invoices")
        XCTAssertEqual(AOMPathRow<EmptyView>.displayPath(home), "~")
        XCTAssertEqual(AOMPathRow<EmptyView>.displayPath(URL(fileURLWithPath: "/Applications")), "/Applications")
    }

    func testQuickActionsCoverTheNewEntryPointsAndTheirModules() {
        let kinds = WorkspaceQuickActionKind.allCases
        XCTAssertEqual(kinds.count, 10, "two rows of five")
        XCTAssertEqual(WorkspaceQuickActionKind.measureScreen.module, .capture)
        XCTAssertEqual(WorkspaceQuickActionKind.dropShelf.module, .files)
        XCTAssertEqual(WorkspaceQuickActionKind.focusSession.module, .focus)
        XCTAssertEqual(WorkspaceQuickActionKind.muteMicrophone.module, .audio)
        XCTAssertEqual(Set(kinds.map(\.layoutID)).count, kinds.count)
    }
}
