import Foundation

/// What Settings › Data › Reset Preferences clears and what it keeps (3.3.3
/// re-audit N333-07, B05). Until 3.3.3 the reset removed nine fixed keys, so
/// the title-bar snap, the Dock and menu-bar gestures and most capture,
/// recording, clipboard and audio choices survived it.
///
/// The rule is the key's prefix: every key that starts with "AOM" or "aom."
/// (and the two older settings without one) is a preference and goes back to
/// its default, unless it is kept below with its reason. A setting added later
/// is therefore reset without being listed here; only something a reset must
/// keep has to be added. Kept: what the user made, the limits that decide how
/// much clipboard and capture history stays (a default could delete items),
/// access and exclusions decided on purpose, whether AOM is paused, runtime
/// and recovery state, usage history, one-time markers and the backup store's
/// own options. Automations, presets, the clipboard history and pinboards,
/// captures and recordings live in files, which a reset never touches.
///
/// Separate from the backup list (`PresetManager`): a backup carries the
/// user's choices to another Mac, a reset brings this one back to its
/// defaults. `N333PreferenceResetTests` checks the two agree on every setting,
/// or that the difference is listed here with its reason.
enum PreferenceResetRegistry {
    /// Preferences older than the "AOM" prefix. The login item itself is a
    /// macOS setting (`SMAppService`) and stays as it is.
    static let unprefixedPreferenceKeys: Set<String> = ["showMenuBarIcon", "launchAtLogin"]

    /// AOM keys a reset keeps, and why.
    static let preservedKeys: [String: String] = {
        let consent = "decided on purpose, never by a reset"
        let made = "made by the user"
        let history = "usage history"
        let runtime = "runtime state, not a preference"
        let once = "shown or run once"
        let backupStore = "the backup store's own option"
        let pairs: [(String, String)] = [
            (AutomationGate.masterSwitchKey, "whether AOM is paused: a reset never pauses or resumes AOM"),
            ("AOMMCPEnabled", "\(consent) (AI tool access)"),
            ("AOMMCPTools", "\(consent) (AI tool access)"),
            ("AOMIntelligentClipboardEnabled", "\(consent) (reads clipboard content)"),
            ("AOMIntelligentClipboardReadsScreen", "\(consent) (reads the screen)"),
            ("AOMAudioDiagnostics", "\(consent) (diagnostics opt-in)"),
            // How much history stays: a default would delete older items or
            // record apps the user excluded.
            ("AOMClipboardSettings.v1", "clipboard history limits and the apps it never records"),
            ("AOMCaptureHistoryCapacity", "how many captures the history keeps"),
            ("AOMCaptureHistoryRetentionDays", "how long the capture history keeps captures"),
            ("AOMWindowLayoutsV1", "\(made) (saved window layouts)"),
            ("AOMFloatingMenusV1", "\(made) (floating menus)"),
            ("AOMWorkflowVariables", "\(made) (automation variables)"),
            ("AOMActionFavorites.v1", "\(made) (favorite actions)"),
            ("AOMKeyRemaps", "\(made) (key remapping rules)"),
            ("AOMAudioFavorites", "\(made) (favorites in the audio mixer)"),
            ("AOMAudioUserApps", "\(made) (apps added to the audio mixer)"),
            (AudioDeviceEQ.presetsKey, "\(made) (EQ curves saved or imported)"),
            ("AOMAnnotationStylePresets", "\(made) (annotation styles)"),
            ("AOMAnnotationBackgroundPresets", "\(made) (annotation backgrounds)"),
            ("AOMAnnotationMyColors", "\(made) (annotation colors)"),
            (TextCaptureSettings.Key.customWords, "\(made) (words taught to text recognition)"),
            ("AOMGestureEvents", history), ("AOMGestureStatistics_fired", history),
            ("AOMGestureStatistics_total", history), ("AOMGestureStatistics.v2", history),
            ("AOMActionRecents.v1", history), ("AOMAnnotationRecentColors", history), ("AOMSessionStart", history),
            ("AOMKeyRemapOwnedPairs", "the key remaps AOM applied, so it can take them back"),
            ("AOMParkedWindowRecoveryV1", "windows to bring back after a crash"),
            ("AOMQuickAccessRecentlyClosedIDs", runtime),
            ("aom.audio.appliedOutputUID", "the audio outputs AOM restores"),
            ("aom.audio.lastLocalOutputUID", "the audio outputs AOM restores"),
            ("aom.audio.previousOutputUID", "the audio outputs AOM restores"),
            ("aom.audio.outputChangedAt", runtime),
            // `CaptureSettings.Key` is private to its file; N333PreferenceResetTests
            // holds these spellings to `CaptureSettings.machineSpecificKeys`.
            ("AOMCaptureLastArea", "\(runtime) (the last capture area)"),
            ("AOMCaptureLastAreaDisplayID", "\(runtime) (the last capture area)"),
            (AudioDiagnostics.resetRequestKey, "a one-off request, not a preference"),
            ("AOMAudioSoundSourceModelMigrated", "\(once) (removing it would run a migration again)"),
            ("AOMLastSeenVersion", once), ("AOMSpaceShortcutHintShown", once),
            ("AOMHasSeenTutorial", "\(once) (Settings › Data › Onboarding Tour shows it again)"),
            ("AOMBackupPath", backupStore), ("AOMBackupsEnabled", backupStore), ("AOMMaxBackups", backupStore),
            (PresetManager.backupFormatKey, "backup metadata"), (PresetManager.backupAppVersionKey, "backup metadata"),
            (PresetManager.backupCreatedKey, "backup metadata"), (PresetManager.backupUnsetKeysKey, "backup metadata"),
            (PresetManager.backupFamiliesKey, "backup metadata")
        ]
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }()

    /// Families of AOM keys (one per app, device or hint) a reset keeps, and why.
    static let preservedPrefixes: [String: String] = [
        "AOMShortcutConflictDismissed_": "dismissed hints",
        "AOMAudioOutputUnmute_": "the volume AOM brings back when it unmutes an output without a mute switch",
        "AOMAudioInputUnmute_": "the volume AOM brings back when it unmutes a microphone without a mute switch"
    ]

    /// Left out of backups (`PresetManager.settingsNotBackedUp`) yet reset,
    /// and why: preferences that only make sense on this Mac or in one view.
    static let resetThoughNotBackedUp: [String: String] = {
        let layout = "how a window or view is laid out: back to its default"
        var pairs = ["AOMAllInOneLastRatio", "AOMAutomationListWidth", "AOMAutomationTableWidth",
                     "AOMAutomationViewMode", "AOMAudioWorkspaceSection", "AOMSidebarVisible", "AOMInsightsPeriod",
                     "AOMGroupTriggersByFolder", "AOMShowLog", "AOMShowTouchVisualizer", "AOMAudioShowAllApps",
                     "AOMAnnotationBackgroundPanelOpen", "AOMAnnotationBackgroundPrevious"].map { ($0, layout) }
        for key in ["AOMCaptureSaveDirectory", CaptureSettings.RecordingKey.cameraID,
                    CaptureSettings.RecordingKey.microphoneID] {
            pairs.append((key, "a choice for this Mac (the save folder, the camera, the microphone): back to the default"))
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }()

    /// Whether `key` is one of AOM's settings at all.
    static func isAOMKey(_ key: String) -> Bool {
        key.hasPrefix("AOM") || key.hasPrefix("aom.") || unprefixedPreferenceKeys.contains(key)
    }

    /// Why a reset keeps `key`, or nil when it resets it (or it is not AOM's).
    static func preservationReason(for key: String) -> String? {
        if let reason = preservedKeys[key] { return reason }
        return preservedPrefixes.first { key.hasPrefix($0.key) }?.value
    }

    static func resets(_ key: String) -> Bool {
        isAOMKey(key) && preservationReason(for: key) == nil
    }

    /// The preferences the backup list and this registry name, as a reset
    /// treats them: the backed-up settings it clears and the ones it clears
    /// although no backup holds them. Any other AOM key is reset too.
    static var knownPreferenceKeys: [String] {
        Set(PresetManager.backedUpSettingKeys + Array(resetThoughNotBackedUp.keys)).filter(resets).sorted()
    }

    /// The AOM preferences `defaults` holds that a reset clears.
    static func keysToReset(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter(resets).sorted()
    }

    /// Removes every preference (`keysToReset`) from `defaults`, so each goes
    /// back to its default; returns the keys removed. Kept keys are untouched.
    @discardableResult
    static func reset(_ defaults: UserDefaults) -> [String] {
        let keys = keysToReset(in: defaults)
        for key in keys { defaults.removeObject(forKey: key) }
        return keys
    }
}
