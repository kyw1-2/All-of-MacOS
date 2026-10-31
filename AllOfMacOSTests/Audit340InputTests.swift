import XCTest
import AppKit
import Carbon
@testable import AllOfMacOS

/// 3.4.0 audit: the input monitors after macOS turned an event tap off, typed
/// strings while AOM is paused, the left and right keys of one modifier, and
/// the autorepeat of a swallowed shortcut. Nothing here creates a tap or posts
/// an event: the monitors run with system monitoring off, actions go to
/// `ActionExecutor.onActionExecuted`, and pauses are runtime state that
/// `tearDown` lifts again.
final class Audit340InputTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TriggerSuppression.shared.resume()
    }

    override func tearDown() {
        TriggerSuppression.shared.resume()
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    private func drain() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: Typed strings and Pause AOM

    private func typedStringMonitor() -> KeyboardMonitor {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        monitor.registeredTriggers = [Trigger(name: "signature",
                                              input: .typedString(TypedStringSpec(abbreviation: ";j340", replacement: "Kim")))]
        return monitor
    }

    /// Paused, an abbreviation's last key was swallowed, the abbreviation
    /// erased and the replacement typed. The check now comes before anything
    /// that reads the screen or AppKit.
    func testTypedStringsStayQuietWhileAOMIsPaused() {
        let monitor = typedStringMonitor()
        TriggerSuppression.shared.pauseUntilResumed()
        XCTAssertFalse(monitor.typedStringExpansionAllowed(), "paused until resumed: nothing is erased or typed")
        TriggerSuppression.shared.resume()
        TriggerSuppression.shared.pause(for: 60)
        XCTAssertFalse(monitor.typedStringExpansionAllowed(), "a timed pause too")
    }

    func testTypedStringsStayQuietInAnAppAOMIsPausedFor() throws {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        try XCTSkipIf(front == nil, "no frontmost app in this session")
        let monitor = typedStringMonitor()
        TriggerSuppression.shared.pauseApp(try XCTUnwrap(front))
        XCTAssertFalse(monitor.typedStringExpansionAllowed(), "a per-app pause covers typed strings")
    }

    // MARK: The sequence detector after a disabled tap

    func testADisabledTapLeavesNoModifierHeld() {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        defer { monitor.unregisterAll() }
        let option = KeySequenceStroke(keyCode: 58, modifiers: 0)
        monitor.registeredTriggers = [Trigger(name: "double ⌥", input: .keySequence([option, option]))]
        let leftOptionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        monitor.handleSequenceModifierEvent(keyCode: 58, flags: leftOptionDown)
        XCTAssertTrue(monitor.sequenceDetector.isHeld(58))
        // ⌥ goes up while macOS has the tap off: that key-up never arrives.
        monitor.tapWasDisabled()
        XCTAssertFalse(monitor.sequenceDetector.isHeld(58), "nothing stays held")
        monitor.handleSequenceModifierEvent(keyCode: 58, flags: leftOptionDown)
        XCTAssertTrue(monitor.sequenceDetector.isHeld(58), "the next ⌥ press counts again (it was refused as a repeat)")
    }

    func testReleasingOneSideOfAModifierWhileTheOtherIsHeldIsARelease() {
        let command = CGEventFlags.maskCommand.rawValue
        let left: UInt64 = 0x08, right: UInt64 = 0x10
        XCTAssertTrue(KeyboardMonitor.modifierIsDown(keyCode: 55, flags: CGEventFlags(rawValue: command | left)))
        XCTAssertTrue(KeyboardMonitor.modifierIsDown(keyCode: 54, flags: CGEventFlags(rawValue: command | left | right)))
        XCTAssertFalse(KeyboardMonitor.modifierIsDown(keyCode: 55, flags: CGEventFlags(rawValue: command | right)),
                       "left ⌘ lifted while right ⌘ is held: the flags still carry ⌘")
        XCTAssertFalse(KeyboardMonitor.modifierIsDown(keyCode: 54, flags: []))
        XCTAssertFalse(KeyboardMonitor.modifierIsDown(keyCode: 61, flags: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)),
                       "only left ⌥ is down")
        XCTAssertTrue(KeyboardMonitor.modifierIsDown(keyCode: 62, flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)))
        XCTAssertTrue(KeyboardMonitor.modifierIsDown(keyCode: 60, flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x04)))
        // Events without device bits keep the generic reading.
        XCTAssertTrue(KeyboardMonitor.modifierIsDown(keyCode: 58, flags: .maskAlternate))
        XCTAssertTrue(KeyboardMonitor.modifierIsDown(keyCode: 63, flags: .maskSecondaryFn))
        XCTAssertFalse(KeyboardMonitor.modifierIsDown(keyCode: 63, flags: []))
    }

    func testBothCommandKeysThroughTheMonitorLeaveNoneHeld() {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        defer { monitor.unregisterAll() }
        let command = KeySequenceStroke(keyCode: 55, modifiers: 0)
        monitor.registeredTriggers = [Trigger(name: "double ⌘", input: .keySequence([command, command]))]
        let cmd = CGEventFlags.maskCommand.rawValue
        monitor.handleSequenceModifierEvent(keyCode: 55, flags: CGEventFlags(rawValue: cmd | 0x08))
        monitor.handleSequenceModifierEvent(keyCode: 54, flags: CGEventFlags(rawValue: cmd | 0x18))
        monitor.handleSequenceModifierEvent(keyCode: 55, flags: CGEventFlags(rawValue: cmd | 0x10))
        XCTAssertFalse(monitor.sequenceDetector.isHeld(55), "left ⌘ went up while right ⌘ was held")
        XCTAssertTrue(monitor.sequenceDetector.isHeld(54))
        monitor.handleSequenceModifierEvent(keyCode: 54, flags: [])
        XCTAssertFalse(monitor.sequenceDetector.isHeld(54))
    }

    // MARK: The autorepeat of a swallowed shortcut

    func testTheAutorepeatOfAShortcutLetGoEarlyStaysSwallowed() {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        var trigger = Trigger(name: "fixture", input: .keyboardShortcut(KeyboardShortcut(keyCode: 49, modifiers: .option)))
        trigger.actions = [TriggerAction(actionType: .playPause)]
        var runs = 0
        ActionExecutor.onActionExecuted = { _ in runs += 1 }
        defer { monitor.unregisterAll(); ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]) }
        ActionExecutor.registerTriggers([trigger]); monitor.registerTriggers([trigger])

        XCTAssertTrue(monitor.handleInput(keyCode: 49, modifiers: .option, isDown: true))
        drain()
        XCTAssertEqual(runs, 1)
        // The action switched apps (the 4 Hz poll then lets every press go),
        // or macOS turned the tap off and on.
        monitor.tapWasDisabled()
        XCTAssertTrue(monitor.handleInput(keyCode: 49, modifiers: .option, isDown: true, isRepeat: true),
                      "the autorepeat never reaches the new app as typed text")
        drain()
        XCTAssertEqual(runs, 1, "and runs nothing")
        XCTAssertFalse(monitor.handleInput(keyCode: 49, modifiers: .option, isDown: false), "its release passes")
        XCTAssertFalse(monitor.handleInput(keyCode: 49, modifiers: [], isDown: true, isRepeat: true),
                       "after the release nothing of it is kept")

        // A key-up lost for good: the next fresh press is ordinary typing.
        XCTAssertTrue(monitor.handleInput(keyCode: 49, modifiers: .option, isDown: true))
        monitor.tapWasDisabled()
        XCTAssertFalse(monitor.handleInput(keyCode: 49, modifiers: [], isDown: true), "a fresh Space is typed")
        XCTAssertFalse(monitor.handleInput(keyCode: 49, modifiers: [], isDown: true, isRepeat: true), "and repeats as usual")
        drain()
        XCTAssertEqual(runs, 2)
    }

    // MARK: The Hyper key after a disabled tap

    func testTheHyperKeyIsNotLeftHeldAfterADisabledTap() {
        // F18 went up while the tap was off; it is up now.
        var state = HyperKeyTap.resynchronized(hyperKeyDown: false)
        XCTAssertFalse(state.held)
        let next = HyperKeyTap.process(type: .keyDown, keyCode: Int64(kVK_ANSI_A), isSynthetic: false, state: &state)
        XCTAssertTrue(next.pass)
        XCTAssertFalse(next.addHyper, "a later key gets no ⌃⌥⇧⌘")
        // Still down across the gap: Hyper stays on, but its release is no lone tap.
        state = HyperKeyTap.resynchronized(hyperKeyDown: true)
        XCTAssertTrue(HyperKeyTap.process(type: .keyDown, keyCode: Int64(kVK_ANSI_A), isSynthetic: false, state: &state).addHyper)
        state = HyperKeyTap.resynchronized(hyperKeyDown: true)
        XCTAssertFalse(HyperKeyTap.process(type: .keyUp, keyCode: Int64(kVK_F18), isSynthetic: false, state: &state).sendEscape,
                       "no Escape for a press whose middle was not seen")
    }

    // MARK: The mouse after a disabled tap

    func testALongPressCannotFireForAButtonReleasedWhileTheTapWasOff() {
        let monitor = MouseButtonMonitor()
        var time: TimeInterval = 100
        var fired: [MouseTriggerSpec] = []
        monitor.clock = { time }
        monitor.frontmostBundleID = { "com.example.app" }
        monitor.globalEnabled = { true }
        monitor.timingDefaults = UserDefaults(suiteName: "Audit340Mouse-\(UUID().uuidString)")!
        monitor.onFire = { fired.append($0.spec) }
        monitor.buttonIsDown = { _ in false }
        defer { monitor.unregisterAll() }
        var trigger = Trigger(name: "middle hold", input: .mouse(MouseTriggerSpec(button: 2, kind: .longPress)))
        trigger.suppressClick = true
        trigger.actions = [TriggerAction(actionType: .showHUD)]
        monitor.registerEntries([trigger])

        XCTAssertTrue(monitor.handle(MouseInputEvent(kind: .down, button: 2, time: time)), "the press is swallowed")
        monitor.tapWasDisabled() // its release went around the tap
        time += 1
        monitor.pollNow()
        XCTAssertTrue(fired.isEmpty, "no long press for a button already let go")
        XCTAssertFalse(monitor.handle(MouseInputEvent(kind: .up, button: 2, time: time)),
                       "a release seen later is no longer swallowed")

        // Control: an ordinary long press still fires.
        _ = monitor.handle(MouseInputEvent(kind: .down, button: 2, time: time))
        time += 1
        monitor.pollNow()
        XCTAssertEqual(fired, [MouseTriggerSpec(button: 2, kind: .longPress)])
        _ = monitor.handle(MouseInputEvent(kind: .up, button: 2, time: time))
    }
}
