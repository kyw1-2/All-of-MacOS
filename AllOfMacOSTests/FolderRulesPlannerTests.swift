import Foundation
import XCTest
@testable import AllOfMacOS

/// Passes and the dry run on temporary folders: which rule takes an item,
/// unfinished downloads and growing files, Hazel's memory, the loop guard
/// and the rate limit.
final class FolderRulesPlannerTests: XCTestCase {
    private var kit: FolderRulesTestKit!
    private let folderID = UUID()

    override func setUpWithError() throws { kit = try FolderRulesTestKit() }
    override func tearDown() { kit.remove() }

    private func runner(_ memory: FolderRuleMemory = FolderRuleMemory()) -> FolderRulesRunner {
        FolderRulesRunner(environment: kit.environment(), memory: memory)
    }

    func testTheDryRunListsWhatEachRuleWouldDoAndChangesNothing() throws {
        let receipts = try kit.folder("Documents")
        try kit.writeSettled("Invoice March.pdf")
        try kit.writeSettled("영수증_10월.pdf")
        try kit.writeSettled("Lecture.pdf")
        try kit.writeSettled("Photo.jpg")
        try kit.write("Movie.mp4.crdownload")
        let before = kit.names()
        let rule = FolderRule(folderID: folderID, name: "Receipts",
                              conditions: [.kind(.pdf), .name(.contains, ["invoice", "영수증"])],
                              actions: [.move(to: receipts.path, subfolders: "Receipts/{year}"), .addTags(["Receipt"])])
        let config = kit.config([], folderID: folderID)
        let preview = runner().preview(rule, config: FolderRulesConfig(isEnabled: true, folders: config.folders, rules: [rule]))
        XCTAssertEqual(preview.folderState, .ok(items: 5))
        XCTAssertEqual(preview.inProgress, 1, "the unfinished download is counted and left alone")
        XCTAssertEqual(Set(preview.willRun.map(\.info.name)), ["Invoice March.pdf", "영수증_10월.pdf"])
        let invoice = try XCTUnwrap(preview.items.first { $0.info.name == "Invoice March.pdf" })
        let year = Calendar(identifier: .gregorian).component(.year, from: invoice.info.dateAdded ?? kit.now)
        XCTAssertEqual(invoice.steps, ["Move to \(FolderRulesSafety.display(receipts.appendingPathComponent("Receipts/\(year)")))",
                                       "Add the tag “Receipt”"])
        XCTAssertEqual(invoice.conditionResults, [true, true])
        XCTAssertEqual(kit.names(), before, "a preview never changes the folder")
        XCTAssertEqual(kit.names(in: receipts), [])
    }

    func testAnEarlierRuleTakesTheItemFirst() throws {
        try kit.writeSettled("Shot.png")
        let tag = FolderRule(folderID: folderID, name: "Tag images", conditions: [.kind(.image)], actions: [.addTags(["Image"])])
        let trash = FolderRule(folderID: folderID, name: "Trash PNGs", conditions: [.fileExtension(.is, ["png"])], actions: [.moveToTrash])
        var config = kit.config([tag, trash], folderID: folderID)
        let preview = runner().preview(config.rules[1], config: config)
        XCTAssertEqual(preview.items.first?.state, .earlierRule("Tag images"))
        config.rules[0].isEnabled = false
        XCTAssertEqual(runner().preview(config.rules[1], config: config).items.first?.state, .willRun,
                       "a rule that is off doesn't take items")
    }

    func testAPassRunsTheFirstMatchingRuleAndRemembersIt() throws {
        let archive = try kit.folder("Archive")
        try kit.writeSettled("a.txt")
        try kit.writeSettled("b.txt")
        let tag = FolderRule(folderID: folderID, name: "Tag", conditions: [.fileExtension(.is, ["txt"])], actions: [.addTags(["Seen"])])
        let move = FolderRule(folderID: folderID, name: "Move", conditions: [.tags(.has, ["Seen"])], actions: [.move(to: archive.path)])
        let config = kit.config([tag, move], folderID: folderID)
        let runner = runner()
        let first = runner.pass(.init(config: config, folderIDs: nil))
        XCTAssertEqual(first.runs.map(\.ruleName), ["Tag", "Tag"])
        XCTAssertTrue(first.runs.allSatisfy { !$0.outcome.failed })
        XCTAssertEqual(kit.names(), ["a.txt", "b.txt"])
        // The next pass: "Tag" already handled them, so "Move" gets them (Hazel's order).
        let second = runner.pass(.init(config: config, folderIDs: nil))
        XCTAssertEqual(second.runs.map(\.ruleName), ["Move", "Move"])
        XCTAssertEqual(kit.names(in: archive), ["a.txt", "b.txt"])
        // Nothing left to do: a third pass runs nothing.
        XCTAssertEqual(runner.pass(.init(config: config, folderIDs: nil)).runs.count, 0)
    }

    func testAHandledItemIsLeftAloneUntilItStopsMatchingOrTheConditionsChange() throws {
        try kit.writeSettled("report.txt")
        var rule = FolderRule(folderID: folderID, name: "Notify", conditions: [.name(.contains, ["report"])],
                              actions: [FolderRuleAction(kind: .notify, message: "{name} arrived")])
        let runner = runner()
        var output = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil))
        XCTAssertEqual(output.notifications.values.flatMap { $0 }, ["report arrived"])
        output = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil))
        XCTAssertTrue(output.runs.isEmpty, "loop protection: no second notification for the same file")
        // Stops matching (renamed away), then matches again (renamed back): runs again.
        let file = kit.watched.appendingPathComponent("report.txt")
        let other = kit.watched.appendingPathComponent("summary.txt")
        try FileManager.default.moveItem(at: file, to: other)
        XCTAssertTrue(runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil)).runs.isEmpty)
        try FileManager.default.moveItem(at: other, to: file)
        XCTAssertEqual(runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil)).runs.count, 1)
        // Changed conditions look at it again.
        rule.conditions = [.name(.startsWith, ["rep"])]
        XCTAssertEqual(runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil)).runs.count, 1)
    }

    func testRenameLoopsStopBecauseTheItemKeepsItsIdentity() throws {
        try kit.writeSettled("IMG_1.jpg")
        let rule = FolderRule(folderID: folderID, name: "Prefix", conditions: [.name(.contains, ["IMG"])],
                              actions: [.rename("IMG {name}")])
        let runner = runner()
        for _ in 0..<4 { _ = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil)) }
        XCTAssertEqual(kit.names(), ["IMG IMG_1.jpg"], "renamed once, not once per pass")
    }

    func testARuleNeverActsOnItsOwnCopiesAndTheLoopGuardStopsCrossFolderLoops() throws {
        try kit.writeSettled("photo.jpg")
        let copy = FolderRule(folderID: folderID, name: "Copy here", conditions: [.kind(.image)],
                              actions: [.copy(to: kit.watched.path, subfolders: "Copies")])
        let runner = runner()
        var config = kit.config([copy], folderID: folderID)
        config.rules[0].includeSubfolders = true
        for _ in 0..<5 { _ = runner.pass(.init(config: config, folderIDs: nil)) }
        XCTAssertEqual(kit.names(in: kit.watched.appendingPathComponent("Copies")), ["photo.jpg"],
                       "the copy it made is never copied again")

        // Two folders copying into each other make new files each time; the guard turns the rule off.
        let other = try kit.folder("Other")
        let otherID = UUID()
        let there = FolderRule(folderID: folderID, name: "To other", conditions: [.kind(.image)], actions: [.copy(to: other.path)])
        let back = FolderRule(folderID: otherID, name: "Back", conditions: [.kind(.image)], actions: [.copy(to: kit.watched.path)])
        var loop = FolderRulesConfig(isEnabled: true,
                                     folders: [FolderRuleFolder(id: folderID, path: kit.watched.path), FolderRuleFolder(id: otherID, path: other.path)],
                                     rules: [there, back])
        for index in loop.rules.indices { loop.rules[index].isEnabled = true }
        let loopRunner = FolderRulesRunner(environment: kit.environment())
        var stopped: [UUID: String] = [:]
        for _ in 0..<40 where stopped.isEmpty {
            stopped.merge(loopRunner.pass(.init(config: loop, folderIDs: nil)).stoppedRules) { first, _ in first }
            kit.now = kit.now.addingTimeInterval(1)
        }
        XCTAssertFalse(stopped.isEmpty, "the loop guard stepped in")
        XCTAssertTrue(stopped.values.first?.contains("loop") == true)
    }

    func testUnfinishedAndGrowingFilesWaitUntilTheySettle() throws {
        kit.now = Date()
        let growing = try kit.write("big.mov", Data(repeating: 1, count: 1_000), modified: kit.now.addingTimeInterval(-1))
        let rule = FolderRule(folderID: folderID, name: "Tag movies", conditions: [.kind(.movie)], actions: [.addTags(["Movie"])])
        let config = kit.config([rule], folderID: folderID)
        let runner = runner()
        var output = runner.pass(.init(config: config, folderIDs: nil))
        XCTAssertTrue(output.runs.isEmpty, "written a second ago: wait")
        XCTAssertNotNil(output.recheckAfter)
        // Still growing a few seconds later.
        kit.now = kit.now.addingTimeInterval(4)
        try Data(repeating: 1, count: 5_000).write(to: growing)
        try FileManager.default.setAttributes([.modificationDate: kit.now.addingTimeInterval(-3.5)], ofItemAtPath: growing.path)
        output = runner.pass(.init(config: config, folderIDs: nil))
        XCTAssertTrue(output.runs.isEmpty, "the size changed since the last look")
        // Same size and time on the next look: it runs.
        kit.now = kit.now.addingTimeInterval(3)
        output = runner.pass(.init(config: config, folderIDs: nil))
        XCTAssertEqual(output.runs.count, 1)
        // A .crdownload never counts, however old.
        try kit.writeSettled("clip.mov.crdownload")
        XCTAssertTrue(runner.pass(.init(config: config, folderIDs: nil)).runs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kit.watched.appendingPathComponent("clip.mov.crdownload").path))
    }

    func testDestructiveRulesAskFirstUnlessApprovedOrRunWithoutAsking() throws {
        try kit.writeSettled("old.dmg")
        var rule = FolderRule(folderID: folderID, name: "Old installers", conditions: [.fileExtension(.is, ["dmg"])],
                              actions: [.moveToTrash])
        let runner = runner()
        var output = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil))
        XCTAssertTrue(output.runs.isEmpty)
        let request = try XCTUnwrap(output.approvals.first)
        XCTAssertEqual(request.info.name, "old.dmg")
        XCTAssertEqual(kit.names(), ["old.dmg"], "nothing moved before the OK")
        // Waiting: not asked twice.
        output = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil, pending: [request.key]))
        XCTAssertTrue(output.approvals.isEmpty)
        // Approved: it runs.
        output = runner.runApproved([request], config: kit.config([rule], folderID: folderID))
        XCTAssertEqual(output.runs.count, 1)
        XCTAssertEqual(kit.names(), [])
        XCTAssertEqual(kit.names(in: kit.trash), ["old.dmg"])
        // Run without asking, and items granted by the preview, need no approval.
        try kit.writeSettled("second.dmg")
        rule.runWithoutAsking = true
        output = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil))
        XCTAssertEqual(output.runs.count, 1)
        XCTAssertTrue(output.approvals.isEmpty)
    }

    func testSkippingAnApprovalLeavesTheItemAloneForGood() throws {
        try kit.writeSettled("keep.dmg")
        let rule = FolderRule(folderID: folderID, name: "Trash", conditions: [.fileExtension(.is, ["dmg"])], actions: [.moveToTrash])
        let config = kit.config([rule], folderID: folderID)
        let runner = runner()
        let request = try XCTUnwrap(runner.pass(.init(config: config, folderIDs: nil)).approvals.first)
        runner.markSkipped([request], config: config)
        let output = runner.pass(.init(config: config, folderIDs: nil))
        XCTAssertTrue(output.approvals.isEmpty && output.runs.isEmpty)
        XCTAssertEqual(kit.names(), ["keep.dmg"])
    }

    func testGrantedItemsFromTheTurnOnPreviewRunWithoutAskingAgain() throws {
        try kit.writeSettled("a.dmg")
        let rule = FolderRule(folderID: folderID, name: "Trash", conditions: [.fileExtension(.is, ["dmg"])], actions: [.moveToTrash])
        let config = kit.config([rule], folderID: folderID)
        let runner = runner()
        let preview = runner.preview(config.rules[0], config: config)
        let keys = Set(preview.willRun.map(\.id))
        XCTAssertEqual(keys.count, 1)
        let output = runner.pass(.init(config: config, folderIDs: nil, granted: keys))
        XCTAssertEqual(output.runs.count, 1)
        XCTAssertEqual(output.consumedGrants, keys)
    }

    func testTheRateLimitPacesALargeFolder() throws {
        for index in 0..<(FolderRuleRateLimiter.perMinute + 5) { try kit.writeSettled("note \(index).txt") }
        let rule = FolderRule(folderID: folderID, name: "Tag", conditions: [.fileExtension(.is, ["txt"])], actions: [.addTags(["Note"])])
        let runner = runner()
        let output = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil))
        XCTAssertEqual(output.runs.count, FolderRuleRateLimiter.perMinute)
        XCTAssertNotNil(output.recheckAfter, "the rest wait for the next minute")
        kit.now = kit.now.addingTimeInterval(61)
        XCTAssertEqual(runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil)).runs.count, 5)
    }

    func testAFailedRunRetriesAThenGivesUp() throws {
        try kit.writeSettled("a.txt")
        let rule = FolderRule(folderID: folderID, name: "Move", conditions: [.fileExtension(.is, ["txt"])],
                              actions: [.move(to: kit.root.appendingPathComponent("Missing").path)])
        let runner = runner()
        for attempt in 1...FolderRuleMemory.maxFailures {
            let output = runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil))
            XCTAssertEqual(output.runs.count, 1, "attempt \(attempt)")
            XCTAssertTrue(output.runs[0].outcome.failed)
            XCTAssertTrue(output.runs[0].outcome.failure?.contains("doesn't exist") == true)
        }
        XCTAssertTrue(runner.pass(.init(config: kit.config([rule], folderID: folderID), folderIDs: nil)).runs.isEmpty,
                      "after \(FolderRuleMemory.maxFailures) failures it waits for a change")
    }

    func testMemoryKeysSurviveRenamesAndPrune() {
        var memory = FolderRuleMemory()
        let rule = UUID()
        let key = FolderRuleMemory.key(rule: rule, device: 1, inode: 42, created: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(key, "\(rule.uuidString)|1|42|100")
        memory.markHandled(key, signature: "s", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(memory.isSettled(key, signature: "s"))
        XCTAssertFalse(memory.isSettled(key, signature: "changed"))
        memory.prune(now: Date(timeIntervalSince1970: FolderRuleMemory.retention + 1), ruleIDs: [rule])
        XCTAssertTrue(memory.entries.isEmpty, "not seen for 30 days")
        memory.markHandled(key, signature: "s", now: Date())
        memory.prune(now: Date(), ruleIDs: [])
        XCTAssertTrue(memory.entries.isEmpty, "a deleted rule's memory goes too")
        XCTAssertEqual(memory.counter(for: rule), 1)
        memory.advanceCounter(for: rule)
        XCTAssertEqual(memory.counter(for: rule), 2)
    }

    func testTheStabilityCheckNeedsTwoQuietLooks() {
        var stability = FolderRuleStability()
        let now = Date(timeIntervalSince1970: 10_000)
        var info = FolderRuleFileInfo.fixture("a.mov", size: 10, modified: now.addingTimeInterval(-1))
        XCTAssertFalse(stability.isStable(info, now: now))
        info.dateModified = now.addingTimeInterval(-5)
        XCTAssertFalse(stability.isStable(info, now: now), "first quiet look")
        XCTAssertFalse(stability.isStable(info, now: now.addingTimeInterval(1)), "too soon")
        XCTAssertTrue(stability.isStable(info, now: now.addingTimeInterval(2.5)))
        let old = FolderRuleFileInfo.fixture("b.mov", size: 10, modified: now.addingTimeInterval(-3_600))
        XCTAssertTrue(stability.isStable(old, now: now), "untouched for an hour")
    }
}
