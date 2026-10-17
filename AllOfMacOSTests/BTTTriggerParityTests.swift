import XCTest
import AppKit
@testable import AllOfMacOS

/// Trigger-side BTT parity: suppression, trigger-level options, keyboard hold
/// phases and Normal Mouse recognition. Everything is driven by injected clocks
/// and synthetic events — no real input, sleep, or system state is touched.
final class BTTTriggerParityTests: XCTestCase {

    private func drain(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    private func isolatedDefaults() -> UserDefaults {
        let name = "BTTTriggerParityTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    override func tearDown() {
        ActionExecutor.onActionExecuted = nil
        ActionExecutor.registerTriggers([])
        TriggerSuppression.shared.resume()
        TriggerGate.suppression = { TriggerSuppression.shared }
        TriggerGate.schedule = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        super.tearDown()
    }

    // MARK: - 1. Suppression

    private final class Env {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var front: String? = "com.example.front"
        var modifiers: UInt = 0
        var sinceKey: TimeInterval = .infinity
    }
    private func makeSuppression(_ env: Env, defaults: UserDefaults? = nil) -> TriggerSuppression {
        TriggerSuppression(defaults: defaults ?? isolatedDefaults(),
                           now: { env.now }, frontmostBundleID: { env.front },
                           heldModifiers: { env.modifiers }, secondsSinceLastKeyDown: { env.sinceKey },
                           schedulesExpiry: false)
    }

    func testTimedPauseBlocksEverythingThenExpires() {
        let env = Env(); let s = makeSuppression(env)
        XCTAssertNil(s.reason(for: .trackpad))
        s.pause(for: 300)
        for kind in [TriggerSuppressionKind.trackpad, .keyboard, .mouse, .drawing, .system] {
            XCTAssertEqual(s.reason(for: kind), .paused(until: env.now.addingTimeInterval(300)))
        }
        XCTAssertTrue(s.isPaused)
        env.now = env.now.addingTimeInterval(299.9)
        XCTAssertFalse(s.allows(kind: .keyboard))
        env.now = env.now.addingTimeInterval(0.2)
        XCTAssertTrue(s.allows(kind: .keyboard), "pause must lapse on its own")
        XCTAssertFalse(s.isPaused)
        XCTAssertNil(s.statusDescription)
    }

    func testPauseUntilResumedAndResume() {
        let env = Env(); let s = makeSuppression(env)
        s.pauseUntilResumed()
        env.now = env.now.addingTimeInterval(86_400 * 30)
        XCTAssertEqual(s.reason(for: .system), .paused(until: nil))
        s.pause(for: 5) // must not shorten an indefinite pause
        XCTAssertTrue(s.pause.indefinite)
        s.resume()
        XCTAssertNil(s.reason(for: .system))
        XCTAssertNil(s.statusDescription)
    }

    func testShorterPauseNeverShortensLongerOne() {
        let env = Env(); let s = makeSuppression(env)
        s.pause(for: 3600); s.pause(for: 60)
        XCTAssertEqual(s.pause.until, env.now.addingTimeInterval(3600))
        s.pause(for: 0); s.pause(for: -4); s.pause(for: .infinity); s.pause(for: .nan)
        XCTAssertEqual(s.pause.until, env.now.addingTimeInterval(3600), "invalid durations are ignored")
    }

    func testPerAppPauseOnlyAppliesWhileThatAppIsFrontmost() {
        let env = Env(); let s = makeSuppression(env)
        s.pauseApp("com.example.game")
        env.front = "com.example.front"
        XCTAssertNil(s.reason(for: .mouse))
        env.front = "com.example.game"
        XCTAssertEqual(s.reason(for: .mouse), .pausedForApp("com.example.game"))
        XCTAssertEqual(s.reason(for: .keyboard), .pausedForApp("com.example.game"))
        s.resumeApp("com.example.game")
        XCTAssertNil(s.reason(for: .mouse))
        env.front = "com.example.front"
        XCTAssertEqual(s.pauseFrontmostApp(), "com.example.front")
        XCTAssertEqual(s.reason(for: .trackpad), .pausedForApp("com.example.front"))
        s.toggleApp("com.example.front")
        XCTAssertNil(s.reason(for: .trackpad))
        s.pauseApp("   ")
        XCTAssertTrue(s.pause.appBundleIDs.isEmpty, "blank bundle ids are ignored")
    }

    func testModifierHoldDisablesPointerFamiliesButNotKeyboardOrSystem() {
        let env = Env(); let s = makeSuppression(env)
        s.settings.disableWhileHoldingModifiers = NSEvent.ModifierFlags([.command, .option]).rawValue
        env.modifiers = 0
        XCTAssertNil(s.reason(for: .trackpad))
        env.modifiers = NSEvent.ModifierFlags.shift.rawValue
        XCTAssertNil(s.reason(for: .trackpad), "an unlisted modifier does nothing")
        env.modifiers = NSEvent.ModifierFlags([.shift, .option]).rawValue | 0x100 // device-dependent noise bits
        XCTAssertEqual(s.reason(for: .trackpad), .holdingModifiers)
        XCTAssertEqual(s.reason(for: .mouse), .holdingModifiers)
        XCTAssertEqual(s.reason(for: .drawing), .holdingModifiers)
        XCTAssertNil(s.reason(for: .keyboard), "a modifier-disables-keyboard rule would make ⌘-shortcuts impossible")
        XCTAssertNil(s.reason(for: .system))
    }

    func testAfterKeystrokeWindowAppliesToTrackpadOnlyAndHonoursBoundary() {
        let env = Env(); let s = makeSuppression(env)
        s.settings.disableTrackpadAfterKeyEnabled = true
        s.settings.disableTrackpadAfterKeyMs = 400
        env.sinceKey = 0.399
        XCTAssertEqual(s.reason(for: .trackpad), .recentKeystroke)
        XCTAssertNil(s.reason(for: .mouse))
        XCTAssertNil(s.reason(for: .keyboard))
        env.sinceKey = 0.4
        XCTAssertNil(s.reason(for: .trackpad), "window end is exclusive")
        // Disabled setting never consults the key age.
        s.settings.disableTrackpadAfterKeyEnabled = false
        env.sinceKey = 0
        XCTAssertNil(s.reason(for: .trackpad))
        // An absurd stored value is clamped, not trusted.
        XCTAssertEqual(TriggerSuppression.clamp(1_000_000), 5000)
        XCTAssertEqual(TriggerSuppression.clamp(-3), 50)
    }

    func testSettingsPersistAndPauseStateDoesNot() {
        let defaults = isolatedDefaults(); let env = Env()
        let first = makeSuppression(env, defaults: defaults)
        first.settings.disableWhileHoldingModifiers = NSEvent.ModifierFlags.control.rawValue
        first.settings.disableTrackpadAfterKeyEnabled = true
        first.settings.disableTrackpadAfterKeyMs = 750
        first.pauseUntilResumed(); first.pauseApp("com.example.x")
        let second = makeSuppression(env, defaults: defaults)
        XCTAssertEqual(second.settings, first.settings)
        XCTAssertFalse(second.isPaused, "runtime pause state must not survive a relaunch")
        XCTAssertTrue(second.pause.appBundleIDs.isEmpty)
    }

    func testSettingsDecodeFromOldOrEmptyJSON() throws {
        let empty = try JSONDecoder().decode(TriggerSuppressionSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, TriggerSuppressionSettings())
        let partial = try JSONDecoder().decode(TriggerSuppressionSettings.self,
                                               from: Data(#"{"disableTrackpadAfterKeyEnabled":true}"#.utf8))
        XCTAssertTrue(partial.disableTrackpadAfterKeyEnabled)
        XCTAssertEqual(partial.disableTrackpadAfterKeyMs, 500)
    }

    func testSharedStorageIsIsolatedUnderTests() {
        // The shared instance and timing store must not be the user's real defaults.
        let before = UserDefaults.standard.data(forKey: TriggerSuppression.settingsKey)
        TriggerSuppression.shared.settings.disableTrackpadAfterKeyMs = 1234
        XCTAssertEqual(UserDefaults.standard.data(forKey: TriggerSuppression.settingsKey), before)
        XCTAssertNotEqual(TriggerTimingSettings.store, UserDefaults.standard)
        TriggerTimingSettings.store.set(777, forKey: TriggerTimingSettings.keyboardLongPressKey)
        XCTAssertNil(UserDefaults.standard.object(forKey: TriggerTimingSettings.keyboardLongPressKey))
        TriggerTimingSettings.store.removeObject(forKey: TriggerTimingSettings.keyboardLongPressKey)
        TriggerSuppression.shared.settings = TriggerSuppressionSettings()
    }

    func testSuppressionKindMapping() {
        XCTAssertEqual(TriggerSuppressionKind(.trackpadGesture(.twoFingerTap)), .trackpad)
        XCTAssertEqual(TriggerSuppressionKind(.mouseButton(.button4)), .mouse)
        XCTAssertEqual(TriggerSuppressionKind(.mouse(MouseTriggerSpec(button: 0, kind: .click))), .mouse)
        XCTAssertEqual(TriggerSuppressionKind(.keyboardShortcut(KeyboardShortcut(keyCode: 0, modifiers: .command))), .keyboard)
        XCTAssertEqual(TriggerSuppressionKind(.namedTrigger("x")), .system)
        XCTAssertEqual(TriggerSuppressionKind(.drawingPattern("x")), .drawing)
        XCTAssertEqual(TriggerSuppressionKind(nil), .system)
    }

    func testDisabledOrDeletedTriggerCannotExecuteStaleFallback() {
        var trigger = Trigger(name: "stale", input: .mouseButton(.button4))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        trigger.isEnabled = false
        ActionExecutor.registerTriggers([trigger])
        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 0)
        trigger.isEnabled = true
        ActionExecutor.registerTriggers([trigger])
        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 1)
        ActionExecutor.registerTriggers([])
        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 1)
    }

    func testGateBlocksActionExecutorFireWhilePaused() {
        let env = Env(); let s = makeSuppression(env)
        TriggerGate.suppression = { s }
        var trigger = Trigger(name: "t", input: .mouseButton(.button4))
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])
        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 1)
        s.pause(for: 60)
        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 1, "paused AOM must not run actions")
        s.resume()
        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 2)
    }

    // MARK: - 2. Trigger-level options

    func testOldTriggerJSONDecodesWithNewFieldDefaults() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Old","input":{"mouseButton":{"_0":"Button 4"}},"actions":[],"isEnabled":true,"order":3}
        """
        let trigger = try JSONDecoder().decode(Trigger.self, from: Data(json.utf8))
        XCTAssertEqual(trigger.notes, "")
        XCTAssertEqual(trigger.delayBeforeTriggeringMs, 0)
        XCTAssertEqual(trigger.minHoldMs, 0)
        XCTAssertEqual(trigger.maxHoldMs, 0)
        XCTAssertNil(trigger.colorLabel)
        XCTAssertNil(trigger.folder)
        XCTAssertEqual(trigger.keyboardPhase, .keyDown)
        XCTAssertEqual(trigger.input, .mouseButton(.button4))
    }

    func testNewTriggerFieldsRoundTripAndNegativeValuesClamp() throws {
        var trigger = Trigger(name: "n", input: .namedTrigger("x"))
        trigger.notes = "remember"; trigger.delayBeforeTriggeringMs = 250
        trigger.minHoldMs = 100; trigger.maxHoldMs = 900
        trigger.colorLabel = "#FF8800"; trigger.folder = "Work"
        trigger.keyboardPhase = .quickRelease
        let decoded = try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(trigger))
        XCTAssertEqual(decoded, trigger)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as! [String: Any]
        json["delayBeforeTriggeringMs"] = -50; json["minHoldMs"] = -1
        let clamped = try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(clamped.delayBeforeTriggeringMs, 0)
        XCTAssertEqual(clamped.minHoldMs, 0)
    }

    func testOldKeyboardPhaseRawValuesStillDecode() throws {
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPhase.self, from: Data(#""Key up""#.utf8)), .keyUp)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPhase.self, from: Data(#""Key down""#.utf8)), .keyDown)
        XCTAssertEqual(KeyboardPhase.allCases.map(\.rawValue), ["Key down", "Key up", "Long press", "Quick release"])
    }

    func testDelayBeforeTriggeringDefersThenRunsOnce() {
        let env = Env(); let s = makeSuppression(env)
        TriggerGate.suppression = { s }
        var pending: [() -> Void] = []
        var delays: [TimeInterval] = []
        TriggerGate.schedule = { delay, work in delays.append(delay); pending.append(work) }
        var trigger = Trigger(name: "d", input: .mouseButton(.button5))
        trigger.delayBeforeTriggeringMs = 750
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])

        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 0, "must wait for the delay")
        XCTAssertEqual(delays, [0.75])
        pending.removeFirst()()
        XCTAssertEqual(fired, 1)
        // The delay applies again to the next independent firing.
        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(pending.count, 1)
    }

    func testDelayedTriggerIsRecheckedForSuppressionAndDeletion() {
        let env = Env(); let s = makeSuppression(env)
        TriggerGate.suppression = { s }
        var pending: [() -> Void] = []
        TriggerGate.schedule = { _, work in pending.append(work) }
        var trigger = Trigger(name: "d", input: .mouseButton(.button5))
        trigger.delayBeforeTriggeringMs = 100
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        var fired = 0
        ActionExecutor.onActionExecuted = { _ in fired += 1 }
        ActionExecutor.registerTriggers([trigger])

        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        s.pause(for: 60) // paused during the wait
        pending.removeFirst()()
        XCTAssertEqual(fired, 0)
        s.resume()

        ActionExecutor.fire(triggerID: trigger.id, fallbackActions: trigger.actions)
        ActionExecutor.registerTriggers([]) // deleted during the wait
        pending.removeFirst()()
        XCTAssertEqual(fired, 0)
    }

    // MARK: - 2b. Keyboard hold plans (pure)

    func testHoldPlans() {
        XCTAssertEqual(TriggerKeyHold.plan(phase: .keyDown, minHoldMs: 0, longPressMs: 500), .immediately)
        XCTAssertEqual(TriggerKeyHold.plan(phase: .keyDown, minHoldMs: 200, longPressMs: 500), .afterHold(ms: 200))
        XCTAssertEqual(TriggerKeyHold.plan(phase: .longPress, minHoldMs: 0, longPressMs: 500), .afterHold(ms: 500))
        XCTAssertEqual(TriggerKeyHold.plan(phase: .longPress, minHoldMs: 900, longPressMs: 500), .afterHold(ms: 900),
                       "min hold can only lengthen a long press")
        XCTAssertEqual(TriggerKeyHold.plan(phase: .keyUp, minHoldMs: 0, longPressMs: 500), .onRelease)
        XCTAssertEqual(TriggerKeyHold.plan(phase: .quickRelease, minHoldMs: 0, longPressMs: 500), .onRelease)
    }

    func testReleaseAcceptanceBoundaries() {
        func accepts(_ p: KeyboardPhase, _ held: Int, min: Int = 0, max: Int = 0, quick: Int = 250) -> Bool {
            TriggerKeyHold.acceptsRelease(phase: p, heldMs: held, minHoldMs: min, maxHoldMs: max, quickReleaseMaxMs: quick)
        }
        XCTAssertTrue(accepts(.keyUp, 0))
        XCTAssertTrue(accepts(.keyUp, 100, min: 100, max: 300))
        XCTAssertTrue(accepts(.keyUp, 300, min: 100, max: 300))
        XCTAssertFalse(accepts(.keyUp, 99, min: 100, max: 300))
        XCTAssertFalse(accepts(.keyUp, 301, min: 100, max: 300))
        XCTAssertTrue(accepts(.keyUp, 99_999), "max 0 means unlimited")
        XCTAssertTrue(accepts(.quickRelease, 250))
        XCTAssertFalse(accepts(.quickRelease, 251))
        XCTAssertFalse(accepts(.quickRelease, 40, min: 50))
        XCTAssertFalse(accepts(.keyDown, 10))
        XCTAssertFalse(accepts(.longPress, 10))
    }

    func testTimingSettingsClampAndDefaults() {
        let d = isolatedDefaults()
        XCTAssertEqual(TriggerTimingSettings.keyboardLongPressMs(d), 500)
        XCTAssertEqual(TriggerTimingSettings.keyboardQuickReleaseMs(d), 250)
        XCTAssertEqual(TriggerTimingSettings.mouseLongPressMs(d), 500)
        XCTAssertEqual(TriggerTimingSettings.mouseDragThresholdPx(d), 40)
        d.set(1, forKey: TriggerTimingSettings.keyboardLongPressKey)
        XCTAssertEqual(TriggerTimingSettings.keyboardLongPressMs(d), 100)
        d.set(10_000_000, forKey: TriggerTimingSettings.keyboardQuickReleaseKey)
        XCTAssertEqual(TriggerTimingSettings.keyboardQuickReleaseMs(d), 2000)
        XCTAssertEqual(TriggerTimingSettings.mouseMultiClickMs(d, system: 0.5), 500)
        XCTAssertEqual(TriggerTimingSettings.mouseMultiClickMs(d, system: 9), 1500)
    }

    // MARK: - 2c. Keyboard monitor phases (injected clock/scheduler)

    private final class KeyRig {
        var time: TimeInterval = 100
        var timers: [(TimeInterval, () -> Void)] = []
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        var fired = 0
        init(_ triggers: [Trigger], defaults: UserDefaults) {
            monitor.clock = { [unowned self] in time }
            monitor.scheduler = { [unowned self] delay, work in timers.append((delay, work)) }
            monitor.timingDefaults = defaults
            ActionExecutor.onActionExecuted = { [unowned self] _ in fired += 1 }
            ActionExecutor.registerTriggers(triggers)
            monitor.registerTriggers(triggers)
        }
    }
    private func keyTrigger(_ phase: KeyboardPhase, min: Int = 0, max: Int = 0) -> Trigger {
        var t = Trigger(name: "k", input: .keyboardShortcut(KeyboardShortcut(keyCode: 40, modifiers: [.control, .option])))
        t.keyboardPhase = phase; t.minHoldMs = min; t.maxHoldMs = max
        t.actions = [TriggerAction(actionType: .showHUD)]
        return t
    }
    private let mods: NSEvent.ModifierFlags = [.control, .option]

    func testKeyDownWithoutHoldFiresImmediately() {
        let rig = KeyRig([keyTrigger(.keyDown)], defaults: isolatedDefaults())
        XCTAssertTrue(rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true))
        drain()
        XCTAssertEqual(rig.fired, 1)
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: false)
        drain()
        XCTAssertEqual(rig.fired, 1)
    }

    func testKeyDownWithMinHoldWaitsAndCancelsOnEarlyRelease() {
        let rig = KeyRig([keyTrigger(.keyDown, min: 300)], defaults: isolatedDefaults())
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true)
        drain()
        XCTAssertEqual(rig.fired, 0)
        XCTAssertEqual(rig.timers.map(\.0), [0.3])
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: false)
        rig.timers.removeFirst().1(); drain()
        XCTAssertEqual(rig.fired, 0, "released before the minimum hold")

        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true)
        rig.timers.removeFirst().1(); drain()
        XCTAssertEqual(rig.fired, 1, "still held after 300 ms")
    }

    func testLongPressUsesGlobalDurationAndFiresOnce() {
        let d = isolatedDefaults(); d.set(800, forKey: TriggerTimingSettings.keyboardLongPressKey)
        let rig = KeyRig([keyTrigger(.longPress)], defaults: d)
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true)
        XCTAssertEqual(rig.timers.map(\.0), [0.8])
        rig.timers.removeFirst().1(); drain()
        XCTAssertEqual(rig.fired, 1)
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: false); drain()
        XCTAssertEqual(rig.fired, 1, "release after a long press fires nothing more")
    }

    func testLongPressNotFiredWhenReleasedEarly() {
        let rig = KeyRig([keyTrigger(.longPress)], defaults: isolatedDefaults())
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true)
        rig.time += 0.1
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: false)
        rig.timers.removeFirst().1(); drain()
        XCTAssertEqual(rig.fired, 0)
    }

    func testQuickReleaseFiresOnlyForShortPresses() {
        let rig = KeyRig([keyTrigger(.quickRelease)], defaults: isolatedDefaults())
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true)
        rig.time += 0.2
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: false); drain()
        XCTAssertEqual(rig.fired, 1)
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true)
        rig.time += 0.4
        _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: false); drain()
        XCTAssertEqual(rig.fired, 1, "a 400 ms press is not a quick release")
    }

    func testKeyUpMinMaxHoldWindow() {
        let rig = KeyRig([keyTrigger(.keyUp, min: 200, max: 600)], defaults: isolatedDefaults())
        for (held, expected) in [(0.1, 0), (0.3, 1), (0.9, 1)] as [(Double, Int)] {
            _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true)
            rig.time += held
            _ = rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: false); drain()
            XCTAssertEqual(rig.fired, expected, "held \(held)s")
        }
    }

    func testPausedKeyboardDoesNotSwallowOrFire() {
        let env = Env(); let s = makeSuppression(env)
        TriggerGate.suppression = { s }
        let rig = KeyRig([keyTrigger(.keyDown)], defaults: isolatedDefaults())
        // KeyboardMonitor consults the shared instance, so pause that one.
        TriggerSuppression.shared.pause(for: 60)
        XCTAssertFalse(rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true), "a paused AOM must not swallow keys")
        drain()
        XCTAssertEqual(rig.fired, 0)
        TriggerSuppression.shared.resume()
        XCTAssertTrue(rig.monitor.handleInput(keyCode: 40, modifiers: mods, isDown: true))
    }
}

// MARK: - 3. Normal Mouse

final class BTTMouseParityTests: XCTestCase {

    private let cmd = NSEvent.ModifierFlags.command.rawValue
    private let opt = NSEvent.ModifierFlags.option.rawValue


    private func recognizer(_ wanted: [(Int, MouseTriggerKind)], config: MouseGestureRecognizer.Config = .init()) -> MouseGestureRecognizer {
        MouseGestureRecognizer(config: config, wanted: Set(wanted.map { MouseTriggerSpec(button: $0.0, kind: $0.1) }))
    }
    private func spec(_ b: Int, _ k: MouseTriggerKind) -> MouseTriggerSpec { MouseTriggerSpec(button: b, kind: k) }

    // MARK: Model

    func testSpecNormalizationAndNames() {
        XCTAssertEqual(MouseTriggerSpec(button: 99, kind: .click).button, MouseTriggerSpec.maxButton)
        XCTAssertEqual(MouseTriggerSpec(button: -4, kind: .click).button, 0)
        XCTAssertEqual(MouseTriggerSpec(button: 7, kind: .scrollUp).button, 0, "scroll has no button")
        XCTAssertEqual(spec(0, .click).displayName, "Left Click")
        XCTAssertEqual(spec(1, .doubleClick).displayName, "Right Double Click")
        XCTAssertEqual(spec(2, .longPress).displayName, "Middle Long Press")
        XCTAssertEqual(spec(11, .tripleClick).displayName, "Button 12 Triple Click")
        XCTAssertEqual(spec(0, .scrollLeft).displayName, "Scroll Left")
        XCTAssertEqual(TriggerInput.mouse(spec(3, .dragUp)).category, .normalMouse)
        XCTAssertTrue(MouseTriggerSpec.pickerButtons.contains(11), "buttons up to 12+ are selectable")
    }

    func testLegacyMouseButtonStillDecodesAndKeepsMeaning() throws {
        let legacy = Data(#"{"mouseButton":{"_0":"Middle Click (Button 3)"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(TriggerInput.self, from: legacy), .mouseButton(.button3))
        XCTAssertEqual(MouseTriggerSpec(legacy: .button3), spec(2, .click))
        XCTAssertEqual(MouseTriggerSpec(legacy: .button7), spec(6, .click))
    }

    func testNewMouseInputRoundTripsAndOldJSONSampleForSpecDecodesWithDefaults() throws {
        let input = TriggerInput.mouse(spec(5, .doubleClick))
        XCTAssertEqual(try JSONDecoder().decode(TriggerInput.self, from: JSONEncoder().encode(input)), input)
        // A spec with missing keys decodes with defaults rather than failing the preset.
        let sparse = try JSONDecoder().decode(MouseTriggerSpec.self, from: Data("{}".utf8))
        XCTAssertEqual(sparse, spec(0, .click))
    }

    func testLeftRightAndScrollRequireModifiersAtCreation() {
        for kind in [MouseTriggerKind.click, .doubleClick, .tripleClick, .longPress, .dragLeft] {
            XCTAssertNotNil(TriggerValidation.problem(for: .mouse(spec(0, kind)), requiredModifiers: nil), "left \(kind)")
            XCTAssertNotNil(TriggerValidation.problem(for: .mouse(spec(1, kind)), requiredModifiers: 0), "right \(kind)")
            XCTAssertNil(TriggerValidation.problem(for: .mouse(spec(0, kind)), requiredModifiers: cmd))
        }
        XCTAssertNotNil(TriggerValidation.problem(for: .mouse(spec(0, .scrollUp)), requiredModifiers: nil))
        XCTAssertNil(TriggerValidation.problem(for: .mouse(spec(0, .scrollUp)), requiredModifiers: opt))
        // Middle and extra buttons are safe without a modifier, and legacy buttons never gain a restriction.
        XCTAssertNil(TriggerValidation.problem(for: .mouse(spec(2, .click)), requiredModifiers: nil))
        XCTAssertNil(TriggerValidation.problem(for: .mouse(spec(8, .longPress)), requiredModifiers: nil))
        XCTAssertNil(TriggerValidation.problem(for: .mouseButton(.button4), requiredModifiers: nil))
        // A non-modifier bit alone does not count as a modifier.
        XCTAssertNotNil(TriggerValidation.problem(for: .mouse(spec(0, .click)), requiredModifiers: 0x100))
    }

    // MARK: Click counting

    func testSingleClickFiresOnEveryRapidPressWhenNoMultiClickRegistered() {
        var r = recognizer([(2, .click)])
        XCTAssertEqual(r.buttonDown(2, x: 5, y: 5, time: 1, modifiers: 0).map(\.spec), [spec(2, .click)])
        _ = r.buttonUp(2, time: 1.05)
        XCTAssertEqual(r.buttonDown(2, x: 5, y: 5, time: 1.1, modifiers: 0).map(\.spec), [spec(2, .click)])
        XCTAssertNil(r.nextDeadline)
    }

    func testDoubleClickCountsAndSingleWaitsWhenBothRegistered() {
        var r = recognizer([(2, .click), (2, .doubleClick)])
        XCTAssertTrue(r.buttonDown(2, x: 0, y: 0, time: 10, modifiers: 0).isEmpty, "single must wait for a possible second click")
        _ = r.buttonUp(2, time: 10.05)
        XCTAssertEqual(r.nextDeadline, 10.5)
        XCTAssertEqual(r.buttonDown(2, x: 1, y: 1, time: 10.2, modifiers: 0).map(\.spec), [spec(2, .doubleClick)])
        _ = r.buttonUp(2, time: 10.25)
        XCTAssertTrue(r.poll(now: 99).isEmpty, "the superseded single click must not fire later")
    }

    func testSingleClickFiresAfterInterval() {
        var r = recognizer([(2, .click), (2, .doubleClick)])
        _ = r.buttonDown(2, x: 0, y: 0, time: 10, modifiers: cmd)
        _ = r.buttonUp(2, time: 10.05)
        XCTAssertTrue(r.poll(now: 10.49).isEmpty)
        let out = r.poll(now: 10.5)
        XCTAssertEqual(out, [.init(spec: spec(2, .click), modifiers: cmd)])
        XCTAssertTrue(r.poll(now: 11).isEmpty, "fires once")
    }

    func testTripleClickAndWraparound() {
        var r = recognizer([(3, .click), (3, .doubleClick), (3, .tripleClick)])
        var results: [[MouseTriggerSpec]] = []
        for i in 0..<4 {
            results.append(r.buttonDown(3, x: 0, y: 0, time: 20 + Double(i) * 0.15, modifiers: 0).map(\.spec))
            _ = r.buttonUp(3, time: 20 + Double(i) * 0.15 + 0.05)
        }
        XCTAssertEqual(results[0], [])
        XCTAssertEqual(results[1], [])
        XCTAssertEqual(results[2], [spec(3, .tripleClick)])
        XCTAssertEqual(results[3], [], "fourth press starts a fresh sequence")
        XCTAssertEqual(r.poll(now: 30).map(\.spec), [spec(3, .click)])
    }

    func testSlowOrDistantPressesDoNotChain() {
        var r = recognizer([(2, .doubleClick)])
        XCTAssertTrue(r.buttonDown(2, x: 0, y: 0, time: 1, modifiers: 0).isEmpty)
        _ = r.buttonUp(2, time: 1.05)
        XCTAssertTrue(r.buttonDown(2, x: 0, y: 0, time: 1.6, modifiers: 0).isEmpty, "gap above the interval restarts the count")
        _ = r.buttonUp(2, time: 1.65)
        XCTAssertTrue(r.buttonDown(2, x: 300, y: 0, time: 1.7, modifiers: 0).isEmpty, "far-apart press restarts the count")
        _ = r.buttonUp(2, time: 1.75)
        XCTAssertEqual(r.buttonDown(2, x: 301, y: 0, time: 1.9, modifiers: 0).map(\.spec), [spec(2, .doubleClick)])
    }

    func testButtonsCountIndependently() {
        var r = recognizer([(2, .doubleClick), (3, .doubleClick)])
        XCTAssertTrue(r.buttonDown(2, x: 0, y: 0, time: 1, modifiers: 0).isEmpty)
        XCTAssertTrue(r.buttonDown(3, x: 0, y: 0, time: 1.1, modifiers: 0).isEmpty, "other button must not complete the double")
        XCTAssertEqual(r.buttonDown(2, x: 0, y: 0, time: 1.2, modifiers: 0).map(\.spec), [spec(2, .doubleClick)])
    }

    // MARK: Long press

    func testLongPressFiresAtDeadlineOnlyWhileHeld() {
        var cfg = MouseGestureRecognizer.Config(); cfg.longPressDuration = 0.6
        var r = recognizer([(4, .longPress)], config: cfg)
        _ = r.buttonDown(4, x: 0, y: 0, time: 5, modifiers: opt)
        XCTAssertEqual(r.nextDeadline, 5.6)
        XCTAssertTrue(r.poll(now: 5.59).isEmpty)
        XCTAssertEqual(r.poll(now: 5.6), [.init(spec: spec(4, .longPress), modifiers: opt)])
        XCTAssertTrue(r.poll(now: 9).isEmpty, "only once per press")
        XCTAssertNil(r.nextDeadline)

        var early = recognizer([(4, .longPress)], config: cfg)
        _ = early.buttonDown(4, x: 0, y: 0, time: 5, modifiers: 0)
        _ = early.buttonUp(4, time: 5.3)
        XCTAssertTrue(early.poll(now: 9).isEmpty, "released early")
    }

    func testClickIsDeferredToReleaseWhenLongPressSharesTheButtonAndSuppressedAfterHold() {
        var r = recognizer([(2, .click), (2, .longPress)])
        XCTAssertTrue(r.buttonDown(2, x: 0, y: 0, time: 1, modifiers: 0).isEmpty, "click waits for release")
        XCTAssertEqual(r.buttonUp(2, time: 1.2).map(\.spec), [spec(2, .click)])
        _ = r.buttonDown(2, x: 0, y: 0, time: 2, modifiers: 0)
        XCTAssertEqual(r.poll(now: 2.5).map(\.spec), [spec(2, .longPress)])
        XCTAssertTrue(r.buttonUp(2, time: 3).isEmpty, "a long press is not also a click")
    }

    // MARK: Drag

    func testDragDirectionsUseDominantAxisAndThreshold() {
        let cases: [(Double, Double, MouseTriggerKind)] = [
            (0, -60, .dragUp), (0, 60, .dragDown), (-60, 5, .dragLeft), (60, -5, .dragRight), (45, 50, .dragDown)]
        for (dx, dy, expected) in cases {
            var r = recognizer([(2, .dragUp), (2, .dragDown), (2, .dragLeft), (2, .dragRight)])
            _ = r.buttonDown(2, x: 100, y: 100, time: 1, modifiers: cmd)
            XCTAssertTrue(r.moved(x: 100 + dx * 0.5, y: 100 + dy * 0.5, time: 1.01).isEmpty, "below threshold: \(expected)")
            XCTAssertEqual(r.moved(x: 100 + dx, y: 100 + dy, time: 1.02).map(\.spec), [spec(2, expected)])
            XCTAssertTrue(r.moved(x: 100 + dx * 2, y: 100 + dy * 2, time: 1.03).isEmpty, "discrete: once per press")
        }
    }

    func testOnlyRegisteredDirectionFiresAndDragCancelsClick() {
        var r = recognizer([(2, .dragUp), (2, .click)])
        _ = r.buttonDown(2, x: 0, y: 0, time: 1, modifiers: 0)
        XCTAssertTrue(r.moved(x: 90, y: 0, time: 1.1).isEmpty, "drag right was not registered")
        XCTAssertTrue(r.buttonUp(2, time: 1.2).isEmpty, "a drag is not a click")
        // Without a drag trigger, movement must not disturb a click.
        var plain = recognizer([(2, .click)])
        XCTAssertEqual(plain.buttonDown(2, x: 0, y: 0, time: 1, modifiers: 0).count, 1)
        XCTAssertTrue(plain.moved(x: 500, y: 500, time: 1.1).isEmpty)
    }

    func testDragThresholdComesFromConfig() {
        var cfg = MouseGestureRecognizer.Config(); cfg.dragThreshold = 200
        var r = recognizer([(2, .dragLeft)], config: cfg)
        _ = r.buttonDown(2, x: 300, y: 0, time: 1, modifiers: 0)
        XCTAssertTrue(r.moved(x: 150, y: 0, time: 1.1).isEmpty)
        XCTAssertEqual(r.moved(x: 100, y: 0, time: 1.2).count, 1)
    }

    // MARK: Scroll

    func testScrollDirectionAccumulationAndRateLimit() {
        var r = recognizer([(0, .scrollUp), (0, .scrollDown), (0, .scrollRight)])
        XCTAssertTrue(r.scroll(dx: 0, dy: 10, time: 1, modifiers: opt).isEmpty, "below step")
        XCTAssertTrue(r.scroll(dx: 0, dy: 10, time: 1.01, modifiers: opt).isEmpty)
        XCTAssertEqual(r.scroll(dx: 0, dy: 12, time: 1.02, modifiers: opt), [.init(spec: spec(0, .scrollUp), modifiers: opt)])
        XCTAssertTrue(r.scroll(dx: 0, dy: 40, time: 1.03, modifiers: opt).isEmpty, "rate limited")
        XCTAssertEqual(r.scroll(dx: 0, dy: 40, time: 1.2, modifiers: opt).count, 1)
        // Reversal restarts accumulation in the other direction.
        XCTAssertTrue(r.scroll(dx: 0, dy: -20, time: 2, modifiers: opt).isEmpty)
        XCTAssertEqual(r.scroll(dx: 0, dy: -20, time: 2.01, modifiers: opt).map(\.spec), [spec(0, .scrollDown)])
        XCTAssertEqual(r.scroll(dx: 50, dy: 3, time: 3, modifiers: opt).map(\.spec), [spec(0, .scrollRight)])
        // Left was not registered.
        XCTAssertTrue(r.scroll(dx: -80, dy: 0, time: 4, modifiers: opt).isEmpty)
        XCTAssertTrue(r.scroll(dx: 0, dy: 0, time: 5, modifiers: opt).isEmpty)
    }

    // MARK: Monitor pipeline (resolver, modifiers, scope, suppression)

    private final class Rig {
        var time: TimeInterval = 100
        var fired: [MouseTriggerSpec] = []
        let monitor = MouseButtonMonitor()
        init(_ triggers: [Trigger], front: String? = "com.example.app") {
            monitor.clock = { [unowned self] in time }
            monitor.frontmostBundleID = { front }
            monitor.globalEnabled = { true }
            monitor.timingDefaults = UserDefaults(suiteName: "BTTMouseRig-\(UUID().uuidString)")!
            monitor.onFire = { [unowned self] in fired.append($0.spec) }
            monitor.registerEntries(triggers)
        }
        func down(_ b: Int, _ mods: UInt = 0, x: Double = 0, y: Double = 0) -> Bool {
            monitor.handle(MouseInputEvent(kind: .down, button: b, x: x, y: y, modifiers: mods, time: time))
        }
        func up(_ b: Int, _ mods: UInt = 0) -> Bool {
            monitor.handle(MouseInputEvent(kind: .up, button: b, modifiers: mods, time: time))
        }
        func drag(_ b: Int, x: Double, y: Double, _ mods: UInt = 0) -> Bool {
            monitor.handle(MouseInputEvent(kind: .dragged, button: b, x: x, y: y, modifiers: mods, time: time))
        }
        func scroll(dy: Double, _ mods: UInt) -> Bool {
            monitor.handle(MouseInputEvent(kind: .scroll, modifiers: mods, time: time, scrollDX: 0, scrollDY: dy))
        }
    }
    private func mouseTrigger(_ b: Int, _ k: MouseTriggerKind, mods: UInt? = nil, suppress: Bool = false, app: String? = nil) -> Trigger {
        var t = Trigger(name: "m", input: .mouse(spec(b, k)), appBundleID: app)
        t.requiredModifiers = mods; t.suppressClick = suppress
        t.actions = [TriggerAction(actionType: .showHUD)]
        return t
    }

    func testLeftClickTriggerOnlyFiresWithItsModifierAndOnlySwallowsThen() {
        let rig = Rig([mouseTrigger(0, .click, mods: cmd, suppress: true)])
        XCTAssertFalse(rig.down(0), "plain left click must pass through untouched")
        XCTAssertFalse(rig.up(0))
        XCTAssertTrue(rig.fired.isEmpty)
        XCTAssertTrue(rig.down(0, cmd), "matching click is swallowed")
        XCTAssertTrue(rig.up(0), "its release is swallowed too")
        XCTAssertEqual(rig.fired, [spec(0, .click)])
        XCTAssertFalse(rig.down(0, opt), "wrong modifier passes through")
        XCTAssertEqual(rig.fired.count, 1)
    }

    func testLeftClickWithoutModifierIsRejectedAtRegistration() {
        let rig = Rig([mouseTrigger(0, .click, mods: nil), mouseTrigger(1, .doubleClick, mods: 0), mouseTrigger(0, .scrollUp, mods: nil)])
        XCTAssertTrue(rig.monitor.entries.isEmpty, "unsafe triggers are never installed, even if they reach the monitor")
        XCTAssertFalse(rig.down(0))
    }

    func testSuppressClickOffNeverSwallows() {
        let rig = Rig([mouseTrigger(2, .doubleClick, suppress: false)])
        XCTAssertFalse(rig.down(2)); XCTAssertFalse(rig.up(2))
        rig.time += 0.1
        XCTAssertFalse(rig.down(2)); XCTAssertFalse(rig.up(2))
        XCTAssertEqual(rig.fired, [spec(2, .doubleClick)])
    }

    func testLegacyButtonKeepsImmediateFireAndSuppressClick() {
        var legacy = Trigger(name: "l", input: .mouseButton(.button4))
        legacy.suppressClick = true
        legacy.actions = [TriggerAction(actionType: .showHUD)]
        let rig = Rig([legacy])
        XCTAssertTrue(rig.down(3), "legacy swallow behavior preserved")
        XCTAssertEqual(rig.fired, [spec(3, .click)])
        XCTAssertTrue(rig.up(3))
        XCTAssertFalse(rig.down(4), "other buttons untouched")
    }

    func testAppScopedMouseTriggerShadowsGlobal() {
        let global = mouseTrigger(5, .click)
        let scoped = mouseTrigger(5, .click, app: "com.example.app")
        let rigIn = Rig([global, scoped])
        _ = rigIn.down(5)
        XCTAssertEqual(rigIn.fired.count, 1)
        let rigOut = Rig([scoped], front: "com.other")
        _ = rigOut.down(5)
        XCTAssertTrue(rigOut.fired.isEmpty)
    }

    func testMouseFreshDownRepairsLostUpBeforePassingNativeClick() {
        let rig = Rig([mouseTrigger(1, .click, mods: cmd, suppress: true)])
        XCTAssertTrue(rig.down(1, cmd))
        // A lost release must not cause the next ordinary click to lose its up.
        XCTAssertFalse(rig.down(1, 0))
        XCTAssertFalse(rig.up(1, 0))
    }

    func testMouseReregistrationPreservesPendingReleaseEvenWhenBindingIsRemoved() {
        let rig = Rig([mouseTrigger(1, .click, mods: cmd, suppress: true)])
        XCTAssertTrue(rig.down(1, cmd))
        rig.monitor.registerEntries([])
        XCTAssertTrue(rig.up(1, cmd))
        XCTAssertFalse(rig.down(1, cmd))
        XCTAssertFalse(rig.up(1, cmd))
    }

    func testPausedSuppressionLetsEverythingThrough() {
        let rig = Rig([mouseTrigger(2, .click, suppress: true)])
        TriggerSuppression.shared.pause(for: 60)
        defer { TriggerSuppression.shared.resume() }
        XCTAssertFalse(rig.down(2), "paused AOM must not swallow mouse buttons")
        XCTAssertTrue(rig.fired.isEmpty)
    }

    func testLongPressThroughMonitorUsesInjectedClock() {
        let rig = Rig([mouseTrigger(2, .longPress)])
        _ = rig.down(2)
        rig.time += 0.3; rig.monitor.pollNow()
        XCTAssertTrue(rig.fired.isEmpty)
        rig.time += 0.3; rig.monitor.pollNow()
        XCTAssertEqual(rig.fired, [spec(2, .longPress)])
        _ = rig.up(2)
    }

    func testDragThroughMonitorSwallowsSuppressedPressUntilRelease() {
        let rig = Rig([mouseTrigger(1, .dragRight, mods: cmd, suppress: true)])
        XCTAssertTrue(rig.down(1, cmd, x: 10, y: 10))
        XCTAssertTrue(rig.drag(1, x: 80, y: 12, cmd), "drag events of a swallowed press are swallowed")
        XCTAssertEqual(rig.fired, [spec(1, .dragRight)])
        XCTAssertTrue(rig.up(1))
        XCTAssertFalse(rig.drag(1, x: 200, y: 12, cmd), "after release nothing is swallowed")
    }

    func testScrollThroughMonitorRequiresModifierAndSwallowsOnlyThen() {
        let rig = Rig([mouseTrigger(0, .scrollUp, mods: opt, suppress: true)])
        XCTAssertFalse(rig.scroll(dy: 50, 0), "plain scrolling is never touched")
        XCTAssertTrue(rig.fired.isEmpty)
        rig.time += 1
        XCTAssertTrue(rig.scroll(dy: 50, opt))
        XCTAssertEqual(rig.fired, [spec(0, .scrollUp)])
    }

    func testMouseTriggerUsesIsolatedTimingDefaults() {
        let before = UserDefaults.standard.object(forKey: TriggerTimingSettings.mouseLongPressKey)
        _ = MouseButtonMonitor()
        XCTAssertEqual(UserDefaults.standard.object(forKey: TriggerTimingSettings.mouseLongPressKey) as? Int, before as? Int)
        XCTAssertNotEqual(MouseButtonMonitor().timingDefaults, UserDefaults.standard)
    }
}

// MARK: - 4. Trackpad additions

final class BTTTrackpadParityTests: XCTestCase {

    private func pt(_ id: Int, _ x: Float, _ y: Float) -> TouchPoint { TouchPoint(id: id, x: x, y: y, size: 0.4) }
    private func fingers(_ n: Int, y: Float = 0.5) -> [TouchPoint] { (0..<n).map { pt($0, 0.2 + Float($0) * 0.12, y) } }

    /// Feeds frames `(time, points)` and returns every gesture emitted, in order.
    private func run(_ enabled: Set<TrackpadGesture>, _ frames: [(Double, [TouchPoint])],
                     durations: @escaping (TrackpadGesture) -> [Double] = { _ in [0.5] }) -> [TrackpadGesture] {
        var session = ContactGestureSession()
        var out: [TrackpadGesture] = []
        for (time, points) in frames {
            out += session.update(points, timestamp: time, pressed: false, enabled: enabled, restTime: 0.12,
                                  minVelocity: { _ in 200 }, longTouchDurations: durations)
        }
        // Taps are reported whether or not they are bound; the monitor filters them.
        return out.filter { enabled.contains($0) }
    }

    func testNewGesturesHaveBTTNamesAndAreUnique() {
        XCTAssertEqual(TrackpadGesture.oneFingerLongTouch.rawValue, "1 Finger Long Touch")
        XCTAssertEqual(TrackpadGesture.fiveFingerTouchStart.rawValue, "5 Finger Touch Start")
        XCTAssertEqual(TrackpadGesture.releaseLastFingerAfter3.rawValue, "Release Last Finger After Previous Touch With 3 Fingers")
        XCTAssertEqual(TrackpadGesture.twoFingerSwipeFromLeftEdge.rawValue, "2 Finger Swipe From Left Edge")
        XCTAssertEqual(TrackpadGesture.threeFingerTapTop.rawValue, "3 Finger Tap Top")
        XCTAssertEqual(TrackpadGesture.scrollUp.rawValue, "Scroll Up (modifier key needed)")
        XCTAssertEqual(Set(TrackpadGesture.allCases.map(\.rawValue)).count, TrackpadGesture.allCases.count)
    }

    func testOldTrackpadPresetStillDecodesAndNewGestureRoundTrips() throws {
        let old = Data(#"{"trackpadGesture":{"_0":"2 Finger Swipe Up"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(TriggerInput.self, from: old), .trackpadGesture(.twoFingerSwipeUp))
        let input = TriggerInput.trackpadGesture(.threeFingerLongTouch)
        XCTAssertEqual(try JSONDecoder().decode(TriggerInput.self, from: JSONEncoder().encode(input)), input)
    }

    // Touch Start

    func testTouchStartFiresOncePerCountAfterSettling() {
        let one = fingers(1), two = fingers(2)
        XCTAssertEqual(run([.oneFingerTouchStart, .twoFingerTouchStart],
            [(1.00, one), (1.02, one), (1.06, one), (1.10, one), (1.12, two), (1.20, two), (1.30, two)]),
            [.oneFingerTouchStart, .twoFingerTouchStart])
    }

    func testTouchStartIgnoresAFingerCountThatNeverSettles() {
        // The first finger is replaced within the settle time, so "1 finger" never starts.
        XCTAssertEqual(run([.oneFingerTouchStart, .twoFingerTouchStart],
            [(1.00, fingers(1)), (1.02, fingers(2)), (1.10, fingers(2))]), [.twoFingerTouchStart])
    }

    func testTouchStartDoesNotRefireWhenAFingerLiftsAndTheCountDrops() {
        let result = run([.oneFingerTouchStart, .twoFingerTouchStart],
            [(1.00, fingers(2)), (1.10, fingers(2)), (1.20, fingers(1)), (1.30, fingers(1))])
        XCTAssertEqual(result, [.twoFingerTouchStart], "going from 2 to 1 is not a new 1-finger touch start")
    }

    func testOnlyEnabledTouchStartsFire() {
        XCTAssertTrue(run([.threeFingerTouchStart], [(1, fingers(2)), (1.2, fingers(2))]).isEmpty)
    }

    // Long Touch

    func testLongTouchFiresAtDurationOnlyWhileResting() {
        let hold = fingers(2)
        XCTAssertEqual(run([.twoFingerLongTouch], (0...6).map { (1 + Double($0) * 0.1, hold) }), [.twoFingerLongTouch],
                       "fires once after 0.5 s of rest")
        XCTAssertTrue(run([.twoFingerLongTouch], (0...3).map { (1 + Double($0) * 0.1, hold) }).isEmpty, "0.3 s is too short")
        // Lifting early produces nothing even with a release frame afterwards.
        XCTAssertTrue(run([.twoFingerLongTouch], [(1, hold), (1.3, hold), (1.4, [])]).isEmpty)
    }

    func testLongTouchRestartsWhenFingersMove() {
        var frames: [(Double, [TouchPoint])] = []
        for i in 0...4 { frames.append((1 + Double(i) * 0.1, fingers(1))) }          // rests 0.4 s
        frames.append((1.5, [pt(0, 0.45, 0.5)]))                                     // moves → restart
        for i in 1...4 { frames.append((1.5 + Double(i) * 0.1, [pt(0, 0.45, 0.5)])) } // rests another 0.4 s
        XCTAssertTrue(run([.oneFingerLongTouch], frames).isEmpty)
        frames.append((2.0, [pt(0, 0.45, 0.5)]))
        XCTAssertEqual(run([.oneFingerLongTouch], frames), [.oneFingerLongTouch])
    }

    func testLongTouchHonoursConfiguredDurationsAndReportsWhichOne() {
        var session = ContactGestureSession()
        let hold = fingers(3)
        var emitted: [(Double, Double?)] = []
        for i in 0...25 {
            let t = 1 + Double(i) * 0.1
            let g = session.update(hold, timestamp: t, pressed: false, enabled: [.threeFingerLongTouch], restTime: 0.12,
                                   minVelocity: { _ in 200 }, longTouchDurations: { _ in [0.2, 2.0] })
            if g.contains(.threeFingerLongTouch) { emitted.append((t, session.lastLongTouchDuration)) }
        }
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted[0].1, 0.2); XCTAssertEqual(emitted[0].0, 1.2, accuracy: 0.001)
        XCTAssertEqual(emitted[1].1, 2.0); XCTAssertEqual(emitted[1].0, 3.0, accuracy: 0.001)
    }

    func testLongTouchDurationPersistsClampedAndDefaultsFromOldJSON() throws {
        var trigger = Trigger(name: "l", input: .trackpadGesture(.twoFingerLongTouch))
        XCTAssertEqual(trigger.longTouchDurationMs, 500)
        trigger.longTouchDurationMs = 1500
        XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(trigger)).longTouchDurationMs, 1500)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as! [String: Any]
        json["longTouchDurationMs"] = 999_999
        XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: json)).longTouchDurationMs, 5000)
        json.removeValue(forKey: "longTouchDurationMs")
        XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: json)).longTouchDurationMs, 500)
    }

    func testMonitorRoutesLongTouchToTheMatchingDurationOnly() {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "x" })
        var quick = Trigger(name: "quick", input: .trackpadGesture(.twoFingerLongTouch)); quick.longTouchDurationMs = 200
        var slow = Trigger(name: "slow", input: .trackpadGesture(.twoFingerLongTouch)); slow.longTouchDurationMs = 1000
        for (i, t) in [quick, slow].enumerated() {
            var p = ActionParameters(); p.text = "t\(i)"
            var copy = t; copy.actions = [TriggerAction(actionType: .typeText, parameters: p)]
            if i == 0 { quick = copy } else { slow = copy }
        }
        var fired: [String] = []
        ActionExecutor.onActionExecuted = { fired.append($0.parameters.text ?? "?") }
        defer { ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]); monitor.unregisterAll() }
        ActionExecutor.registerTriggers([quick, slow])
        monitor.registerTriggers([quick, slow])
        let hold = fingers(2)
        for i in 0...12 { monitor.processTouchFrame(hold, count: 2, timestamp: 1 + Double(i) * 0.1, pressedButtons: 0) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(fired.sorted(), ["t0", "t1"], "each trigger fires once, at its own duration")
    }

    // Release Last Finger

    func testReleaseLastFingerAfterNAndRegardless() {
        let two = fingers(2)
        let frames: [(Double, [TouchPoint])] = [(1, two), (1.1, fingers(1)), (1.2, [])]
        XCTAssertEqual(run([.releaseLastFingerAfter2], frames), [.releaseLastFingerAfter2])
        XCTAssertTrue(run([.releaseLastFingerAfter1], frames).isEmpty, "peak was 2, not 1")
        XCTAssertEqual(run([.releaseLastFingerRegardless], frames), [.releaseLastFingerRegardless])
        XCTAssertEqual(Set(run([.releaseLastFingerAfter2, .releaseLastFingerRegardless], frames)),
                       [.releaseLastFingerAfter2, .releaseLastFingerRegardless])
        // Fires only when the LAST finger leaves, not when one of two does.
        XCTAssertTrue(run([.releaseLastFingerRegardless], [(1, two), (1.1, fingers(1))]).isEmpty)
        // After a long hold and a swipe the release still counts.
        XCTAssertEqual(run([.releaseLastFingerAfter1], (0...8).map { (1 + Double($0) * 0.1, fingers(1)) } + [(2, [])]),
                       [.releaseLastFingerAfter1])
    }

    // 2-finger swipe from edge

    func testTwoFingerSwipeFromEachEdgeFiresInwardOnly() {
        let cases: [(TrackpadGesture, [TouchPoint], Float, Float)] = [
            (.twoFingerSwipeFromLeftEdge, [pt(1, 0.03, 0.45), pt(2, 0.05, 0.55)], 0.2, 0),
            (.twoFingerSwipeFromRightEdge, [pt(1, 0.97, 0.45), pt(2, 0.95, 0.55)], -0.2, 0),
            (.twoFingerSwipeFromTopEdge, [pt(1, 0.45, 0.96), pt(2, 0.55, 0.94)], 0, -0.2),
            (.twoFingerSwipeFromBottomEdge, [pt(1, 0.45, 0.04), pt(2, 0.55, 0.06)], 0, 0.2)]
        for (gesture, start, dx, dy) in cases {
            let moved = start.map { pt($0.id, $0.x + dx, $0.y + dy) }
            XCTAssertEqual(run([gesture], [(1, start), (1.1, moved), (1.2, [])]), [gesture], "\(gesture)")
            // Moving the wrong way (outward) does nothing.
            let outward = start.map { pt($0.id, min(max($0.x - dx, 0), 1), min(max($0.y - dy, 0), 1)) }
            XCTAssertTrue(run([gesture], [(1, start), (1.1, outward)]).isEmpty, "outward \(gesture)")
        }
    }

    func testEdgeSwipeNeedsEdgeStartAndShadowsPlainSwipe() {
        let interior = [pt(1, 0.4, 0.45), pt(2, 0.5, 0.55)]
        let movedInterior = interior.map { pt($0.id, $0.x + 0.2, $0.y) }
        XCTAssertTrue(run([.twoFingerSwipeFromLeftEdge], [(1, interior), (1.1, movedInterior)]).isEmpty,
                      "an interior swipe is not an edge swipe")
        XCTAssertEqual(run([.twoFingerSwipeRight], [(1, interior), (1.1, movedInterior)]), [.twoFingerSwipeRight])
        // From the edge with both bound, only the edge gesture fires.
        let edge = [pt(1, 0.03, 0.45), pt(2, 0.05, 0.55)]
        let movedEdge = edge.map { pt($0.id, $0.x + 0.2, $0.y) }
        XCTAssertEqual(run([.twoFingerSwipeFromLeftEdge, .twoFingerSwipeRight], [(1, edge), (1.1, movedEdge), (1.2, movedEdge)]),
                       [.twoFingerSwipeFromLeftEdge])
        // With only the plain swipe bound, an edge start still swipes normally.
        XCTAssertEqual(run([.twoFingerSwipeRight], [(1, edge), (1.1, movedEdge)]), [.twoFingerSwipeRight])
        // One finger on the edge and one inside is not an edge start.
        XCTAssertNil(ContactGestureSession.twoFingerEdge([pt(1, 0.03, 0.5), pt(2, 0.6, 0.5)]))
        XCTAssertNil(ContactGestureSession.twoFingerEdge([pt(1, 0.03, 0.5)]))
    }

    // 3 finger tap top / bottom

    func testThreeFingerTapRegions() {
        func tap(_ y: Float, _ enabled: Set<TrackpadGesture>) -> [TrackpadGesture] {
            run(enabled, [(1, fingers(3, y: y)), (1.1, fingers(3, y: y)), (1.15, [])])
        }
        XCTAssertEqual(tap(0.85, [.threeFingerTapTop, .threeFingerTapBottom]), [.threeFingerTapTop])
        XCTAssertEqual(tap(0.12, [.threeFingerTapTop, .threeFingerTapBottom]), [.threeFingerTapBottom])
        XCTAssertEqual(tap(0.5, [.threeFingerTapTop, .threeFingerTapBottom, .threeFingerTap]), [.threeFingerTap], "middle band falls back to the plain tap")
        XCTAssertEqual(tap(0.85, [.threeFingerTap]), [.threeFingerTap], "plain tap still works when top is not bound")
        XCTAssertEqual(ContactGestureSession.threeFingerTapRegion(centroidY: 0.6), nil)
        XCTAssertEqual(ContactGestureSession.threeFingerTapRegion(centroidY: 0.61), .threeFingerTapTop)
        XCTAssertEqual(ContactGestureSession.threeFingerTapRegion(centroidY: 0.39), .threeFingerTapBottom)
    }

    // Trackpad scroll with modifier

    private func scrollMonitor(mods: UInt?, held: UInt) -> (TrackpadMonitor, () -> [String]) {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "x" })
        monitor.modifierFlagsProvider = { held }
        var up = Trigger(name: "up", input: .trackpadGesture(.scrollUp)); up.requiredModifiers = mods
        var down = Trigger(name: "down", input: .trackpadGesture(.scrollDown)); down.requiredModifiers = mods
        for (index, name) in ["up", "down"].enumerated() {
            var p = ActionParameters(); p.text = name
            if index == 0 { up.actions = [TriggerAction(actionType: .typeText, parameters: p)] }
            else { down.actions = [TriggerAction(actionType: .typeText, parameters: p)] }
        }
        var fired: [String] = []
        ActionExecutor.onActionExecuted = { fired.append($0.parameters.text ?? "?") }
        ActionExecutor.registerTriggers([up, down])
        monitor.registerTriggers([up, down])
        return (monitor, { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); return fired })
    }

    func testTrackpadScrollFiresOnlyWithTheRequiredModifierHeld() {
        let opt = NSEvent.ModifierFlags.option.rawValue
        defer { ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]) }
        let (held, heldFired) = scrollMonitor(mods: opt, held: opt)
        held.processScroll(deltaX: 0, deltaY: 30, phase: .changed, timestamp: 1)
        held.processScroll(deltaX: 0, deltaY: 30, phase: .changed, timestamp: 1.05)
        held.processScroll(deltaX: 0, deltaY: -50, phase: .changed, timestamp: 2)
        XCTAssertEqual(heldFired(), ["up", "down"])
        held.unregisterAll()

        let (notHeld, notHeldFired) = scrollMonitor(mods: opt, held: 0)
        notHeld.processScroll(deltaX: 0, deltaY: 80, phase: .changed, timestamp: 1)
        XCTAssertTrue(notHeldFired().isEmpty, "no modifier, no trigger")
        notHeld.unregisterAll()
    }

    func testMomentumScrollAndUnmodifiedScrollTriggersAreIgnored() {
        let opt = NSEvent.ModifierFlags.option.rawValue
        defer { ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]) }
        let (monitor, fired) = scrollMonitor(mods: opt, held: opt)
        monitor.processScroll(deltaX: 0, deltaY: 90, phase: [], momentumPhase: .changed, timestamp: 1)
        XCTAssertTrue(fired().isEmpty, "inertia must not fire")
        monitor.unregisterAll()
        // A scroll trigger lacking a modifier is never installed.
        let (open, openFired) = scrollMonitor(mods: nil, held: 0)
        open.processScroll(deltaX: 0, deltaY: 90, phase: .changed, timestamp: 1)
        XCTAssertTrue(openFired().isEmpty)
        XCTAssertNotNil(TriggerValidation.problem(for: .trackpadGesture(.scrollUp), requiredModifiers: nil))
        XCTAssertNil(TriggerValidation.problem(for: .trackpadGesture(.scrollUp), requiredModifiers: opt))
        XCTAssertNil(TriggerValidation.problem(for: .trackpadGesture(.twoFingerTap), requiredModifiers: nil))
        open.unregisterAll()
    }

    func testPausedSuppressionBlocksTrackpadFiresAndPostKeystrokeRuleAppliesToTrackpadOnly() {
        // The gate decides by family; this pins the trackpad rule the monitor relies on.
        let t = Trigger(name: "t", input: .trackpadGesture(.twoFingerTap))
        let s = TriggerSuppression(defaults: UserDefaults(suiteName: "BTTTrackpadParity-\(UUID().uuidString)")!,
                                   secondsSinceLastKeyDown: { 0.1 }, schedulesExpiry: false)
        s.settings.disableTrackpadAfterKeyEnabled = true
        XCTAssertFalse(s.allows(t))
        XCTAssertTrue(s.allows(Trigger(name: "m", input: .mouseButton(.button4))))
    }
}

// MARK: - 5. Other / System triggers

final class BTTSystemTriggerParityTests: XCTestCase {

    private final class FakeProvider: SystemSignalProvider {
        var started: [Set<SignalSource>] = []
        var stops = 0
        func start(_ needs: Set<SignalSource>, emit: @escaping (SystemSignal) -> Void) { started.append(needs) }
        func stop() { stops += 1 }
    }

    private final class Rig {
        var time: TimeInterval = 1000
        var frames: [CGRect] = [CGRect(x: 0, y: 0, width: 1000, height: 600)]
        var scheduled: [(TimeInterval, () -> Void)] = []
        var fired: [String] = []
        let provider = FakeProvider()
        let monitor: SystemTriggerMonitor
        init(_ kinds: [SystemTriggerKind], appScoped: [(SystemTriggerKind, String)] = []) {
            var holder: Rig?
            monitor = SystemTriggerMonitor(provider: provider, screenFrames: { holder?.frames ?? [] },
                                           clock: { holder?.time ?? 0 }, scheduler: { holder?.scheduled.append(($0, $1)) })
            holder = self
            var triggers: [Trigger] = []
            for (index, kind) in kinds.enumerated() {
                var t = Trigger(name: "t\(index)", input: .systemEvent(kind))
                var p = ActionParameters(); p.text = "t\(index)"
                t.actions = [TriggerAction(actionType: .typeText, parameters: p)]
                triggers.append(t)
            }
            for (index, (kind, app)) in appScoped.enumerated() {
                var t = Trigger(name: "a\(index)", input: .systemEvent(kind), appBundleID: app)
                var p = ActionParameters(); p.text = "a\(index)"
                t.actions = [TriggerAction(actionType: .typeText, parameters: p)]
                triggers.append(t)
            }
            ActionExecutor.onActionExecuted = { [unowned self] in fired.append($0.parameters.text ?? "?") }
            ActionExecutor.registerTriggers(triggers)
            monitor.registerTriggers(triggers)
        }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        deinit { monitor.unregisterAll(); ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]) }
    }

    // MARK: Model / persistence

    func testEveryNewKindRoundTripsAndHasLabelAndIcon() throws {
        let kinds: [SystemTriggerKind] = [
            .systemWillSleep, .systemDidWake, .appActivated(""), .appActivated("com.apple.Safari"), .appDeactivated("com.apple.Safari"),
            .screensaverStarted, .screensaverStopped, .activeSpaceChanged, .batteryBelow(20), .batteryAbove(80),
            .wifiConnected(ssid: ""), .wifiConnected(ssid: "Home"), .wifiDisconnected(ssid: "Home"),
            .usbConnected(name: ""), .usbDisconnected(name: "Keyboard"), .bluetoothConnected(name: "AirPods"), .bluetoothDisconnected(name: ""),
            .inputSourceChanged, .audioOutputChanged, .clipboardChanged, .fileDidChange(path: "/tmp/x"),
            .screenCornerHover(corner: .topLeft, dwellMs: 300), .screenEdgeHover(edge: .right, dwellMs: 300, minDistance: 4),
            .variableChanged(name: ""), .variableChanged(name: "mode")]
        for kind in kinds {
            let input = TriggerInput.systemEvent(kind)
            XCTAssertEqual(try JSONDecoder().decode(TriggerInput.self, from: JSONEncoder().encode(input)), input, "\(kind)")
            XCTAssertFalse(kind.displayName.isEmpty); XCTAssertFalse(kind.symbolName.isEmpty)
            XCTAssertEqual(input.category, .otherTriggers)
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil), "\(kind.symbolName) is not an SF Symbol")
        }
        XCTAssertEqual(SystemTriggerKind.batteryBelow(20).displayName, "Battery drops below 20%")
        XCTAssertEqual(SystemTriggerKind.screenEdgeHover(edge: .left, dwellMs: 300, minDistance: 4).displayName, "Pointer hovers left screen edge")
        XCTAssertEqual(SystemTriggerKind.defaultHoverDwellMs, 300)
        XCTAssertEqual(SystemTriggerKind.defaultEdgeDistancePx, 4)
    }

    func testPreExistingSystemKindsStillDecodeFromOldJSON() throws {
        let old: [(String, SystemTriggerKind)] = [
            (#"{"daily":{"hour":9,"minute":30}}"#, .daily(hour: 9, minute: 30)),
            (#"{"screenLocked":{}}"#, .screenLocked),
            (#"{"appLaunched":{"_0":"com.apple.TextEdit"}}"#, .appLaunched("com.apple.TextEdit")),
            (#"{"powerSourceChanged":{"ac":false}}"#, .powerSourceChanged(ac: false)),
            (#"{"everyMinutes":{"_0":15}}"#, .everyMinutes(15))]
        for (json, expected) in old { XCTAssertEqual(try JSONDecoder().decode(SystemTriggerKind.self, from: Data(json.utf8)), expected, json) }
    }

    // MARK: Lazy installation

    func testOnlyNeededSourcesAreRequested() {
        XCTAssertTrue(SignalSource.needs(for: [.daily(hour: 1, minute: 0), .displayChanged, .screenLocked, .appLaunched("x")]).isEmpty,
                      "pre-existing kinds keep their own observers")
        XCTAssertEqual(SignalSource.needs(for: [.batteryBelow(20), .batteryAbove(90), .systemDidWake]), [.battery, .sleepWake])
        XCTAssertEqual(SignalSource.needs(for: [.screenCornerHover(corner: .topLeft, dwellMs: 1), .screenEdgeHover(edge: .top, dwellMs: 1, minDistance: 1)]), [.pointer])
        XCTAssertEqual(SignalSource.needs(for: [.fileDidChange(path: "/tmp/a"), .fileDidChange(path: "/tmp/b"), .fileDidChange(path: "relative")]),
                       [.files([TriggerSystemPaths.normalized("/tmp/a")!, TriggerSystemPaths.normalized("/tmp/b")!])],
                       "relative paths are never watched")
        let all = SignalSource.needs(for: [.appActivated(""), .screensaverStarted, .activeSpaceChanged, .wifiConnected(ssid: ""),
            .usbConnected(name: ""), .bluetoothConnected(name: ""), .inputSourceChanged, .audioOutputChanged, .clipboardChanged, .variableChanged(name: "")])
        XCTAssertEqual(all, [.appFocus, .screensaver, .space, .wifi, .usb, .bluetooth, .inputSource, .audioOutput, .clipboard, .variables])
    }

    func testMonitorStartsProviderOnlyWithNeededSourcesAndStopsOnUnregister() {
        let rig = Rig([.batteryBelow(20)])
        XCTAssertEqual(rig.provider.started, [[.battery]])
        let idle = Rig([.daily(hour: 3, minute: 0)])
        XCTAssertTrue(idle.provider.started.isEmpty, "a preset with no new kinds installs nothing")
        rig.monitor.unregisterAll()
        XCTAssertGreaterThanOrEqual(rig.provider.stops, 1)
    }

    func testTestsUseTheFakeProviderNotRealSystemObservers() {
        // The default live provider is only constructed by the production initializer.
        XCTAssertTrue(Rig([.systemDidWake]).provider is FakeProvider)
    }

    // MARK: Stateless signals

    func testSleepWakeScreensaverSpaceInputAudioClipboard() {
        let rig = Rig([.systemWillSleep, .systemDidWake, .screensaverStarted, .screensaverStopped, .activeSpaceChanged,
                       .inputSourceChanged, .audioOutputChanged, .clipboardChanged])
        let signals: [SystemSignal] = [.willSleep, .didWake, .screensaver(started: true), .screensaver(started: false),
                                       .spaceChanged, .inputSourceChanged, .audioOutputChanged, .clipboardChanged]
        for (index, signal) in signals.enumerated() {
            rig.fired.removeAll()
            rig.monitor.handle(signal); rig.drain()
            XCTAssertEqual(rig.fired, ["t\(index)"], "\(signal)")
        }
    }

    func testAppActivatedDeactivatedFilterByBundle() {
        let rig = Rig([.appActivated(""), .appActivated("com.a"), .appDeactivated("com.a")])
        rig.monitor.handle(.appActivated(bundleID: "com.b")); rig.drain()
        XCTAssertEqual(rig.fired, ["t0"])
        rig.fired.removeAll()
        rig.monitor.handle(.appActivated(bundleID: "com.a")); rig.drain()
        XCTAssertEqual(rig.fired.sorted(), ["t0", "t1"])
        rig.fired.removeAll()
        rig.monitor.handle(.appDeactivated(bundleID: "com.a")); rig.drain()
        XCTAssertEqual(rig.fired, ["t2"])
    }

    func testAppScopedSystemTriggerHonoursFrontmostApp() {
        // The test host is not "com.example.nobody", so an app-scoped trigger must not fire.
        let rig = Rig([], appScoped: [(.systemDidWake, "com.example.nobody")])
        rig.monitor.handle(.didWake); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty)
    }

    func testPausedSuppressionBlocksSystemTriggers() {
        let rig = Rig([.systemDidWake])
        TriggerSuppression.shared.pause(for: 60)
        defer { TriggerSuppression.shared.resume() }
        rig.monitor.handle(.didWake); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty)
    }

    // MARK: Battery

    func testBatteryFiresOnCrossingNotOnBaselineOrWhileStayingBelow() {
        let rig = Rig([.batteryBelow(20), .batteryAbove(80)])
        rig.monitor.handle(.battery(percent: 15)); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "first reading is only a baseline")
        rig.monitor.handle(.battery(percent: 14)); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "already below")
        rig.monitor.handle(.battery(percent: 21)); rig.monitor.handle(.battery(percent: 19)); rig.drain()
        XCTAssertEqual(rig.fired, ["t0"], "crossing from 21 to 19")
        rig.fired.removeAll()
        rig.monitor.handle(.battery(percent: 80)); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "80 is not above 80")
        rig.monitor.handle(.battery(percent: 81)); rig.drain()
        XCTAssertEqual(rig.fired, ["t1"])
        rig.monitor.handle(.battery(percent: 90)); rig.drain()
        XCTAssertEqual(rig.fired, ["t1"], "stays above: no repeat")
    }

    // MARK: Wi-Fi

    func testWiFiConnectDisconnectAndNetworkSwitch() {
        let rig = Rig([.wifiConnected(ssid: ""), .wifiConnected(ssid: "Office"), .wifiDisconnected(ssid: ""), .wifiDisconnected(ssid: "Home")])
        rig.monitor.handle(.wifi(ssid: "Home")); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "baseline")
        rig.monitor.handle(.wifi(ssid: "Home")); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "no change")
        rig.monitor.handle(.wifi(ssid: "Office")); rig.drain()
        XCTAssertEqual(rig.fired.sorted(), ["t0", "t1", "t2", "t3"], "switching = leave Home + join Office")
        rig.fired.removeAll()
        rig.monitor.handle(.wifi(ssid: nil)); rig.drain()
        XCTAssertEqual(rig.fired, ["t2"], "disconnect from Office matches only the any-network rule")
        rig.fired.removeAll()
        rig.monitor.handle(.wifi(ssid: "")); rig.drain()
        XCTAssertEqual(rig.fired, ["t0"], "unreadable SSID matches only 'any network'")
    }

    // MARK: USB / Bluetooth

    func testUSBAndBluetoothNameFilters() {
        let rig = Rig([.usbConnected(name: ""), .usbConnected(name: "keyboard"), .usbDisconnected(name: "Mouse"),
                       .bluetoothConnected(name: "airpods"), .bluetoothDisconnected(name: "")])
        rig.monitor.handle(.usb(name: "Magic Keyboard", connected: true)); rig.drain()
        XCTAssertEqual(rig.fired.sorted(), ["t0", "t1"])
        rig.fired.removeAll()
        rig.monitor.handle(.usb(name: "Magic Keyboard", connected: false)); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "nothing listens for that disconnect")
        rig.monitor.handle(.usb(name: "USB Mouse", connected: false)); rig.drain()
        XCTAssertEqual(rig.fired, ["t2"])
        rig.fired.removeAll()
        rig.monitor.handle(.bluetooth(name: "Kim's AirPods Pro", connected: true)); rig.drain()
        XCTAssertEqual(rig.fired, ["t3"])
        rig.fired.removeAll()
        rig.monitor.handle(.bluetooth(name: "Anything", connected: false)); rig.drain()
        XCTAssertEqual(rig.fired, ["t4"])
        XCTAssertTrue(SystemSignalMatcher.nameMatches("", ""))
        XCTAssertFalse(SystemSignalMatcher.nameMatches("zzz", "abc"))
    }

    func testBluetoothIsGatedOnTheUsageDescription() {
        // The test bundle has no NSBluetoothAlwaysUsageDescription, so the live
        // provider must not touch IOBluetooth here.
        XCTAssertFalse(LiveSystemSignalProvider.bluetoothAvailable)
    }

    // MARK: File changes

    func testFileChangeMatchesNormalizedPathAndDebounces() {
        let path = NSTemporaryDirectory() + "bttparity-watch.txt"
        let rig = Rig([.fileDidChange(path: path)])
        let normalized = TriggerSystemPaths.normalized(path)!
        rig.monitor.handle(.fileChanged(path: normalized)); rig.drain()
        XCTAssertEqual(rig.fired, ["t0"])
        rig.monitor.handle(.fileChanged(path: normalized)); rig.drain()
        XCTAssertEqual(rig.fired, ["t0"], "burst within the debounce window")
        rig.time += 0.3
        rig.monitor.handle(.fileChanged(path: normalized)); rig.drain()
        XCTAssertEqual(rig.fired, ["t0", "t0"])
        rig.monitor.handle(.fileChanged(path: "/somewhere/else")); rig.drain()
        XCTAssertEqual(rig.fired.count, 2)
        XCTAssertNil(TriggerSystemPaths.normalized("relative/path"))
        XCTAssertNil(TriggerSystemPaths.normalized("/tmp/a\0b"))
    }

    // MARK: Variables

    func testVariableChangeFiresOnlyWhenTheValueChanges() {
        let name = "bttparity_\(UUID().uuidString.prefix(6).replacingOccurrences(of: "-", with: ""))"
        let rig = Rig([.variableChanged(name: name), .variableChanged(name: "")])
        rig.monitor.handle(.variable(name: name, value: "1")); rig.drain()
        XCTAssertEqual(rig.fired.sorted(), ["t0", "t1"])
        rig.fired.removeAll()
        rig.monitor.handle(.variable(name: name, value: "1")); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "same value")
        rig.monitor.handle(.variable(name: name, value: "2")); rig.drain()
        XCTAssertEqual(rig.fired.sorted(), ["t0", "t1"])
        rig.fired.removeAll()
        rig.monitor.handle(.variable(name: "other", value: "x")); rig.drain()
        XCTAssertEqual(rig.fired, ["t1"], "named rule ignores other variables")
    }

    func testVariableSnapshotReadsTheWorkflowVariablesStore() {
        // WorkflowVariables persists through UserDefaults; the live provider diffs that store.
        let name = "bttparity_snap\(Int.random(in: 1000...9999))"
        XCTAssertTrue(WorkflowVariables.set(name, value: "v"))
        XCTAssertEqual(LiveSystemSignalProvider.variableSnapshot()[name], "v")
        UserDefaults.standard.removeObject(forKey: "AOMWorkflowVariables")
    }

    // MARK: Hover (corner / edge)

    private func hover(_ zones: Set<ScreenHoverRecognizer.Zone>) -> ScreenHoverRecognizer { ScreenHoverRecognizer(zones: zones) }
    private let screens = [CGRect(x: 0, y: 0, width: 1000, height: 600)]

    func testCornerHoverNeedsDwellAndFiresOncePerVisit() {
        let zone = ScreenHoverRecognizer.Zone.corner(.topRight, dwellMs: 300)
        var r = hover([zone])
        r.move(to: CGPoint(x: 998, y: 598), screens: screens, now: 10)
        XCTAssertTrue(r.poll(now: 10.29).isEmpty)
        XCTAssertEqual(r.nextDeadline!, 10.3, accuracy: 0.0001)
        XCTAssertEqual(r.poll(now: 10.3), [zone])
        r.move(to: CGPoint(x: 999, y: 599), screens: screens, now: 11)
        XCTAssertTrue(r.poll(now: 12).isEmpty, "still the same visit")
        r.move(to: CGPoint(x: 500, y: 300), screens: screens, now: 13)   // leave
        r.move(to: CGPoint(x: 999, y: 599), screens: screens, now: 14)   // come back
        XCTAssertEqual(r.poll(now: 14.31), [zone])
    }

    func testLeavingBeforeDwellCancelsAndWrongCornerDoesNothing() {
        let zone = ScreenHoverRecognizer.Zone.corner(.topLeft, dwellMs: 300)
        var r = hover([zone])
        r.move(to: CGPoint(x: 2, y: 598), screens: screens, now: 1)
        r.move(to: CGPoint(x: 300, y: 300), screens: screens, now: 1.2)
        XCTAssertTrue(r.poll(now: 5).isEmpty)
        r.move(to: CGPoint(x: 998, y: 2), screens: screens, now: 6)
        XCTAssertTrue(r.poll(now: 9).isEmpty, "bottom right is not top left")
        XCTAssertNil(r.nextDeadline)
    }

    func testEdgeHoverUsesMinDistanceAndExcludesCorners() {
        let zone = ScreenHoverRecognizer.Zone.edge(.left, dwellMs: 0, minDistance: 4)
        XCTAssertTrue(ScreenHoverRecognizer.contains(zone, point: CGPoint(x: 3, y: 300), screens: screens))
        XCTAssertTrue(ScreenHoverRecognizer.contains(zone, point: CGPoint(x: 0, y: 300), screens: screens))
        XCTAssertFalse(ScreenHoverRecognizer.contains(zone, point: CGPoint(x: 5, y: 300), screens: screens), "5 px is outside a 4 px zone")
        XCTAssertFalse(ScreenHoverRecognizer.contains(zone, point: CGPoint(x: 2, y: 598), screens: screens), "the corner belongs to the corner trigger")
        let wide = ScreenHoverRecognizer.Zone.edge(.left, dwellMs: 0, minDistance: 40)
        XCTAssertTrue(ScreenHoverRecognizer.contains(wide, point: CGPoint(x: 39, y: 300), screens: screens))
        for (edge, point) in [(ScreenEdge.right, CGPoint(x: 998, y: 300)), (.top, CGPoint(x: 500, y: 598)), (.bottom, CGPoint(x: 500, y: 2))] {
            XCTAssertTrue(ScreenHoverRecognizer.contains(.edge(edge, dwellMs: 0, minDistance: 4), point: point, screens: screens), "\(edge)")
        }
    }

    func testSharedBorderBetweenDisplaysIsNotAnEdge() {
        let two = [CGRect(x: 0, y: 0, width: 1000, height: 600), CGRect(x: 1000, y: 0, width: 1000, height: 600)]
        let right = ScreenHoverRecognizer.Zone.edge(.right, dwellMs: 0, minDistance: 4)
        XCTAssertFalse(ScreenHoverRecognizer.contains(right, point: CGPoint(x: 998, y: 300), screens: two), "continues onto the next display")
        XCTAssertTrue(ScreenHoverRecognizer.contains(right, point: CGPoint(x: 1998, y: 300), screens: two))
        XCTAssertTrue(ScreenHoverRecognizer.contains(.edge(.left, dwellMs: 0, minDistance: 4), point: CGPoint(x: 1002, y: 300), screens: two) == false)
    }

    func testMonitorHoverFiresAfterDwellViaInjectedScheduler() {
        let rig = Rig([.screenCornerHover(corner: .bottomLeft, dwellMs: 300), .screenEdgeHover(edge: .top, dwellMs: 300, minDistance: 4)])
        XCTAssertEqual(rig.provider.started, [[.pointer]])
        rig.monitor.handle(.pointer(CGPoint(x: 1, y: 1))); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty)
        XCTAssertEqual(rig.scheduled.count, 1, "one wake scheduled for the dwell deadline")
        XCTAssertEqual(rig.scheduled[0].0, 0.305, accuracy: 0.001)
        rig.time += 0.31
        rig.scheduled.removeFirst().1(); rig.drain()
        XCTAssertEqual(rig.fired, ["t0"])
        // The top edge is a different zone and starts its own dwell.
        rig.monitor.handle(.pointer(CGPoint(x: 500, y: 599))); rig.drain()
        rig.time += 0.31
        rig.scheduled.removeAll { _ in false }
        rig.monitor.handle(.pointer(CGPoint(x: 501, y: 599))); rig.drain()
        XCTAssertEqual(rig.fired, ["t0", "t1"])
    }

    // MARK: Isolation

    func testNoRealObserversAreInstalledByRegistrationWithFakeProvider() {
        // Registering every new kind through the fake provider only records requested sources.
        let kinds: [SystemTriggerKind] = [.systemWillSleep, .wifiConnected(ssid: ""), .usbConnected(name: ""), .bluetoothConnected(name: ""),
                                          .audioOutputChanged, .fileDidChange(path: "/tmp/nothing-here")]
        let rig = Rig(kinds)
        XCTAssertEqual(rig.provider.started.count, 1)
        XCTAssertTrue(rig.provider.started[0].contains(.sleepWake))
        XCTAssertTrue(rig.provider.started[0].contains(.bluetooth))
    }
}
