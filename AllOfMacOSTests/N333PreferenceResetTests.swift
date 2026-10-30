import XCTest
@testable import AllOfMacOS

/// N333-07 (3.3.3 re-audit, B05): Reset Preferences clears every AOM
/// preference, the 3.3.3 title-bar, Dock, menu-bar, recording, clipboard and
/// audio ones included, and keeps what `PreferenceResetRegistry` keeps, each
/// with its reason. The reset and the backup list agree on every setting, or
/// the difference is listed with a reason. Only throwaway UserDefaults suites
/// are written: never the app's own domain or the test process's standard one.
final class N333PreferenceResetTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let name = "AOMN333Reset.\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// Settings the 3.3.2 reset (nine fixed keys) left alone, one or more per
    /// area. The title-bar keys are spelled out as the re-audit names them.
    private var settingsTheOldResetMissed: [String: Any] {
        var settings: [String: Any] = [
            "AOMTitleBarSnapEnabled": true, "AOMTitleBarSnapMotionPause": false,
            "AOMTitleBarSnapSuperAnywhere": true, "AOMTitleBarSnapTabs": false,
            "AOMTitleBarSnapNativeTiling": true, "AOMTitleBarSnapTooltip": false,
            "AOMTitleBarSnapHotkeyCenter": true, "AOMTitleBarSnapPinch": false,
            TrackpadUtilityGestures.dockGesturesKey: false, TrackpadUtilityGestures.menuBarGesturesKey: false,
            TrackpadUtilityGestures.dockDoublePinchKey: false, TrackpadUtilityGestures.menuBarSwitcherKey: "apps",
            TrackpadUtilityGestures.appMenuGesturesKey: true, TrackpadUtilityGestures.menuBarScrollToTopKey: true,
            TrackpadUtilityGestures.missionControlGesturesKey: true, TrackpadUtilityGestures.spacesEnabledKey: false,
            CaptureSettings.RecordingKey.clickStyle: "ring", CaptureSettings.RecordingKey.scalesTo1x: true,
            CaptureSettings.RecordingKey.hidesDesktopIcons: true, CaptureSettings.RecordingKey.cameraID: "camera",
            "AOMCaptureRecordingOutputFormat": "gif", "AOMCaptureFormat": "jpeg",
            "AOMClipboardLinkCards": true, "AOMClipboardQuickModifier": "option", "AOMClipboardShortcut_history": "⌥V",
            AudioBoostPreset.masterKey: "speech", AudioDeviceEQ.assignmentsKey: Data("{}".utf8),
            AudioUnitEffectHost.choiceKey: "effect", AudioUnitEffectHost.stateKey: Data("{}".utf8),
            "AOMAudioGain_com.example.player": 0.4, "AOMAudioMagicBoostPreset_com.example.player": "night",
            "aom.audio.protectMediaPlayback": false,
            TriggerSuppression.settingsKey: Data("{}".utf8), "AOMForceTouchStageHysteresis": 0.2,
            "AOMSwipeMinVelocity_twoFingerSwipeUp": 300.0, "AOMKeyboardLongPressMs": 700,
            "AOMAccentColor": "pink", "showMenuBarIcon": false, "AOMHUDBackgroundOpacity": 0.3,
            "AOMShowLog": true, "AOMCaptureSaveDirectory": "/tmp/elsewhere"
        ]
        for role in SwishSnap.ModifierRole.allCases { settings[role.defaultsKey] = "control" }
        return settings
    }

    /// Data, limits, access and state a reset keeps.
    private let dataTheResetKeeps: [String: Any] = [
        AutomationGate.masterSwitchKey: false,
        "AOMClipboardSettings.v1": Data("{\"retentionDays\":365}".utf8),
        "AOMCaptureHistoryCapacity": 200, "AOMCaptureHistoryRetentionDays": 0,
        "AOMWindowLayoutsV1": Data("[]".utf8), "AOMFloatingMenusV1": Data("[]".utf8),
        "AOMWorkflowVariables": ["name": "value"], "AOMKeyRemaps": Data("[]".utf8),
        AudioDeviceEQ.presetsKey: Data("[]".utf8), "AOMAnnotationStylePresets": Data("[]".utf8),
        TextCaptureSettings.Key.customWords: ["Kiro"],
        "AOMMCPEnabled": true, "AOMMCPTools": ["read_item"], "AOMIntelligentClipboardEnabled": true,
        "AOMKeyRemapOwnedPairs": [1, 2], "AOMParkedWindowRecoveryV1": Data("[]".utf8),
        "AOMHasSeenTutorial": true, "AOMAudioSoundSourceModelMigrated": true,
        "AOMBackupPath": "/tmp/aom-backups", "AOMBackupsEnabled": false, "AOMMaxBackups": 9,
        "AOMGestureStatistics.v2": Data("{}".utf8), "AOMCaptureLastArea": "0 0 10 10",
        "AOMShortcutConflictDismissed_com.example.app_⌘K": true, "AOMAudioOutputUnmute_BuiltInSpeaker": 0.6
    ]

    func testTheResetClearsThe333PreferencesAndKeepsTheData() throws {
        let defaults = try defaults()
        let preferences = settingsTheOldResetMissed
        for (key, value) in preferences { defaults.set(value, forKey: key) }
        for (key, value) in dataTheResetKeeps { defaults.set(value, forKey: key) }
        // Not AOM's: a window frame AppKit keeps in the same domain.
        defaults.set("0 0 800 600 0 0 1440 900", forKey: "NSWindow Frame AOMTestWindow")

        let removed = Set(PreferenceResetRegistry.reset(defaults))

        for key in preferences.keys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) goes back to its default")
            XCTAssertTrue(removed.contains(key), key)
        }
        for key in dataTheResetKeeps.keys {
            XCTAssertNotNil(defaults.object(forKey: key),
                            "\(key) is kept: \(PreferenceResetRegistry.preservationReason(for: key) ?? "no reason")")
            XCTAssertFalse(removed.contains(key), key)
        }
        XCTAssertNotNil(defaults.object(forKey: "NSWindow Frame AOMTestWindow"), "only AOM's keys are touched")
        XCTAssertTrue(Set(PreferenceResetRegistry.keysToReset(in: defaults)).isDisjoint(with: preferences.keys),
                      "nothing of these is left to reset")
    }

    /// The keys the re-audit named, spelled out, and every modifier role.
    func testTheNamedSwishSettingsAreResetPreferences() {
        let named = ["AOMTitleBarSnapMotionPause", "AOMDockDoublePinch", "AOMMenuBarSwitcher", "AOMAppMenuGestures",
                     "AOMMenuBarScrollToTop", "AOMMissionControlGestures", "AOMDockGestures", "AOMMenuBarGestures"]
            + SwishSnap.ModifierRole.allCases.map(\.defaultsKey)
        let known = Set(PreferenceResetRegistry.knownPreferenceKeys)
        for key in named {
            XCTAssertTrue(PreferenceResetRegistry.resets(key), key)
            XCTAssertTrue(known.contains(key), "\(key) is a named preference")
        }
        XCTAssertTrue(SwishSnap.ModifierRole.allCases.allSatisfy { $0.defaultsKey.hasPrefix("AOMTitleBarSnapModifier") })
    }

    /// The 3.3.2 reset's nine keys: still reset, except the pause switch (a
    /// reset never pauses or resumes AOM) and the onboarding marker.
    func testTheOldResetsKeysAreResetExceptThePauseSwitchAndTheTour() {
        for key in ["AOMAccentColor", "AOMAppearance", "AOMPressDragThreshold", "AOMTipTapMinRestTime",
                    "AOMSuppressMouseDuringDrawing", "showMenuBarIcon", "AOMHUDBackgroundOpacity"] {
            XCTAssertTrue(PreferenceResetRegistry.resets(key), key)
        }
        XCTAssertFalse(PreferenceResetRegistry.resets(AutomationGate.masterSwitchKey))
        XCTAssertFalse(PreferenceResetRegistry.resets("AOMHasSeenTutorial"))
    }

    /// Every backed-up setting is one the reset rule sees; the backed-up
    /// settings it keeps are exactly the user's data and the history limits.
    func testEveryBackedUpSettingIsResetOrKeptForAReason() {
        for key in PresetManager.backedUpSettingKeys {
            XCTAssertTrue(PreferenceResetRegistry.isAOMKey(key), "\(key): add it to unprefixedPreferenceKeys")
        }
        let kept = Set(PresetManager.backedUpSettingKeys.filter { !PreferenceResetRegistry.resets($0) })
        XCTAssertEqual(kept, ["AOMWindowLayoutsV1", "AOMFloatingMenusV1", "AOMWorkflowVariables", "AOMActionFavorites.v1",
                              "AOMKeyRemaps", "AOMAudioFavorites", "AOMAudioUserApps", AudioDeviceEQ.presetsKey,
                              "AOMAnnotationStylePresets", "AOMAnnotationBackgroundPresets", "AOMAnnotationMyColors",
                              TextCaptureSettings.Key.customWords, "AOMClipboardSettings.v1",
                              "AOMCaptureHistoryCapacity", "AOMCaptureHistoryRetentionDays"],
                       "a backed-up setting the reset keeps is listed in preservedKeys with its reason")
        for key in kept { XCTAssertFalse((PreferenceResetRegistry.preservationReason(for: key) ?? "").isEmpty, key) }
        // Families keyed by app or device: reset, except the volumes AOM brings back on unmute.
        let keptFamilies = PresetManager.backedUpSettingPrefixes.filter { !PreferenceResetRegistry.resets($0 + "member") }
        XCTAssertEqual(Set(keptFamilies), ["AOMAudioOutputUnmute_", "AOMAudioInputUnmute_"])
    }

    /// Every setting left out of backups is kept by the reset, or reset with
    /// the reason listed in `resetThoughNotBackedUp`; never both.
    func testEverySettingLeftOutOfBackupsIsKeptOrResetForAReason() {
        for key in PresetManager.settingsNotBackedUp.keys.sorted() {
            let kept = PreferenceResetRegistry.preservationReason(for: key) != nil
            let resetForAReason = PreferenceResetRegistry.resetThoughNotBackedUp[key] != nil
            XCTAssertTrue(kept != resetForAReason, "\(key): kept with a reason or reset with a reason")
        }
        for key in PreferenceResetRegistry.resetThoughNotBackedUp.keys {
            XCTAssertNotNil(PresetManager.settingsNotBackedUp[key], "\(key) is left out of backups")
            XCTAssertTrue(PreferenceResetRegistry.resets(key), key)
        }
        // The capture keys this registry spells out (`CaptureSettings.Key` is private).
        for key in CaptureSettings.machineSpecificKeys {
            XCTAssertTrue(PreferenceResetRegistry.preservationReason(for: key) != nil
                          || PreferenceResetRegistry.resetThoughNotBackedUp[key] != nil, key)
        }
        for (prefix, reason) in PresetManager.settingPrefixesNotBackedUp {
            XCTAssertTrue(PreferenceResetRegistry.preservedPrefixes[prefix] != nil || reason == "window layout",
                          "\(prefix): kept, or reset like the other window layout")
        }
        for (key, reason) in PreferenceResetRegistry.preservedKeys {
            XCTAssertTrue(PreferenceResetRegistry.isAOMKey(key), key)
            XCTAssertFalse(reason.isEmpty, key)
            XCTAssertNil(PreferenceResetRegistry.resetThoughNotBackedUp[key], "\(key) is not both kept and reset")
        }
    }

    /// The prefix rule sees every setting key the sources use: a key without
    /// the AOM prefix must be listed, or a reset would miss it.
    func testEverySettingKeyInTheSourcesIsSeenByTheResetRule() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AllOfMacOS", isDirectory: true)
        let patterns = [
            #"@AppStorage\("([^"]+)""#,
            #"\b(?:object|string|bool|integer|double|float|data|array|stringArray|dictionary|url|set|removeObject)\((?:[^()\n]*?, )?forKey: *"([^"]+)""#,
            #"Hub[A-Za-z]*Row\([^\n]*?\bkey: *"([^"]+)""#,
            #"static let [A-Za-z0-9_]*[Kk]ey *(?:: *String)? *= *"([^"]+)""#
        ].map { try! NSRegularExpression(pattern: $0) }
        var found: [String: String] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: range) {
                    if let key = Range(match.range(at: 1), in: text) { found[String(text[key])] = url.lastPathComponent }
                }
            }
        }
        XCTAssertGreaterThan(found.count, 150, "the scan found the app's settings (\(found.count))")
        let unseen = found.filter { !PreferenceResetRegistry.isAOMKey($0.key) }.map { "\($0.value): \($0.key)" }.sorted()
        XCTAssertEqual(unseen, [], "add these to PreferenceResetRegistry.unprefixedPreferenceKeys")
    }

    /// The reset acts on the defaults it is given and nothing else.
    func testTheResetOnlyTouchesTheDefaultsItIsGiven() throws {
        let reset = try defaults()
        let other = try defaults()
        let motionPause = "AOMTitleBarSnapMotionPause"
        for target in [reset, other] {
            target.set(false, forKey: motionPause)
            target.set("apps", forKey: TrackpadUtilityGestures.menuBarSwitcherKey)
        }
        let both: Set = [motionPause, TrackpadUtilityGestures.menuBarSwitcherKey]
        XCTAssertTrue(both.isSubset(of: PreferenceResetRegistry.keysToReset(in: reset)))
        PreferenceResetRegistry.reset(reset)
        XCTAssertNil(reset.object(forKey: motionPause))
        XCTAssertNil(reset.object(forKey: TrackpadUtilityGestures.menuBarSwitcherKey))
        XCTAssertEqual(other.object(forKey: motionPause) as? Bool, false)
        XCTAssertEqual(other.string(forKey: TrackpadUtilityGestures.menuBarSwitcherKey), "apps")
    }
}
