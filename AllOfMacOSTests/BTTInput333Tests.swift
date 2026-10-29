import XCTest
import AppKit
@testable import AllOfMacOS

// 3.3.3 BTT input: complete MIDI input decoding, continuous value bindings
// (B03) and Force Touch pressure stages. Everything here runs on synthetic
// byte streams, synthetic pressure readings and fake sinks: no MIDI device,
// trackpad, output volume or display brightness is touched.

// MARK: - Item 1: MIDI decoder and MIDI trigger types

final class BTTInput333MIDITests: XCTestCase {
    private func decode(_ packets: [[UInt8]]) -> [MIDIInputMessage] {
        var decoder = MIDIMessageDecoder()
        return packets.flatMap { decoder.consume($0) }
    }
    private func message(_ status: Int, _ channel: Int, _ number: Int, _ value: Int) -> MIDIInputMessage {
        MIDIInputMessage(status: status, channel: channel, number: number, value: value)
    }

    /// The audit probe (midi-parser-probe.swift) fed these exact streams to the
    /// 3.3.2 decoder; Pitch Bend, Program Change, Channel and Poly Pressure all
    /// came back empty.
    func testAuditProbeStreamsAllDecode() {
        XCTAssertEqual(decode([[0x90, 60, 100]]), [message(0x90, 1, 60, 100)])
        XCTAssertEqual(decode([[0xB0, 7, 64]]), [message(0xB0, 1, 7, 64)])
        XCTAssertEqual(decode([[0xE0, 0, 64]]), [message(0xE0, 1, 0, 8192)])
        XCTAssertEqual(decode([[0xC0, 12]]), [message(0xC0, 1, 12, 12)])
        XCTAssertEqual(decode([[0xD0, 50]]), [message(0xD0, 1, 0, 50)])
        XCTAssertEqual(decode([[0xA0, 60, 50]]), [message(0xA0, 1, 60, 50)])
    }

    func testNoteOnAndNoteOffWithZeroVelocityRelease() {
        XCTAssertEqual(decode([[0x93, 64, 127, 64, 0, 0x83, 64, 30]]),
                       [message(0x90, 4, 64, 127), message(0x80, 4, 64, 0), message(0x80, 4, 64, 30)])
    }

    func testControlChangeKeepsRunningStatusAcrossPackets() {
        XCTAssertEqual(decode([[0xBF, 1], [10, 1, 11], [1, 12]]),
                       [message(0xB0, 16, 1, 10), message(0xB0, 16, 1, 11), message(0xB0, 16, 1, 12)])
    }

    func testPitchBendIsFourteenBitLeastSignificantFirst() {
        XCTAssertEqual(decode([[0xE3, 0x7F, 0x7F, 0x00, 0x00, 0x01, 0x40]]),
                       [message(0xE0, 4, 0, 16383), message(0xE0, 4, 0, 0), message(0xE0, 4, 0, 8193)])
    }

    func testProgramChangeIsOneDataByteWithRunningStatus() {
        XCTAssertEqual(decode([[0xC9, 0, 127], [5]]),
                       [message(0xC0, 10, 0, 0), message(0xC0, 10, 127, 127), message(0xC0, 10, 5, 5)])
    }

    func testChannelPressureIsOneDataByteWithRunningStatus() {
        XCTAssertEqual(decode([[0xD1, 0, 64, 127]]),
                       [message(0xD0, 2, 0, 0), message(0xD0, 2, 0, 64), message(0xD0, 2, 0, 127)])
    }

    func testPolyPressureCarriesTheNote() {
        XCTAssertEqual(decode([[0xA2, 60, 10, 62, 90]]), [message(0xA0, 3, 60, 10), message(0xA0, 3, 62, 90)])
    }

    func testRealtimeBytesInsideAMessageChangeNothing() {
        // Clock, start, active sensing and reset inside a split pitch bend and
        // between running-status messages.
        XCTAssertEqual(decode([[0xE0, 0xF8], [0x10, 0xFA, 0xFE], [0x20, 0xFF, 0x30, 0xF8, 0x40]]),
                       [message(0xE0, 1, 0, 0x10 | 0x20 << 7), message(0xE0, 1, 0, 0x30 | 0x40 << 7)])
    }

    func testSysExIsSkippedEvenAcrossPacketsAndCancelsRunningStatus() {
        // CC, then a SysEx split over two packets, then bytes that would be a CC
        // under running status: the specification says they are not.
        XCTAssertEqual(decode([[0xB0, 7, 100, 0xF0, 0x7E, 0x7F], [0x06, 0x01, 0xF7, 7, 101], [0xB0, 7, 102]]),
                       [message(0xB0, 1, 7, 100), message(0xB0, 1, 7, 102)])
        // A dump that loses its F7 ends at the next status byte.
        XCTAssertEqual(decode([[0xF0, 1, 2, 3, 0xD0, 9]]), [message(0xD0, 1, 0, 9)])
    }

    func testSystemCommonDataIsSkipped() {
        // Song position (2 data bytes), MTC quarter frame and song select (1 each).
        XCTAssertEqual(decode([[0x90, 60, 1, 0xF2, 0x10, 0x20, 0xF1, 0x05, 0xF3, 0x02, 61, 2]]),
                       [message(0x90, 1, 60, 1)])
    }

    func testIncompleteMessageIsDroppedByTheNextStatus() {
        XCTAssertEqual(decode([[0x90, 60, 0xB0, 1, 2]]), [message(0xB0, 1, 1, 2)])
    }

    // MARK: Matching

    private func midi(_ status: Int, channel: Int = 0, number: Int = 0, low: Int = 0, high: Int = 127,
                      device: String = "") -> SystemTriggerKind {
        .midiMessage(device: device, status: status, channel: channel, number: number, minimumValue: low, maximumValue: high)
    }
    private func signal(_ message: MIDIInputMessage, device: String = "Keys") -> SystemSignal {
        .midi(device: device, status: message.status, channel: message.channel, number: message.number, value: message.value)
    }

    func testPitchBendTriggerIgnoresNumberAndFiltersTheFourteenBitRange() {
        let up = midi(0xE0, channel: 2, number: 99, low: 12000, high: 16383)
        XCTAssertTrue(SystemSignalMatcher.matches(up, signal(message(0xE0, 2, 0, 16383))))
        XCTAssertFalse(SystemSignalMatcher.matches(up, signal(message(0xE0, 2, 0, 8192))), "centre is outside the range")
        XCTAssertFalse(SystemSignalMatcher.matches(up, signal(message(0xE0, 3, 0, 16383))), "channel filter")
    }

    func testProgramChangeTriggerMatchesTheProgramAndIgnoresTheValueRange() {
        let program = midi(0xC0, channel: 1, number: 5, low: 1, high: 127)
        XCTAssertTrue(SystemSignalMatcher.matches(program, signal(message(0xC0, 1, 5, 5))))
        XCTAssertFalse(SystemSignalMatcher.matches(program, signal(message(0xC0, 1, 6, 6))))
        let programZero = midi(0xC0, number: 0, low: 1, high: 127)
        XCTAssertTrue(SystemSignalMatcher.matches(programZero, signal(message(0xC0, 9, 0, 0))),
                      "program 0 must not be filtered out by a 1…127 value range")
        let anyProgram = midi(0xC0, number: MIDIMessageType.anyNumber)
        XCTAssertTrue(SystemSignalMatcher.matches(anyProgram, signal(message(0xC0, 16, 77, 77))))
    }

    func testChannelPressureTriggerFiltersPressure() {
        let hard = midi(0xD0, channel: 0, number: 0, low: 100, high: 127)
        XCTAssertTrue(SystemSignalMatcher.matches(hard, signal(message(0xD0, 7, 0, 110))))
        XCTAssertFalse(SystemSignalMatcher.matches(hard, signal(message(0xD0, 7, 0, 40))))
        XCTAssertFalse(SystemSignalMatcher.matches(hard, signal(message(0xA0, 7, 0, 110))), "poly pressure is a different message")
    }

    func testPolyPressureTriggerFiltersNoteOrMatchesAnyNote() {
        let note = midi(0xA0, number: 60, low: 1, high: 127)
        XCTAssertTrue(SystemSignalMatcher.matches(note, signal(message(0xA0, 1, 60, 5))))
        XCTAssertFalse(SystemSignalMatcher.matches(note, signal(message(0xA0, 1, 61, 5))))
        let any = midi(0xA0, number: MIDIMessageType.anyNumber, low: 1, high: 127)
        XCTAssertTrue(SystemSignalMatcher.matches(any, signal(message(0xA0, 1, 61, 5))))
        XCTAssertFalse(SystemSignalMatcher.matches(any, signal(message(0xA0, 1, 61, 0))), "value range still applies")
    }

    func testAnyNumberAndValueBindingMatchingForNotesAndControllers() {
        let anyNote = midi(0x90, number: MIDIMessageType.anyNumber, low: 1, high: 127)
        XCTAssertTrue(SystemSignalMatcher.matches(anyNote, signal(message(0x90, 1, 36, 90))))
        let cc = midi(0xB0, channel: 1, number: 7, low: 64, high: 127)
        // A value binding takes every value; the trigger's range does not gate it.
        XCTAssertFalse(SystemSignalMatcher.matches(cc, signal(message(0xB0, 1, 7, 0))))
        XCTAssertTrue(SystemSignalMatcher.midiMatches(cc, device: "Keys", status: 0xB0, channel: 1, number: 7, value: 0, checkValue: false))
        XCTAssertFalse(SystemSignalMatcher.midiMatches(cc, device: "Keys", status: 0xB0, channel: 1, number: 8, value: 0, checkValue: false))
    }

    func testLegacyNoteAndControllerTriggersMatchExactlyAsBefore() {
        let kind = midi(0xB0, channel: 2, number: 7, low: 64, high: 127, device: "regex:^Keys [0-9]+$")
        XCTAssertTrue(SystemSignalMatcher.matches(kind, signal(message(0xB0, 2, 7, 90), device: "Keys 49")))
        XCTAssertFalse(SystemSignalMatcher.matches(kind, signal(message(0xB0, 2, 7, 90), device: "Pads")))
        XCTAssertEqual(kind.displayName, "MIDI CC 7 · channel 2")
        XCTAssertEqual(midi(0x90, number: 60).displayName, "MIDI Note On 60 · channel any")
    }

    func testNewMessageTypesHaveReadableNames() {
        XCTAssertEqual(midi(0xE0, channel: 1).displayName, "MIDI Pitch Bend · channel 1")
        XCTAssertEqual(midi(0xC0, channel: 3, number: 5).displayName, "MIDI Program Change 5 · channel 3")
        XCTAssertEqual(midi(0xD0).displayName, "MIDI Channel Pressure · channel any")
        XCTAssertEqual(midi(0xA0, number: MIDIMessageType.anyNumber).displayName, "MIDI Poly Pressure · any note · channel any")
        XCTAssertEqual(MIDIMessageType.allCases.map(\.rawValue), [0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0])
        XCTAssertEqual(MIDIMessageType.allCases.filter(\.isContinuous), [.polyPressure, .controlChange, .channelPressure, .pitchBend])
    }

    func testValidationCoversEveryFilter() {
        XCTAssertNil(TriggerValidation.systemProblem(for: midi(0xE0, low: 0, high: 16383)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: midi(0xE0, low: 0, high: 16384)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: midi(0xB0, low: 0, high: 128)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: midi(0xF0)), "system messages are not triggers")
        XCTAssertNotNil(TriggerValidation.systemProblem(for: midi(0x90, channel: 17)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: midi(0x90, number: 128)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: midi(0x90, number: -2)))
        XCTAssertNil(TriggerValidation.systemProblem(for: midi(0xD0, number: 500)), "channel pressure has no number")
        XCTAssertNil(TriggerValidation.systemProblem(for: midi(0xC0, number: 0, low: 90, high: 3)), "program change has no value range")
    }

    func testNewKindsRoundTripAndInstallOnlyTheMIDISource() throws {
        let kinds = [midi(0xE0), midi(0xC0, number: -1), midi(0xD0), midi(0xA0, number: 60)]
        for kind in kinds { XCTAssertEqual(try JSONDecoder().decode(SystemTriggerKind.self, from: JSONEncoder().encode(kind)), kind) }
        XCTAssertEqual(SignalSource.needs(for: kinds), [.midi])
    }

    func testDecodedMessagesReachTriggersThroughTheMonitor() {
        let rig = SystemRig(kinds: [midi(0xE0, low: 16000, high: 16383), midi(0xC0, number: 3), midi(0xD0, low: 1, high: 127),
                                    midi(0xA0, number: 60, low: 1, high: 127)])
        var decoder = MIDIMessageDecoder()
        for message in decoder.consume([0xE0, 0x7F, 0x7F, 0xC0, 3, 0xD0, 9, 0xA0, 60, 4]) {
            rig.monitor.handle(signal(message))
        }
        rig.drain()
        XCTAssertEqual(rig.fired, ["t0", "t1", "t2", "t3"])
    }
}

// MARK: - Shared rigs

final class FakeSignalProvider333: SystemSignalProvider {
    var started: [Set<SignalSource>] = []
    func start(_ needs: Set<SignalSource>, emit: @escaping (SystemSignal) -> Void) { started.append(needs) }
    func stop() {}
}

/// Collects what a continuous sink would have applied. Nothing real is set.
/// Captures are weak: a test may keep only the engine and drop the recorder.
final class RecordingSink333 {
    private(set) var applied: [(ContinuousTargetRef, Double)] = []
    var scheduled: [(TimeInterval, () -> Void)] = []
    var now: TimeInterval = 100
    lazy var sink = ContinuousValueSink(minimumInterval: 0.05, clock: { [weak self] in self?.now ?? 0 },
                                        schedule: { [weak self] delay, work in self?.scheduled.append((delay, work)) },
                                        apply: { [weak self] target, value in self?.applied.append((target, value)); return true })
    /// Runs the scheduled flushes whose time has come, in order.
    func run(advancingBy seconds: TimeInterval = 0) {
        now += seconds
        let due = scheduled; scheduled.removeAll()
        for (_, work) in due { work() }
    }
    var values: [Double] { applied.map(\.1) }
}

final class SystemRig {
    let provider = FakeSignalProvider333()
    let monitor: SystemTriggerMonitor
    var fired: [String] = []
    init(kinds: [SystemTriggerKind], configure: (inout Trigger, Int) -> Void = { _, _ in }) {
        monitor = SystemTriggerMonitor(provider: provider)
        var triggers: [Trigger] = []
        for (index, kind) in kinds.enumerated() {
            var trigger = Trigger(name: "t\(index)", input: .systemEvent(kind))
            var parameters = ActionParameters(); parameters.text = "t\(index)"
            trigger.actions = [TriggerAction(actionType: .typeText, parameters: parameters)]
            configure(&trigger, index)
            triggers.append(trigger)
        }
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        ActionExecutor.onActionExecuted = { [weak self] in self?.fired.append($0.parameters.text ?? "?") }
        ActionExecutor.registerTriggers(triggers)
        monitor.registerTriggers(triggers)
    }
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    deinit { monitor.unregisterAll(); ActionExecutor.onActionExecuted = nil; ActionExecutor.registerTriggers([]) }
}

// MARK: - Item 2: continuous value bindings (B03)

final class BTTInput333ValueBindingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
    }
    override func tearDown() {
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    private final class Clock { var now: TimeInterval = 100 }
    private func engine(level: Double? = 0.5, target: ContinuousTargetRef? = .systemVolume,
                        clock: Clock = Clock()) -> (ContinuousValueEngine, RecordingSink333) {
        let recorder = RecordingSink333()
        let engine = ContinuousValueEngine(sink: recorder.sink, resolve: { _ in target },
                                           currentLevel: { _ in level }, clock: { clock.now })
        return (engine, recorder)
    }
    private func assertValues(_ actual: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 0.0001, "\(actual)", file: file, line: line) }
    }

    // MARK: Mapping

    func testInputRangeIsClampedAndScaledIntoTheOutputRange() {
        let binding = ContinuousValueBinding(inputMinimum: 0.25, inputMaximum: 0.75, outputMinimum: 0.2, outputMaximum: 0.8)
        XCTAssertEqual(binding.output(forInput: 0), 0.2, accuracy: 1e-9)
        XCTAssertEqual(binding.output(forInput: 0.25), 0.2, accuracy: 1e-9)
        XCTAssertEqual(binding.output(forInput: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(binding.output(forInput: 1), 0.8, accuracy: 1e-9)
        XCTAssertEqual(binding.output(forInput: .nan), 0.2, accuracy: 1e-9, "a bad reading maps to the minimum, never NaN")
    }

    func testInversionReversesTheDirection() {
        let binding = ContinuousValueBinding(outputMinimum: 0.1, outputMaximum: 0.9, inverted: true)
        XCTAssertEqual(binding.output(forInput: 0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(binding.output(forInput: 1), 0.1, accuracy: 1e-9)
    }

    func testCurvesAreMonotonicEndpointPreservingAndInvertible() {
        for curve in ContinuousValueBinding.Curve.allCases {
            XCTAssertEqual(curve.apply(0), 0, accuracy: 1e-9, "\(curve)")
            XCTAssertEqual(curve.apply(1), 1, accuracy: 1e-9, "\(curve)")
            var previous = -1.0
            for step in 0...100 {
                let x = Double(step) / 100
                let y = curve.apply(x)
                XCTAssertGreaterThanOrEqual(y, previous, "\(curve) at \(x)")
                XCTAssertEqual(curve.inverse(y), x, accuracy: 1e-6, "\(curve) inverse at \(x)")
                previous = y
            }
        }
        XCTAssertEqual(ContinuousValueBinding.Curve.exponential.apply(0.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(ContinuousValueBinding.Curve.logarithmic.apply(0.5), 0.75, accuracy: 1e-9)
        XCTAssertEqual(ContinuousValueBinding.Curve.sCurve.apply(0.25), 0.15625, accuracy: 1e-9)
    }

    func testSourcesNormalizeToTheAOMValue() {
        XCTAssertEqual(MIDIMessageType.controlChange.normalized(127), 1)
        XCTAssertEqual(MIDIMessageType.controlChange.normalized(0), 0)
        XCTAssertEqual(MIDIMessageType.channelPressure.normalized(300), 1, "out-of-range input clamps")
        XCTAssertEqual(MIDIMessageType.pitchBend.normalized(16383), 1)
        XCTAssertEqual(MIDIMessageType.pitchBend.normalized(MIDIMessageType.pitchBendCentre), 0.5, accuracy: 0.0001)
    }

    // MARK: Persistence and validation

    func testBindingRoundTripsAndOldOrForeignDataNeverBreaksTheTrigger() throws {
        let binding = ContinuousValueBinding(target: .appVolume, appBundleID: "com.apple.Music", inputMinimum: 0.1,
                                             outputMaximum: 0.8, curve: .sCurve, inverted: true, holdPeak: true,
                                             scrollSensitivity: 0.5)
        XCTAssertEqual(try JSONDecoder().decode(ContinuousValueBinding.self, from: JSONEncoder().encode(binding)), binding)
        XCTAssertEqual(try JSONDecoder().decode(ContinuousValueBinding.self, from: Data("{}".utf8)), ContinuousValueBinding())

        var trigger = Trigger(name: "Fader", input: .systemEvent(.midiMessage(device: "", status: 0xB0, channel: 1, number: 7,
                                                                              minimumValue: 0, maximumValue: 127)))
        trigger.valueBinding = binding
        XCTAssertEqual(try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(trigger)).valueBinding, binding)

        // A target a newer AOM might add: the trigger survives, the binding is dropped.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? [String: Any])
        json["valueBinding"] = ["target": "keyboardBacklight"]
        let decoded = try JSONDecoder().decode(Trigger.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.id, trigger.id)
        XCTAssertNil(decoded.valueBinding)
    }

    func testATriggerWithoutABindingEncodesExactlyAsBefore() throws {
        let trigger = Trigger(name: "Plain", input: .keyboardShortcut(KeyboardShortcut(keyCode: 0, modifiers: [.command])))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? [String: Any])
        XCTAssertNil(json["valueBinding"])
    }

    func testOnlyContinuousInputsAcceptABindingAndRangesMustBeSane() {
        func cc(_ status: Int) -> TriggerInput {
            .systemEvent(.midiMessage(device: "", status: status, channel: 0, number: 1, minimumValue: 0, maximumValue: 127))
        }
        for input in [cc(0xB0), cc(0xE0), cc(0xD0), cc(0xA0), .systemEvent(.forceTouchStage(stage: 1)),
                      .trackpadGesture(.scrollUp), .trackpadGesture(.scrollDown)] as [TriggerInput] {
            XCTAssertTrue(ContinuousValueBinding.supports(input), "\(input)")
        }
        for input in [cc(0x90), cc(0x80), cc(0xC0), .trackpadGesture(.threeFingerSwipeUp), .systemEvent(.displayChanged),
                      .keyboardShortcut(KeyboardShortcut(keyCode: 0, modifiers: []))] as [TriggerInput] {
            XCTAssertFalse(ContinuousValueBinding.supports(input), "\(input)")
        }
        XCTAssertNil(ContinuousValueBinding().problem(for: cc(0xB0)))
        XCTAssertNotNil(ContinuousValueBinding(inputMinimum: 0.5, inputMaximum: 0.5).problem(for: cc(0xB0)))
        XCTAssertNotNil(ContinuousValueBinding(outputMinimum: 0.9, outputMaximum: 0.1).problem(for: cc(0xB0)))
        XCTAssertNotNil(ContinuousValueBinding(outputMaximum: 1.5).problem(for: cc(0xB0)))
        XCTAssertNotNil(ContinuousValueBinding(scrollSensitivity: 0).problem(for: cc(0xB0)))
        var noteOn = Trigger(name: "n", input: cc(0x90)); noteOn.valueBinding = ContinuousValueBinding()
        XCTAssertNotNil(TriggerValidation.problem(for: noteOn), "Note On is discrete")
    }

    // MARK: Rate limiting

    func testSinkCoalescesABurstAndAlwaysWritesItsLastValue() {
        let recorder = RecordingSink333()
        recorder.sink.submit(0.1, to: .systemVolume)
        XCTAssertEqual(recorder.scheduled.map(\.0), [0], "an idle target is written at once")
        recorder.run()
        for step in 2...9 { recorder.sink.submit(Double(step) / 10, to: .systemVolume) }
        XCTAssertEqual(recorder.scheduled.count, 1, "the burst is one write")
        XCTAssertEqual(recorder.scheduled[0].0, 0.05, accuracy: 1e-9, "no sooner than the interval after the last write")
        recorder.run(advancingBy: 0.05)
        assertValues(recorder.values, [0.1, 0.9])
    }

    func testSinkSkipsUnchangedValuesAndKeepsTargetsApart() {
        let recorder = RecordingSink333()
        recorder.sink.submit(0.5, to: .systemVolume)
        recorder.sink.submit(0.5, to: .displayBrightness(displayID: 1))
        recorder.run()
        XCTAssertEqual(recorder.applied.count, 2)
        recorder.sink.submit(0.5, to: .systemVolume)
        recorder.run(advancingBy: 1)
        XCTAssertEqual(recorder.applied.count, 2, "an unchanged value is not written again")
    }

    func testSinkWritesOnItsOwnQueueNeverOnTheCallingThread() {
        let lock = NSLock()
        var writes: [(value: Double, main: Bool, label: String)] = []
        let done = expectation(description: "last value written")
        let sink = ContinuousValueSink(apply: { _, value in
            let label = String(cString: __dispatch_queue_get_label(nil))
            lock.lock(); writes.append((value, Thread.isMainThread, label)); lock.unlock()
            if value == 1 { done.fulfill() }
            return true
        })
        for step in 1...200 { sink.submit(Double(step) / 200, to: .systemVolume) }
        wait(for: [done], timeout: 2)
        lock.lock(); defer { lock.unlock() }
        XCTAssertLessThanOrEqual(writes.count, 3, "200 readings collapse to a few writes: \(writes.map(\.value))")
        XCTAssertEqual(writes.last?.value, 1)
        XCTAssertTrue(writes.allSatisfy { !$0.main && $0.label == ContinuousValueSink.queueLabel })
    }

    // MARK: Engine

    func testAbsoluteSourcesGoThroughTheMapping() {
        let (engine, recorder) = engine()
        let id = UUID()
        XCTAssertEqual(engine.drive(ContinuousValueBinding(outputMaximum: 0.5), input: 1, from: id) ?? -1, 0.5, accuracy: 1e-9)
        recorder.run()
        assertValues(recorder.values, [0.5])
    }

    func testHoldPeakKeepsTheHighestValueOfEachPress() {
        let (engine, _) = engine()
        let binding = ContinuousValueBinding(holdPeak: true)
        let id = UUID()
        XCTAssertEqual(engine.drive(binding, input: 0.2, from: id) ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(engine.drive(binding, input: 0.6, from: id) ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(engine.drive(binding, input: 0.3, from: id) ?? -1, 0.6, accuracy: 1e-9, "letting go does not lower it")
        XCTAssertNil(engine.drive(binding, input: 0, from: id), "the release itself changes nothing")
        XCTAssertEqual(engine.drive(binding, input: 0.1, from: id) ?? -1, 0.1, accuracy: 1e-9, "a new press starts again")
        engine.release(id)
        XCTAssertEqual(engine.drive(binding, input: 0.05, from: id) ?? -1, 0.05, accuracy: 1e-9)
    }

    func testScrollStartsFromTheTargetMovesFromItsOwnPositionAndResyncsAfterAPause() {
        let clock = Clock()
        var level = 0.5
        let recorder = RecordingSink333()
        let engine = ContinuousValueEngine(sink: recorder.sink, resolve: { _ in .systemVolume },
                                           currentLevel: { _ in level }, clock: { clock.now })
        let binding = ContinuousValueBinding()
        let id = UUID()
        XCTAssertEqual(engine.nudge(binding, by: 0.1, from: id) ?? -1, 0.6, accuracy: 1e-9)
        level = 0.0 // the read is not repeated mid-gesture
        XCTAssertEqual(engine.nudge(binding, by: 0.1, from: id) ?? -1, 0.7, accuracy: 1e-9)
        clock.now += ContinuousValueEngine.relativeResync + 0.1
        level = 0.2 // changed elsewhere during the pause
        XCTAssertEqual(engine.nudge(binding, by: 0.1, from: id) ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(engine.nudge(binding, by: 5, from: id) ?? -1, 1, accuracy: 1e-9, "clamped at the top")
        XCTAssertEqual(engine.nudge(ContinuousValueBinding(inverted: true), by: 0.25, from: UUID()) ?? -1, 0.0, accuracy: 1e-9,
                       "inverted scroll moves the other way (from 0.2)")
        XCTAssertNil(engine.nudge(binding, by: 0, from: id))
    }

    func testScrollRespectsTheCurveAndOutputRange() {
        let (engine, _) = engine(level: 0.25)
        let binding = ContinuousValueBinding(outputMinimum: 0, outputMaximum: 1, curve: .exponential)
        // 0.25 on an x² curve is position 0.5; +0.1 → 0.6² = 0.36.
        XCTAssertEqual(engine.nudge(binding, by: 0.1, from: UUID()) ?? -1, 0.36, accuracy: 1e-9)
    }

    func testAnUnresolvableTargetSubmitsNothing() {
        let (engine, recorder) = engine(target: nil)
        XCTAssertNil(engine.drive(ContinuousValueBinding(target: .appVolume), input: 1, from: UUID()))
        XCTAssertNil(engine.nudge(ContinuousValueBinding(target: .appVolume), by: 0.1, from: UUID()))
        recorder.run()
        XCTAssertTrue(recorder.applied.isEmpty)
    }

    func testLiveOutputsRefuseEveryWriteUnderTests() {
        XCTAssertFalse(ContinuousTargetIO.apply(.systemVolume, 0.5), "tests must never change the real volume")
        XCTAssertFalse(ContinuousTargetIO.apply(.displayBrightness(displayID: CGMainDisplayID()), 0.5))
        XCTAssertFalse(ContinuousTargetIO.apply(.appVolume(bundleID: "com.apple.Music"), 0.5))
    }

    // MARK: Monitors

    private func ccKind(_ number: Int = 7, low: Int = 64) -> SystemTriggerKind {
        .midiMessage(device: "", status: 0xB0, channel: 1, number: number, minimumValue: low, maximumValue: 127)
    }
    private func cc(_ number: Int, _ value: Int, status: Int = 0xB0) -> SystemSignal {
        .midi(device: "Faders", status: status, channel: 1, number: number, value: value)
    }

    func testMIDIValueBindingDrivesTheValueInsteadOfRunningActions() {
        let rig = SystemRig(kinds: [ccKind(), .midiMessage(device: "", status: 0x90, channel: 0, number: 60, minimumValue: 1, maximumValue: 127)]) { trigger, index in
            if index == 0 { trigger.valueBinding = ContinuousValueBinding() }
        }
        let (engine, recorder) = engine()
        rig.monitor.continuousEngine = engine
        rig.monitor.handle(cc(7, 127)); recorder.run()
        rig.monitor.handle(cc(7, 0)); recorder.run(advancingBy: 1)
        rig.monitor.handle(cc(8, 90)); recorder.run(advancingBy: 1)
        rig.monitor.handle(.midi(device: "Faders", status: 0x90, channel: 1, number: 60, value: 100))
        rig.drain()
        assertValues(recorder.values, [1, 0])
        XCTAssertEqual(rig.fired, ["t1"], "the bound CC never runs actions; the Note On still does")
    }

    func testPitchBendAndChannelPressureBindings() {
        let rig = SystemRig(kinds: [.midiMessage(device: "", status: 0xE0, channel: 0, number: 0, minimumValue: 0, maximumValue: 16383),
                                    .midiMessage(device: "", status: 0xD0, channel: 0, number: 0, minimumValue: 0, maximumValue: 127)]) { trigger, index in
            trigger.valueBinding = ContinuousValueBinding(target: index == 0 ? .systemVolume : .displayBrightness)
        }
        let recorder = RecordingSink333()
        rig.monitor.continuousEngine = ContinuousValueEngine(sink: recorder.sink, resolve: { binding in
            binding.target == .systemVolume ? .systemVolume : .displayBrightness(displayID: 1)
        }, currentLevel: { _ in nil })
        rig.monitor.handle(cc(0, 8192, status: 0xE0))
        rig.monitor.handle(cc(0, 127, status: 0xD0))
        recorder.run()
        XCTAssertEqual(recorder.applied.count, 2)
        XCTAssertEqual(recorder.applied.first { $0.0 == .systemVolume }?.1 ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(recorder.applied.first { $0.0 == .displayBrightness(displayID: 1) }?.1 ?? -1, 1, accuracy: 1e-9)
    }

    func testValueBindingsHonourAppScopeAndTheMasterSwitch() {
        let rig = SystemRig(kinds: [ccKind(1), ccKind(2)]) { trigger, index in
            trigger.valueBinding = ContinuousValueBinding()
            if index == 0 { trigger.appBundleID = "com.example.never-frontmost" }
        }
        let (engine, recorder) = engine()
        rig.monitor.continuousEngine = engine
        rig.monitor.handle(cc(1, 127)); recorder.run()
        XCTAssertTrue(recorder.applied.isEmpty, "app-scoped binding is idle in other apps")
        UserDefaults.standard.set(false, forKey: AutomationGate.masterSwitchKey)
        rig.monitor.handle(cc(2, 127)); recorder.run()
        XCTAssertTrue(recorder.applied.isEmpty, "AOM switched off")
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
        rig.monitor.handle(cc(2, 127)); recorder.run()
        assertValues(recorder.values, [1])
    }

    private func scrollMonitor(_ bindings: [(TrackpadGesture, ContinuousValueBinding?)]) -> (TrackpadMonitor, [Trigger]) {
        let monitor = TrackpadMonitor(systemMonitoringEnabled: false, frontmostBundleID: { "test" })
        let triggers: [Trigger] = bindings.enumerated().map { index, entry in
            var trigger = Trigger(name: "s\(index)", input: .trackpadGesture(entry.0))
            trigger.requiredModifiers = NSEvent.ModifierFlags.option.rawValue
            var parameters = ActionParameters(); parameters.text = "s\(index)"
            trigger.actions = [TriggerAction(actionType: .typeText, parameters: parameters)]
            trigger.valueBinding = entry.1
            return trigger
        }
        monitor.registerTriggers(triggers)
        return (monitor, triggers)
    }

    func testScrollBindingNeedsItsModifierAndMovesBothWays() {
        let (monitor, _) = scrollMonitor([(.scrollUp, ContinuousValueBinding())])
        let (engine, recorder) = engine(level: 0.5)
        monitor.continuousEngine = engine
        monitor.modifierFlagsProvider = { 0 }
        monitor.processScroll(deltaX: 0, deltaY: 40, phase: .changed, timestamp: 1)
        recorder.run()
        XCTAssertTrue(recorder.applied.isEmpty, "no modifier, no value change")
        monitor.modifierFlagsProvider = { NSEvent.ModifierFlags.option.rawValue }
        monitor.processScroll(deltaX: 0, deltaY: 40, phase: .changed, timestamp: 2) // 40 pt × 0.25 / 100 pt
        recorder.run(advancingBy: 1)
        monitor.processScroll(deltaX: 0, deltaY: -80, phase: .changed, timestamp: 2.1)
        recorder.run(advancingBy: 1)
        monitor.processScroll(deltaX: 0, deltaY: 400, phase: [], momentumPhase: .changed, timestamp: 2.2)
        recorder.run(advancingBy: 1)
        monitor.processScroll(deltaX: 0, deltaY: 1, phase: .changed, precise: false, timestamp: 2.3) // one wheel line
        recorder.run(advancingBy: 1)
        assertValues(recorder.values, [0.6, 0.4, 0.425])
    }

    func testBoundScrollNeverRunsActionsAndUnboundScrollStillDoes() {
        let (monitor, triggers) = scrollMonitor([(.scrollUp, ContinuousValueBinding()), (.scrollDown, nil)])
        let (engine, _) = engine()
        monitor.continuousEngine = engine
        monitor.modifierFlagsProvider = { NSEvent.ModifierFlags.option.rawValue }
        var fired: [String] = []
        ActionExecutor.onActionExecuted = { fired.append($0.parameters.text ?? "?") }
        ActionExecutor.registerTriggers(triggers)
        defer { ActionExecutor.registerTriggers([]); monitor.unregisterAll() }
        for (index, dy) in [25.0, 25, -25, -25].enumerated() {
            monitor.processScroll(deltaX: 0, deltaY: CGFloat(dy), phase: .changed, timestamp: 1 + Double(index) * 0.2)
        }
        let deadline = Date().addingTimeInterval(1)
        while fired.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(fired, ["s1"])
    }
}

// MARK: - Item 3: Force Touch pressure stages

final class BTTInput333PressureStageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AutomationGate.masterSwitchKey)
    }
    override func tearDown() {
        ActionExecutor.onActionExecuted = nil
        super.tearDown()
    }

    func testLevelPlacesEachStageBetweenItsBoundaries() {
        XCTAssertEqual(PressureStageTracker.level(stage: 0, pressure: 0.7), 0)
        XCTAssertEqual(PressureStageTracker.level(stage: 1, pressure: 0), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(PressureStageTracker.level(stage: 1, pressure: 1), 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(PressureStageTracker.level(stage: 2, pressure: 0), 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(PressureStageTracker.level(stage: 2, pressure: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(PressureStageTracker.level(stage: 3, pressure: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(PressureStageTracker.level(stage: 1, pressure: .nan), 1.0 / 3, accuracy: 1e-9)
    }

    func testStageOneFiresOnceAtTheClickAndReArmsOnlyOnRelease() {
        var tracker = PressureStageTracker(hysteresis: 0.1)
        XCTAssertEqual(tracker.feed(stage: 1, pressure: 0), [1])
        XCTAssertEqual(tracker.feed(stage: 1, pressure: 0.5), [])
        XCTAssertEqual(tracker.feed(stage: 1, pressure: 0), [], "still clicked")
        XCTAssertTrue(tracker.isHeld(1))
        XCTAssertEqual(tracker.feed(stage: 0, pressure: 0), [])
        XCTAssertFalse(tracker.isHeld(1))
        XCTAssertEqual(tracker.feed(stage: 1, pressure: 0.1), [1], "the next click fires again")
    }

    func testStageTwoHasHysteresisAroundTheDeepPress() {
        var tracker = PressureStageTracker(hysteresis: 0.1)
        XCTAssertEqual(tracker.feed(stage: 1, pressure: 0.9), [1])
        XCTAssertEqual(tracker.feed(stage: 2, pressure: 0), [2])
        // Wobbling across the deep-press point stays inside the band.
        XCTAssertEqual(tracker.feed(stage: 1, pressure: 0.95), [])
        XCTAssertEqual(tracker.feed(stage: 2, pressure: 0.05), [], "no second stage 2 without leaving the band")
        XCTAssertTrue(tracker.isHeld(2))
        // Level (1 + 0.6) / 3 = 0.533 is below 2/3 − 0.1: stage 2 re-arms.
        XCTAssertEqual(tracker.feed(stage: 1, pressure: 0.6), [])
        XCTAssertFalse(tracker.isHeld(2))
        XCTAssertTrue(tracker.isHeld(1))
        XCTAssertEqual(tracker.feed(stage: 2, pressure: 0), [2])
    }

    func testAFastDeepPressEntersBothStages() {
        var tracker = PressureStageTracker(hysteresis: 0.1)
        XCTAssertEqual(tracker.feed(stage: 2, pressure: 0.5), [1, 2])
        XCTAssertEqual(tracker.feed(stage: 0, pressure: 0), [])
        XCTAssertFalse(tracker.isHeld(1) || tracker.isHeld(2))
    }

    func testHysteresisIsClampedAndReadFromSettings() {
        XCTAssertEqual(PressureStageTracker(hysteresis: 5).hysteresis, PressureStageTracker.hysteresisRange.upperBound)
        XCTAssertEqual(PressureStageTracker(hysteresis: 0).hysteresis, PressureStageTracker.hysteresisRange.lowerBound)
        XCTAssertEqual(PressureStageTracker(hysteresis: .nan).hysteresis, PressureStageTracker.defaultHysteresis)
        let suite = "AOM.PressureStage.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PressureStageTracker.storedHysteresis(defaults), PressureStageTracker.defaultHysteresis)
        defaults.set(0.2, forKey: PressureStageTracker.hysteresisKey)
        XCTAssertEqual(PressureStageTracker.storedHysteresis(defaults), 0.2)
    }

    func testProgressRunsFromTheStageBoundaryToFullPressure() {
        var tracker = PressureStageTracker(hysteresis: 0.1)
        _ = tracker.feed(stage: 1, pressure: 0)
        XCTAssertEqual(tracker.progress(from: 1), 0, accuracy: 1e-9)
        _ = tracker.feed(stage: 2, pressure: 0)
        XCTAssertEqual(tracker.progress(from: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(tracker.progress(from: 2), 0, accuracy: 1e-9)
        _ = tracker.feed(stage: 2, pressure: 1)
        XCTAssertEqual(tracker.progress(from: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(tracker.progress(from: 2), 1, accuracy: 1e-9)
    }

    func testStageTriggersFireOncePerPressThroughTheMonitor() {
        let rig = SystemRig(kinds: [.forceTouchStage(stage: 1), .forceTouchStage(stage: 2)])
        let press: [(Int, Double)] = [(1, 0.2), (1, 0.8), (2, 0.1), (1, 0.95), (2, 0.2), (1, 0.3), (0, 0)]
        for (stage, pressure) in press { rig.monitor.handle(.forceTouch(stage: stage, pressure: pressure)) }
        rig.drain()
        XCTAssertEqual(rig.fired, ["t0", "t1"])
        rig.monitor.handle(.forceTouch(stage: 1, pressure: 0.3)); rig.drain()
        XCTAssertEqual(rig.fired, ["t0", "t1", "t0"], "a new click is a new stage 1")
    }

    private func boundRig(holdPeak: Bool) -> (SystemRig, RecordingSink333) {
        let rig = SystemRig(kinds: [.forceTouchStage(stage: 1)]) { trigger, _ in
            trigger.valueBinding = ContinuousValueBinding(target: .displayBrightness, holdPeak: holdPeak)
        }
        let recorder = RecordingSink333()
        rig.monitor.continuousEngine = ContinuousValueEngine(sink: recorder.sink, resolve: { _ in .displayBrightness(displayID: 1) },
                                                             currentLevel: { _ in nil })
        return (rig, recorder)
    }
    private func feed(_ rig: SystemRig, _ recorder: RecordingSink333, _ readings: [(Int, Double)]) {
        for (stage, pressure) in readings {
            rig.monitor.handle(.forceTouch(stage: stage, pressure: pressure))
            recorder.run(advancingBy: 1)
        }
    }

    func testABoundStageFollowsThePressureWhileHeldAndNeverRunsActions() {
        let (rig, recorder) = boundRig(holdPeak: false)
        feed(rig, recorder, [(1, 0), (1, 0.5), (2, 0.5), (0, 0), (0, 0)])
        rig.drain()
        let values = recorder.values
        XCTAssertEqual(values.count, 3, "\(values)")
        for (a, e) in zip(values, [0, 0.25, 0.75]) { XCTAssertEqual(a, e, accuracy: 1e-6) }
        XCTAssertTrue(rig.fired.isEmpty, "a bound stage drives its value instead of firing")
    }

    func testHoldPeakKeepsTheDeepestPressAfterRelease() {
        let (rig, recorder) = boundRig(holdPeak: true)
        feed(rig, recorder, [(1, 0), (1, 0.5), (2, 0.5), (1, 0.2), (0, 0), (1, 0.3)])
        let values = recorder.values
        XCTAssertEqual(values.count, 3, "\(values)")
        for (a, e) in zip(values, [0.25, 0.75, 0.15]) { XCTAssertEqual(a, e, accuracy: 1e-6) }
    }

    func testStagesNeedOnlyTheForceTouchSourceAndAreValidated() throws {
        let kinds: [SystemTriggerKind] = [.forceTouchStage(stage: 1), .forceTouchStage(stage: 2)]
        XCTAssertEqual(SignalSource.needs(for: kinds), [.forceTouch])
        for kind in kinds { XCTAssertEqual(try JSONDecoder().decode(SystemTriggerKind.self, from: JSONEncoder().encode(kind)), kind) }
        XCTAssertEqual(kinds.map(\.displayName), ["Force Touch stage 1 (click)", "Force Touch stage 2 (deep press)"])
        XCTAssertNil(TriggerValidation.systemProblem(for: .forceTouchStage(stage: 2)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: .forceTouchStage(stage: 3)))
        let rig = SystemRig(kinds: [.forceTouchStage(stage: 3)])
        rig.monitor.handle(.forceTouch(stage: 2, pressure: 1)); rig.drain()
        XCTAssertTrue(rig.fired.isEmpty, "an invalid stage is never registered")
        XCTAssertTrue(rig.provider.started.isEmpty)
    }

    func testPressureMonitorDropsRepeatsClampsAndReleases() {
        var signals: [SystemSignal] = []
        let monitor = ForceTouchPressureMonitor { signals.append($0) } // never started: no real event monitor
        monitor.forward(stage: 1, pressure: 0.5)
        monitor.forward(stage: 1, pressure: 0.505)
        monitor.forward(stage: 1, pressure: 0.52)
        monitor.forward(stage: 5, pressure: 2)
        monitor.forward(stage: 0, pressure: 0.7)
        monitor.forward(stage: 0, pressure: 0)
        XCTAssertEqual(signals, [.forceTouch(stage: 1, pressure: 0.5), .forceTouch(stage: 1, pressure: 0.52),
                                 .forceTouch(stage: 2, pressure: 1), .forceTouch(stage: 0, pressure: 0)])
    }
}
