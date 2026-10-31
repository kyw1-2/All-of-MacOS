import AppKit
import Foundation
import XCTest
@testable import AllOfMacOS

/// The engine end to end on a temporary folder: a pass through the runner's
/// queue, the activity line and Undo, the Workspace status, the status menu,
/// and the FSEvents watcher. The Trash is the kit's temporary folder.
@MainActor
final class FolderRulesEngineTests: XCTestCase {
    private var kit: FolderRulesTestKit!

    override func setUpWithError() throws { kit = try FolderRulesTestKit() }
    override func tearDown() { kit.remove() }

    private func engine(publishes: Bool = false) throws -> FolderRulesEngine {
        let engine = FolderRulesEngine(store: FolderRulesStore(directory: try kit.folder("Store")), environment: kit.environment(),
                                       publishesStatus: publishes)
        engine.gateIsOpen = { true }
        engine.notify = { _, _ in }
        return engine
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testRunNowMovesTheFileLogsItAndUndoPutsItBack() throws {
        let engine = try engine()
        let archive = try kit.folder("Archive")
        try kit.writeSettled("report.txt")
        let folder = try XCTUnwrap(try? engine.addFolder(kit.watched).get())
        var rule = engine.newRule(in: folder.id)
        rule.conditions = [.fileExtension(.is, ["txt"])]
        rule.actions = [.move(to: archive.path)]
        engine.update(rule)
        engine.setRule(rule.id, enabled: true)
        XCTAssertTrue(engine.config.isEnabled, "turning a rule on turns Folder Rules on")
        engine.runNow()
        waitUntil { engine.activity.contains { $0.fileName == "report.txt" } }
        let line = try XCTUnwrap(engine.activity.first { $0.fileName == "report.txt" })
        XCTAssertEqual(line.result, .succeeded, line.detail)
        XCTAssertEqual(kit.names(in: archive), ["report.txt"])
        XCTAssertEqual(engine.filesToday, 1)
        XCTAssertTrue(engine.statusDetail.contains("1 file today"), engine.statusDetail)
        XCTAssertTrue(line.canUndo)
        engine.undo(line.id)
        waitUntil { engine.activity.first { $0.id == line.id }?.undone == true }
        XCTAssertEqual(engine.activity.first { $0.id == line.id }?.undone, true)
        XCTAssertEqual(kit.names(), ["report.txt"], "back in the watched folder")
        XCTAssertEqual(engine.message?.tone, .success)
        // Pause AOM: nothing runs, and the status says why.
        engine.gateIsOpen = { false }
        XCTAssertEqual(engine.statusDetail, "Paused with AOM")
        XCTAssertFalse(engine.isActive)
    }

    func testDestructiveRulesWaitForApprovalAndSkipLeavesThemAlone() throws {
        let engine = try engine()
        try kit.writeSettled("old.dmg")
        let folder = try XCTUnwrap(try? engine.addFolder(kit.watched).get())
        var rule = engine.newRule(in: folder.id)
        rule.conditions = [.fileExtension(.is, ["dmg"])]
        rule.actions = [.moveToTrash]
        engine.update(rule)
        engine.setRule(rule.id, enabled: true)
        engine.runNow()
        waitUntil { !engine.approvals.isEmpty }
        let approval = try XCTUnwrap(engine.approvals.first)
        XCTAssertEqual(approval.question, "Move “old.dmg” to the Trash?")
        XCTAssertEqual(engine.waitingCount, 1)
        XCTAssertEqual(engine.attention, "1 action is waiting for your OK")
        XCTAssertEqual(kit.names(), ["old.dmg"], "nothing happens before the OK")
        engine.skip(approval.id)
        XCTAssertTrue(engine.approvals.isEmpty)
        XCTAssertEqual(engine.activity.first?.detail, "Skipped by you")
        engine.runNow()
        waitUntil(1.5) { !engine.approvals.isEmpty }
        XCTAssertTrue(engine.approvals.isEmpty, "skipped items aren't asked about again")
        XCTAssertEqual(kit.names(), ["old.dmg"])
        XCTAssertTrue(kit.trashed.isEmpty)
    }

    func testTheWorkspaceStatusAndTheStatusMenuShowTheRealState() throws {
        let engine = try engine(publishes: true)
        let status = AOMModuleStatusBoard.folderRules
        XCTAssertEqual(status.isOn, false)
        XCTAssertNil(status.count, "off shows Off, not a count")
        XCTAssertEqual(status.detail, "No rules yet")
        XCTAssertNotNil(status.setOn, "the tile gets a switch")
        let folder = try XCTUnwrap(try? engine.addFolder(kit.watched).get())
        var rule = engine.newRule(in: folder.id)
        rule.conditions = [.kind(.pdf)]
        engine.update(rule)
        engine.setRule(rule.id, enabled: true)
        XCTAssertEqual(status.isOn, true)
        XCTAssertEqual(status.count, 1)
        XCTAssertEqual(status.unit, "rule")
        XCTAssertTrue(status.detail.hasPrefix("Watching Watched"), status.detail)
        XCTAssertNil(status.attention)
        engine.setMasterEnabled(false)
        XCTAssertEqual(status.isOn, false)
        XCTAssertEqual(status.detail, "Off · 1 rule set up")

        // The menu is built from the shared engine (a temporary store under tests).
        let titles = FolderRulesModule.statusMenuItems().map(\.title)
        XCTAssertTrue(titles.contains("Install Disk Image…"))
        XCTAssertTrue(titles.contains("Set Up Folder Rules…") || titles.contains("Run Folder Rules Now"))
        XCTAssertTrue(FolderRulesModule.statusMenuItems().allSatisfy { $0.image != nil }, "every item has a symbol")
    }

    func testTheWatcherReportsChangesBelowAWatchedFolder() throws {
        let watcher = FolderRulesWatcher()
        var reported: [String] = []
        watcher.onChange = { reported.append(contentsOf: $0) }
        watcher.watch([kit.watched.path])
        XCTAssertTrue(watcher.isWatching)
        // FSEvents delivers events from a moment after the stream starts.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try kit.write("new.txt")
        waitUntil(10) { !reported.isEmpty }
        XCTAssertEqual(Set(reported), [kit.watched.path])
        watcher.watch([])
        XCTAssertFalse(watcher.isWatching, "no folders, no stream")
    }

    func testClearingTheActivityCanBeUndone() throws {
        let engine = try engine()
        let archive = try kit.folder("Archive")
        try kit.writeSettled("notes.txt")
        let folder = try XCTUnwrap(try? engine.addFolder(kit.watched).get())
        var rule = engine.newRule(in: folder.id)
        rule.conditions = [.fileExtension(.is, ["txt"])]
        rule.actions = [.move(to: archive.path)]
        engine.update(rule)
        engine.setRule(rule.id, enabled: true)
        engine.runNow()
        waitUntil { engine.activity.contains { $0.fileName == "notes.txt" } }
        let before = engine.activity
        XCTAssertFalse(before.isEmpty)

        let removed = engine.clearActivity()
        XCTAssertEqual(removed, before)
        XCTAssertTrue(engine.activity.isEmpty)
        XCTAssertEqual(engine.filesToday, 0)
        XCTAssertEqual(kit.names(in: archive), ["notes.txt"], "clearing the list leaves the files alone")

        engine.restoreActivity(removed)
        XCTAssertEqual(engine.activity, before)
        XCTAssertEqual(engine.filesToday, 1)
        engine.restoreActivity(removed)
        XCTAssertEqual(engine.activity, before, "undoing twice doesn't double the lines")
    }
}
