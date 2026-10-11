import XCTest
import AppKit
@testable import AllOfMacOS

final class SystemActionTests: XCTestCase {
    func testAppKitFramesConvertToAXForVerticallyStackedDisplays() {
        XCTAssertEqual(WindowGeometry.accessibilityFrame(CGRect(x: 266, y: -900, width: 1440, height: 900), primaryTop: 1080), CGRect(x: 266, y: 1080, width: 1440, height: 900))
        XCTAssertEqual(WindowGeometry.accessibilityFrame(CGRect(x: 0, y: 1080, width: 1920, height: 1080), primaryTop: 1080), CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(WindowGeometry.accessibilityFrame(CGRect(x: 0, y: 0, width: 1920, height: 1049), primaryTop: 1080), CGRect(x: 0, y: 31, width: 1920, height: 1049))
    }
    func testScreenDetectionWorksBothDirectionsAndForNegativeCoordinates() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 266, y: 1080, width: 1440, height: 900), CGRect(x: -1280, y: 0, width: 1280, height: 720)]
        for i in screens.indices {
            XCTAssertEqual(WindowGeometry.screenIndex(for: WindowGeometry.moved(CGRect(x: 0, y: 0, width: 600, height: 400), into: screens[i], maximize: false), screens: screens), i)
        }
    }
    func testScreenChosenByLargestIntersectionAndOffscreenFallback() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 1000), CGRect(x: 1000, y: 0, width: 1000, height: 1000)]
        XCTAssertEqual(WindowGeometry.screenIndex(for: CGRect(x: 900, y: 10, width: 600, height: 400), screens: screens), 1)
        XCTAssertEqual(WindowGeometry.screenIndex(for: CGRect(x: -1000, y: 10, width: 600, height: 400), screens: screens), 0)
        XCTAssertNil(WindowGeometry.screenIndex(for: .zero, screens: []))
    }
    func testMoveFitsSmallerMonitorAndMaximizeUsesDestinationVisibleFrame() {
        let visible = CGRect(x: 266, y: 1080, width: 1440, height: 824)
        let huge = CGRect(x: 0, y: 0, width: 1920, height: 1049)
        XCTAssertEqual(WindowGeometry.moved(huge, into: visible, maximize: false), visible)
        XCTAssertEqual(WindowGeometry.moved(CGRect(x: 0, y: 0, width: 300, height: 200), into: visible, maximize: true), visible)
    }
    func testSequentialDelaysDoNotReorderActions() {
        let previous = ActionExecutor.onActionExecuted
        defer { ActionExecutor.onActionExecuted = previous }
        var fired: [ActionType] = []
        let done = expectation(description: "sequence complete")
        ActionExecutor.onActionExecuted = { action in
            fired.append(action.actionType)
            if fired.count == 3 { done.fulfill() }
        }
        var first = TriggerAction(actionType: .volumeUp); first.parameters.delayBeforeMs = 50
        let second = TriggerAction(actionType: .volumeDown)
        var third = TriggerAction(actionType: .muteVolume); third.parameters.delayBeforeMs = 10
        ActionExecutor.executeActions([first, second, third])
        XCTAssertTrue(fired.isEmpty)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(fired, [.volumeUp, .volumeDown, .muteVolume])
    }
    func testDisabledActionsDoNotExecuteOrDelaySequence() {
        let previous = ActionExecutor.onActionExecuted
        defer { ActionExecutor.onActionExecuted = previous }
        var fired: [ActionType] = []
        ActionExecutor.onActionExecuted = { fired.append($0.actionType) }
        var disabled = TriggerAction(actionType: .volumeUp); disabled.isEnabled = false; disabled.parameters.delayBeforeMs = 10000
        ActionExecutor.executeActions([disabled, TriggerAction(actionType: .volumeDown)])
        XCTAssertEqual(fired, [.volumeDown])
    }
    func testAudioUIDPreventsDuplicateNameOrReconnectAmbiguity() {
        let devices = [AudioOutputDevice(id: 1, uid: "A", name: "Speakers"), AudioOutputDevice(id: 2, uid: "B", name: "Speakers")]
        XCTAssertNil(AudioOutputSelection.resolve(name: "Speakers", uid: nil, devices: devices))
        XCTAssertEqual(AudioOutputSelection.resolve(name: "Old name", uid: "B", devices: devices)?.id, 2)
        XCTAssertNil(AudioOutputSelection.resolve(name: "Speakers", uid: "disconnected", devices: devices))
    }
    func testAirPlayRoomDoesNotResolveToGenericHALAirPlayDevice() {
        let devices = [AudioOutputDevice(id: 131, uid: "generic", name: "AirPlay")]
        XCTAssertNil(AudioOutputSelection.resolve(name: "Bedroom", uid: nil, devices: devices))
    }
    func testAudioDeviceNamesMatchExactly() {
        let device = AudioOutputDevice(id: 3, uid: "C", name: "Jim’s Speakers")
        XCTAssertEqual(AudioOutputSelection.resolve(name: "Jim’s Speakers", uid: nil, devices: [device]), device)
        XCTAssertNil(AudioOutputSelection.resolve(name: "Jim's Speakers", uid: nil, devices: [device]))
    }
    func testNewActionParametersRoundTripAndOldPresetsStillDecode() throws {
        var action = TriggerAction(actionType: .setSoundOutput)
        action.parameters.audioOutputName = "Bedroom"; action.parameters.audioOutputUID = "stable"
        let decoded = try JSONDecoder().decode(TriggerAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded, action)
        let old = try JSONDecoder().decode(ActionParameters.self, from: Data("{\"delayBeforeMs\":10}".utf8))
        XCTAssertNil(old.audioOutputName); XCTAssertNil(old.audioOutputUID)
        XCTAssertEqual(ActionType.moveWindowNextMonitorAndMaximize.category, .windowManagement)
        XCTAssertEqual(ActionType.setSoundOutput.category, .systemActions)
    }
    func testTextChunksPreserveEmojiAndCombiningCharacters() {
        let input = String(repeating: "한글 e\u{301} 😀", count: 9)
        let chunks = ActionExecutor.textChunks(input)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
        XCTAssertEqual(chunks.flatMap { $0 }, Array(input.utf16))
        for chunk in chunks {
            XCTAssertFalse((0xDC00...0xDFFF).contains(chunk.first!))
            XCTAssertFalse((0xD800...0xDBFF).contains(chunk.last!))
        }
        XCTAssertTrue(ActionExecutor.textChunks("").isEmpty)
    }

    func testTextEventsClearHotkeyModifiersAndTagBothEdges() throws {
        let units = Array("한글 😀".utf16)
        let pair = try XCTUnwrap(ActionExecutor.textEvents(units))
        XCTAssertEqual(pair.0.type, .keyDown)
        XCTAssertEqual(pair.1.type, .keyUp)
        for event in [pair.0, pair.1] {
            XCTAssertEqual(event.flags.rawValue, 0)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 0x475454)
            var count = 0
            var output = [UInt16](repeating: 0, count: 20)
            event.keyboardGetUnicodeString(maxStringLength: 20, actualStringLength: &count, unicodeString: &output)
            XCTAssertEqual(Array(output.prefix(count)), units)
        }
    }

    func testActivateApplicationCanBeSavedWithoutChangingLaunchAction() throws {
        var action = TriggerAction(actionType: .activateApplication)
        action.parameters.applicationName = "com.example.app"
        let decoded = try JSONDecoder().decode(TriggerAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.actionType.category, .applicationControl)
        XCTAssertEqual(ActionType.launchApplication.rawValue, "Launch Application")
    }

    func testVolumeStepAddsPercentagePointsAndClampsAtEndpoints() {
        XCTAssertEqual(AudioOutputService.steppedVolume(0.1875, percentagePoints: 6), 0.2475, accuracy: 0.000001)
        XCTAssertEqual(AudioOutputService.steppedVolume(0.1875, percentagePoints: -6), 0.1275, accuracy: 0.000001)
        XCTAssertEqual(AudioOutputService.steppedVolume(0.98, percentagePoints: 6), 1)
        XCTAssertEqual(AudioOutputService.steppedVolume(0.02, percentagePoints: -6), 0)
        var volume: Float32 = 0.2
        for _ in 0..<5 { volume = AudioOutputService.steppedVolume(volume, percentagePoints: 6) }
        XCTAssertEqual(volume, 0.5, accuracy: 0.000001)
    }
    func testMutedOutputIsUnmutedOnlyWhenIncreasingVolume() {
        XCTAssertTrue(AudioOutputService.shouldUnmuteOnIncrease(isMuted: true, percentagePoints: 6))
        XCTAssertFalse(AudioOutputService.shouldUnmuteOnIncrease(isMuted: true, percentagePoints: -6))
        XCTAssertFalse(AudioOutputService.shouldUnmuteOnIncrease(isMuted: true, percentagePoints: 0))
        XCTAssertFalse(AudioOutputService.shouldUnmuteOnIncrease(isMuted: false, percentagePoints: 6))
        XCTAssertEqual(AudioOutputService.steppedVolume(0, percentagePoints: 6), 0.06, accuracy: 0.000001)
    }
    func testVolumeStepParameterRoundTripsAndOldPresetsDefault() throws {
        var params = ActionParameters(); params.volumeStepPercent = 6
        XCTAssertEqual(try JSONDecoder().decode(ActionParameters.self, from: JSONEncoder().encode(params)).volumeStepPercent, 6)
        XCTAssertNil(try JSONDecoder().decode(ActionParameters.self, from: Data("{}".utf8)).volumeStepPercent)
    }

}

final class ActionWorkflowTests: XCTestCase {
    func testNestedGroupRepeatsPreserveOrderAndWaitForAsyncCompletion() {
        let done = expectation(description: "finished")
        let a = TriggerAction(actionType: .playPause), b = TriggerAction(actionType: .nextTrack)
        var group = TriggerAction(actionType: .actionGroup)
        group.parameters.children = [a, b]; group.parameters.repeatCount = 2
        var order: [UUID] = []; var active = 0
        let runner = ActionSequenceRunner { action, callback in
            XCTAssertEqual(active, 0); active += 1; order.append(action.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { active -= 1; callback(true); callback(true) }
        }
        runner.run([group]) { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(order, [a.id, b.id, a.id, b.id])
    }
    func testFailureStopsUnlessContinueIsConfigured() {
        for keepGoing in [false, true] {
            var first = TriggerAction(actionType: .playPause); first.parameters.continueOnFailure = keepGoing
            let second = TriggerAction(actionType: .nextTrack); var order: [UUID] = []; var result: Bool?
            let runner = ActionSequenceRunner { action, done in order.append(action.id); done(action.id != first.id) }
            runner.run([first, second]) { result = $0 }
            XCTAssertEqual(order, keepGoing ? [first.id, second.id] : [first.id])
            XCTAssertEqual(result, keepGoing)
        }
    }
    func testConditionSkipsEntireGroupAndDisabledSteps() {
        var group = TriggerAction(actionType: .actionGroup)
        group.parameters.onlyAppBundleID = "test.app"; group.parameters.windowTitleContains = "Inbox"
        group.parameters.children = [TriggerAction(actionType: .playPause)]
        XCTAssertTrue(ActionSequenceRunner.matches(group, bundleID: "test.app", windowTitle: "inbox — mail"))
        XCTAssertFalse(ActionSequenceRunner.matches(group, bundleID: "wrong.app", windowTitle: "Inbox"))
        XCTAssertFalse(ActionSequenceRunner.matches(group, bundleID: "test.app", windowTitle: "Draft"))
        var disabled = TriggerAction(actionType: .playPause); disabled.isEnabled = false
        var calls = 0
        let runner = ActionSequenceRunner(perform: { _, done in calls += 1; done(true) }, matches: { _ in false })
        runner.run([group, disabled]) { XCTAssertTrue($0) }
        XCTAssertEqual(calls, 0)
    }
    func testCancelDuringDelayDoesNotExecuteNextStepAndCompletesOnce() {
        var pause = TriggerAction(actionType: .wait); pause.parameters.waitMs = 40
        var calls = 0; var completions = 0
        let runner = ActionSequenceRunner { _, done in calls += 1; done(true) }
        runner.run([pause, TriggerAction(actionType: .playPause)]) { ok in XCTAssertFalse(ok); completions += 1 }
        runner.cancel(); runner.cancel()
        let done = expectation(description: "delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(calls, 0); XCTAssertEqual(completions, 1)
    }
    func testBeforeAfterAndRepeatTiming() {
        var a = TriggerAction(actionType: .playPause)
        a.parameters.delayBeforeMs = 20; a.parameters.delayAfterMs = 20
        a.parameters.repeatCount = 2; a.parameters.repeatIntervalMs = 20
        let start = ProcessInfo.processInfo.systemUptime; var times: [Double] = []
        let done = expectation(description: "timing")
        let runner = ActionSequenceRunner { _, callback in times.append(ProcessInfo.processInfo.systemUptime - start); callback(true) }
        runner.run([a, TriggerAction(actionType: .nextTrack)]) { _ in done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(times.count, 3); XCTAssertGreaterThanOrEqual(times[0], 0.018)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.018); XCTAssertGreaterThanOrEqual(times[2] - times[1], 0.018)
    }
    func testNestedMutationAndDuplicateUseFreshIDsWithoutLosingSettings() {
        var child = TriggerAction(actionType: .wait); child.parameters.waitMs = 123
        var group = TriggerAction(actionType: .actionGroup); group.parameters.children = [child]
        let copy = ActionTree.duplicate(group)
        XCTAssertNotEqual(copy.id, group.id); XCTAssertNotEqual(copy.parameters.children?.first?.id, child.id)
        XCTAssertEqual(copy.parameters.children?.first?.parameters.waitMs, 123)
        var actions = [group]
        XCTAssertTrue(ActionTree.edit(&actions, id: child.id) { list, i in list[i].parameters.waitMs = 456 })
        XCTAssertEqual(actions[0].parameters.children?[0].parameters.waitMs, 456)
        XCTAssertEqual(ActionTree.rows(actions).map(\.depth), [0, 1])
    }
    func testWorkflowJSONAndCoreDataRoundTrip() throws {
        var child = TriggerAction(actionType: .sendKeyStroke); child.parameters.shortcutKeyCode = 12; child.parameters.shortcutModifiers = 1048576
        var group = TriggerAction(actionType: .actionGroup)
        group.parameters.children = [child]; group.parameters.repeatCount = 3; group.parameters.onlyAppBundleID = "test.app"
        group.parameters.notes = "Fixture"; group.parameters.label = "Test group"; group.parameters.delayAfterMs = 15
        var trigger = Trigger(name: "Test", input: .trackpadGesture(.threeFingerDoubleTap)); trigger.actions = [group]
        var preset = Preset(name: "Test"); preset.triggers = [trigger]
        let data = try PresetCodec.encode(preset, envelope: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 9)
        let decoded = try PresetCodec.decode(data); XCTAssertEqual(decoded.triggers, preset.triggers)
        let store = try TrackpadPresetStore(url: nil, inMemory: true); try store.save(decoded)
        XCTAssertEqual(try store.load()?.triggers, preset.triggers)
    }
    func testLegacyActionsDecodeWithoutWorkflowOptions() throws {
        let action = TriggerAction(actionType: .playPause)
        let raw = try JSONEncoder().encode(action); let decoded = try JSONDecoder().decode(TriggerAction.self, from: raw)
        XCTAssertNil(decoded.parameters.children); XCTAssertNil(decoded.parameters.repeatCount)
        XCTAssertNil(ActionTree.problem([decoded]))
    }
    func testLimitsRejectInvalidRepeatDepthAndDuplicateIDs() {
        var action = TriggerAction(actionType: .wait); action.parameters.repeatCount = 0
        XCTAssertNotNil(ActionTree.problem([action])); action.parameters.repeatCount = 1
        XCTAssertNotNil(ActionTree.problem([action, action]))
        for _ in 0..<10 { var parent = TriggerAction(actionType: .actionGroup); parent.parameters.children = [action]; action = parent }
        XCTAssertNotNil(ActionTree.problem([action]))
        var group = TriggerAction(actionType: .actionGroup); group.parameters.repeatCount = 100
        var child = TriggerAction(actionType: .wait); child.parameters.repeatCount = 100; group.parameters.children = [child]
        XCTAssertNotNil(ActionTree.problem([group]))
    }
    func testSameTriggerCannotInterleaveRunningSequences() {
        let previous = ActionExecutor.onActionExecuted; defer { ActionExecutor.onActionExecuted = previous; ActionExecutor.cancelAllSequences() }
        var waitAction = TriggerAction(actionType: .wait); waitAction.parameters.waitMs = 50
        let key = UUID(); var rejected = false
        ActionExecutor.executeActions([waitAction], triggerID: key)
        ActionExecutor.executeActions([waitAction], triggerID: key) { rejected = !$0 }
        XCTAssertTrue(rejected)
    }
}

final class AdvancedWorkflowTests: XCTestCase {
    override func tearDown() {
        ActionExecutor.cancelAllSequences(); ActionExecutor.registerTriggers([]); ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }
    private func named(_ name: String, actions: [TriggerAction]) -> Trigger {
        var t = Trigger(name: name, input: .namedTrigger(name)); t.actions = actions; return t
    }
    private func call(_ name: String) -> TriggerAction {
        var a = TriggerAction(actionType: .triggerNamedTrigger); a.parameters.namedTriggerName = name; return a
    }
    private func pause(_ ms: Int) -> TriggerAction {
        var a = TriggerAction(actionType: .wait); a.parameters.waitMs = ms; return a
    }
    func testModifierSpecificityAndScopeWithLegacyWildcard() {
        var base = Trigger(name: "legacy", input: .trackpadGesture(.fourFingerTap))
        var command = Trigger(name: "command", input: base.input); command.requiredModifiers = NSEvent.ModifierFlags.command.rawValue
        var plain = Trigger(name: "plain", input: base.input); plain.requiredModifiers = 0
        func resolve(_ items: [Trigger], flags: NSEvent.ModifierFlags) -> [String] {
            TriggerResolver.resolve(items, payload: base.input, frontBundleID: "test.app", payloadOf: { $0.input },
                appBundleIDOf: { $0.appBundleID }, modifiers: flags.rawValue, requiredModifiersOf: { $0.requiredModifiers }).map(\.name)
        }
        XCTAssertEqual(resolve([base, command, plain], flags: [.command, .capsLock]), ["command"])
        XCTAssertEqual(resolve([base, command, plain], flags: []), ["plain"])
        XCTAssertEqual(resolve([base, command, plain], flags: [.shift, .command]), ["legacy"])
        base.appBundleID = "test.app"
        XCTAssertEqual(resolve([base, command], flags: .command), ["legacy"]) // App scope has priority.
        base.requiredModifiers = NSEvent.ModifierFlags.option.rawValue
        XCTAssertEqual(resolve([base, command], flags: .command), ["command"])
    }
    func testNamedCallWaitsThenResumesParent() {
        let childAction = TriggerAction(actionType: .playPause), end = TriggerAction(actionType: .nextTrack)
        let child = named("child", actions: [pause(20), childAction]); var seen: [UUID] = []
        ActionExecutor.registerTriggers([child]); ActionExecutor.onActionExecuted = { seen.append($0.id) }
        let done = expectation(description: "parent")
        ActionExecutor.executeActions([call("child"), end]) { XCTAssertTrue($0); done.fulfill() }
        XCTAssertTrue(seen.isEmpty); wait(for: [done], timeout: 1)
        XCTAssertEqual(seen, [childAction.id, end.id])
    }
    func testNamedRecursionMissingAndAmbiguityFailWithoutSideEffects() {
        let a = named("a", actions: [call("b")]), b = named("b", actions: [call("a")])
        ActionExecutor.onActionExecuted = { _ in XCTFail("No leaf action should run") }
        ActionExecutor.registerTriggers([a, b])
        var result: Bool?
        ActionExecutor.executeActions([call("a")]) { result = $0 }; XCTAssertEqual(result, false)
        ActionExecutor.executeActions([call("missing")]) { result = $0 }; XCTAssertEqual(result, false)
        ActionExecutor.registerTriggers([a, named("a", actions: [])])
        ActionExecutor.executeActions([call("a")]) { result = $0 }; XCTAssertEqual(result, false)
        let selfCall = named("self", actions: [call("self")]); ActionExecutor.registerTriggers([selfCall])
        ActionExecutor.executeActions(selfCall.actions, triggerID: selfCall.id) { result = $0 }; XCTAssertEqual(result, false)
    }
    func testNamedAppScopeOverridesGlobalAndDisabledNamesAreExcluded() {
        let globalAction = TriggerAction(actionType: .playPause), scopedAction = TriggerAction(actionType: .nextTrack)
        let global = named("child", actions: [globalAction]); var scoped = named("child", actions: [scopedAction])
        scoped.appBundleID = ActionExecutor.externalBundleID ?? "test.no.front"
        var seen: [UUID] = []; ActionExecutor.onActionExecuted = { seen.append($0.id) }
        ActionExecutor.registerTriggers([global, scoped]); ActionExecutor.executeActions([call("child")])
        XCTAssertEqual(seen, [ActionExecutor.externalBundleID == nil ? globalAction.id : scopedAction.id])
        seen = []; scoped.isEnabled = false
        ActionExecutor.registerTriggers([global, scoped]); ActionExecutor.executeActions([call("child")]); XCTAssertEqual(seen, [globalAction.id])
    }
    func testCancelParentCancelsWaitingNamedDescendant() {
        let child = named("child", actions: [pause(60), TriggerAction(actionType: .playPause)])
        ActionExecutor.registerTriggers([child]); ActionExecutor.onActionExecuted = { _ in XCTFail("Cancelled descendant ran") }
        let id = UUID(); var completions = 0
        ActionExecutor.executeActions([call("child")], triggerID: id) { XCTAssertFalse($0); completions += 1 }
        ActionExecutor.cancelSequence(id)
        let done = expectation(description: "wait past delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done.fulfill() }
        wait(for: [done], timeout: 1); XCTAssertEqual(completions, 1)
    }
    func testRestartCancelsOldRunAndOldCompletionCannotRemoveNewRun() {
        var trigger = named("restart", actions: [pause(40), TriggerAction(actionType: .playPause)])
        trigger.executionPolicy = .restart; ActionExecutor.registerTriggers([trigger])
        var seen = 0; ActionExecutor.onActionExecuted = { _ in seen += 1 }
        var old: Bool?; ActionExecutor.executeActions(trigger.actions, triggerID: trigger.id) { old = $0 }
        let done = expectation(description: "new run")
        ActionExecutor.executeActions(trigger.actions, triggerID: trigger.id) { XCTAssertTrue($0); done.fulfill() }
        XCTAssertEqual(old, false); wait(for: [done], timeout: 1); XCTAssertEqual(seen, 1)
    }
    func testParallelCapAndCancellation() {
        var trigger = named("parallel", actions: [pause(60)])
        trigger.executionPolicy = .parallel; ActionExecutor.registerTriggers([trigger])
        var completions = 0
        for _ in 0..<4 { ActionExecutor.executeActions(trigger.actions, triggerID: trigger.id) { XCTAssertFalse($0); completions += 1 } }
        var fifth: Bool?; ActionExecutor.executeActions(trigger.actions, triggerID: trigger.id) { fifth = $0 }
        XCTAssertEqual(fifth, false); XCTAssertEqual(completions, 0)
        ActionExecutor.cancelSequence(trigger.id); XCTAssertEqual(completions, 4)
    }
    func testSystemConditionsFailClosedAndCombine() {
        var action = TriggerAction(actionType: .playPause)
        action.parameters.minimumBatteryPercent = 20; action.parameters.maximumBatteryPercent = 80
        action.parameters.minimumDisplayCount = 2; action.parameters.maximumDisplayCount = 3; action.parameters.powerSource = "battery"
        func matches(_ system: SystemConditions?) -> Bool { ActionSequenceRunner.matches(action, bundleID: "", windowTitle: "", system: system) }
        XCTAssertTrue(matches(SystemConditions(batteryPercent: 50, powerSource: "battery", displayCount: 2)))
        XCTAssertFalse(matches(nil)); XCTAssertFalse(matches(SystemConditions(displayCount: 2)))
        XCTAssertFalse(matches(SystemConditions(batteryPercent: 90, powerSource: "battery", displayCount: 2)))
        XCTAssertFalse(matches(SystemConditions(batteryPercent: 50, powerSource: "ac", displayCount: 2)))
        XCTAssertFalse(matches(SystemConditions(batteryPercent: 50, powerSource: "battery", displayCount: 1)))
        action.parameters.minimumBatteryPercent = 90; XCTAssertNotNil(ActionTree.problem([action]))
    }
    func testHoldStopsOnReleaseAndDoesNotOverlapSlowAction() {
        var time = 0.0; var held = true; var calls = 0; var stops = 0
        var callbacks: [(Bool) -> Void] = []
        let repeater = HoldRepeater(delayMs: 100, intervalMs: 50, isHeld: { held }, now: { time }, automatic: false) { done in
            calls += 1; callbacks.append(done)
        }
        repeater.start { stops += 1 }; XCTAssertEqual(calls, 1)
        time = 0.12; repeater.tick(); XCTAssertEqual(calls, 1)
        time = 0.13; callbacks[0](true)
        time = 0.17; repeater.tick(); XCTAssertEqual(calls, 1)
        time = 0.19; repeater.tick(); XCTAssertEqual(calls, 2)
        held = false; repeater.tick(); XCTAssertEqual(stops, 1)
        callbacks[1](true); time = 10; repeater.tick(); repeater.cancel()
        XCTAssertEqual(calls, 2); XCTAssertEqual(stops, 1)
    }
    func testHoldUsesInitialDelayAndIntervalsWithoutCatchupOrDuplicateCompletion() {
        var time = 100.0; var calls = 0; var stops = 0
        var callbacks: [(Bool) -> Void] = []
        let repeater = HoldRepeater(delayMs: 400, intervalMs: 150, isHeld: { true }, now: { time }, automatic: false) { done in
            calls += 1; callbacks.append(done)
        }
        repeater.start { stops += 1 }; callbacks[0](true)
        time = 100.39; repeater.tick(); XCTAssertEqual(calls, 1)
        time = 100.4; repeater.tick(); XCTAssertEqual(calls, 2)
        callbacks[0](false); callbacks[1](true); XCTAssertEqual(stops, 0)
        time = 100.54; repeater.tick(); XCTAssertEqual(calls, 2)
        time = 105; repeater.tick(); XCTAssertEqual(calls, 3)
        repeater.tick(); XCTAssertEqual(calls, 3)
        callbacks[2](false); XCTAssertEqual(stops, 1)
        repeater.start {}; repeater.tick(); XCTAssertEqual(calls, 3)
    }
    func testHoldAlreadyReleasedDoesNotExecute() {
        var calls = 0; var stops = 0
        let repeater = HoldRepeater(delayMs: 100, intervalMs: 50, isHeld: { false }, automatic: false) { _ in calls += 1 }
        repeater.start { stops += 1 }; repeater.tick(); repeater.cancel()
        XCTAssertEqual(calls, 0); XCTAssertEqual(stops, 1)
    }
    func testTriggerAndConditionsRoundTripInJSONAndDatabaseAndLegacyDefaults() throws {
        var t = Trigger(name: "test", input: .trackpadGesture(.cornerClickTopLeft))
        t.requiredModifiers = NSEvent.ModifierFlags.option.rawValue; t.executionPolicy = .parallel
        t.repeatWhileHeld = true; t.holdDelayMs = 550; t.holdIntervalMs = 250; t.keyboardPhase = .keyUp
        var a = call("macro"); a.parameters.minimumBatteryPercent = 20; a.parameters.minimumDisplayCount = 2; t.actions = [a]
        var preset = Preset(name: "test"); preset.triggers = [t]
        let decoded = try PresetCodec.decode(PresetCodec.encode(preset, envelope: true)); XCTAssertEqual(decoded.triggers, [t])
        let store = try TrackpadPresetStore(url: nil, inMemory: true); try store.save(decoded); XCTAssertEqual(try store.load()?.triggers, [t])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        for key in ["requiredModifiers", "executionPolicy", "keyboardPhase", "repeatWhileHeld", "holdDelayMs", "holdIntervalMs"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.requiredModifiers); XCTAssertEqual(legacy.executionPolicy, .ignoreWhileRunning)
        XCTAssertFalse(legacy.repeatWhileHeld); XCTAssertEqual(legacy.keyboardPhase, .keyDown)
    }
}

final class KeyboardDispatchTests: XCTestCase {
    private func drain() {
        let done = expectation(description: "dispatch"); DispatchQueue.main.async { done.fulfill() }; wait(for: [done], timeout: 1)
    }
    func testKeyDownIsConsumedOnceAndReleaseIsPairedAfterModifierChanges() {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        var trigger = Trigger(name: "fixture", input: .keyboardShortcut(KeyboardShortcut(keyCode: 12, modifiers: .option)))
        trigger.actions = [TriggerAction(actionType: .playPause)]
        var count = 0; ActionExecutor.onActionExecuted = { _ in count += 1 }
        defer { monitor.unregisterAll(); ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]) }
        ActionExecutor.registerTriggers([trigger]); monitor.registerTriggers([trigger])
        XCTAssertTrue(monitor.handleInput(keyCode: 12, modifiers: .option, isDown: true))
        XCTAssertTrue(monitor.handleInput(keyCode: 12, modifiers: .option, isDown: true, isRepeat: true))
        drain(); XCTAssertEqual(count, 1)
        XCTAssertTrue(monitor.handleInput(keyCode: 12, modifiers: [], isDown: false))
        XCTAssertFalse(monitor.handleInput(keyCode: 12, modifiers: [], isDown: false))
        XCTAssertFalse(monitor.handleInput(keyCode: 11, modifiers: [], isDown: true))
    }
    func testKeyUpOnlyRunsAfterMatchingDownAndPendingFireIsDiscardedOnReconfiguration() {
        let monitor = KeyboardMonitor(systemMonitoringEnabled: false)
        var trigger = Trigger(name: "fixture", input: .keyboardShortcut(KeyboardShortcut(keyCode: 12, modifiers: [])))
        trigger.keyboardPhase = .keyUp; trigger.actions = [TriggerAction(actionType: .playPause)]
        var count = 0; ActionExecutor.onActionExecuted = { _ in count += 1 }
        defer { monitor.unregisterAll(); ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]) }
        ActionExecutor.registerTriggers([trigger]); monitor.registerTriggers([trigger])
        XCTAssertFalse(monitor.handleInput(keyCode: 12, modifiers: [], isDown: false))
        XCTAssertTrue(monitor.handleInput(keyCode: 12, modifiers: [], isDown: true)); drain(); XCTAssertEqual(count, 0)
        XCTAssertTrue(monitor.handleInput(keyCode: 12, modifiers: [], isDown: false)); drain(); XCTAssertEqual(count, 1)
        trigger.keyboardPhase = .keyDown; monitor.registerTriggers([trigger]); ActionExecutor.registerTriggers([trigger])
        XCTAssertTrue(monitor.handleInput(keyCode: 12, modifiers: [], isDown: true))
        monitor.registerTriggers([trigger]); drain(); XCTAssertEqual(count, 1)
    }
}

extension KeyboardDispatchTests {
    func testFunctionKeyNoiseDoesNotBreakLegacyShortcutsAndFnLetterRemainsDistinct() {
        XCTAssertEqual(KeyboardShortcut(keyCode: 122, modifiers: [.function, .capsLock]), KeyboardShortcut(keyCode: 122, modifiers: []))
        XCTAssertNotEqual(KeyboardShortcut(keyCode: 12, modifiers: .function), KeyboardShortcut(keyCode: 12, modifiers: []))
        XCTAssertEqual(KeyboardShortcut(keyCode: 12, modifiers: [.capsLock, .numericPad, .option]), KeyboardShortcut(keyCode: 12, modifiers: .option))
    }
}
