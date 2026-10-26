import XCTest
import SQLite3
@testable import AllOfMacOS

final class TrackpadStabilityTests: XCTestCase {
    private func fixture() -> Preset {
        var preset = Preset(name: "Trackpad round trip", isMaster: true)
        let app = AppTarget(id: UUID(), bundleID: "test.app", name: "Test", iconPath: nil)
        preset.appTargets.append(app)
        var global = Trigger(name: "Global", input: .trackpadGesture(.fourFingerTap))
        global.hapticFeedback = true; global.suppressClick = true
        var key = TriggerAction(actionType: .sendKeyStroke); key.parameters.shortcutKeyCode = 12
        var script = TriggerAction(actionType: .runShellScript); script.parameters.scriptContent = "printf test"; script.parameters.scriptTimeoutSeconds = 2
        global.actions = [key, script]
        let unrelated = Trigger(name: "Keyboard preserved", input: .keyboardShortcut(KeyboardShortcut(keyCode: 24, modifiers: .option)))
        var scoped = Trigger(name: "Scoped", input: .trackpadGesture(.fourFingerTap), appBundleID: app.bundleID)
        scoped.actions = [TriggerAction(actionType: .maximizeWindow)]
        preset.triggers = [global, unrelated, scoped]
        return preset
    }
    func testNormalizedGraphRoundTripPreservesOrderScopeShortcutsAndOtherInputs() throws {
        let store = try TrackpadPresetStore(url: nil, inMemory: true)
        let preset = fixture(); try store.save(preset)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.triggers, preset.triggers)
        XCTAssertEqual(loaded.appTargets, preset.appTargets)
        XCTAssertEqual(loaded.id, preset.id)
    }
    func testSQLiteReopensAndTransactionRejectsDuplicateBindings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trackpad.sqlite")
        let preset = fixture()
        var store: TrackpadPresetStore? = try TrackpadPresetStore(url: url)
        try store?.save(preset)
        var invalid = preset; invalid.triggers.append(invalid.triggers[0])
        XCTAssertThrowsError(try store?.save(invalid))
        store = nil
        let reopened = try TrackpadPresetStore(url: url)
        XCTAssertEqual(try reopened.load()?.triggers, preset.triggers)
    }
    func testMalformedDatabasePositionsAndShortcutCodesThrowInsteadOfCrashing() throws {
        for statement in ["UPDATE ZGESTUREBINDING SET ZPOSITION = -1",
                          "UPDATE ZACTIONSHORTCUT SET ZKEYCODE = 65536",
                          "UPDATE ZACTIONSHORTCUT SET ZMODIFIERS = 'not-a-number'"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("trackpad.sqlite")
            var original: TrackpadPresetStore? = try TrackpadPresetStore(url: url)
            try original?.save(fixture())
            original = nil
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK)
            XCTAssertGreaterThan(sqlite3_changes(database), 0)
            sqlite3_close(database)
            let reopened = try TrackpadPresetStore(url: url)
            XCTAssertThrowsError(try reopened.load(), statement)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testLegacyAndVersionedPresetFormatsRoundTrip() throws {
        let preset = fixture()
        for envelope in [false, true] {
            XCTAssertEqual(try PresetCodec.decode(PresetCodec.encode(preset, envelope: envelope)).triggers, preset.triggers)
        }
    }
    func testUnknownVersionAndPartiallyDecodablePresetAreRejected() throws {
        let preset = fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetCodec.encode(preset, envelope: true)) as? [String: Any])
        object["schemaVersion"] = 999
        XCTAssertThrowsError(try PresetCodec.decode(JSONSerialization.data(withJSONObject: object)))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetCodec.encode(preset)) as? [String: Any])
        var triggers = raw["triggers"] as! [[String: Any]]; triggers[0]["input"] = ["unrecognizedGesture": [:]]; raw["triggers"] = triggers
        XCTAssertThrowsError(try PresetCodec.decode(JSONSerialization.data(withJSONObject: raw)))
    }
    func testCorruptJSONRecoversCommittedGraphAndPreservesOriginalFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = PresetManager(directory: dir)
        defer { manager.flushPendingWrites() }
        let preset = fixture()
        manager.save(preset, createBackup: false)
        manager.flushPendingWrites()
        let file = dir.appendingPathComponent("master_preset.json")
        let broken = Data("{unreadable".utf8)
        try broken.write(to: file)
        XCTAssertEqual(manager.loadPreset()?.triggers, preset.triggers)
        XCTAssertEqual(try PresetCodec.decode(Data(contentsOf: file)).triggers, preset.triggers)
        let originals = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("unreadable-preset-") }
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(originals.first)), broken)
    }
    func testHapticsAreOptInThrottledAndDoNotFireForDisabledFeedback() {
        var count = 0; let haptics = GestureHaptics { count += 1 }
        XCTAssertFalse(haptics.feedback(enabled: false, now: 1))
        XCTAssertTrue(haptics.feedback(enabled: true, now: 1))
        XCTAssertFalse(haptics.feedback(enabled: true, now: 1.03))
        XCTAssertTrue(haptics.feedback(enabled: true, now: 1.09))
        XCTAssertEqual(count, 2)
    }
}
