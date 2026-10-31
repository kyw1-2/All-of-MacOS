import Foundation
import XCTest
@testable import AllOfMacOS

/// rules.json and friends, the templates, and the engine's bookkeeping
/// (approvals, activity, status text) with a temporary store.
@MainActor
final class FolderRulesStoreTests: XCTestCase {
    private var kit: FolderRulesTestKit!

    override func setUpWithError() throws { kit = try FolderRulesTestKit() }
    override func tearDown() { kit.remove() }

    private func store() throws -> FolderRulesStore { FolderRulesStore(directory: try kit.folder("Store")) }

    func testTheStoreLivesUnderAnIsolatedFolderInTests() {
        XCTAssertTrue(FolderRulesStore.defaultDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(FolderRulesStore.defaultDirectory.path.contains("Application Support"))
        XCTAssertTrue(AppInputSourceStore.defaultDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testRulesRoundTripAndOldFilesDecodeLeniently() throws {
        let store = try store()
        let folder = FolderRuleFolder(path: kit.watched.path)
        var optimize = FolderRuleAction(kind: .optimizeImage)
        optimize.image = FolderRuleImageOptions(maxDimension: 1200, quality: 0.6, stripLocation: false, screenshotOutput: .heic, original: .overwrite)
        let rule = FolderRule(folderID: folder.id, name: "Everything", match: .any,
                              conditions: [.name(.contains, ["a"]), .fileExtension(.is, ["png"]), .kind(.screenshot),
                                           .date(.dateAdded, .newerThan, 2, .hours), .size(.greaterThan, 3, .megabytes),
                                           .downloadedFrom(["github.com"]), .tags(.hasNot, ["Done"]), .namePattern("x+")],
                              actions: [.move(to: "/tmp", subfolders: "{year}"), .rename("{name} {counter:2}"), .addTags(["T"]),
                                        .colorLabel(.orange), optimize, FolderRuleAction(kind: .installApp)],
                              includeSubfolders: true, runWithoutAsking: true, templateID: "custom")
        let config = FolderRulesConfig(isEnabled: true, folders: [folder], rules: [rule])
        try store.save(config)
        XCTAssertEqual(store.loadConfig(defaults: { FolderRulesConfig() }).config, config)
        // A file from an older or hand-edited version: missing fields fall back.
        let minimal = """
        {"folders":[{"path":"\(kit.watched.path)"}],
         "rules":[{"folderID":"\(UUID().uuidString)","conditions":[{"attribute":"kind"}],"actions":[{"kind":"moveToTrash"}]}]}
        """
        try Data(minimal.utf8).write(to: store.configURL)
        let loaded = store.loadConfig(defaults: { FolderRulesConfig() })
        XCTAssertTrue(loaded.existed)
        XCTAssertFalse(loaded.config.isEnabled)
        XCTAssertEqual(loaded.config.rules.first?.isEnabled, false)
        XCTAssertEqual(loaded.config.rules.first?.conditions.first?.comparison, .is)
        XCTAssertEqual(loaded.config.rules.first?.actions.first?.trashOriginal, true)
    }

    func testAnUnreadableRulesFileIsKeptAside() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.configURL)
        let loaded = store.loadConfig(defaults: { FolderRulesConfig(isEnabled: false, folders: [], rules: []) })
        XCTAssertFalse(loaded.existed)
        let aside = try XCTUnwrap(loaded.setAside)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json", "kept, never deleted")
    }

    func testEveryTemplateStartsOffAndIsComplete() {
        XCTAssertEqual(FolderRuleTemplates.all.count, 6)
        for template in FolderRuleTemplates.all {
            let rule = template.make(UUID())
            XCTAssertFalse(rule.isEnabled, template.id)
            XCTAssertEqual(rule.problems, [], template.id)
            XCTAssertEqual(rule.templateID, template.id)
        }
        let receipts = FolderRuleTemplates.template("receipts")!.make(UUID())
        let invoice = FolderRuleFileInfo.fixture("청구서 2026-10.pdf", kind: "com.adobe.pdf")
        XCTAssertTrue(FolderRuleMatcher.matches(receipts, invoice, now: Date()))
        XCTAssertFalse(FolderRuleMatcher.matches(receipts, .fixture("notes.pdf", kind: "com.adobe.pdf"), now: Date()))
        XCTAssertEqual(receipts.actions.map(\.kind), [.move, .addTags])
        let archive = FolderRuleTemplates.template("archive-downloads")!.make(UUID())
        XCTAssertFalse(FolderRuleMatcher.matches(archive, .fixture("Archive", added: Date(timeIntervalSinceNow: -40 * 86_400), directory: true),
                                                 now: Date()), "the Archive folder itself is never archived")
        XCTAssertTrue(FolderRuleTemplates.template("install-disk-images")!.make(UUID()).needsApproval, "installs ask first")
        XCTAssertTrue(FolderRuleTemplates.template("old-installers")!.make(UUID()).needsApproval)
    }

    func testTheEngineGroupsApprovalsPerRuleAndSaysWhatTheyDo() throws {
        let store = try store()
        let engine = FolderRulesEngine(store: store, environment: kit.environment(), publishesStatus: false)
        engine.gateIsOpen = { true }
        var notes: [String] = []
        engine.notify = { title, body in notes.append("\(title): \(body)") }
        XCTAssertEqual(engine.statusDetail, "No rules yet")
        let folder = try XCTUnwrap(try? engine.addFolder(kit.watched).get())
        let rule = engine.newRule(in: folder.id)
        XCTAssertEqual(engine.statusDetail, "Off · 1 rule set up")
        XCTAssertEqual(engine.config.rules.first { $0.id == rule.id }?.isEnabled, false, "new rules start off")
        var approval = FolderRuleApproval(id: UUID(), ruleID: rule.id, ruleName: "R", folderName: "Watched",
                                          requests: [FolderRuleApprovalRequest(key: "k", ruleID: rule.id, folderID: folder.id,
                                                                               info: .fixture("Old.dmg"))],
                                          created: Date(), verb: "", question: "")
        var trash = rule
        trash.actions = [.moveToTrash]
        FolderRulesEngine.describe(&approval, rule: trash)
        XCTAssertEqual(approval.verb, "Move to Trash")
        XCTAssertEqual(approval.question, "Move “Old.dmg” to the Trash?")
        var install = rule
        install.actions = [FolderRuleAction(kind: .installApp)]
        approval.requests.append(approval.requests[0])
        FolderRulesEngine.describe(&approval, rule: install)
        XCTAssertEqual(approval.verb, "Install")
        XCTAssertEqual(approval.question, "Install the apps from 2 disk images?")
        XCTAssertEqual(engine.addFolder(kit.root.appendingPathComponent("Missing")).failureMessage?.contains("isn't a folder"), true)
        let package = kit.watched.appendingPathComponent("Tool.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertEqual(engine.addFolder(package).failureMessage, "Folder Rules never works inside apps or other packages.")
        engine.setMasterEnabled(true)
        XCTAssertTrue(engine.config.isEnabled)
        XCTAssertEqual(engine.activeRules.count, 0, "the new rule is still off")
        engine.flushSaves()
        XCTAssertEqual(store.loadConfig(defaults: { FolderRulesConfig() }).config.isEnabled, true, "saved to rules.json")
    }

    func testActivityLinesSummarizeRunsAndTrim() {
        let record = FolderRuleRunRecord(ruleID: UUID(), ruleName: "Receipts", folderID: UUID(), folderName: "Downloads",
                                         fileName: "bill.pdf", originalPath: "/tmp/bill.pdf",
                                         outcome: FolderRuleRunOutcome(steps: [FolderRuleStepRecord(action: .move, result: .done, summary: "Moved to ~/Documents/Receipts",
                                                                                                    undo: .moveBack(current: "/b", original: "/a")),
                                                                               FolderRuleStepRecord(action: .addTags, result: .done, summary: "Tagged “Receipt”")],
                                                                       finalURL: URL(fileURLWithPath: "/b")))
        let line = FolderRuleActivity(record, date: Date())
        XCTAssertEqual(line.result, .succeeded)
        XCTAssertEqual(line.detail, "Moved to ~/Documents/Receipts · Tagged “Receipt”")
        XCTAssertTrue(line.canUndo)
        var failed = record.outcome
        failed.failed = true
        failed.steps.append(FolderRuleStepRecord(action: .moveToTrash, result: .failed, summary: "It's in use."))
        let bad = FolderRuleActivity(FolderRuleRunRecord(ruleID: record.ruleID, ruleName: "R", folderID: record.folderID, folderName: "D",
                                                         fileName: "x", originalPath: "/x", outcome: failed), date: Date())
        XCTAssertEqual(bad.result, .failed)
        XCTAssertEqual(bad.detail, "Couldn't finish: It's in use.")
        let now = Date()
        let many = (0..<1_100).map { FolderRuleActivity(date: now.addingTimeInterval(Double(-$0)), ruleID: nil, ruleName: "", folderName: "",
                                                        fileName: "\($0)", result: .succeeded, detail: "") }
            + [FolderRuleActivity(date: now.addingTimeInterval(-31 * 86_400), ruleID: nil, ruleName: "", folderName: "", fileName: "old",
                                  result: .succeeded, detail: "")]
        let trimmed = FolderRulesStore.trimmed(many, now: now)
        XCTAssertEqual(trimmed.count, FolderRulesStore.activityLimit)
        XCTAssertEqual(trimmed.first?.fileName, "0", "newest first")
        XCTAssertFalse(trimmed.contains { $0.fileName == "old" })
    }
}

private extension Result where Failure == FolderRuleFailure {
    var failureMessage: String? {
        if case .failure(let failure) = self { return failure.message }
        return nil
    }
}
