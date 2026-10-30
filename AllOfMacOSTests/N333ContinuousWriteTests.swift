import XCTest
import AppKit
@testable import AllOfMacOS

// N333-04: a continuous write that fails must not count as written, and a
// level written to one output device must not stand for another. Everything
// here runs on a fake clock, schedule, device and output: no volume,
// brightness or audio device is read or changed.

/// A sink whose clock, schedule, devices and writes are all fakes. `results`
/// answers the writes in order; once it is empty every write succeeds.
private final class FakeOutputs {
    var results: [Bool] = []
    var systemOutput: AnyHashable? = AnyHashable("speakers")
    /// Runs inside a write, as another thread could while the sink queue is busy.
    var duringWrite: ((ContinuousTargetRef, Double) -> Void)?
    private(set) var writes: [(target: ContinuousTargetRef, value: Double)] = []
    var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    var now: TimeInterval = 100
    lazy var sink = ContinuousValueSink(
        minimumInterval: 0.05, clock: { [weak self] in self?.now ?? 0 },
        schedule: { [weak self] delay, work in self?.scheduled.append((delay, work)) },
        device: { [weak self] target in target == .systemVolume ? self?.systemOutput : nil },
        apply: { [weak self] target, value in
            guard let self else { return false }
            self.writes.append((target, value))
            self.duringWrite?(target, value)
            return self.results.isEmpty ? true : self.results.removeFirst()
        })
    /// Runs the flushes scheduled so far, in order. A retry they schedule
    /// waits for the next run.
    func run(advancingBy seconds: TimeInterval = 0) {
        now += seconds
        let due = scheduled; scheduled.removeAll()
        for (_, work) in due { work() }
    }
    var values: [Double] { writes.map { $0.value } }
    func written(to target: ContinuousTargetRef) -> [Double] { writes.filter { $0.target == target }.map { $0.value } }
}

final class N333ContinuousWriteTests: XCTestCase {
    private let volume = ContinuousTargetRef.systemVolume
    private let display = ContinuousTargetRef.displayBrightness(displayID: 1)
    private let retry = ContinuousValueSink.retryDelay

    private func assertValues(_ actual: [Double], _ expected: [Double], _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual) \(message)", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 0.0001, "\(actual) \(message)", file: file, line: line)
        }
    }

    // MARK: Only a successful write counts

    /// The audit case: the first write fails and the same level comes again.
    func testAFailedWriteIsWrittenAgainWhenTheSameValueReturns() {
        let rig = FakeOutputs(); rig.results = [false]
        rig.sink.submit(0.5, to: volume); rig.run()
        rig.sink.submit(0.5, to: volume)
        XCTAssertEqual(rig.scheduled.count, 1, "the repeat rides on the pending retry")
        rig.run(advancingBy: retry)
        assertValues(rig.values, [0.5, 0.5])
        rig.sink.submit(0.5, to: volume); rig.run(advancingBy: 1)
        assertValues(rig.values, [0.5, 0.5], "once it succeeded, the same value is skipped again")
    }

    func testAFailedWriteIsRetriedOnceOnItsOwn() {
        let rig = FakeOutputs(); rig.results = [false]
        rig.sink.submit(0.5, to: volume); rig.run()
        XCTAssertEqual(rig.scheduled.map { $0.delay }, [retry], "the retry waits; it is not a busy loop")
        XCTAssertGreaterThanOrEqual(retry, rig.sink.minimumInterval)
        rig.run(advancingBy: retry)
        assertValues(rig.values, [0.5, 0.5], "a fader left on the value still gets there")
        XCTAssertTrue(rig.scheduled.isEmpty, "a successful retry schedules nothing more")
    }

    func testFailFailSucceedStopsAfterOneRetryAndRecoversOnTheNextValue() {
        let rig = FakeOutputs(); rig.results = [false, false, true]
        rig.sink.submit(0.5, to: volume); rig.run()
        rig.run(advancingBy: retry)
        assertValues(rig.values, [0.5, 0.5])
        XCTAssertTrue(rig.scheduled.isEmpty, "a failed retry waits for the next value")
        for _ in 0..<3 { rig.run(advancingBy: 10) }
        XCTAssertEqual(rig.writes.count, 2, "nothing polls the target")
        rig.sink.submit(0.5, to: volume); rig.run()
        assertValues(rig.values, [0.5, 0.5, 0.5], "the same value is tried again")
        rig.sink.submit(0.5, to: volume); rig.run(advancingBy: 1)
        XCTAssertEqual(rig.writes.count, 3, "and skipped once it succeeded")
    }

    func testASuccessfulWriteIsStillDeduplicated() {
        let rig = FakeOutputs()
        rig.sink.submit(0.5, to: volume); rig.run()
        XCTAssertTrue(rig.scheduled.isEmpty, "no retry after a success")
        rig.sink.submit(0.5, to: volume)
        XCTAssertEqual(rig.scheduled.count, 1, "a repeat is still scheduled; its flush skips it")
        rig.run(advancingBy: 1)
        rig.sink.submit(0.5004, to: volume); rig.run(advancingBy: 1)
        assertValues(rig.values, [0.5], "within the tolerance")
        rig.sink.submit(0.6, to: volume); rig.run(advancingBy: 1)
        assertValues(rig.values, [0.5, 0.6])
    }

    func testAFailureForgetsTheLevelThatWasThereBefore() {
        let rig = FakeOutputs(); rig.results = [true, false, false]
        rig.sink.submit(0.3, to: volume); rig.run()
        rig.sink.submit(0.5, to: volume); rig.run(advancingBy: 1)
        rig.run(advancingBy: retry)
        rig.sink.submit(0.3, to: volume); rig.run(advancingBy: 1)
        assertValues(rig.values, [0.3, 0.5, 0.5, 0.3], "after a failure the target's level is unknown")
    }

    func testAValueSubmittedDuringAFailedWriteReplacesTheRetry() {
        let rig = FakeOutputs(); rig.results = [false]
        rig.duringWrite = { [weak rig] _, value in if value == 0.5 { rig?.sink.submit(0.7, to: .systemVolume) } }
        rig.sink.submit(0.5, to: volume); rig.run()
        XCTAssertEqual(rig.scheduled.count, 1, "only the newer value waits, not a retry of the old one")
        rig.run(advancingBy: 1)
        assertValues(rig.values, [0.5, 0.7])
        XCTAssertTrue(rig.scheduled.isEmpty)
    }

    func testATargetThatCannotBeSetIsBackedOffAndNeverPolled() {
        let rig = FakeOutputs(); rig.results = Array(repeating: false, count: 50)
        rig.sink.submit(0.1, to: volume); rig.run()
        for step in 2...6 { rig.sink.submit(Double(step) / 10, to: volume) }
        XCTAssertEqual(rig.scheduled.count, 1, "readings during the retry delay ride on the retry")
        rig.run(advancingBy: retry)
        rig.run(advancingBy: retry)
        for _ in 0..<5 { rig.run(advancingBy: 10) }
        assertValues(rig.values, [0.1, 0.6, 0.6], "one retry after the last reading, then nothing")
        XCTAssertTrue(rig.scheduled.isEmpty)
    }

    // MARK: Forgetting

    func testForgettingWritesTheSameValueAgainEvenDuringAWrite() {
        let rig = FakeOutputs()
        rig.sink.submit(0.5, to: volume); rig.run()
        rig.sink.forgetLastWritten()
        rig.sink.submit(0.5, to: volume); rig.run(advancingBy: 1)
        assertValues(rig.values, [0.5, 0.5])

        rig.duringWrite = { [weak rig] _, _ in rig?.sink.forgetLastWritten() }
        rig.sink.submit(0.6, to: volume); rig.run(advancingBy: 1)
        rig.duringWrite = nil
        rig.sink.submit(0.6, to: volume); rig.run(advancingBy: 1)
        assertValues(rig.values, [0.5, 0.5, 0.6, 0.6], "a forget while the write runs is not undone by its success")
    }

    // MARK: Targets and devices

    func testTargetsFailAndRetryIndependently() {
        let rig = FakeOutputs(); rig.results = [false, true]
        rig.sink.submit(0.5, to: volume)
        rig.sink.submit(0.5, to: display)
        rig.run()
        XCTAssertEqual(rig.scheduled.count, 1, "only the failed target is retried")
        rig.sink.submit(0.5, to: display)
        rig.run(advancingBy: retry)
        XCTAssertEqual(rig.written(to: volume), [0.5, 0.5])
        XCTAssertEqual(rig.written(to: display), [0.5], "the display's success is still remembered")
    }

    func testTheSameVolumeIsWrittenAgainAfterTheOutputDeviceChanges() {
        let rig = FakeOutputs()
        rig.sink.submit(0.5, to: volume); rig.sink.submit(0.5, to: display); rig.run()
        rig.systemOutput = AnyHashable("homepod")
        rig.sink.submit(0.5, to: volume); rig.sink.submit(0.5, to: display); rig.run(advancingBy: 1)
        XCTAssertEqual(rig.written(to: volume), [0.5, 0.5], "a level on the speakers says nothing about the new output")
        XCTAssertEqual(rig.written(to: display), [0.5], "a display is named by its target; its level stays known")
        rig.sink.submit(0.5, to: volume); rig.run(advancingBy: 1)
        XCTAssertEqual(rig.written(to: volume), [0.5, 0.5], "same output again: skipped")
        rig.systemOutput = AnyHashable("speakers")
        rig.sink.submit(0.5, to: volume); rig.run(advancingBy: 1)
        XCTAssertEqual(rig.written(to: volume), [0.5, 0.5, 0.5], "switching back is a change too")
    }

    func testAWriteDuringWhichTheOutputChangedIsNotRemembered() {
        let rig = FakeOutputs()
        rig.duringWrite = { [weak rig] _, _ in rig?.systemOutput = AnyHashable("headphones") }
        rig.sink.submit(0.5, to: volume); rig.run()
        rig.duringWrite = nil
        XCTAssertTrue(rig.scheduled.isEmpty, "the write itself succeeded: no retry")
        rig.sink.submit(0.5, to: volume); rig.run(advancingBy: 1)
        XCTAssertEqual(rig.written(to: volume), [0.5, 0.5], "the new output gets the level")
    }

    func testAFaderHeldOnTheSameValueRecoversThroughTheEngine() {
        let rig = FakeOutputs(); rig.results = [false, false]
        let engine = ContinuousValueEngine(sink: rig.sink, resolve: { _ in .systemVolume },
                                           currentLevel: { _ in 0.5 }, clock: { 0 })
        let fader = UUID()
        engine.drive(ContinuousValueBinding(), input: 0.5, from: fader); rig.run()
        rig.run(advancingBy: retry)
        engine.drive(ContinuousValueBinding(), input: 0.5, from: fader); rig.run(advancingBy: 1)
        XCTAssertEqual(rig.written(to: volume), [0.5, 0.5, 0.5])
    }

    // MARK: Manual schedule model and live wiring

    /// Independent333AuditTests runs exactly one scheduled flush per submit,
    /// so every submit must leave exactly one, failed write before or not.
    private func runAuditModel(failFirst: Bool, file: StaticString = #filePath, line: UInt = #line) -> Int {
        var work: [() -> Void] = []
        var calls = 0
        let sink = ContinuousValueSink(minimumInterval: 0, schedule: { _, task in work.append(task) }, apply: { _, _ in
            calls += 1
            return !failFirst || calls > 1
        })
        for _ in 0..<2 {
            sink.submit(0.5, to: .systemVolume)
            XCTAssertEqual(work.count, 1, "exactly one flush waits", file: file, line: line)
            guard !work.isEmpty else { return calls }
            work.removeFirst()()
        }
        XCTAssertTrue(work.isEmpty, "nothing is left scheduled", file: file, line: line)
        return calls
    }

    func testTheAuditScheduleModelAlwaysHasOneFlushToRun() {
        XCTAssertEqual(runAuditModel(failFirst: true), 2)
        XCTAssertEqual(runAuditModel(failFirst: false), 1)
    }

    func testLiveDeviceIdentityReadsNothingUnderTests() {
        XCTAssertNil(ContinuousTargetIO.device(.systemVolume), "like apply, no audio device is read under XCTest")
        XCTAssertNil(ContinuousTargetIO.device(display))
        XCTAssertNil(ContinuousTargetIO.device(.appVolume(bundleID: "com.apple.Music")))
    }
}
