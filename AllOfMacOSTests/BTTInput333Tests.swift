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
final class RecordingSink333 {
    private(set) var applied: [(ContinuousTargetRef, Double)] = []
    var scheduled: [(TimeInterval, () -> Void)] = []
    var now: TimeInterval = 100
    lazy var sink = ContinuousValueSink(minimumInterval: 0.05, clock: { [unowned self] in now },
                                        schedule: { [unowned self] delay, work in scheduled.append((delay, work)) },
                                        apply: { [unowned self] target, value in applied.append((target, value)); return true })
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
