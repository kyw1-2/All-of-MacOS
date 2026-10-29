import XCTest
@testable import AllOfMacOS

/// Audit 2026-10-28 F07 and its review: every AOM setting is either in a
/// backup or deliberately left out with a reason, so a new setting cannot
/// silently miss the backup again (3.3.0 missed the title-bar snap, the
/// review found gesture timing, key remaps and text capture still missing).
///
/// The scan reads the app's sources for settings keys in the forms the app
/// uses: `forKey: "…"`, `@AppStorage("…")`, `static let … = "…"` and key
/// prefixes built as `"…_\(…)"` or `"…_" + …`. A key built as `"…" + name`
/// (3.3.3's modifier roles) shows only its prefix, so its keys are listed in
/// `builtKeys`. A key built some other way is not seen by this test.
final class BackupScopeTests: XCTestCase {
    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AllOfMacOS", isDirectory: true)

    /// Literals the scan sees that are not settings.
    private static let notSettings: Set<String> = ["AOMCategory_"]  // an accessibility identifier

    /// The keys behind each `"…" + name` prefix the scan finds, taken from
    /// the code that builds them. A new prefix of this form fails the scan
    /// until its keys are listed here.
    private static let builtKeys: [String: [String]] = [
        "AOMTitleBarSnapModifier": SwishSnap.ModifierRole.allCases.map(\.defaultsKey)
    ]

    private func scannedKeys() throws -> Set<String> {
        let patterns = [
            #"forKey: *"((?:AOM|aom\.)[A-Za-z0-9_.]*)""#,
            #"@AppStorage\("((?:AOM|aom\.)[A-Za-z0-9_.]*)""#,
            #"static let [A-Za-z0-9_]+ *(?:: *String)? *= *"((?:AOM|aom\.)[A-Za-z0-9_.]*)""#,
            #""((?:AOM|aom\.)[A-Za-z0-9.]*_)" *\+"#,
            #""((?:AOM|aom\.)[A-Za-z0-9.]*_)\\\("#
        ].map { try! NSRegularExpression(pattern: $0) }
        // `"AOMTitleBarSnapModifier" + title`: a prefix without the family underscore.
        let builtPrefix = try NSRegularExpression(pattern: #""((?:AOM|aom\.)[A-Za-z0-9.]*[A-Za-z0-9])" *\+"#)
        var keys: Set<String> = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: range) {
                    if let key = Range(match.range(at: 1), in: text) { keys.insert(String(text[key])) }
                }
            }
            for match in builtPrefix.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                let prefix = String(text[found])
                let built = try XCTUnwrap(Self.builtKeys[prefix],
                                          "\(url.lastPathComponent) builds keys from \"\(prefix)\" + …: list them in builtKeys")
                keys.formUnion(built)
            }
        }
        return keys
    }

    func testEverySettingIsBackedUpOrLeftOutForAReason() throws {
        let keys = try scannedKeys()
        XCTAssertGreaterThan(keys.count, 150, "the scan found the app's settings (\(keys.count))")
        let backedUp = PresetManager.backedUpSettingKeys
        var unclassified: [String] = []
        for key in keys.sorted() where !Self.notSettings.contains(key) {
            if key.hasSuffix("_") {
                // A family: backed up as a family, built from backed-up keys
                // (one per gesture or shortcut), or left out.
                let classified = PresetManager.backedUpSettingPrefixes.contains(key)
                    || PresetManager.settingPrefixesNotBackedUp[key] != nil
                    || backedUp.contains { $0.hasPrefix(key) }
                if !classified { unclassified.append(key) }
            } else if !PresetManager.isBackedUpSetting(key) && PresetManager.settingsNotBackedUp[key] == nil {
                unclassified.append(key)
            }
        }
        XCTAssertEqual(unclassified, [], "add these to PresetManager's backup list or to settingsNotBackedUp with a reason")
    }

    func testNoSettingIsBothBackedUpAndLeftOut() {
        let both = PresetManager.backedUpSettingKeys.filter { PresetManager.settingsNotBackedUp[$0] != nil }
        XCTAssertEqual(both, [], "a key listed in both would be saved but never restored")
        for (key, reason) in PresetManager.settingsNotBackedUp { XCTAssertFalse(reason.isEmpty, key) }
    }

    /// The review's list of settings the Backups page promised but 3.3.1's
    /// first draft left out.
    func testTheSettingsThePagePromisesAreBackedUp() {
        for key in ["AOMGlobalSwipeMinVelocity", "AOMKeyboardLongPressMs", "AOMKeyboardQuickReleaseMaxMs", "AOMMouseLongPressMs",
                    "AOMMouseDragThresholdPx", "AOMForcePressEnabled", "AOMForcePressThreshold", "AOMKeyRemaps",
                    "AOMHyperKeyEnabled", "AOMReverseMouseWheel", "AOMHUDEnabled", "AOMAudioOverdrive_com.example.app",
                    "AOMMissionControlButtons", "AOMMissionControlHotkeys", TextCaptureSettings.Key.languages,
                    TextCaptureShortcutAction.readQRCode.userDefaultsKey] {
            XCTAssertTrue(PresetManager.isBackedUpSetting(key), key)
        }
        for key in ["AOMKeyRemapOwnedPairs", "AOMMCPEnabled", "AOMIntelligentClipboardReadsScreen", "AOMMaxBackups"] {
            XCTAssertFalse(PresetManager.isBackedUpSetting(key), key)
        }
    }

    /// 3.3.3's clipboard, capture, annotation and audio settings are backed
    /// up; a diagnostics reset request and the recording devices are left out
    /// with a reason. (The 3.3.3 gesture settings are in ProfileBackupRestoreTests.)
    func testThe333SettingsAreBackedUpOrLeftOutForAReason() {
        let backedUp = ["AOMClipboardLinkCards", CaptureSettings.RecordingKey.clickStyle,
                        CaptureSettings.RecordingKey.hidesDesktopIcons, CaptureSettings.RecordingKey.scalesTo1x,
                        AudioBoostPreset.masterKey, AudioBoostPreset.appKey("com.example.player"),
                        AudioDeviceEQ.presetsKey, AudioDeviceEQ.assignmentsKey,
                        AudioUnitEffectHost.choiceKey, AudioUnitEffectHost.stateKey] + AnnotationSettings.backedUpKeys
        for key in backedUp { XCTAssertTrue(PresetManager.isBackedUpSetting(key), key) }
        for key in AnnotationSettings.backedUpKeys { XCTAssertTrue(CaptureSettings.backedUpKeys.contains(key), key) }
        for key in [AudioDiagnostics.resetRequestKey, CaptureSettings.RecordingKey.cameraID,
                    CaptureSettings.RecordingKey.microphoneID] {
            XCTAssertFalse(PresetManager.isBackedUpSetting(key), key)
            XCTAssertFalse((PresetManager.settingsNotBackedUp[key] ?? "").isEmpty, "\(key) is left out with a reason")
        }
        XCTAssertTrue(PresetManager.settingsNotBackedUp[CaptureSettings.RecordingKey.cameraID]?.contains("devices") == true,
                      "the machine-specific reason names the devices")
    }
}
