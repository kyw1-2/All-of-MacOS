import Foundation
import XCTest
@testable import AllOfMacOS

/// Actions on real files in a temporary folder, and Undo. The Trash is a
/// temporary folder; ditto runs on temporary files only.
final class FolderRulesExecutorTests: XCTestCase {
    private var kit: FolderRulesTestKit!
    private let folderID = UUID()

    override func setUpWithError() throws { kit = try FolderRulesTestKit() }
    override func tearDown() { kit.remove() }

    private func run(_ actions: [FolderRuleAction], on url: URL) throws -> FolderRuleRunOutcome {
        let info = try XCTUnwrap(FolderRuleFileReader.read(url))
        let rule = FolderRule(folderID: folderID, name: "Test", conditions: [.name(.contains, ["a"])], actions: actions)
        return FolderRuleExecutor(environment: kit.environment()).run(rule, on: info, in: kit.watched)
    }

    func testMoveRenameAndTrashUndoInReverseOrder() throws {
        let archive = try kit.folder("Archive")
        let file = try kit.writeSettled("scan.pdf")
        let outcome = try run([.rename("Scan {date:yyyy}"), .move(to: archive.path, subfolders: "{kind}"), .moveToTrash], on: file)
        XCTAssertFalse(outcome.failed, outcome.failure ?? "")
        XCTAssertNil(outcome.finalURL, "in the Trash at the end")
        XCTAssertEqual(outcome.steps.map(\.result), [.done, .done, .done])
        XCTAssertTrue(outcome.steps.allSatisfy(\.canUndo))
        XCTAssertEqual(kit.names(), [])
        XCTAssertEqual(kit.names(in: archive.appendingPathComponent("PDFs")), [])
        XCTAssertEqual(kit.trashed.count, 1)
        let undone = FolderRuleExecutor(environment: kit.environment()).undo(outcome.steps)
        XCTAssertNil(undone.failure)
        XCTAssertTrue(undone.steps.allSatisfy(\.undone))
        XCTAssertEqual(kit.names(), ["scan.pdf"], "back under its old name in its old folder")
        XCTAssertEqual(kit.names(in: kit.trash), [])
        XCTAssertFalse(FolderRuleExecutor(environment: kit.environment()).undo(undone.steps).steps.contains { $0.canUndo },
                       "nothing left to undo")
    }

    func testUndoFindsAFreeNameWhenTheOriginalWasTaken() throws {
        let archive = try kit.folder("Archive")
        let file = try kit.writeSettled("a.txt")
        let outcome = try run([.move(to: archive.path)], on: file)
        try kit.write("a.txt")
        let undone = FolderRuleExecutor(environment: kit.environment()).undo(outcome.steps)
        XCTAssertNil(undone.failure)
        XCTAssertEqual(kit.names(), ["a 2.txt", "a.txt"])
    }

    func testUndoSaysWhyWhenTheFileIsGone() throws {
        let archive = try kit.folder("Archive")
        let file = try kit.writeSettled("a.txt")
        let outcome = try run([.move(to: archive.path)], on: file)
        try FileManager.default.removeItem(at: archive.appendingPathComponent("a.txt"))
        let undone = FolderRuleExecutor(environment: kit.environment()).undo(outcome.steps)
        XCTAssertTrue(undone.failure?.contains("is no longer at") == true)
        XCTAssertFalse(undone.steps[0].undone)
    }

    func testCaseOnlyRenamesWork() throws {
        let file = try kit.writeSettled("report.txt")
        let outcome = try run([.rename("Report")], on: file)
        XCTAssertFalse(outcome.failed, outcome.failure ?? "")
        XCTAssertEqual(kit.names(), ["Report.txt"])
    }

    func testCopyHandsTheCopyToTheNextActionsLikeHazel() throws {
        let backup = try kit.folder("Backup")
        let file = try kit.writeSettled("a.txt")
        let outcome = try run([.copy(to: backup.path), .rename("copied {name}")], on: file)
        XCTAssertFalse(outcome.failed, outcome.failure ?? "")
        XCTAssertEqual(kit.names(), ["a.txt"], "the original stays as it was")
        XCTAssertEqual(kit.names(in: backup), ["copied a.txt"])
        XCTAssertEqual(outcome.produced.map(\.lastPathComponent), ["a.txt"])
        XCTAssertNil(outcome.steps[0].undo, "a copy has nothing to put back")
    }

    func testTagsAndColorLabels() throws {
        let file = try kit.writeSettled("bill.pdf")
        let outcome = try run([.addTags(["Receipt", " ", "receipt"]), .colorLabel(.red)], on: file)
        XCTAssertFalse(outcome.failed, outcome.failure ?? "")
        let values = try file.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
        XCTAssertTrue(values.tagNames?.contains("Receipt") == true)
        XCTAssertEqual(values.labelNumber, FolderRuleColorLabel.red.rawValue)
        let again = try run([.addTags(["Receipt"])], on: file)
        XCTAssertEqual(again.steps.first?.result, .skipped, "already tagged")
    }

    func testCompressAndExtractWithDitto() throws {
        let folder = kit.watched.appendingPathComponent("Album", isDirectory: true)
        try kit.write("one.txt", in: folder)
        try kit.write("two.txt", in: folder)
        var compress = FolderRuleAction(kind: .compress)
        compress.trashOriginal = true
        let outcome = try run([compress], on: folder)
        XCTAssertFalse(outcome.failed, outcome.failure ?? "")
        XCTAssertEqual(kit.names(), ["Album.zip"])
        XCTAssertEqual(kit.names(in: kit.trash), ["Album"])
        XCTAssertEqual(kit.requests.first?.arguments.prefix(4), ["-c", "-k", "--sequesterRsrc", "--keepParent"])
        XCTAssertTrue(outcome.steps[0].canUndo, "the original can come back from the Trash")

        var extract = FolderRuleAction(kind: .extract)
        extract.trashOriginal = false
        let unzip = try run([extract], on: kit.watched.appendingPathComponent("Album.zip"))
        XCTAssertFalse(unzip.failed, unzip.failure ?? "")
        XCTAssertEqual(kit.names(), ["Album", "Album.zip"])
        XCTAssertEqual(kit.names(in: kit.watched.appendingPathComponent("Album")), ["one.txt", "two.txt"])
        XCTAssertEqual(unzip.finalURL?.lastPathComponent, "Album", "later actions get the extracted folder")
        XCTAssertFalse(FileManager.default.contentsOfDirectory(atPath: kit.watched.path, error: nil).contains { $0.hasPrefix(".aom-extract") })
    }

    func testExtractRefusesWhatIsntAZip() throws {
        let file = try kit.writeSettled("a.txt")
        let outcome = try run([FolderRuleAction(kind: .extract)], on: file)
        XCTAssertTrue(outcome.failed)
        XCTAssertTrue(outcome.failure?.contains("isn't a ZIP archive") == true)
    }

    func testMoveRefusesAMissingFolderAndMovingIntoItself() throws {
        let file = try kit.writeSettled("a.txt")
        let missing = try run([.move(to: "/Volumes/AOM-Unplugged-Drive")], on: file)
        XCTAssertTrue(missing.failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/AOM-Unplugged-Drive"), "never created on the startup disk")
        let folder = kit.watched.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let into = try run([.move(to: folder.path, subfolders: "Inner")], on: folder)
        XCTAssertTrue(into.failed)
        XCTAssertTrue(into.failure?.contains("can't go into itself") == true)
        let already = try run([.move(to: kit.watched.path)], on: file)
        XCTAssertEqual(already.steps.first?.result, .skipped)
    }

    func testNothingOutsideTheWatchedFolderIsTouched() throws {
        let outside = try kit.folder("Elsewhere")
        let file = try kit.writeSettled("a.txt", in: outside)
        let info = try XCTUnwrap(FolderRuleFileReader.read(file))
        let rule = FolderRule(folderID: folderID, name: "Test", conditions: [.name(.contains, ["a"])], actions: [.moveToTrash])
        let outcome = FolderRuleExecutor(environment: kit.environment()).run(rule, on: info, in: kit.watched)
        XCTAssertTrue(outcome.failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(kit.trashed.isEmpty)
    }

    func testAFailedStepStopsTheRestAndNotificationsAreCollected() throws {
        let file = try kit.writeSettled("a.txt")
        let outcome = try run([FolderRuleAction(kind: .notify, message: "Got {name}.{ext}"),
                               .move(to: kit.root.appendingPathComponent("Nope").path), .addTags(["Never"])], on: file)
        XCTAssertTrue(outcome.failed)
        XCTAssertEqual(outcome.steps.map(\.result), [.done, .failed])
        XCTAssertEqual(outcome.notifications, ["Got a.txt"])
        XCTAssertNil(try file.resourceValues(forKeys: [.tagNamesKey]).tagNames?.first)
    }

    func testShortcutsGetTheFileAsInputThroughAnArgumentArray() throws {
        let file = try kit.writeSettled("a b.txt")
        var seen: FolderRulesProcess.Request?
        let environment = kit.environment(run: { request in
            seen = request
            return FolderRulesProcess.Result(status: 0, stdout: Data(), stderr: "")
        })
        let info = try XCTUnwrap(FolderRuleFileReader.read(file))
        var shortcut = FolderRuleAction(kind: .runShortcut)
        shortcut.shortcutName = "Resize \"Images\"; rm -rf ~"
        let rule = FolderRule(folderID: folderID, name: "Shortcut", conditions: [.kind(.document)], actions: [shortcut])
        let outcome = FolderRuleExecutor(environment: environment).run(rule, on: info, in: kit.watched)
        XCTAssertFalse(outcome.failed, outcome.failure ?? "")
        XCTAssertEqual(seen?.executable, "/usr/bin/shortcuts")
        XCTAssertEqual(seen?.arguments, ["run", "Resize \"Images\"; rm -rf ~", "--input-path", file.path],
                       "the name and path are single arguments, never shell text")
        let failing = kit.environment(run: { _ in FolderRulesProcess.Result(status: 1, stdout: Data(), stderr: "Shortcut not found") })
        let failed = FolderRuleExecutor(environment: failing).run(rule, on: info, in: kit.watched)
        XCTAssertTrue(failed.failure?.contains("Shortcut not found") == true)
    }

    func testProcessRunnerTimesOutAndDrainsBothPipes() {
        let quick = FolderRulesProcess.run(.init("/bin/echo", ["hello"], timeout: 10))
        XCTAssertTrue(quick.succeeded)
        XCTAssertEqual(String(decoding: quick.stdout, as: UTF8.self), "hello\n")
        let slow = FolderRulesProcess.run(.init("/bin/sleep", ["10"], timeout: 0.3))
        XCTAssertTrue(slow.timedOut)
        XCTAssertFalse(slow.succeeded)
        XCTAssertTrue(slow.failure(.init("/bin/sleep", ["10"], timeout: 0.3)).contains("was stopped"))
        let missing = FolderRulesProcess.run(.init("/nonexistent/tool", [], timeout: 1))
        XCTAssertNotNil(missing.launchError)
        XCTAssertEqual(FolderRulesProcess.meaningfulLines("hdiutil: WARNING: 'hdiutil attach' is deprecated.\nhdiutil: attach failed - no mountable file systems\n"),
                       "hdiutil: attach failed - no mountable file systems")
    }
}

private extension FileManager {
    func contentsOfDirectory(atPath path: String, error: Void?) -> [String] {
        (try? contentsOfDirectory(atPath: path)) ?? []
    }
}
