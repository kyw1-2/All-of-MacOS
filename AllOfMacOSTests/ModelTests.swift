import XCTest
@testable import AllOfMacOS

final class ModelTests: XCTestCase {

    // MARK: - Trigger model

    func testTriggerDefaultValues() {
        let trigger = Trigger(name: "Test", input: .trackpadGesture(.twoFingerTap))
        XCTAssertTrue(trigger.isEnabled)
        XCTAssertNil(trigger.appBundleID)
        XCTAssertTrue(trigger.actions.isEmpty)
        XCTAssertEqual(trigger.order, 0)
    }

    func testTriggerDisplayNameFallsBackToInput() {
        let trigger = Trigger(name: "", input: .trackpadGesture(.threeFingerSwipeUp))
        XCTAssertEqual(trigger.displayName, "3 Finger Swipe Up")
    }

    func testTriggerDisplayNameUsesCustomName() {
        let trigger = Trigger(name: "My Gesture", input: .trackpadGesture(.threeFingerSwipeUp))
        XCTAssertEqual(trigger.displayName, "My Gesture")
    }

    func testTriggerInputCategory() {
        XCTAssertEqual(TriggerInput.trackpadGesture(.twoFingerTap).category, .trackpad)
        XCTAssertEqual(TriggerInput.keyboardShortcut(KeyboardShortcut(keyCode: 0, modifiers: .command)).category, .keyboard)
        XCTAssertEqual(TriggerInput.mouseButton(.button3).category, .normalMouse)
        XCTAssertEqual(TriggerInput.drawingPattern("circle").category, .drawings)
        XCTAssertEqual(TriggerInput.namedTrigger("custom").category, .otherTriggers)
    }

    // MARK: - Action model

    func testActionParametersDefaultsNil() {
        let params = ActionParameters()
        XCTAssertNil(params.text)
        XCTAssertNil(params.applicationPath)
        XCTAssertNil(params.scriptContent)
        XCTAssertNil(params.url)
        XCTAssertNil(params.shortcutKeyCode)
        XCTAssertNil(params.shortcutModifiers)
        XCTAssertNil(params.delayBeforeMs)
    }

    func testTriggerActionDefaultEnabled() {
        let action = TriggerAction(actionType: .volumeUp)
        XCTAssertTrue(action.isEnabled)
    }

    func testActionTypeCategories() {
        XCTAssertEqual(ActionType.maximizeWindow.category, .windowManagement)
        XCTAssertEqual(ActionType.sendKeyStroke.category, .keyboardActions)
        XCTAssertEqual(ActionType.launchApplication.category, .applicationControl)
        XCTAssertEqual(ActionType.lockScreen.category, .systemActions)
        XCTAssertEqual(ActionType.runShellScript.category, .scriptExecution)
        XCTAssertEqual(ActionType.playPause.category, .mediaControls)
    }

    func testActionsForCategory() {
        let windowActions = ActionType.actionsForCategory(.windowManagement)
        XCTAssertTrue(windowActions.contains(.maximizeWindow))
        XCTAssertTrue(windowActions.contains(.snapWindowLeft))
        XCTAssertFalse(windowActions.contains(.sendKeyStroke))

        let mediaActions = ActionType.actionsForCategory(.mediaControls)
        XCTAssertTrue(mediaActions.contains(.playPause))
        XCTAssertTrue(mediaActions.contains(.nextTrack))
        XCTAssertTrue(mediaActions.contains(.previousTrack))
        XCTAssertEqual(mediaActions.count, 3)
    }

    // MARK: - TrackpadGesture completeness

    func testAllTrackpadGesturesHaveUniqueRawValues() {
        let rawValues = TrackpadGesture.allCases.map { $0.rawValue }
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "Duplicate raw values in TrackpadGesture")
    }

    func testAllActionTypesHaveUniqueRawValues() {
        let rawValues = ActionType.allCases.map { $0.rawValue }
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "Duplicate raw values in ActionType")
    }

    func testAllActionTypesHaveIcons() {
        for actionType in ActionType.allCases {
            XCTAssertFalse(actionType.iconName.isEmpty, "\(actionType) has no icon")
        }
    }

    // MARK: - Preset model

    func testPresetDefaultValues() {
        let preset = Preset(name: "Test Preset")
        XCTAssertEqual(preset.name, "Test Preset")
        XCTAssertTrue(preset.isEnabled)
        XCTAssertFalse(preset.isMaster)
        XCTAssertTrue(preset.triggers.isEmpty)
    }

    func testPresetAddTrigger() {
        var preset = Preset(name: "P")
        let trigger = Trigger(name: "T", input: .trackpadGesture(.twoFingerTap))
        preset.addTrigger(trigger)
        XCTAssertEqual(preset.triggers.count, 1)
        XCTAssertEqual(preset.triggers.first?.name, "T")
    }

    func testPresetRemoveTrigger() {
        var preset = Preset(name: "P")
        let trigger = Trigger(name: "T", input: .trackpadGesture(.twoFingerTap))
        preset.addTrigger(trigger)
        XCTAssertEqual(preset.triggers.count, 1)
        preset.removeTrigger(id: trigger.id)
        XCTAssertTrue(preset.triggers.isEmpty)
    }

    func testPresetUpdateTrigger() {
        var preset = Preset(name: "P")
        var trigger = Trigger(name: "Original", input: .trackpadGesture(.twoFingerTap))
        preset.addTrigger(trigger)

        trigger.name = "Updated"
        preset.updateTrigger(trigger)

        XCTAssertEqual(preset.triggers.first?.name, "Updated")
    }

    func testPresetFilterByAppAndCategory() {
        var preset = Preset(name: "P")

        var t1 = Trigger(name: "Global Tap", input: .trackpadGesture(.twoFingerTap))
        t1 = Trigger(name: "Global Tap", input: .trackpadGesture(.twoFingerTap), appBundleID: nil)
        preset.addTrigger(t1)

        let t2 = Trigger(name: "App Tap", input: .trackpadGesture(.threeFingerTap), appBundleID: "com.test.app")
        preset.addTrigger(t2)

        let t3 = Trigger(name: "App Key", input: .keyboardShortcut(KeyboardShortcut(keyCode: 0, modifiers: .command)), appBundleID: "com.test.app")
        preset.addTrigger(t3)

        let appTarget = AppTarget(id: UUID(), bundleID: "com.test.app", name: "Test", iconPath: nil)
        let appTrackpad = preset.triggers(for: appTarget, category: .trackpad)
        XCTAssertEqual(appTrackpad.count, 1)
        XCTAssertEqual(appTrackpad.first?.name, "App Tap")

        let appKeyboard = preset.triggers(for: appTarget, category: .keyboard)
        XCTAssertEqual(appKeyboard.count, 1)
        XCTAssertEqual(appKeyboard.first?.name, "App Key")
    }

    // MARK: - KeyboardShortcut

    func testKeyboardShortcutDisplayString() {
        let shortcut = KeyboardShortcut(keyCode: 15, modifiers: [.command, .shift])
        let display = shortcut.displayString
        XCTAssertTrue(display.contains("⌘"))
        XCTAssertTrue(display.contains("⇧"))
        XCTAssertTrue(display.contains("R"))
    }

    func testKeyboardShortcutDisplayStringAllModifiers() {
        let shortcut = KeyboardShortcut(keyCode: 0, modifiers: [.control, .option, .shift, .command])
        let display = shortcut.displayString
        XCTAssertTrue(display.contains("⌃"))
        XCTAssertTrue(display.contains("⌥"))
        XCTAssertTrue(display.contains("⇧"))
        XCTAssertTrue(display.contains("⌘"))
        XCTAssertTrue(display.contains("A"))
    }

    // MARK: - TriggerResolver

    /// Mirrors how the monitors actually register: a flat tuple, not a Trigger.
    private typealias Registration = (id: UUID, button: MouseButton, appBundleID: String?)

    private func registration(_ button: MouseButton, app: String? = nil) -> Registration {
        (id: UUID(), button: button, appBundleID: app)
    }

    private func resolve(_ items: [Registration], _ button: MouseButton, front: String?) -> [Registration] {
        TriggerResolver.resolve(
            items,
            payload: button,
            frontBundleID: front,
            payloadOf: { $0.button },
            appBundleIDOf: { $0.appBundleID }
        )
    }

    func testResolverReturnsGlobalWhenNoAppSpecificMatch() {
        let items = [registration(.button3), registration(.button3, app: "com.other.app")]
        let fired = resolve(items, .button3, front: "com.front.app")
        XCTAssertEqual(fired.count, 1)
        XCTAssertNil(fired[0].appBundleID)
    }

    func testResolverPrefersAppSpecificAndSkipsGlobalsEntirely() {
        // App-specific shadowing is not a merge: the global must not also fire.
        let items = [registration(.button3), registration(.button3, app: "com.front.app")]
        let fired = resolve(items, .button3, front: "com.front.app")
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].appBundleID, "com.front.app")
    }

    func testResolverReturnsEveryAppSpecificEntryForTheFrontApp() {
        let items = [registration(.button3, app: "com.front.app"), registration(.button3, app: "com.front.app")]
        let fired = resolve(items, .button3, front: "com.front.app")
        XCTAssertEqual(fired.count, 2)
    }

    func testResolverIgnoresEntriesForADifferentPayload() {
        let items = [registration(.button4)]
        let fired = resolve(items, .button3, front: nil)
        XCTAssertTrue(fired.isEmpty)
    }

    func testResolverReturnsEmptyWhenNothingMatches() {
        let items = [registration(.button3, app: "com.other.app")]
        let fired = resolve(items, .button3, front: "com.front.app")
        XCTAssertTrue(fired.isEmpty)
    }

    func testResolverTreatsMissingFrontAppAsGlobalOnly() {
        let items = [registration(.button3), registration(.button3, app: "com.front.app")]
        let fired = resolve(items, .button3, front: nil)
        XCTAssertEqual(fired.count, 1)
        XCTAssertNil(fired[0].appBundleID)
    }

    func testResolverMatchesKeyboardShortcutByPayload() {
        let shortcut = KeyboardShortcut(keyCode: 15, modifiers: [.command])
        let other = KeyboardShortcut(keyCode: 16, modifiers: [.command])
        let items = [
            Trigger(name: "Cmd-R", input: .keyboardShortcut(shortcut)),
            Trigger(name: "Cmd-Y", input: .keyboardShortcut(other)),
        ]
        let fired = TriggerResolver.resolve(
            items,
            payload: shortcut,
            frontBundleID: nil,
            payloadOf: { trigger -> KeyboardShortcut? in
                if case .keyboardShortcut(let value) = trigger.input { return value }
                return nil
            },
            appBundleIDOf: { $0.appBundleID }
        )
        XCTAssertEqual(fired.map(\.name), ["Cmd-R"])
    }

    func testResolverMatchesTrackpadGestureByPayload() {
        let items = [
            Trigger(name: "Tap", input: .trackpadGesture(.twoFingerTap)),
            Trigger(name: "Swipe", input: .trackpadGesture(.twoFingerSwipeUp)),
        ]
        let fired = TriggerResolver.resolve(
            items,
            payload: TrackpadGesture.twoFingerTap,
            frontBundleID: nil,
            payloadOf: { trigger -> TrackpadGesture? in
                if case .trackpadGesture(let value) = trigger.input { return value }
                return nil
            },
            appBundleIDOf: { $0.appBundleID }
        )
        XCTAssertEqual(fired.map(\.name), ["Tap"])
    }

    // MARK: - Force quit target selection
    //
    // The dangerous part of "force quit" is choosing what to kill. These cover
    // the rule directly, including the case that would otherwise let the app
    // SIGKILL itself.

    private typealias Candidate = ActionExecutor.ForceQuitCandidate

    private func candidates() -> [Candidate] {
        [
            Candidate(pid: 100, bundleID: "com.example.front"),
            Candidate(pid: 200, bundleID: "com.example.other"),
            Candidate(pid: 300, bundleID: "com.kyw.allofmacos"),
        ]
    }

    func testForceQuitTargetsTheConfiguredApp() {
        let targets = ActionExecutor.forceQuitTargets(
            candidates: candidates(),
            configuredBundleID: "com.example.other",
            frontmostBundleID: "com.example.front",
            ownPID: 300,
            ownBundleID: "com.kyw.allofmacos"
        )
        XCTAssertEqual(targets.map(\.pid), [200], "a named app wins over the frontmost one")
    }

    func testForceQuitFallsBackToTheFrontmostAppWhenNothingIsConfigured() {
        for empty in [nil, ""] {
            let targets = ActionExecutor.forceQuitTargets(
                candidates: candidates(),
                configuredBundleID: empty,
                frontmostBundleID: "com.example.front",
                ownPID: 300,
                ownBundleID: "com.kyw.allofmacos"
            )
            XCTAssertEqual(targets.map(\.pid), [100], "empty target means the frontmost app")
        }
    }

    func testForceQuitNeverTargetsItselfByPID() {
        let targets = ActionExecutor.forceQuitTargets(
            candidates: candidates(),
            configuredBundleID: nil,
            // Even if we are somehow reported as frontmost.
            frontmostBundleID: "com.kyw.allofmacos",
            ownPID: 300,
            ownBundleID: "com.kyw.allofmacos"
        )
        XCTAssertTrue(targets.isEmpty, "the gesture engine must not kill itself")
    }

    func testForceQuitNeverTargetsItselfByBundleID() {
        // Same bundle, different pid — still us.
        let targets = ActionExecutor.forceQuitTargets(
            candidates: [Candidate(pid: 999, bundleID: "com.kyw.allofmacos")],
            configuredBundleID: "com.kyw.allofmacos",
            frontmostBundleID: nil,
            ownPID: 300,
            ownBundleID: "com.kyw.allofmacos"
        )
        XCTAssertTrue(targets.isEmpty, "own bundle id is excluded regardless of pid")
    }

    func testForceQuitWithNoMatchingAppKillsNothing() {
        let targets = ActionExecutor.forceQuitTargets(
            candidates: candidates(),
            configuredBundleID: "com.example.absent",
            frontmostBundleID: "com.example.front",
            ownPID: 300,
            ownBundleID: "com.kyw.allofmacos"
        )
        XCTAssertTrue(targets.isEmpty, "a name that matches nothing must not fall through to the frontmost app")
    }

    func testForceQuitWithNoFrontmostAppKillsNothing() {
        let targets = ActionExecutor.forceQuitTargets(
            candidates: candidates(),
            configuredBundleID: nil,
            frontmostBundleID: nil,
            ownPID: 300,
            ownBundleID: "com.kyw.allofmacos"
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testForceQuitActionIsAvailableAndCategorised() {
        XCTAssertEqual(ActionType.forceQuitApplication.category, .applicationControl)
        XCTAssertTrue(ActionType.allCases.contains(.forceQuitApplication))
        XCTAssertEqual(ActionType.forceQuitApplication.rawValue, "Force Quit Application")
        // Distinct from the polite quit, which is what the gesture is for.
        XCTAssertNotEqual(ActionType.forceQuitApplication, .quitApplication)
    }
}
