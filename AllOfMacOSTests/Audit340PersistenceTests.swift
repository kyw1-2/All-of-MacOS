import XCTest
import AppKit
@testable import AllOfMacOS

/// 3.4.0 audit: automations that could not be read, rolling backups that
/// pushed each other out, settings that Reset Preferences or Restore Backup
/// changed underneath a running service, and results that were dropped
/// without a word. Temporary folders and throwaway defaults suites only.
final class Audit340PersistenceTests: XCTestCase {
    private var folders: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for folder in folders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        folders.removeAll(); suites.removeAll()
        super.tearDown()
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Audit340-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func defaults() throws -> UserDefaults {
        let name = "Audit340.\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// A master preset as a newer AOM would write it: one action this
    /// version does not know, so the whole file is refused.
    private func presetFromANewerAOM() throws -> Data {
        var preset = Preset(name: "Master Preset", isMaster: true)
        var trigger = Trigger(name: "Deploy", input: .keyboardShortcut(KeyboardShortcut(keyCode: 2, modifiers: [.command, .option])))
        trigger.actions = [TriggerAction(actionType: .playPause)]
        preset.triggers = [trigger]
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetCodec.encode(preset)) as? [String: Any])
        var triggers = try XCTUnwrap(root["triggers"] as? [[String: Any]])
        var actions = try XCTUnwrap(triggers[0]["actions"] as? [[String: Any]])
        actions[0]["actionType"] = "Audit340 Action From A Newer AOM"
        triggers[0]["actions"] = actions
        root["triggers"] = triggers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        XCTAssertThrowsError(try PresetCodec.decode(data), "the fixture really is unreadable here")
        return data
    }

    private func unreadableCopies(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("unreadable-preset-") }
    }

    // MARK: Automations that cannot be read

    /// The copy was made only when the database had the automations too; a
    /// fall back to a backup or to an empty start kept nothing, and the first
    /// edit overwrote the file.
    func testAnUnreadablePresetIsKeptBeforeAnyFallbackAndSurvivesTheFirstSave() throws {
        let directory = try folder()
        let manager = PresetManager(directory: directory)
        defer { manager.flushPendingWrites() }
        _ = PresetManager.takeUnreadablePresetReport()
        let original = try presetFromANewerAOM()
        try original.write(to: directory.appendingPathComponent("master_preset.json"))

        _ = manager.loadPreset()
        let copies = try unreadableCopies(in: directory)
        XCTAssertEqual(copies.count, 1, "the file AOM could not read is kept")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original)
        let report = try XCTUnwrap(PresetManager.takeUnreadablePresetReport(), "launch is told, so the person is")
        XCTAssertEqual(report.kept?.lastPathComponent, copies.first?.lastPathComponent)

        manager.save(Preset(name: "Master Preset", isMaster: true), createBackup: false)
        XCTAssertNil(manager.lastPersistError)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), original, "the first save no longer costs the automations")
    }

    /// When no copy can be made, nothing replaces the file this session.
    func testAnUnreadablePresetThatCannotBeCopiedIsNeverOverwritten() throws {
        let directory = try folder()
        let original = try presetFromANewerAOM()
        let master = directory.appendingPathComponent("master_preset.json")
        try original.write(to: master)
        _ = PresetManager.takeUnreadablePresetReport()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let manager = PresetManager(directory: directory)
        defer { manager.flushPendingWrites() }
        _ = manager.loadPreset()
        let report = try XCTUnwrap(PresetManager.takeUnreadablePresetReport())
        XCTAssertNil(report.kept, "no copy could be made")
        // The folder is writable again, but the session stays hands-off.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        manager.save(Preset(name: "Master Preset", isMaster: true), createBackup: false)
        XCTAssertNotNil(manager.lastPersistError, "the save says it did not save")
        XCTAssertEqual(try Data(contentsOf: master), original)
    }

    @MainActor
    func testLaunchSaysWhatHappenedToAnUnreadablePreset() {
        let kept = URL(fileURLWithPath: "/tmp/AllOfMacOS/unreadable-preset-1234.json")
        let withCopy = AppState.unreadablePresetDetail(kept: kept, opened: 3)
        XCTAssertTrue(withCopy.contains("unreadable-preset-1234.json"))
        XCTAssertTrue(withCopy.contains("opened 3 automations"))
        XCTAssertTrue(AppState.unreadablePresetDetail(kept: kept, opened: 1).contains("1 automation from"))
        let none = AppState.unreadablePresetDetail(kept: nil, opened: 0)
        XCTAssertTrue(none.contains("no automations"))
        XCTAssertTrue(none.contains("will not save"))
    }

    func testAnUnreadableNewestBackupDoesNotHideAnOlderOne() throws {
        let backups = try folder()
        let older = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(Preset(name: "Older")),
                                                           directory: backups, settings: try defaults()))
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-600)], ofItemAtPath: older.path)
        let newest = backups.appendingPathComponent("preset_backup_2099-01-01_00-00-00.json")
        try presetFromANewerAOM().write(to: newest)
        XCTAssertEqual(PresetManager.listBackups(in: backups).first?.url.lastPathComponent, newest.lastPathComponent)
        XCTAssertEqual(PresetManager.loadLatestBackup(in: backups)?.name, "Older", "the newest one that can be read")
    }

    // MARK: Rolling backups

    /// Every launch saved the preset again and wrote another backup, so five
    /// identical copies pushed every older version out.
    func testASaveThatChangedNothingKeepsTheOlderBackups() throws {
        let backups = try folder()
        let settings = try defaults()
        let before = try PresetCodec.encode(Preset(name: "Before the edit"))
        let after = try PresetCodec.encode(Preset(name: "After the edit"))
        let first = try XCTUnwrap(PresetManager.saveBackup(data: before, directory: backups, settings: settings))
        XCTAssertEqual(PresetManager.saveBackup(data: before, directory: backups, settings: settings)?.lastPathComponent,
                       first.lastPathComponent, "the same preset and settings: the newest backup is kept")
        _ = PresetManager.saveBackup(data: after, directory: backups, settings: settings)
        for _ in 0..<(PresetManager.maxBackups + 2) {
            _ = PresetManager.saveBackup(data: after, directory: backups, settings: settings) // launches without edits
        }
        let rolling = PresetManager.listBackups(in: backups).map(\.url)
        XCTAssertEqual(rolling.count, 2)
        XCTAssertTrue(rolling.map(\.lastPathComponent).contains(first.lastPathComponent), "the version before the edit survives")

        // Changed settings are a new moment and get their own backup.
        settings.set(16.0, forKey: TitleBarWindowSnap.marginKey)
        _ = PresetManager.saveBackup(data: after, directory: backups, settings: settings)
        XCTAssertEqual(PresetManager.listBackups(in: backups).count, 3)
        // A safety snapshot is always written.
        _ = PresetManager.saveBackup(data: after, reason: "before-import", directory: backups, settings: settings)
        XCTAssertEqual(PresetManager.listBackups(in: backups).count, 4)
    }

    // MARK: Settings changed underneath a running service

    /// Reset Preferences removes the key and posts .aomSettingChanged; the
    /// rules read at launch stayed in force and the next edit wrote them back.
    func testAResetIsNotUndoneByTheSuppressionRulesReadAtLaunch() throws {
        let suite = try defaults()
        let suppression = TriggerSuppression(defaults: suite, schedulesExpiry: false)
        suppression.settings.disableWhileHoldingModifiers = NSEvent.ModifierFlags.command.rawValue
        XCTAssertNotNil(suite.data(forKey: TriggerSuppression.settingsKey))

        suite.removeObject(forKey: TriggerSuppression.settingsKey)
        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        XCTAssertEqual(suppression.settings.disableWhileHoldingModifiers, 0, "the reset is in force at once")
        XCTAssertNil(suite.data(forKey: TriggerSuppression.settingsKey), "and the defaults are not written back")

        suppression.settings.disableTrackpadAfterKeyEnabled = true
        let stored = try JSONDecoder().decode(TriggerSuppressionSettings.self,
                                              from: XCTUnwrap(suite.data(forKey: TriggerSuppression.settingsKey)))
        XCTAssertEqual(stored.disableWhileHoldingModifiers, 0, "the next edit keeps the reset")
        XCTAssertTrue(stored.disableTrackpadAfterKeyEnabled)
    }

    @MainActor
    func testClipboardPreferencesFollowAReset() throws {
        let suite = try defaults()
        let preferences = ClipboardPreferences(defaults: suite)
        preferences.networkPreviews = true
        preferences.compact = true
        suite.removeObject(forKey: "AOMClipboardNetworkPreviews")
        suite.removeObject(forKey: "AOMClipboardCompact")
        NotificationCenter.default.post(name: .aomSettingChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(preferences.networkPreviews, "link previews stop fetching at once")
        XCTAssertFalse(preferences.compact)
        XCTAssertTrue(preferences.showInScreenCapture, "untouched keys keep their values")
    }

    /// Restore Backup writes the backup's variables; the copy cached at
    /// launch then overwrote them at the next script result or Set Variable.
    func testRestoredVariablesAreNotOverwrittenByTheLaunchCopy() throws {
        XCTAssertTrue(WorkflowVariables.set("audit340_before", value: "1"))
        let name = TriggerSuppression.suiteNamePrefix + "Variables" + String(ProcessInfo.processInfo.processIdentifier)
        let stored = try XCTUnwrap(UserDefaults(suiteName: name), "the variables' own test suite")
        defer {
            for key in ["audit340_before", "audit340_restored", "audit340_after"] { WorkflowVariables.remove(key) }
        }
        stored.set(["audit340_restored": "from the backup"], forKey: "AOMWorkflowVariables")
        XCTAssertEqual(WorkflowVariables.value("audit340_restored"), "from the backup")
        XCTAssertTrue(WorkflowVariables.set("audit340_after", value: "2"))
        let now = try XCTUnwrap(stored.dictionary(forKey: "AOMWorkflowVariables") as? [String: String])
        XCTAssertEqual(now["audit340_restored"], "from the backup", "the next write keeps what the restore put there")
        XCTAssertEqual(now["audit340_after"], "2")
        XCTAssertNil(now["audit340_before"], "and does not bring back what the restore replaced")
    }

    func testAScriptResultThatCannotBeStoredSaysSo() {
        var logged: [String] = []
        let long = String(repeating: "a", count: 60)
        defer { for key in [long, "audit340_ok", "audit340_ok_exitCode", "audit340_ok_timedOut"] { WorkflowVariables.remove(key) } }
        XCTAssertFalse(ScriptActionResults.record(name: long, output: "out", code: 0, timedOut: false, log: { logged.append($0) }))
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.first?.contains("55") == true, "says how long a name may be")
        XCTAssertFalse(ScriptActionResults.record(name: "결과", output: "out", code: 0, timedOut: false, log: { logged.append($0) }))
        XCTAssertEqual(logged.count, 2)
        XCTAssertTrue(ScriptActionResults.record(name: "audit340_ok", output: "out", code: 3, timedOut: false, log: { logged.append($0) }))
        XCTAssertEqual(logged.count, 2, "a result that was stored logs nothing")
        XCTAssertEqual(WorkflowVariables.value("audit340_ok_exitCode"), "3")
    }
}
