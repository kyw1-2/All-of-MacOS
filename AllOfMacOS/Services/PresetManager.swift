import Foundation

class PresetManager {
    private static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AllOfMacOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A throwaway directory used instead of the real one when running under a
    /// test host.
    ///
    /// Detected from the loaded XCTest host,
    /// because the decision has to hold for every path into this type —
    /// `loadPreset`, `save`, and the trackpad database all resolve their
    /// location here.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static var previewDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--aom-ui-preview"), args.indices.contains(index + 1) else { return nil }
        let directory = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return directory.path.hasPrefix(temporary) ? directory : nil
    }
    static var isUIPreview: Bool { previewDirectory != nil }
    /// `--aom-preview-size 1280x800` sizes the main window of an isolated UI
    /// preview, so screens are compared at fixed sizes without driving the
    /// window through Accessibility.
    static var previewWindowSize: CGSize? {
        let args = ProcessInfo.processInfo.arguments
        guard isUIPreview, let index = args.firstIndex(of: "--aom-preview-size"), args.indices.contains(index + 1) else { return nil }
        let parts = args[index + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 >= 400 && $0 <= 4000 }) else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
    private static let isolatedDirectory: URL? = {
        if let previewDirectory { return previewDirectory }
        guard isRunningTests else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOMTestPresets-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        return dir
    }()

    static var backupDirectory: URL {
        // A test host must not write into the user's real backup folder; a run
        // of the suite would otherwise bury the genuine backups in noise and
        // push them out through the rolling limit.
        if let isolated = isolatedDirectory {
            return isolated
        }
        if let custom = UserDefaults.standard.string(forKey: "AOMBackupPath"),
           !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".allofmacos_backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var backupsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "AOMBackupsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AOMBackupsEnabled") }
    }

    /// Maximum number of rolling backups to keep
    static var maxBackups: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "AOMMaxBackups")
            return stored > 0 ? stored : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: "AOMMaxBackups") }
    }

    /// Only files AOM wrote itself are backups. A custom backup folder may
    /// hold anything; until 3.3.1 every *.json in it was listed, offered as
    /// "latest backup" at launch and deleted past the retention limit
    /// (audit 2026-10-28 F07).
    static func isPresetBackup(_ url: URL) -> Bool {
        url.pathExtension == "json" && url.lastPathComponent.hasPrefix("preset_backup_")
    }

    /// Snapshots taken before a preset is replaced keep their own retention,
    /// so a run of later edits cannot prune the only copy of the old preset.
    static func isSafetySnapshot(_ url: URL) -> Bool {
        isPresetBackup(url) && url.deletingPathExtension().lastPathComponent.contains("-before-")
    }
    static let maxSafetySnapshots = 5

    /// Returns info about existing backups (date and file size), newest first.
    static func listBackups(in directory: URL = backupDirectory) -> [(date: Date, size: Int64, url: URL)] {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
                .filter(isPresetBackup)
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db
                }
            return files.compactMap { url in
                let vals = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let date = vals?.creationDate ?? .distantPast
                let size = Int64(vals?.fileSize ?? 0)
                return (date: date, size: size, url: url)
            }
        } catch {
            return []
        }
    }

    static var presetFilePath: String {
        (isolatedDirectory ?? defaultDirectory).appendingPathComponent("master_preset.json").path
    }

    private let persistenceQueue = DispatchQueue(label: "com.kyw.allofmacos.preset-io", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingSave: (preset: Preset, backup: Bool)?
    private var saveGeneration = 0

    private let presetsDirectory: URL
    private lazy var trackpadStore: TrackpadPresetStore? = {
        do { return try TrackpadPresetStore(url: presetsDirectory.appendingPathComponent("trackpad-v1.sqlite")) }
        catch { NSLog("[AOM] Trackpad database unavailable: %@", error.localizedDescription); return nil }
    }()
    private var masterPresetURL: URL {
        presetsDirectory.appendingPathComponent("master_preset.json")
    }

    init(directory: URL? = nil) {
        if let dir = directory {
            self.presetsDirectory = dir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } else if let isolated = Self.isolatedDirectory {
            // A test host must never reach the user's real preset. Creating an
            // AppState in a test used to load the live master_preset.json and
            // then write it back, which destroyed the real configuration.
            self.presetsDirectory = isolated
            try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        } else {
            self.presetsDirectory = Self.defaultDirectory
        }
    }


    // MARK: - Backup

    /// The settings a backup holds and a restore applies: the user's choices
    /// for how AOM behaves. Every other AOM setting is listed, with its
    /// reason, in `settingsNotBackedUp`; `BackupScopeTests` fails for a
    /// setting in neither list.
    private static let userDefaultsKeys: [String] = {
        var keys = [
            "AOMAccentColor",
            "AOMAppearance",
            "AOMPressDragThreshold",
            "AOMTipTapMinRestTime",
            "AOMSuppressMouseDuringDrawing",
            "launchAtLogin",
            "showMenuBarIcon",
            "AOMAudioEQEnabled", "AOMAudioEQPreset", "AOMAudioEQGains", "AOMAudioUserApps",
            "AOMAudioMasterBoostEnabled", "AOMAudioMasterBoostLevel",
            "AOMSoundEnabled", "AOMAudioEngineEnabled",
            "AOMWindowGesturesEnabled", "AOMWindowGestureEdgeSize", "AOMWindowGestureRequireModifier",
            // Added in 3.2–3.3 and missing from backups until 3.3.1 (audit
            // 2026-10-28 F07): trackpad gesture layers, suppression rules,
            // saved window layouts and HUD opacity.
            TitleBarWindowSnap.enabledKey, TitleBarWindowSnap.hapticKey, TitleBarWindowSnap.marginKey,
            TitleBarWindowSnap.activateKey, TitleBarWindowSnap.keepPointerKey,
            // 3.3.2 title-bar snap options and the shared hold-still cancel.
            TitleBarWindowSnap.thirdsKey, TitleBarWindowSnap.previewKey, TitleBarWindowSnap.holdCancelKey,
            // 3.3.2 Swish title-bar gestures: pinches, double tap, tap and
            // hold, a swipe down on a free window, and the modifier variants.
            TitleBarWindowSnap.pinchKey, TitleBarWindowSnap.doubleTapKey, TitleBarWindowSnap.holdKey,
            TitleBarWindowSnap.downActionKey, TitleBarWindowSnap.modifiersKey, TitleBarWindowSnap.sensitivityKey,
            // 3.3.2 Swish snapping options: the grid, almost maximize, the ⌃⌥
            // hotkeys, drag to unsnap, re-snapping, the preview animation,
            // the Stage Manager offset and resizing adjacent windows.
            TitleBarWindowSnap.gridKey, TitleBarWindowSnap.almostKey, TitleBarWindowSnap.hotkeysKey,
            TitleBarWindowSnap.dragUnsnapKey, TitleBarWindowSnap.resnapKey, TitleBarWindowSnap.animationKey,
            TitleBarWindowSnap.stageManagerOffsetKey, TitleBarWindowSnap.resizeAdjacentKey,
            // 3.3.3 title-bar snap: the multi-motion pause, Super anywhere, tab
            // gestures, native tiling, the tooltip, the external display
            // timeout and the ⌃⌥ center key. The five modifier roles follow below.
            TitleBarWindowSnap.motionPauseKey, TitleBarWindowSnap.superAnywhereKey, TitleBarWindowSnap.tabGesturesKey,
            TitleBarWindowSnap.nativeTilingKey, TitleBarWindowSnap.tooltipKey, TitleBarWindowSnap.resnapDelayKey,
            TitleBarWindowSnap.hotkeyCenterKey,
            TrackpadUtilityGestures.spacesEnabledKey, TrackpadUtilityGestures.dockQuitEnabledKey,
            // 3.3.2 Swish Dock and menu-bar gestures.
            TrackpadUtilityGestures.dockGesturesKey, TrackpadUtilityGestures.menuBarGesturesKey,
            TriggerSuppression.settingsKey, "AOMWindowLayoutsV1", "AOMHUDBackgroundOpacity",
            // Settings › Gestures timing, force press, the HUD and the wheel.
            "AOMGlobalSwipeMinVelocity", "AOMKeyboardLongPressMs", "AOMKeyboardQuickReleaseMaxMs",
            "AOMMouseLongPressMs", "AOMMouseQuickReleaseMaxMs", "AOMMouseMultiClickIntervalMs",
            "AOMMouseDragThresholdPx", "AOMForcePressEnabled", "AOMForcePressThreshold",
            // 3.3.3: how far Force Touch pressure eases off before a stage can fire again.
            PressureStageTracker.hysteresisKey,
            "AOMHUDEnabled", "AOMReverseMouseWheel",
            // Key remapping and the Hyper key (the remaps AOM owns at runtime are not settings).
            "AOMKeyRemaps", "AOMHyperKeyEnabled", "AOMHyperKeySource", "AOMHyperKeyTapEscape",
            "AOMMissionControlButtons", "AOMMissionControlHotkeys",
            "AOMWindowPinningOptionsV1", "AOMFloatingMenusV1", "AOMWorkflowVariables", "AOMActionFavorites.v1",
            // Audio output choices.
            "AOMAudioAirPlayProcessingEnabled", "AOMAudioFavorites",
            "aom.audio.protectMediaPlayback", "aom.audio.restoreOutputOnExit",
            // 3.3.3 audio: the output's Magic Boost preset (each app's is the
            // AOMAudioMagicBoostPreset_ family below), the user's EQ curves and
            // which output uses which, and the output's Audio Unit effect and its state.
            AudioBoostPreset.masterKey, AudioDeviceEQ.presetsKey, AudioDeviceEQ.assignmentsKey,
            AudioUnitEffectHost.choiceKey, AudioUnitEffectHost.stateKey,
            // Clipboard preferences (never the history itself).
            "AOMClipboardSettings.v1", "AOMClipboardQuickModifier", "AOMClipboardPlainModifier",
            "AOMClipboardPanelHeight", "AOMClipboardShowInScreenCapture", "AOMClipboardNetworkPreviews",
            "AOMClipboardLinkCards",  // 3.3.3: link cards, under the web-previews switch above
            "AOMClipboardCompact", "AOMClipboardGridLayout", "AOMPasteStackReversed",
            // Text capture.
            TextCaptureSettings.Key.automaticLanguages, TextCaptureSettings.Key.languages,
            TextCaptureSettings.Key.additiveClipboard, TextCaptureSettings.Key.joinsHyphenatedWords,
            TextCaptureSettings.Key.detectsLinks, TextCaptureSettings.Key.readsBarcodes,
            TextCaptureSettings.Key.playsSound, TextCaptureSettings.Key.showsResultHUD,
            TextCaptureSettings.Key.hudDuration, TextCaptureSettings.Key.speaksResult,
            TextCaptureSettings.Key.usesLanguageCorrection, TextCaptureSettings.Key.customWords,
            TextCaptureSettings.Key.engine, TextCaptureSettings.Key.fastRecognition,
            // Capture extras kept next to their views.
            "AOMPrintOverlap", "AOMPrintPageNumbers", "AOMHistoryDeleteWithoutConfirmation"
        ]
        // Capture and recording preferences (audit 2026-10-28 F07).
        keys += CaptureSettings.backedUpKeys
        // 3.3.3 Dock, menu-bar and Mission Control options, and the title-bar
        // snap's five modifier roles (keys built as "AOMTitleBarSnapModifier" + role).
        keys += TrackpadUtilityGestures.settingsKeys333
        keys += SwishSnap.ModifierRole.allCases.map(\.defaultsKey)
        // Add per-gesture swipe velocity keys
        for gesture in TrackpadGesture.allCases {
            keys.append("AOMSwipeMinVelocity_\(gesture.rawValue)")
        }
        // Global shortcut assignments and their enabled flags, so a restored
        // backup recovers the working environment the audit found missing.
        for action in CaptureShortcutAction.allCases {
            keys.append(action.userDefaultsKey)
            keys.append(action.userDefaultsKey + ".disabled")
        }
        for action in TextCaptureShortcutAction.allCases {
            keys.append(action.userDefaultsKey)
            keys.append(action.userDefaultsKey + ".disabled")
        }
        for command in ClipboardShortcuts.Command.allCases {
            let key = "AOMClipboardShortcut_" + command.rawValue
            keys.append(key)
            keys.append(key + "Disabled")
        }
        return keys
    }()

    /// AOM settings deliberately left out of backups, and why (audit
    /// 2026-10-28 F07 and its review). A restore never applies them, even
    /// from a file that holds them.
    static let settingsNotBackedUp: [String: String] = {
        var reasons: [String: String] = [
            AutomationGate.masterSwitchKey: "the live pause switch: a restore never pauses or resumes AOM",
            "AOMBackupPath": "this Mac's backup folder",
            "AOMBackupsEnabled": "the backup store's own option",
            "AOMMaxBackups": "the backup store's own option (a lower limit would prune backups)",
            backupFormatKey: "backup metadata", backupAppVersionKey: "backup metadata", backupCreatedKey: "backup metadata",
            backupUnsetKeysKey: "backup metadata", backupFamiliesKey: "backup metadata",
            "AOMMCPEnabled": "AI tool access is granted on purpose, never by a restore",
            "AOMMCPTools": "AI tool access is granted on purpose, never by a restore",
            "AOMIntelligentClipboardEnabled": "reads clipboard content: turned on on purpose, never by a restore",
            "AOMIntelligentClipboardReadsScreen": "reads the screen: turned on on purpose, never by a restore",
            "AOMAudioDiagnostics": "diagnostics opt-in",
            AudioDiagnostics.resetRequestKey: "a one-off request to reset the diagnostics counters, not a setting",
            "AOMKeyRemapOwnedPairs": "runtime state of the remapper",
            "AOMParkedWindowRecoveryV1": "runtime recovery journal",
            "AOMQuickAccessRecentlyClosedIDs": "runtime state",
            "AOMSessionStart": "runtime state",
            "aom.audio.appliedOutputUID": "this Mac's audio devices", "aom.audio.lastLocalOutputUID": "this Mac's audio devices",
            "aom.audio.outputChangedAt": "runtime state", "aom.audio.previousOutputUID": "this Mac's audio devices",
            "AOMAudioSoundSourceModelMigrated": "one-time migration flag",
            "AOMLastSeenVersion": "one-time hint", "AOMSpaceShortcutHintShown": "one-time hint", "AOMHasSeenTutorial": "one-time hint",
            "AOMGestureEvents": "usage statistics", "AOMGestureStatistics_fired": "usage statistics",
            "AOMGestureStatistics_total": "usage statistics", "AOMGestureStatistics.v2": "usage statistics",
            "AOMActionRecents.v1": "usage history", "AOMAnnotationRecentColors": "usage history",
            "AOMAllInOneLastRatio": "window layout", "AOMAutomationListWidth": "window layout",
            "AOMAutomationTableWidth": "window layout", "AOMAutomationViewMode": "window layout",
            "AOMAudioWorkspaceSection": "window layout", "AOMSidebarVisible": "window layout",
            "AOMInsightsPeriod": "window layout", "AOMGroupTriggersByFolder": "window layout",
            "AOMShowLog": "window layout", "AOMShowTouchVisualizer": "window layout",
            "AOMAudioShowAllApps": "window layout", "AOMAnnotationBackgroundPanelOpen": "window layout",
            "AOMAnnotationBackgroundPrevious": "window layout"
        ]
        for key in CaptureSettings.machineSpecificKeys {
            reasons[key] = "describes this Mac (folders, last area, camera and microphone devices)"
        }
        return reasons
    }()

    /// Families of settings keyed by app or device that are not backed up.
    static let settingPrefixesNotBackedUp: [String: String] = [
        "AOMShortcutConflictDismissed_": "dismissed hints",
        "AOMPermissionOpen_": "window layout"
    ]

    /// Writes one backup file and prunes old ones. `reason` marks a safety
    /// snapshot ("before-import", "before-restore") with its own retention.
    /// `protecting` is never pruned by this save (the backup being restored).
    @discardableResult
    static func saveBackup(data: Data, reason: String? = nil, directory: URL = backupDirectory,
                           settings defaults: UserDefaults = .standard, protecting: URL? = nil) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let suffix = reason.map { "-\($0)" } ?? ""
        var backupURL = directory.appendingPathComponent("preset_backup_\(timestamp)\(suffix).json")
        // Two saves in one second used to overwrite each other.
        if FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = directory.appendingPathComponent("preset_backup_\(timestamp)\(suffix)-\(UUID().uuidString.prefix(4)).json")
        }
        var saved: URL?
        do {
            try data.write(to: backupURL, options: .atomic)
            NSLog("[AOM] Backup saved to %@", backupURL.path)
            saved = backupURL
            // Each backup keeps the settings of its own moment, so restoring
            // an older backup restores older settings too. (The single
            // settings_backup.plist below is rewritten by every save.)
            saveUserDefaultsBackup(from: defaults, toFile: settingsURL(forBackup: backupURL))
            pruneOldBackups(in: directory, protecting: protecting)
        } catch {
            NSLog("[AOM] Failed to save backup: %@", error.localizedDescription)
        }
        // The latest settings, kept for older tools that read this file.
        saveUserDefaultsBackup(from: defaults, to: directory)
        return saved
    }

    /// The settings saved with one preset backup:
    /// `preset_backup_….json` → `preset_backup_….settings.plist`.
    static func settingsURL(forBackup url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("settings.plist")
    }

    /// Internal for the backup-scope test (@testable).
    static var backedUpSettingKeys: [String] { userDefaultsKeys }

    static let settingsBackupFileName = "settings_backup.plist"
    /// Settings keyed by app or device. A settings file holds each family
    /// completely, so a restore also removes the members it does not list.
    static let backedUpSettingPrefixes = ["AOMAudioGain_", "AOMAudioMute_", "AOMAudioRoute_", "AOMAudioMagicBoost_",
                                          "AOMAudioBoostLevel_", "AOMAudioOverdrive_", "AOMAudioBalance_",
                                          "AOMAudioAppEQEnabled_", "AOMAudioAppEQGains_", "AOMAudioAppEQPreset_",
                                          "AOMAudioDeviceGain_", "AOMAudioOutputUnmute_", "AOMAudioInputUnmute_",
                                          // 3.3.3: each app's Magic Boost preset.
                                          "AOMAudioMagicBoostPreset_"]
    private static let backedUpKeySet = Set(userDefaultsKeys)

    /// Whether `key` belongs in a settings backup and may be restored from one.
    static func isBackedUpSetting(_ key: String) -> Bool {
        guard settingsNotBackedUp[key] == nil else { return false }
        return backedUpKeySet.contains(key) || backedUpSettingPrefixes.contains { key.hasPrefix($0) }
    }

    /// Writes the backed-up settings to the latest-settings file in `directory`.
    @discardableResult
    static func saveUserDefaultsBackup(from defaults: UserDefaults = .standard, to directory: URL = backupDirectory) -> Bool {
        saveUserDefaultsBackup(from: defaults, toFile: directory.appendingPathComponent(settingsBackupFileName))
    }

    /// Written into every settings file so a restore can say which version
    /// made it. Not settings: `restoreSettings` never applies them.
    static let backupFormatKey = "AOMBackupFormat"
    static let backupAppVersionKey = "AOMBackupAppVersion"
    static let backupCreatedKey = "AOMBackupCreated"
    /// Format 2: the backed-up settings that had no value at that moment, and
    /// the families held completely, so a restore is faithful: a setting
    /// changed from its default after the backup goes back to the default.
    static let backupUnsetKeysKey = "AOMBackupUnsetKeys"
    static let backupFamiliesKey = "AOMBackupFamilies"
    static let settingsFormat = 2

    /// Writes the backed-up settings to `file`, including which of them were
    /// unset, so even an empty profile can be restored. Returns false when
    /// the file could not be written.
    @discardableResult
    static func saveUserDefaultsBackup(from defaults: UserDefaults = .standard, toFile url: URL) -> Bool {
        var dict: [String: Any] = [:]
        var unset: [String] = []
        for key in userDefaultsKeys where isBackedUpSetting(key) {
            if let value = defaults.object(forKey: key) { dict[key] = value } else { unset.append(key) }
        }
        for key in defaults.dictionaryRepresentation().keys
        where backedUpSettingPrefixes.contains(where: { key.hasPrefix($0) }) && isBackedUpSetting(key) {
            if let value = defaults.object(forKey: key) { dict[key] = value }
        }
        let info = Bundle.main.infoDictionary
        dict[backupFormatKey] = settingsFormat
        dict[backupAppVersionKey] = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        dict[backupCreatedKey] = Date()
        dict[backupUnsetKeysKey] = unset.sorted()
        dict[backupFamiliesKey] = backedUpSettingPrefixes
        let written = (dict as NSDictionary).write(to: url, atomically: true)
        if !written { NSLog("[AOM] Settings backup could not be written to %@", url.path) }
        return written
    }

    /// One settings file, read into memory: a restore applies this, so it
    /// never depends on the file surviving the restore's own backup step.
    struct SettingsSnapshot {
        /// Backed-up settings in the file and their values.
        var values: [String: Any]
        /// Backed-up settings that had no value when the file was written.
        var unsetKeys: [String]
        /// Families the file holds completely.
        var families: [String]
        var format: Int
        var madeBy: String?

        /// The settings applying this to `defaults` would set or remove.
        func changes(against defaults: UserDefaults) -> [String] {
            var keys = values.compactMap { key, value in
                ((defaults.object(forKey: key) as AnyObject?)?.isEqual(value) ?? false) ? nil : key
            }
            keys += unsetKeys.filter { defaults.object(forKey: $0) != nil }
            keys += familyMembersMissing(from: defaults)
            return keys.sorted()
        }

        /// Members of a complete family set in `defaults` but not in the file.
        private func familyMembersMissing(from defaults: UserDefaults) -> [String] {
            defaults.dictionaryRepresentation().keys.filter { key in
                values[key] == nil && families.contains { key.hasPrefix($0) } && PresetManager.isBackedUpSetting(key)
                    && defaults.object(forKey: key) != nil
            }
        }

        /// Applies the file: sets its values, removes what was unset then.
        /// Returns the number of settings set and removed.
        @discardableResult
        func apply(to defaults: UserDefaults) -> (set: Int, removed: Int) {
            let missing = familyMembersMissing(from: defaults)
            for (key, value) in values { defaults.set(value, forKey: key) }
            var removed = 0
            for key in unsetKeys + missing where defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                removed += 1
            }
            return (values.count, removed)
        }
    }

    /// Reads a settings file; nil when it is missing or unreadable. Only
    /// settings AOM backs up are kept; anything else in the file (a token, a
    /// path from another machine, the pause switch) is ignored.
    static func readSettings(fromFile url: URL) -> SettingsSnapshot? {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        let format = dict[backupFormatKey] as? Int ?? 0
        let values = dict.filter { isBackedUpSetting($0.key) }
        // Format 1 and the 3.3.0 file do not say what was unset.
        let unset = format >= 2 ? (dict[backupUnsetKeysKey] as? [String] ?? []).filter(isBackedUpSetting) : []
        let families = format >= 2 ? (dict[backupFamiliesKey] as? [String] ?? []).filter(backedUpSettingPrefixes.contains) : []
        return SettingsSnapshot(values: values, unsetKeys: unset, families: families, format: format,
                                madeBy: dict[backupAppVersionKey] as? String)
    }

    /// Applies the latest-settings file in `directory` (see `restoreSettings`).
    @discardableResult
    static func restoreUserDefaultsFromBackup(into defaults: UserDefaults = .standard, from directory: URL = backupDirectory) -> Int? {
        restoreSettings(fromFile: directory.appendingPathComponent(settingsBackupFileName), into: defaults)
    }

    /// Applies a settings backup, e.g. on a new Mac or user account (see
    /// `readSettings` for what is applied). Returns how many settings were
    /// set, or nil when the file is missing or unreadable. Until 3.3.1 the
    /// restore wrote every key in the file and nothing in the app called it.
    @discardableResult
    static func restoreSettings(fromFile url: URL, into defaults: UserDefaults = .standard) -> Int? {
        guard let snapshot = readSettings(fromFile: url) else { return nil }
        let result = snapshot.apply(to: defaults)
        NSLog("[AOM] Restored %d settings, removed %d, from %@", result.set, result.removed, url.lastPathComponent)
        return result.set
    }

    /// What restoring one backup would change, shown before anything is
    /// replaced (audit 2026-10-28 F07: preview the difference first).
    struct RestorePreview: Equatable {
        var currentAutomations = 0, backupAutomations = 0
        var currentAppSets = 0, backupAppSets = 0
        var currentSnapLayouts = 0, backupSnapLayouts = 0
        /// The backup carries a readable settings file of its own.
        var hasSettings = false
        /// Backed-up settings a settings restore would set or remove.
        var changedSettings = 0
        /// Readable areas of those settings ("Title-bar snap", "Capture").
        var changedAreas: [String] = []
        /// "3.3.1 (2026102802)" for backups written by 3.3.1 or later.
        var madeBy: String?
        /// The file does not say which settings were unset (written before
        /// format 2): settings it does not hold keep their current values.
        var partialSettings = false

        var summary: String {
            var lines = ["Automations: \(currentAutomations) now → \(backupAutomations) in the backup.",
                         "App-specific sets: \(currentAppSets) → \(backupAppSets). Snap layout profiles: \(currentSnapLayouts) → \(backupSnapLayouts)."]
            if hasSettings {
                lines.append(changedSettings == 0
                    ? "Its settings match yours."
                    : "Restoring its settings changes \(changedSettings) setting\(changedSettings == 1 ? "" : "s"): \(changedAreas.joined(separator: ", ")).")
                if partialSettings { lines.append("Settings it does not hold keep their current values.") }
            } else {
                lines.append("It has no settings of its own (made before 3.3.1).")
            }
            if let madeBy { lines.append("Made by All of MacOS \(madeBy).") }
            return lines.joined(separator: "\n")
        }
    }

    static func restorePreview(of backup: URL, current: Preset, defaults: UserDefaults = .standard) -> RestorePreview? {
        guard let data = try? Data(contentsOf: backup), let saved = try? PresetCodec.decode(data) else { return nil }
        var preview = RestorePreview()
        preview.currentAutomations = current.triggers.count
        preview.backupAutomations = saved.triggers.count
        preview.currentAppSets = current.appTargets.filter { !$0.isGlobal }.count
        preview.backupAppSets = saved.appTargets.filter { !$0.isGlobal }.count
        preview.currentSnapLayouts = current.snapProfiles.count
        preview.backupSnapLayouts = saved.snapProfiles.count
        if let settings = readSettings(fromFile: settingsURL(forBackup: backup)) {
            preview.hasSettings = true
            preview.madeBy = settings.madeBy
            preview.partialSettings = settings.format < settingsFormat
            let changes = settings.changes(against: defaults)
            preview.changedSettings = changes.count
            preview.changedAreas = Array(Set(changes.map(settingArea))).sorted()
        }
        return preview
    }

    /// A readable name for the part of AOM a backed-up setting belongs to.
    static func settingArea(_ key: String) -> String {
        if key.hasPrefix("AOMTitleBarSnap") { return "Title-bar snap" }
        if key == TrackpadUtilityGestures.spacesEnabledKey || key == TrackpadUtilityGestures.dockQuitEnabledKey
            || key == TrackpadUtilityGestures.dockGesturesKey || key == TrackpadUtilityGestures.menuBarGesturesKey
            || TrackpadUtilityGestures.settingsKeys333.contains(key)
            || key.hasPrefix("AOMSwipeMinVelocity_") || key.hasPrefix("AOMTipTap") || key == "AOMPressDragThreshold"
            || key == "AOMSuppressMouseDuringDrawing" { return "Trackpad gestures" }
        if ["AOMGlobalSwipeMinVelocity", "AOMKeyboardLongPressMs", "AOMKeyboardQuickReleaseMaxMs", "AOMMouseLongPressMs",
            "AOMMouseQuickReleaseMaxMs", "AOMMouseMultiClickIntervalMs", "AOMMouseDragThresholdPx", "AOMForcePressEnabled",
            "AOMForcePressThreshold", PressureStageTracker.hysteresisKey, "AOMReverseMouseWheel"].contains(key) {
            return "Gesture timing"
        }
        if key.hasPrefix("AOMKeyRemap") || key.hasPrefix("AOMHyperKey") { return "Key remapping" }
        if key.hasPrefix("AOMWindowGesture") || key == "AOMWindowLayoutsV1" || key == "AOMWindowPinningOptionsV1"
            || key.hasPrefix("AOMMissionControl") { return "Window layouts" }
        if key == TriggerSuppression.settingsKey { return "Automation pausing" }
        if key.hasPrefix("AOMClipboardShortcut_") || CaptureShortcutAction.allCases.contains(where: { key.hasPrefix($0.userDefaultsKey) })
            || TextCaptureShortcutAction.allCases.contains(where: { key.hasPrefix($0.userDefaultsKey) }) {
            return "Shortcuts"
        }
        if key.hasPrefix("AOMClipboard") || key == "AOMPasteStackReversed" { return "Clipboard" }
        if key.hasPrefix("AOMTextCapture") || key.hasPrefix("AOMOCR") { return "Text capture" }
        if key.hasPrefix("AOMCapture") || key.hasPrefix("AOMAnnotation") || key.hasPrefix("AOMPinned") || key.hasPrefix("AOMPrint")
            || key == "AOMHistoryDeleteWithoutConfirmation" {
            return "Capture"
        }
        if key.hasPrefix("AOMAudio") || key.hasPrefix("aom.audio.") || key == "AOMSoundEnabled" { return "Audio" }
        if key == "AOMAppearance" || key == "AOMAccentColor" || key == "AOMHUDBackgroundOpacity" || key == "AOMHUDEnabled"
            || key == "showMenuBarIcon" {
            return "Appearance"
        }
        if key == "AOMFloatingMenusV1" || key == "AOMWorkflowVariables" || key == "AOMActionFavorites.v1" { return "Menus and variables" }
        return "General"
    }

    private static func pruneOldBackups(in directory: URL = backupDirectory, protecting: URL? = nil) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter(isPresetBackup)
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db // newest first
                }
            let rolling = files.filter { !isSafetySnapshot($0) }
            let snapshots = files.filter(isSafetySnapshot)
            // Compared as resolved paths: /var and /private/var are one folder.
            let kept = protecting?.resolvingSymlinksInPath().path
            for file in rolling.dropFirst(maxBackups) + snapshots.dropFirst(maxSafetySnapshots)
            where file.resolvingSymlinksInPath().path != kept {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: settingsURL(forBackup: file))
                NSLog("[AOM] Pruned old backup: %@", file.lastPathComponent)
            }
        } catch {
            NSLog("[AOM] Failed to prune backups: %@", error.localizedDescription)
        }
    }

    /// Returns the most recent backup, if any.
    static func loadLatestBackup(in directory: URL = backupDirectory) -> Preset? {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
                .filter(isPresetBackup)
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db
                }
            guard let latest = files.first else { return nil }
            NSLog("[AOM] Restoring from backup: %@", latest.path)
            let data = try Data(contentsOf: latest)
            return try PresetCodec.decode(data)
        } catch {
            NSLog("[AOM] Failed to load backup: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Load

    static func loadPreset() -> Preset? {
        let manager = PresetManager()
        defer { manager.flushPendingWrites() }
        return manager.loadPreset()
    }

    func loadPreset() -> Preset? {
        flushPendingWrites()
        return persistenceQueue.sync { readPreset() }
    }

    private func readPreset() -> Preset? {
        if let data = try? Data(contentsOf: masterPresetURL), let preset = try? PresetCodec.decode(data) {
            trackpadStore?.saveAsync(preset)
            return preset
        }
        // Recover the last fully committed graph before looking at rolling JSON backups.
        if let restored = try? trackpadStore?.load() {
            if FileManager.default.fileExists(atPath: masterPresetURL.path) {
                let preserved = presetsDirectory.appendingPathComponent("unreadable-preset-\(UUID().uuidString).json")
                do { try FileManager.default.copyItem(at: masterPresetURL, to: preserved) }
                catch { return restored } // Never overwrite input that could not be preserved.
            }
            if let data = try? PresetCodec.encode(restored) { try? data.write(to: masterPresetURL, options: .atomic) }
            return restored
        }
        return Self.loadLatestBackup()
    }

    func flushPendingWrites() {
        pendingLock.lock()
        let pending = pendingSave
        pendingSave = nil
        saveGeneration += 1
        pendingLock.unlock()
        persistenceQueue.sync {
            if let pending { persist(pending.preset, createBackup: pending.backup) }
            trackpadStore?.flushPendingWrites()
        }
    }

    /// Text editors and sliders update runtime bindings immediately, but disk
    /// encoding, SQLite and rolling backups are coalesced on a serial worker.
    func scheduleSave(_ preset: Preset) {
        let backup = Self.backupsEnabled
        pendingLock.lock()
        saveGeneration += 1
        let generation = saveGeneration
        pendingSave = (preset, backup)
        pendingLock.unlock()
        persistenceQueue.asyncAfter(deadline: .now() + 0.25) { [self] in
            pendingLock.lock()
            let pending = generation == saveGeneration ? pendingSave : nil
            if pending != nil { pendingSave = nil }
            pendingLock.unlock()
            if let pending { persist(pending.preset, createBackup: pending.backup) }
        }
    }

    // MARK: - Save

    func save(_ preset: Preset, createBackup: Bool = true) {
        flushPendingWrites()
        persistenceQueue.sync { persist(preset, createBackup: createBackup) }
    }

    /// The last save failure, cleared by the next successful save; read by
    /// callers that must not report "saved" for a write that failed.
    private let persistErrorLock = NSLock()
    private var persistError: String?
    var lastPersistError: String? {
        persistErrorLock.lock(); defer { persistErrorLock.unlock() }
        return persistError
    }

    private func persist(_ preset: Preset, createBackup: Bool) {
        do {
            let data = try PresetCodec.encode(preset)
            _ = try PresetCodec.decode(data)
            try data.write(to: masterPresetURL, options: .atomic)
            trackpadStore?.saveAsync(preset)
            if createBackup {
                Self.saveBackup(data: data)
            }
            persistErrorLock.lock(); persistError = nil; persistErrorLock.unlock()
        } catch {
            NSLog("[AOM] Failed to save preset: %@", error.localizedDescription)
            persistErrorLock.lock(); persistError = error.localizedDescription; persistErrorLock.unlock()
        }
    }

    func save(_ preset: Preset) {
        save(preset, createBackup: Self.backupsEnabled)
    }

    /// Throws instead of printing: a failed export used to look exactly like
    /// a successful one (found with audit 2026-10-28 F07).
    func exportPreset(_ preset: Preset, to url: URL) throws {
        let data = try PresetCodec.encode(preset, envelope: true)
        _ = try PresetCodec.decode(data)
        try data.write(to: url, options: .atomic)
    }

    func importPreset(from url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        return try PresetCodec.decode(data)
    }

    /// Keeps the preset that is about to be replaced (import or restore), and
    /// the settings of this moment, as a safety snapshot in the backup folder,
    /// whether or not rolling backups are on. `protecting` (the backup being
    /// restored) is never pruned to make room. Returns the snapshot, or nil
    /// if it could not be written.
    @discardableResult
    func snapshotBeforeReplacing(_ preset: Preset, reason: String, directory: URL = PresetManager.backupDirectory,
                                 settings defaults: UserDefaults = .standard, protecting: URL? = nil) -> URL? {
        guard let data = try? PresetCodec.encode(preset) else { return nil }
        return Self.saveBackup(data: data, reason: reason, directory: directory, settings: defaults, protecting: protecting)
    }
}

extension PresetCodec.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "The file is not an All of MacOS preset, or it is damaged."
        case .unsupportedVersion: return "This preset was made by a newer version of All of MacOS. Update the app, then import it again."
        case .duplicateID: return "The preset contains duplicate items and was not imported."
        case .incompleteDecode: return "Some automations in the preset could not be read, so nothing was imported."
        }
    }
}
