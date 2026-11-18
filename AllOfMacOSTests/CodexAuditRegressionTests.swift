import AppKit
import XCTest
@testable import AllOfMacOS

/// Codex's 2026-11-18 audit reproduced each defect with a probe test that
/// asserted the broken behaviour (`AOM-6.3.3-감사보고서.html`, appendix).
/// These are the same probes asserting the fixed behaviour.
final class CodexAuditFolderRulesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aom-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    /// F01: undoing an optimization whose original is gone used to trash the
    /// optimized file first and then fail, losing both.
    func testUndoWithoutTheOriginalKeepsTheOptimizedFile() throws {
        let optimized = dir.appendingPathComponent("optimized.png")
        let fakeTrash = dir.appendingPathComponent("in-fake-trash.png")
        try Data([1]).write(to: optimized)
        var env = FolderRulesEnvironment.live
        env.trash = { url in try FileManager.default.moveItem(at: url, to: fakeTrash); return fakeTrash }
        let step = FolderRuleStepRecord(action: .optimizeImage, result: .done, summary: "",
            undo: .restoreOriginal(trashed: dir.appendingPathComponent("missing").path,
                                   original: dir.appendingPathComponent("original.png").path, replacement: optimized.path))
        let outcome = FolderRuleExecutor(environment: env).undo([step])
        XCTAssertNotNil(outcome.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: optimized.path), "the optimized file stays put")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeTrash.path))
    }

    /// F01: when the original's return fails after the optimized file went
    /// to the Trash, the optimized file comes back.
    func testFailedRestorePutsTheOptimizedFileBack() throws {
        let optimized = dir.appendingPathComponent("optimized.png")
        let trashedOriginal = dir.appendingPathComponent("trashed-original.png")
        let fakeTrash = dir.appendingPathComponent("trashed-optimized.png")
        try Data([1]).write(to: optimized)
        try Data([2]).write(to: trashedOriginal)
        var env = FolderRulesEnvironment.live
        env.trash = { url in try FileManager.default.moveItem(at: url, to: fakeTrash); return fakeTrash }
        // The original's folder exists at check time but the target name is a
        // directory that can't be replaced: the move fails after trashing.
        let original = dir.appendingPathComponent("blocked/original.png")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: original.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: original.deletingLastPathComponent().path) }
        let step = FolderRuleStepRecord(action: .optimizeImage, result: .done, summary: "",
            undo: .restoreOriginal(trashed: trashedOriginal.path, original: original.path, replacement: optimized.path))
        let outcome = FolderRuleExecutor(environment: env).undo([step])
        XCTAssertNotNil(outcome.failure)
        XCTAssertEqual(try Data(contentsOf: optimized), Data([1]), "the optimized file is back where it was")
    }

    /// F02: one malformed rule used to empty the whole list.
    func testOneDamagedRuleKeepsItsNeighboursAndACopy() throws {
        let store = FolderRulesStore(directory: dir)
        let folder = FolderRuleFolder(path: dir.path)
        try store.save(FolderRulesConfig(folders: [folder], rules: [FolderRule(folderID: folder.id, name: "Keep"),
                                                                   FolderRule(folderID: folder.id, name: "Keep too")]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.configURL)) as? [String: Any])
        var records = try XCTUnwrap(object["rules"] as? [Any])
        records.append("unreadable record")
        object["rules"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: store.configURL)
        let result = store.loadConfig(defaults: { FolderRulesConfig() })
        XCTAssertTrue(result.existed)
        XCTAssertEqual(result.config.rules.map(\.name), ["Keep", "Keep too"])
        XCTAssertEqual(result.config.decodeLosses, 1)
        let copy = try XCTUnwrap(result.setAside, "the damaged original is kept before anything saves over it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNil(result.savesBlocked)
    }

    /// F02: a rule missing one of its conditions would match more than it was
    /// written to, so it loads switched off.
    func testARuleWithAnUnreadableConditionIsTurnedOff() throws {
        let store = FolderRulesStore(directory: dir)
        let folder = FolderRuleFolder(path: dir.path)
        try store.save(FolderRulesConfig(isEnabled: true, folders: [folder],
                                         rules: [FolderRule(folderID: folder.id, name: "Careful", isEnabled: true)]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.configURL)) as? [String: Any])
        var rules = try XCTUnwrap(object["rules"] as? [[String: Any]])
        rules[0]["conditions"] = [["garbage": true]]
        object["rules"] = rules
        try JSONSerialization.data(withJSONObject: object).write(to: store.configURL)
        let rule = try XCTUnwrap(store.loadConfig(defaults: { FolderRulesConfig() }).config.rules.first)
        XCTAssertTrue(rule.isDamaged)
        XCTAssertFalse(rule.isEnabled)
        XCTAssertTrue(rule.conditions.isEmpty)
    }

    /// F03: an unreadable rules.json used to look missing, and the defaults
    /// written next replaced it.
    func testAnUnreadableFileBlocksSaving() throws {
        let store = FolderRulesStore(directory: dir)
        try store.save(FolderRulesConfig(isEnabled: true))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.configURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.configURL.path) }
        let state = store.loadConfig(defaults: { FolderRulesConfig() })
        XCTAssertTrue(state.existed)
        XCTAssertNotNil(state.savesBlocked)
    }

    /// F14: undo used to move whatever file sat at the recorded path.
    func testUndoLeavesADifferentFileAtTheRecordedPathAlone() throws {
        let current = dir.appendingPathComponent("result"), original = dir.appendingPathComponent("origin")
        try Data("step output".utf8).write(to: current)
        let identity = FolderRulesSafety.identity(current)
        try FileManager.default.removeItem(at: current)
        try Data("new occupant".utf8).write(to: current)
        let step = FolderRuleStepRecord(action: .rename, result: .done, summary: "",
                                        undo: .moveBack(current: current.path, original: original.path, identity: identity))
        let result = FolderRuleExecutor(environment: .live).undo([step])
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(try Data(contentsOf: current), Data("new occupant".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testUndoStillMovesTheSameFileBack() throws {
        let current = dir.appendingPathComponent("result"), original = dir.appendingPathComponent("origin")
        try Data("step output".utf8).write(to: current)
        let step = FolderRuleStepRecord(action: .rename, result: .done, summary: "",
                                        undo: .moveBack(current: current.path, original: original.path,
                                                        identity: FolderRulesSafety.identity(current)))
        XCTAssertNil(FolderRuleExecutor(environment: .live).undo([step]).failure)
        XCTAssertEqual(try Data(contentsOf: original), Data("step output".utf8))
    }

    func testRecordsWrittenBeforeIdentityStillDecode() throws {
        let json = #"{"action":"rename","result":"done","summary":"","undo":{"moveBack":{"current":"/a","original":"/b"}}}"#
        let record = try JSONDecoder().decode(FolderRuleStepRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.undo, .moveBack(current: "/a", original: "/b", identity: nil))
    }
}

final class CodexAuditMiscTests: XCTestCase {
    /// F09: a second menu with the same name is refused, and a name two old
    /// menus share finds neither.
    func testMenuNamesAreUnique() throws {
        let suite = "AOMAudit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FloatingMenuStore(defaults: defaults)
        let first = FloatingMenuDefinition()
        try store.save(first)
        XCTAssertThrowsError(try store.save(FloatingMenuDefinition()))
        XCTAssertEqual(store.uniqueName(first.name), "My Menu 2")
        var second = FloatingMenuDefinition(); second.name = store.uniqueName(second.name)
        try store.save(second)
        XCTAssertEqual(store.find(" my menu 2 ")?.id, second.id)
        XCTAssertEqual(store.find(second.id.uuidString)?.id, second.id)
        // Data from before 6.4.0 can still hold two equal names.
        let legacy = [first, { var copy = FloatingMenuDefinition(); copy.name = first.name; return copy }()]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "AOMFloatingMenusV1")
        let reloaded = FloatingMenuStore(defaults: defaults)
        XCTAssertNil(reloaded.find(first.name))
        XCTAssertTrue(reloaded.isAmbiguous(first.name))
    }

    /// F16: schemes other than http(s) and mailto keep their scheme.
    func testOpenURLKeepsEveryScheme() {
        XCTAssertEqual(ActionExecutor.openURLTarget("tel:+821012345678")?.absoluteString, "tel:+821012345678")
        XCTAssertEqual(ActionExecutor.openURLTarget("sms:010")?.scheme, "sms")
        XCTAssertEqual(ActionExecutor.openURLTarget("MAILTO:a@b.c")?.scheme?.lowercased(), "mailto")
        XCTAssertEqual(ActionExecutor.openURLTarget("raycast://extensions")?.scheme, "raycast")
        XCTAssertEqual(ActionExecutor.openURLTarget("apple.com")?.absoluteString, "https://apple.com")
        XCTAssertEqual(ActionExecutor.openURLTarget("localhost:8080/x")?.absoluteString, "https://localhost:8080/x")
        XCTAssertNil(ActionExecutor.openURLTarget("  "))
    }

    /// F15: a helper that ignores SIGTERM no longer keeps the caller waiting.
    func testPaletteProcessAnswersEvenWhenTheToolIgnoresTermination() async {
        let started = Date()
        let output = await PaletteProcess.run("/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30"], timeout: 0.5)
        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testDrainDoesNotWaitForEndOfFile() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("abc".utf8))
        // The write end stays open, as with a grandchild holding it.
        XCTAssertEqual(pipe.fileHandleForReading.drainWithoutWaiting(), Data("abc".utf8))
    }

    /// F05: nothing reaches AppState through NSApp.delegate any more.
    func testNoCodeCastsNSAppDelegate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AllOfMacOS")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("delegate as? AppDelegate"), file.lastPathComponent)
        }
    }

    /// F13: a repeated ID or an absurd size in the capture manifest is safe.
    func testCaptureSizeValidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aom-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CaptureHistory.validatedSize(width: 40, height: 20, scale: 2, source: source)?.pixelWidth, 80)
        let fallback = try XCTUnwrap(CaptureHistory.validatedSize(width: .infinity, height: 20, scale: 1, source: source))
        XCTAssertEqual(fallback.pixelWidth, rep.pixelsWide)
        XCTAssertNotNil(CaptureHistory.validatedSize(width: 1e300, height: 1e300, scale: 1, source: source))
    }
}

final class CodexAuditInFlightTests: XCTestCase {
    /// D02: two picks a second apart are a habit.
    func testTwoPicksMomentsApartAreASuggestion() {
        var knowledge = PaletteKnowledge()
        let start = Date()
        knowledge.record(itemID: "nav", query: "", now: start)
        knowledge.record(itemID: "nav", query: "", now: start.addingTimeInterval(1))
        XCTAssertEqual(knowledge.suggestions(among: ["nav"], limit: 5, now: start.addingTimeInterval(2)), ["nav"])
        XCTAssertTrue(knowledge.suggestions(among: ["nav"], limit: 5, now: start.addingTimeInterval(40 * 86_400)).isEmpty,
                      "a month-old habit is not one now")
    }

    /// D03: the store reads and writes the defaults it was made with.
    @MainActor
    func testKnowledgeStoreUsesItsOwnDefaults() throws {
        let suite = "AOMPalette." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PaletteKnowledgeStore(defaults: defaults).record(itemID: "action.capture", query: "ca")
        XCTAssertEqual(PaletteKnowledgeStore(defaults: defaults).knowledge.pick(for: "ca"), "action.capture")
        XCTAssertNil(UserDefaults.standard.data(forKey: PaletteKnowledgeStore.defaultsKey + ".never"))
    }

    /// D01: low battery stops the display rule's session, and power brings it back.
    func testDisplayRuleWaitsForPowerAfterALowBatteryStop() {
        XCTAssertFalse(KeepAwakeRules.wantsDisplayAssertion(enabled: true, builtInFlags: [true, false])
                       && !KeepAwakeRules.shouldStopForBattery(floor: 20, percent: 10, onBattery: true))
        XCTAssertTrue(KeepAwakeRules.wantsDisplayAssertion(enabled: true, builtInFlags: [true, false])
                      && !KeepAwakeRules.shouldStopForBattery(floor: 20, percent: 10, onBattery: false))
    }
}
