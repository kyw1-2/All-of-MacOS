import XCTest
@testable import AllOfMacOS

/// Audit 2026-10-28 F07: back up a profile and restore it into a new one
/// (a new Mac or user account), plus the safety rules around restoring.
/// Uses throwaway UserDefaults suites and temporary folders only.
@MainActor
final class ProfileBackupRestoreTests: XCTestCase {
    private var folders: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        folders.removeAll(); suites.removeAll()
        super.tearDown()
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AOMAuditF07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private func defaults() throws -> UserDefaults {
        let name = "AOMAuditF07.\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// A profile using the 3.x features the audit named: activation groups,
    /// display snap profiles and app-scoped automations.
    private func profile() -> Preset {
        var preset = Preset(name: "Work Profile")
        var group = ActivationGroup(name: "Browsers")
        group.includedBundleIDs = ["com.example.browser"]
        preset.activationGroups = [group]
        let zones = CustomSnapZone.Collection.essentials.replacing([])
        preset.snapProfiles = [SnapLayoutProfile(name: "Desk", displayIDs: ["external", "internal"], zones: zones, requiresOption: true)]
        preset.automaticSnapProfiles = true
        var swipe = Trigger(name: "Left half", input: .trackpadGesture(.threeFingerSwipeLeft))
        swipe.actions = [TriggerAction(actionType: .snapWindowLeft)]
        swipe.activationGroupID = group.id
        preset.addTrigger(swipe)
        var key = Trigger(name: "Center", input: .keyboardShortcut(.init(keyCode: 8, modifiers: [.control, .option])))
        key.actions = [TriggerAction(actionType: .centerWindow)]
        preset.addTrigger(key)
        return preset
    }

    func testAProfileBacksUpAndRestoresIntoANewProfile() throws {
        let backups = try folder()
        let old = try defaults()
        // 3.2–3.3 settings that 3.3.0 left out of the backup.
        old.set(true, forKey: TitleBarWindowSnap.enabledKey)
        old.set(12.0, forKey: TitleBarWindowSnap.marginKey)
        old.set(false, forKey: TitleBarWindowSnap.activateKey)
        old.set(false, forKey: TrackpadUtilityGestures.dockQuitEnabledKey)
        var suppression = TriggerSuppressionSettings()
        suppression.disableTrackpadAfterKeyEnabled = true
        old.set(try JSONEncoder().encode(suppression), forKey: TriggerSuppression.settingsKey)
        old.set(Data("[]".utf8), forKey: "AOMWindowLayoutsV1")
        old.set(0.4, forKey: "AOMAudioGain_com.example.player")
        old.set(false, forKey: AutomationGate.masterSwitchKey)
        old.set("not a setting", forKey: "AOMSomethingPrivate")
        let original = profile()
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(original), directory: backups, settings: old))
        let settingsFile = PresetManager.settingsURL(forBackup: backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFile.path), "the backup carries its own settings")

        // A new profile: empty preferences and an empty preset folder.
        let fresh = try defaults()
        let restoredCount = try XCTUnwrap(PresetManager.restoreSettings(fromFile: settingsFile, into: fresh))
        XCTAssertEqual(restoredCount, 7, "the seven backed-up settings set above; not the pause switch, not the private one")
        XCTAssertEqual(fresh.object(forKey: TitleBarWindowSnap.enabledKey) as? Bool, true)
        XCTAssertEqual(fresh.double(forKey: TitleBarWindowSnap.marginKey), 12)
        XCTAssertEqual(fresh.object(forKey: TitleBarWindowSnap.activateKey) as? Bool, false)
        XCTAssertEqual(fresh.object(forKey: TrackpadUtilityGestures.dockQuitEnabledKey) as? Bool, false)
        let restoredSuppression = try JSONDecoder().decode(TriggerSuppressionSettings.self,
                                                          from: try XCTUnwrap(fresh.data(forKey: TriggerSuppression.settingsKey)))
        XCTAssertEqual(restoredSuppression, suppression)
        XCTAssertEqual(fresh.double(forKey: "AOMAudioGain_com.example.player"), 0.4, accuracy: 1e-9)
        XCTAssertNil(fresh.object(forKey: AutomationGate.masterSwitchKey), "a restore never pauses or resumes AOM")
        XCTAssertNil(fresh.object(forKey: "AOMSomethingPrivate"), "only backed-up settings are restored")

        let latest = try XCTUnwrap(PresetManager.loadLatestBackup(in: backups))
        let presets = try folder()
        let manager = PresetManager(directory: presets)
        defer { manager.flushPendingWrites() }
        manager.save(latest, createBackup: false)
        manager.flushPendingWrites()
        let reader = PresetManager(directory: presets)
        defer { reader.flushPendingWrites() }
        let reloaded = try XCTUnwrap(reader.loadPreset())
        XCTAssertEqual(reloaded.triggers.map(\.id), original.triggers.map(\.id))
        XCTAssertEqual(reloaded.triggers.map(\.actions), original.triggers.map(\.actions))
        XCTAssertEqual(reloaded.activationGroups, original.activationGroups)
        XCTAssertEqual(reloaded.snapProfiles, original.snapProfiles)
        XCTAssertEqual(reloaded.automaticSnapProfiles, true)
        XCTAssertEqual(reloaded.triggers.first?.activationGroupID, original.activationGroups.first?.id)
    }

    /// A later save must not change what an earlier backup restores (the
    /// single settings_backup.plist is rewritten by every save).
    func testAnOlderBackupRestoresTheSettingsOfItsOwnMoment() throws {
        let backups = try folder()
        let live = try defaults()
        live.set(12.0, forKey: TitleBarWindowSnap.marginKey)
        let older = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: backups, settings: live))
        live.set(30.0, forKey: TitleBarWindowSnap.marginKey)
        Thread.sleep(forTimeInterval: 1.1)       // a different timestamp
        PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: backups, settings: live)
        let target = try defaults()
        XCTAssertNotNil(PresetManager.restoreSettings(fromFile: PresetManager.settingsURL(forBackup: older), into: target))
        XCTAssertEqual(target.double(forKey: TitleBarWindowSnap.marginKey), 12)
        XCTAssertNotNil(PresetManager.restoreUserDefaultsFromBackup(into: target, from: backups))
        XCTAssertEqual(target.double(forKey: TitleBarWindowSnap.marginKey), 30, "the legacy file holds only the latest settings")
    }

    func testRestoringABackupWithSettingsKeepsTheCurrentSettingsFirst() throws {
        let state = AppState()
        // No debounced save may land in a later test's shared preset file.
        defer { state.flushPendingWrites() }
        var reports: [(String, Bool)] = []
        state.presetOperationReporter = { title, _, style in reports.append((title, style == .failure)) }
        let backups = try folder()
        let saved = try defaults()
        saved.set(12.0, forKey: TitleBarWindowSnap.marginKey)
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: backups, settings: saved))
        let live = try defaults()
        live.set(30.0, forKey: TitleBarWindowSnap.marginKey)
        let before = Set(PresetManager.listBackups().map(\.url))
        XCTAssertTrue(state.restorePresetBackup(backup, includeSettings: true, defaults: live))
        XCTAssertEqual(state.currentPreset.name, "Work Profile")
        XCTAssertEqual(live.double(forKey: TitleBarWindowSnap.marginKey), 12, "the backup's settings are applied")
        // The replaced automations and settings are one restorable snapshot.
        let kept = try XCTUnwrap(PresetManager.listBackups().map(\.url).first { !before.contains($0) && $0.lastPathComponent.contains("-before-restore") })
        let previous = try XCTUnwrap(PresetManager.readSettings(fromFile: PresetManager.settingsURL(forBackup: kept)))
        XCTAssertEqual(previous.values[TitleBarWindowSnap.marginKey] as? Double, 30, "the replaced settings were kept first")
        XCTAssertEqual(reports.last?.0, "Backup Restored")
        XCTAssertEqual(reports.last?.1, false)
    }

    /// The review's blocker: with backups on, the set is normally full, and
    /// restoring its oldest member used to delete it (and its settings)
    /// before they were read.
    func testRestoringTheOldestBackupOfAFullSetKeepsItAndRestoresItsSettings() throws {
        let state = AppState()
        defer { state.flushPendingWrites() }
        state.flushPendingWrites()
        var reports: [(String, Bool)] = []
        state.presetOperationReporter = { title, _, style in reports.append((title, style == .failure)) }
        let directory = PresetManager.backupDirectory
        for entry in PresetManager.listBackups(in: directory) {
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: PresetManager.settingsURL(forBackup: entry.url))
        }
        let saved = try defaults()
        var rolling: [URL] = []
        for index in 0..<PresetManager.maxBackups {
            saved.set(Double(10 + index), forKey: TitleBarWindowSnap.marginKey)
            var preset = profile()
            preset.name = "Backup \(index)"
            let url = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(preset), directory: directory, settings: saved))
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(Double(index - 10) * 60)], ofItemAtPath: url.path)
            rolling.append(url)
        }
        XCTAssertEqual(PresetManager.listBackups(in: directory).count, PresetManager.maxBackups, "a full rolling set")
        let oldest = try XCTUnwrap(PresetManager.listBackups(in: directory).last?.url)
        XCTAssertEqual(oldest.lastPathComponent, rolling[0].lastPathComponent)
        let live = try defaults()
        live.set(40.0, forKey: TitleBarWindowSnap.marginKey)
        XCTAssertTrue(state.restorePresetBackup(oldest, includeSettings: true, defaults: live))
        XCTAssertEqual(state.currentPreset.name, "Backup 0")
        XCTAssertEqual(live.double(forKey: TitleBarWindowSnap.marginKey), 10, "its own settings were applied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path), "the restored backup is still listed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: PresetManager.settingsURL(forBackup: oldest).path))
        let after = PresetManager.listBackups(in: directory).map(\.url)
        XCTAssertEqual(after.filter { !PresetManager.isSafetySnapshot($0) }.count, PresetManager.maxBackups,
                       "the restore wrote no rolling backup of its own")
        XCTAssertEqual(after.filter(PresetManager.isSafetySnapshot).count, 1, "one -before-restore snapshot")
        XCTAssertEqual(reports.last?.0, "Backup Restored")

        // The oldest of a full set of safety snapshots is protected the same way.
        for entry in PresetManager.listBackups(in: directory) {
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: PresetManager.settingsURL(forBackup: entry.url))
        }
        let writer = PresetManager(directory: try folder())
        var snapshots: [URL] = []
        for _ in 0..<PresetManager.maxSafetySnapshots {
            snapshots.append(try XCTUnwrap(writer.snapshotBeforeReplacing(profile(), reason: "before-import", directory: directory,
                                                                          settings: saved)))
        }
        for (index, url) in snapshots.enumerated() {
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(Double(index - 20) * 60)], ofItemAtPath: url.path)
        }
        let oldestSnapshot = try XCTUnwrap(PresetManager.listBackups(in: directory).last?.url)
        XCTAssertTrue(state.restorePresetBackup(oldestSnapshot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldestSnapshot.path), "a full set of snapshots does not lose the one restored")
    }

    func testASettingsRestoreNeverPausesOrResumesAutomation() throws {
        let state = AppState()
        defer { state.flushPendingWrites() }
        state.presetOperationReporter = { _, _, _ in }
        let saved = try defaults()
        saved.set(false, forKey: AutomationGate.masterSwitchKey)      // paused when the backup was made
        saved.set(14.0, forKey: TitleBarWindowSnap.marginKey)
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: try folder(), settings: saved))
        let live = try defaults()
        live.set(true, forKey: AutomationGate.masterSwitchKey)
        let running = state.globalEnabled
        XCTAssertTrue(state.restorePresetBackup(backup, includeSettings: true, defaults: live))
        XCTAssertEqual(live.object(forKey: AutomationGate.masterSwitchKey) as? Bool, true, "the live switch is untouched")
        XCTAssertEqual(state.globalEnabled, running)
        XCTAssertEqual(live.double(forKey: TitleBarWindowSnap.marginKey), 14)
        for key in ["AOMBackupsEnabled", "AOMMaxBackups", "AOMBackupPath", AutomationGate.masterSwitchKey] {
            XCTAssertFalse(PresetManager.isBackedUpSetting(key), key)
        }
    }

    /// A restore puts back the settings of that moment exactly: one changed
    /// from its default afterwards goes back to the default, and an app added
    /// to the mixer afterwards loses its per-app setting.
    func testARestoreIsFaithfulForSettingsThatWereUnsetAtBackupTime() throws {
        let saved = try defaults()
        saved.set(0.4, forKey: "AOMAudioGain_com.example.a")
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: try folder(), settings: saved))
        let live = try defaults()
        live.set(30.0, forKey: TitleBarWindowSnap.marginKey)               // unset in the backup
        live.set(0.9, forKey: "AOMAudioGain_com.example.b")                // not in the backup's family
        live.set(0.4, forKey: "AOMAudioGain_com.example.a")                // same
        let preview = try XCTUnwrap(PresetManager.restorePreview(of: backup, current: Preset(name: "Now"), defaults: live))
        XCTAssertEqual(preview.changedSettings, 2, preview.summary)
        XCTAssertEqual(preview.changedAreas, ["Audio", "Title-bar snap"])
        XCTAssertFalse(preview.partialSettings)
        let snapshot = try XCTUnwrap(PresetManager.readSettings(fromFile: PresetManager.settingsURL(forBackup: backup)))
        let result = snapshot.apply(to: live)
        XCTAssertEqual(result.removed, 2)
        XCTAssertNil(live.object(forKey: TitleBarWindowSnap.marginKey), "back to its default")
        XCTAssertNil(live.object(forKey: "AOMAudioGain_com.example.b"))
        XCTAssertEqual(live.double(forKey: "AOMAudioGain_com.example.a"), 0.4, accuracy: 1e-9)
        XCTAssertTrue(snapshot.changes(against: live).isEmpty, "applying it again changes nothing")
    }

    func testAnUnreadableSettingsFileIsNotOfferedAndRestoringItChangesNothing() throws {
        let state = AppState()
        defer { state.flushPendingWrites() }
        var reports: [(String, Bool)] = []
        state.presetOperationReporter = { title, _, style in reports.append((title, style == .failure)) }
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: try folder(), settings: try defaults()))
        try Data("not a plist".utf8).write(to: PresetManager.settingsURL(forBackup: backup))
        let preview = try XCTUnwrap(PresetManager.restorePreview(of: backup, current: state.currentPreset, defaults: try defaults()))
        XCTAssertFalse(preview.hasSettings, "the dialog offers settings only when the file was read")
        let current = state.currentPreset.name
        XCTAssertFalse(state.restorePresetBackup(backup, includeSettings: true, defaults: try defaults()))
        XCTAssertEqual(state.currentPreset.name, current, "nothing was replaced")
        XCTAssertEqual(reports.last?.0, "Could Not Restore the Backup")
        XCTAssertEqual(reports.last?.1, true)
    }

    func testARestoreThatCannotKeepASnapshotChangesNothing() throws {
        let state = AppState()
        defer { state.flushPendingWrites() }
        var reports: [(String, Bool)] = []
        state.presetOperationReporter = { title, _, style in reports.append((title, style == .failure)) }
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: try folder(), settings: try defaults()))
        let directory = PresetManager.backupDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let current = state.currentPreset.name
        XCTAssertFalse(state.restorePresetBackup(backup))
        XCTAssertEqual(state.currentPreset.name, current, "no snapshot, no replacement")
        XCTAssertEqual(reports.last?.0, "Could Not Restore the Backup")
        XCTAssertEqual(reports.last?.1, true)
    }

    func testEveryNewGestureSettingIsBackedUp() {
        for key in [TitleBarWindowSnap.enabledKey, TitleBarWindowSnap.hapticKey, TitleBarWindowSnap.marginKey,
                    TitleBarWindowSnap.activateKey, TitleBarWindowSnap.keepPointerKey,
                    TitleBarWindowSnap.thirdsKey, TitleBarWindowSnap.previewKey, TitleBarWindowSnap.holdCancelKey,
                    TitleBarWindowSnap.pinchKey, TitleBarWindowSnap.doubleTapKey, TitleBarWindowSnap.holdKey,
                    TitleBarWindowSnap.downActionKey, TitleBarWindowSnap.modifiersKey,
                    TitleBarWindowSnap.sensitivityKey, TitleBarWindowSnap.gridKey, TitleBarWindowSnap.almostKey,
                    TitleBarWindowSnap.hotkeysKey, TitleBarWindowSnap.dragUnsnapKey, TitleBarWindowSnap.resnapKey,
                    TitleBarWindowSnap.animationKey, TitleBarWindowSnap.stageManagerOffsetKey,
                    TitleBarWindowSnap.resizeAdjacentKey,
                    TrackpadUtilityGestures.spacesEnabledKey, TrackpadUtilityGestures.dockQuitEnabledKey,
                    TrackpadUtilityGestures.dockGesturesKey, TrackpadUtilityGestures.menuBarGesturesKey,
                    TriggerSuppression.settingsKey, "AOMWindowLayoutsV1"] {
            XCTAssertTrue(PresetManager.isBackedUpSetting(key), key)
        }
        // 3.3.3: the title-bar snap's new options and modifier roles, the Dock,
        // menu-bar and Mission Control options, and the Force Touch stage hysteresis.
        let keys333 = [TitleBarWindowSnap.motionPauseKey, TitleBarWindowSnap.superAnywhereKey,
                       TitleBarWindowSnap.tabGesturesKey, TitleBarWindowSnap.nativeTilingKey, TitleBarWindowSnap.tooltipKey,
                       TitleBarWindowSnap.resnapDelayKey, TitleBarWindowSnap.hotkeyCenterKey, PressureStageTracker.hysteresisKey]
            + SwishSnap.ModifierRole.allCases.map(\.defaultsKey) + TrackpadUtilityGestures.settingsKeys333
        XCTAssertEqual(keys333.count, 18)
        for key in keys333 { XCTAssertTrue(PresetManager.isBackedUpSetting(key), key) }
        for key in TrackpadUtilityGestures.settingsKeys333 {
            XCTAssertEqual(PresetManager.settingArea(key), "Trackpad gestures", key)
        }
        for role in SwishSnap.ModifierRole.allCases {
            XCTAssertEqual(PresetManager.settingArea(role.defaultsKey), "Title-bar snap", role.defaultsKey)
        }
        XCTAssertEqual(PresetManager.settingArea(PressureStageTracker.hysteresisKey), "Gesture timing")
        XCTAssertFalse(PresetManager.isBackedUpSetting("AOMBackupPath"), "a machine-specific folder is not carried over")
        XCTAssertFalse(PresetManager.isBackedUpSetting(ClipboardMCPSettings.toolsKey), "AI tool access is never restored silently")
    }

    func testAForeignFileInABackupFolderIsNeverListedRestoredOrPruned() throws {
        let backups = try folder()
        let foreign = backups.appendingPathComponent("notes.json")
        // Valid enough to have been picked as "latest backup" by 3.3.0.
        try PresetCodec.encode(Preset(name: "Someone else's file")).write(to: foreign)
        let original = profile()
        for _ in 0..<(PresetManager.maxBackups + 3) {
            XCTAssertNotNil(PresetManager.saveBackup(data: try PresetCodec.encode(original), directory: backups, settings: try defaults()))
        }
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(3600)], ofItemAtPath: foreign.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "pruning left the user's file alone")
        let listed = PresetManager.listBackups(in: backups)
        XCTAssertEqual(listed.count, PresetManager.maxBackups, "rolling backups are capped")
        XCTAssertFalse(listed.contains { $0.url.lastPathComponent == "notes.json" })
        XCTAssertEqual(PresetManager.loadLatestBackup(in: backups)?.name, original.name, "the newer foreign file is not restored")
    }

    func testASafetySnapshotSurvivesLaterRollingBackups() throws {
        let backups = try folder()
        let manager = PresetManager(directory: try folder())
        let before = try XCTUnwrap(manager.snapshotBeforeReplacing(Preset(name: "Before import"), reason: "before-import", directory: backups))
        for _ in 0..<(PresetManager.maxBackups + 4) {
            PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: backups, settings: try defaults())
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.path))
        XCTAssertTrue(PresetManager.isSafetySnapshot(before))
    }

    func testImportKeepsTheCurrentPresetAndAFailedImportChangesNothing() throws {
        let state = AppState()
        defer { state.flushPendingWrites() }
        var reports: [(String, Bool)] = []
        state.presetOperationReporter = { title, _, style in reports.append((title, style == .failure)) }
        var current = Preset(name: "Current")
        current.addTrigger(Trigger(name: "Keep me", input: .namedTrigger("Keep me")))
        state.currentPreset = current

        let incoming = try folder().appendingPathComponent("incoming.json")
        try PresetCodec.encode(profile(), envelope: true).write(to: incoming)
        XCTAssertTrue(state.importPreset(from: incoming))
        XCTAssertEqual(state.currentPreset.name, "Work Profile")
        XCTAssertEqual(reports.last?.0, "Preset Imported")
        let snapshot = try XCTUnwrap(PresetManager.listBackups().first { $0.url.lastPathComponent.contains("-before-import") })
        XCTAssertEqual(try PresetCodec.decode(Data(contentsOf: snapshot.url)).name, "Current", "the replaced preset was kept")

        let newer = try folder().appendingPathComponent("newer.json")
        try Data(#"{"format":"aom.preset","schemaVersion":999,"preset":{"triggers":[]}}"#.utf8).write(to: newer)
        XCTAssertFalse(state.importPreset(from: newer))
        XCTAssertEqual(state.currentPreset.name, "Work Profile", "a rejected file changes nothing")
        XCTAssertEqual(reports.last?.0, "Could Not Import the Preset")
        XCTAssertEqual(reports.last?.1, true)
        XCTAssertTrue(PresetCodec.Failure.unsupportedVersion.localizedDescription.contains("newer version"))
    }

    /// The audit's acceptance case: new snap, capture and shortcut settings
    /// round-trip into an empty profile; this Mac's folders stay behind.
    func testCaptureAndShortcutSettingsRoundTripIntoAnEmptyProfile() throws {
        let backups = try folder()
        let old = try defaults()
        let captureShortcut = try XCTUnwrap(CaptureShortcutAction.allCases.first).userDefaultsKey
        let clipboardShortcut = "AOMClipboardShortcut_" + (try XCTUnwrap(ClipboardShortcuts.Command.allCases.first)).rawValue
        let values: [String: Any] = [
            TitleBarWindowSnap.keepPointerKey: true,
            TitleBarWindowSnap.hapticKey: false,
            "AOMCaptureFormat": "jpeg",
            "AOMCaptureShowsCursor": true,
            "AOMCaptureRecordingFPS": 60,
            "AOMCaptureOverlayCorner": "topLeft",
            "AOMCaptureRecordingKeystrokeOverlay": true,
            "AOMOCRKeepsLineBreaks": false,
            captureShortcut: Data([1, 2, 3]),
            clipboardShortcut: Data([4, 5, 6]),
            "AOMClipboardQuickModifier": "option"
        ]
        for (key, value) in values { old.set(value, forKey: key) }
        old.set("/Users/someone/Desktop", forKey: "AOMCaptureSaveDirectory")
        old.set("/Volumes/Old Mac Backups", forKey: "AOMBackupPath")
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: backups, settings: old))

        let empty = try defaults()
        let restored = try XCTUnwrap(PresetManager.restoreSettings(fromFile: PresetManager.settingsURL(forBackup: backup), into: empty))
        XCTAssertEqual(restored, values.count)
        for (key, value) in values {
            XCTAssertTrue((empty.object(forKey: key) as AnyObject?)?.isEqual(value) ?? false, "\(key) round-trips")
        }
        XCTAssertNil(empty.object(forKey: "AOMCaptureSaveDirectory"), "the old Mac's save folder is not carried over")
        XCTAssertNil(empty.object(forKey: "AOMBackupPath"))
        for key in CaptureSettings.machineSpecificKeys { XCTAssertFalse(PresetManager.isBackedUpSetting(key), key) }
    }

    func testEveryBackupSaysWhichVersionMadeItAndThatIsNeverRestored() throws {
        let backups = try folder()
        let live = try defaults()
        live.set(true, forKey: TitleBarWindowSnap.enabledKey)
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: backups, settings: live))
        let file = try XCTUnwrap(NSDictionary(contentsOf: PresetManager.settingsURL(forBackup: backup)) as? [String: Any])
        XCTAssertEqual(file[PresetManager.backupFormatKey] as? Int, PresetManager.settingsFormat)
        XCTAssertTrue((file[PresetManager.backupUnsetKeysKey] as? [String] ?? []).contains(TitleBarWindowSnap.marginKey),
                      "the file says which backed-up settings were still unset")
        XCTAssertNotNil(file[PresetManager.backupAppVersionKey] as? String)
        XCTAssertNotNil(file[PresetManager.backupCreatedKey] as? Date)
        let target = try defaults()
        XCTAssertEqual(PresetManager.restoreSettings(fromFile: PresetManager.settingsURL(forBackup: backup), into: target), 1)
        XCTAssertNil(target.object(forKey: PresetManager.backupAppVersionKey), "metadata is not a setting")
    }

    /// The audit's "복원 전 차이 미리보기": counts and changed areas before
    /// anything is replaced.
    func testTheRestorePreviewSaysWhatWouldChange() throws {
        let backups = try folder()
        let saved = try defaults()
        saved.set(12.0, forKey: TitleBarWindowSnap.marginKey)
        saved.set("jpeg", forKey: "AOMCaptureFormat")
        saved.set(true, forKey: TrackpadUtilityGestures.spacesEnabledKey)
        let backup = try XCTUnwrap(PresetManager.saveBackup(data: try PresetCodec.encode(profile()), directory: backups, settings: saved))

        let live = try defaults()
        live.set(30.0, forKey: TitleBarWindowSnap.marginKey)     // differs
        live.set("jpeg", forKey: "AOMCaptureFormat")             // same
        // spacesEnabledKey missing here: differs
        var current = Preset(name: "Current")
        for index in 0..<5 { current.addTrigger(Trigger(name: "T\(index)", input: .namedTrigger("T\(index)"))) }
        let preview = try XCTUnwrap(PresetManager.restorePreview(of: backup, current: current, defaults: live))
        XCTAssertEqual(preview.currentAutomations, 5)
        XCTAssertEqual(preview.backupAutomations, 2)
        XCTAssertEqual(preview.currentSnapLayouts, 0)
        XCTAssertEqual(preview.backupSnapLayouts, 1)
        XCTAssertTrue(preview.hasSettings)
        XCTAssertEqual(preview.changedSettings, 2)
        XCTAssertEqual(preview.changedAreas, ["Title-bar snap", "Trackpad gestures"])
        XCTAssertNotNil(preview.madeBy)
        XCTAssertTrue(preview.summary.contains("Automations: 5 now → 2 in the backup."), preview.summary)
        XCTAssertTrue(preview.summary.contains("changes 2 settings"), preview.summary)

        let unreadable = backups.appendingPathComponent("preset_backup_2026-01-01_00-00-00.json")
        try Data("not json".utf8).write(to: unreadable)
        XCTAssertNil(PresetManager.restorePreview(of: unreadable, current: current, defaults: live), "an unreadable backup is refused before the dialog")
    }

    func testAFailedExportIsReported() throws {
        let state = AppState()
        defer { state.flushPendingWrites() }
        var reports: [(String, Bool)] = []
        state.presetOperationReporter = { title, _, style in reports.append((title, style == .failure)) }
        let unwritable = URL(fileURLWithPath: "/System/aom-audit-\(UUID().uuidString).json")
        XCTAssertFalse(state.exportPreset(to: unwritable))
        XCTAssertEqual(reports.last?.0, "Could Not Export the Preset")
        XCTAssertEqual(reports.last?.1, true)
    }
}
