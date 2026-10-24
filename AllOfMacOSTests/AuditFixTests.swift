import XCTest
@testable import AllOfMacOS

/// Integration tests for the 2026-10-25 audit fixes: registration wiring,
/// switcher click targets, Keep Awake lifecycle, reset scope, settings-list
/// completeness and the backup allowlist.
@MainActor
final class AuditFixTests: XCTestCase {

    // MARK: 1. Text expansion reaches the keyboard monitor's registration

    func testTypedStringTriggersRegisterInTheKeyboardMonitor() {
        let monitor = KeyboardMonitor()
        let trigger = Trigger(name: "email expansion",
                              input: .typedString(TypedStringSpec(abbreviation: ";email", replacement: "me@example.com")))
        monitor.registerTriggers([trigger], groups: [])
        XCTAssertTrue(monitor.registeredTriggers.contains { $0.id == trigger.id },
                      "a saved typed-string rule must be registered — the engine's entry guard reads this list")
        monitor.unregisterAll()
        XCTAssertFalse(monitor.registeredTriggers.contains { $0.id == trigger.id })
    }

    // MARK: 3. Switcher click activates the clicked card

    func testSwitcherClickActivatesTheClickedCardNotTheKeyboardSelection() {
        let controller = WindowSwitcherController.shared
        var activated: [CGWindowID] = []
        controller.activateTarget = { activated.append($0.id) }
        defer { controller.activateTarget = { _ in } }

        func item(_ id: CGWindowID) -> WindowSwitcherController.Item {
            WindowSwitcherController.Item(id: id, title: "W\(id)", appName: "App",
                                          icon: nil, axWindow: nil, pid: 1, thumbnail: nil)
        }
        controller.items = [item(11), item(22), item(33)]
        // selectedIndex stays 0 (keyboard selection) — the click must override it.

        controller.selectAndConfirm(id: 33)
        XCTAssertEqual(activated, [33], "clicking the third card must activate window 33, not the selected 11")
    }

    func testSwitcherClickOnVanishedWindowCancels() {
        let controller = WindowSwitcherController.shared
        var activated: [CGWindowID] = []
        controller.activateTarget = { activated.append($0.id) }
        defer { controller.activateTarget = { _ in } }
        controller.items = [WindowSwitcherController.Item(id: 7, title: "A", appName: "App",
                                                          icon: nil, axWindow: nil, pid: 1, thumbnail: nil)]
        controller.selectAndConfirm(id: 99) // closed between render and click
        XCTAssertTrue(activated.isEmpty, "a vanished window must cancel instead of activating something else")
    }

    // MARK: 4. Keep Awake lifecycle

    func testKeepAwakeRestartsAfterExpiryAndReplacesDurations() {
        let service = KeepAwakeService()
        var nextID: IOPMAssertionID = 100
        var created: [KeepAwakeService.Assertion] = []
        var released: [IOPMAssertionID] = []
        service.createAssertion = { minutes, keepDisplay in
            let id = nextID; nextID += 1
            let endsAt = minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) }
            let assertion = KeepAwakeService.Assertion(id: id, minutes: minutes, keepDisplay: keepDisplay, endsAt: endsAt)
            created.append(assertion)
            return assertion
        }
        service.releaseAssertion = { released.append($0) }

        // Start a session that expired in the past (the system already released it).
        service.start(minutes: -1, keepDisplay: false)
        XCTAssertFalse(service.isActive)
        XCTAssertTrue(service.hasAssertion, "the stale ID is still around — exactly the audit's blocked-restart state")

        // Restarting after expiry must clear the stale assertion and succeed.
        service.start(minutes: 30, keepDisplay: false)
        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(released.contains(created[0].id), "the expired assertion is released, not guarded away")
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.currentMinutes, 30)

        // Changing the duration while live replaces the assertion.
        service.start(minutes: 60, keepDisplay: false)
        XCTAssertEqual(created.count, 3)
        XCTAssertEqual(released, [created[0].id, created[1].id], "both the stale and the replaced live assertion were released")
        XCTAssertEqual(service.currentMinutes, 60)

        // Indefinite ↔ timed both directions.
        service.start(minutes: nil, keepDisplay: false)
        XCTAssertNil(service.currentMinutes)
        XCTAssertTrue(service.isActive)
        service.start(minutes: 120, keepDisplay: true)
        XCTAssertEqual(service.currentMinutes, 120)

        // Stop clears everything and reports no assertion.
        service.stop()
        XCTAssertFalse(service.isActive)
        XCTAssertFalse(service.hasAssertion)
        XCTAssertEqual(released.count, created.count, "every created assertion was released exactly once")
    }

    // MARK: 6. Restore Capture Defaults leaves the new groups alone

    func testResetCaptureDefaultsPreservesSwitcherAndPinningAssignments() {
        let suite = "AOMResetScope-Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = CaptureShortcuts(defaults: defaults)
        shortcuts.resetToDefaults()

        let custom = KeyboardShortcut(keyCode: 48, modifiers: [.control]) // ⌃Tab
        shortcuts.setShortcut(custom, for: .windowSwitcher)
        shortcuts.setShortcut(nil, for: .captureArea) // disabled by the user
        XCTAssertNotNil(shortcuts.shortcut(for: .windowSwitcher))

        shortcuts.resetCaptureDefaults()

        XCTAssertEqual(shortcuts.shortcut(for: .captureArea), CaptureShortcutAction.captureArea.defaultShortcut,
                       "capture shortcuts return to their CleanShot defaults")
        XCTAssertEqual(shortcuts.shortcut(for: .windowSwitcher), custom,
                       "the switcher assignment survives the capture reset")
    }

    // MARK: 7. Every shortcut action belongs to a rendered settings group

    func testEveryShortcutActionHasARenderedSettingsGroup() {
        let rendered = ["Screen Capture", "Tools & Utilities", "Always on Top", "System & Switching"]
        for action in CaptureShortcutAction.allCases {
            XCTAssertTrue(rendered.contains(action.categoryName),
                          "\(action.displayName) has no settings group and would be invisible")
        }
        // The three actions the audit found missing:
        XCTAssertTrue(["Screen Capture", "Tools & Utilities"].contains(CaptureShortcutAction.pauseRecording.categoryName))
        XCTAssertFalse(CaptureShortcutAction.allInOne.categoryName.isEmpty)
        XCTAssertFalse(CaptureShortcutAction.openProject.categoryName.isEmpty)
    }

    // MARK: 8. Backups cover the global shortcut assignments

    func testBackupAllowlistIncludesShortcutAssignments() {
        let keys = Set(PresetManager.backedUpSettingKeys)
        XCTAssertTrue(keys.contains(CaptureShortcutAction.captureArea.userDefaultsKey))
        XCTAssertTrue(keys.contains(CaptureShortcutAction.windowSwitcher.userDefaultsKey + ".disabled"))
        XCTAssertTrue(keys.contains("AOMClipboardShortcut_history"))
        XCTAssertTrue(keys.contains("AOMClipboardShortcut_historyDisabled"))
    }
}
