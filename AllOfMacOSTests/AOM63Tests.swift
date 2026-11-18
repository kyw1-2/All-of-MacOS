import AppKit
import Carbon.HIToolbox
import XCTest
@testable import AllOfMacOS

final class AudioEffectsIdlePolicyTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "aom.idle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testEffectsOnlySessionIsReleasedAfterASilentMinute() {
        let d = defaults()
        XCTAssertFalse(AudioEffectsIdlePolicy.shouldDetach(effectsOnly: true, playing: false, idleSeconds: 59, defaults: d))
        XCTAssertTrue(AudioEffectsIdlePolicy.shouldDetach(effectsOnly: true, playing: false, idleSeconds: 60, defaults: d))
        XCTAssertFalse(AudioEffectsIdlePolicy.shouldDetach(effectsOnly: true, playing: true, idleSeconds: 600, defaults: d))
    }

    func testAppSettingsKeepTheTap() {
        // A muted, quieter or routed app must never play a first moment at its native level.
        let d = defaults()
        XCTAssertFalse(AudioEffectsIdlePolicy.shouldDetach(effectsOnly: false, playing: false, idleSeconds: 3600, defaults: d))
        XCTAssertTrue(AudioEffectsIdlePolicy.mayAttach(effectsOnly: false, playing: false, defaults: d))
    }

    func testEffectsOnlyAppAttachesWhenItPlays() {
        let d = defaults()
        XCTAssertFalse(AudioEffectsIdlePolicy.mayAttach(effectsOnly: true, playing: false, defaults: d))
        XCTAssertTrue(AudioEffectsIdlePolicy.mayAttach(effectsOnly: true, playing: true, defaults: d))
    }

    func testKeepIdleSessionsRestoresTheOldBehaviour() {
        let d = defaults()
        d.set(true, forKey: AudioEffectsIdlePolicy.keepKey)
        XCTAssertFalse(AudioEffectsIdlePolicy.shouldDetach(effectsOnly: true, playing: false, idleSeconds: 3600, defaults: d))
        XCTAssertTrue(AudioEffectsIdlePolicy.mayAttach(effectsOnly: true, playing: false, defaults: d))
    }
}

final class KeystrokeFormatterTests: XCTestCase {
    private func press(_ keyCode: Int, _ chars: String?, base: String? = nil, _ flags: NSEvent.ModifierFlags = [],
                       shortcutsOnly: Bool = false) -> KeystrokeFormatter.Press? {
        KeystrokeFormatter.press(keyCode: keyCode, characters: chars, baseCharacters: base ?? chars,
                                 modifiers: flags, shortcutsOnly: shortcutsOnly)
    }

    func testShortcutsAreChipsWithModifierGlyphsInMacOrder() {
        XCTAssertEqual(press(kVK_ANSI_K, "k", [.command]), .init(text: "⌘K", isChip: true))
        XCTAssertEqual(press(kVK_ANSI_4, "$", base: "4", [.command, .shift]), .init(text: "⇧⌘4", isChip: true))
        XCTAssertEqual(press(kVK_ANSI_A, "å", base: "a", [.option, .control]), .init(text: "⌃⌥A", isChip: true))
    }

    func testNamedKeysAndTypedText() {
        XCTAssertEqual(press(kVK_Return, "\r"), .init(text: "↩", isChip: true))
        XCTAssertEqual(press(kVK_Tab, "\t", [.shift]), .init(text: "⇧⇥", isChip: true))
        XCTAssertEqual(press(kVK_ANSI_H, "H", [.shift]), .init(text: "H", isChip: false))
        XCTAssertEqual(press(kVK_Space, " "), .init(text: " ", isChip: false))
        XCTAssertEqual(press(kVK_Space, " ", [.control]), .init(text: "⌃Space", isChip: true))
    }

    func testShortcutsOnlyHidesTypedText() {
        XCTAssertNil(press(kVK_ANSI_H, "h", shortcutsOnly: true))
        XCTAssertNil(press(kVK_Return, "\r", shortcutsOnly: true))
        XCTAssertNil(press(kVK_Space, " ", shortcutsOnly: true))
        XCTAssertEqual(press(kVK_ANSI_C, "c", [.command], shortcutsOnly: true)?.text, "⌘C")
    }

    func testControlCharactersAreNotShown() {
        XCTAssertNil(press(kVK_ANSI_A, "\u{1}"))
    }

    func testTypedTextRunsTogetherAndChipsStartNewEntries() {
        var entries: [KeystrokeEntry] = []
        for character in "Hi" { entries = KeystrokeFormatter.appending(.init(text: String(character), isChip: false), to: entries) }
        entries = KeystrokeFormatter.appending(.init(text: "⌘S", isChip: true), to: entries)
        entries = KeystrokeFormatter.appending(.init(text: "o", isChip: false), to: entries)
        XCTAssertEqual(entries.map(\.text), ["Hi", "⌘S", "o"])
        for index in 0..<10 { entries = KeystrokeFormatter.appending(.init(text: "⌘\(index)", isChip: true), to: entries) }
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.last?.text, "⌘9")
    }

    func testLongRunsKeepTheirEnd() {
        let entries = KeystrokeFormatter.appending(.init(text: "z", isChip: false),
                                                   to: [KeystrokeEntry(text: String(repeating: "a", count: 40), isChip: false)])
        XCTAssertEqual(entries.first?.text.count, 32)
        XCTAssertEqual(entries.first?.text.last, "z")
    }
}

final class SystemTools63CatalogTests: XCTestCase {
    func testToolsRemovedIn63AreGoneAndTheirStoredIDsDrop() {
        for raw in ["restart", "shutDown", "logOut", "startupChime", "verifyDisk", "fontCaches"] {
            XCTAssertNil(SystemToolID(rawValue: raw), raw)
            XCTAssertTrue(SystemToolMigration.removed.contains(raw), raw)
        }
        XCTAssertEqual(SystemToolsModel.storedTools(["restart", "darkMode", "fontCaches"]), [.darkMode])
    }

    func testShowKeystrokesIsAQuickToggle() {
        let info = SystemToolCatalog.info(.keystrokes)
        XCTAssertEqual(info.group, .toggles)
        XCTAssertEqual(info.kind, .toggle)
        XCTAssertTrue(info.matches("keycastr"))
        XCTAssertTrue(info.matches("presentation"))
    }

    func testPermissionHintNamesTheStaleEntryTrap() {
        XCTAssertTrue(AOMPermission.accessibility.attentionDetail.contains(AOMPermission.accessibility.attentionSentence))
        XCTAssertTrue(AOMPermission.accessibility.recoveryHint.contains("remove it"))
    }
}

final class KeystrokeLinkTests: XCTestCase {
    func testShowKeystrokesLinks() {
        XCTAssertEqual(AOMCaptureDeepLink.parse(URL(string: "aom://show-keystrokes")!), .keystrokes(.toggle))
        XCTAssertEqual(AOMCaptureDeepLink.parse(URL(string: "aom://show-keystrokes?mode=shortcuts")!), .keystrokes(.shortcuts))
        XCTAssertEqual(AOMCaptureDeepLink.parse(URL(string: "aom://show-keystrokes?mode=OFF")!), .keystrokes(.off))
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://show-keystrokes?mode=toggle")!))
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://show-keystrokes?mode=loud")!))
        XCTAssertNil(AOMCaptureDeepLink.parse(URL(string: "aom://show-keystrokes?mode=all&x=1")!))
    }
}
