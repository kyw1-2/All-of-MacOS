import XCTest
import CoreAudio
@testable import AllOfMacOS

/// The AirPlay direct path's pure pieces, without audio hardware or taps:
/// IO-gap detection, the 5 ms fades, the attach/detach policy, the one-time
/// migration and the diagnostics a direct session writes.
final class AirPlayDirectTests: XCTestCase {
    private let suite = "AirPlayDirectTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: IO gaps

    func testFirstCycleAndContinuousCyclesAreNotGaps() {
        var detector = AudioIOGapDetector()
        XCTAssertEqual(detector.observe(sampleTime: 1_000, valid: true, frames: 128), 0, "the first cycle only anchors")
        XCTAssertEqual(detector.observe(sampleTime: 1_128, valid: true, frames: 128), 0)
        XCTAssertEqual(detector.observe(sampleTime: 1_256.4, valid: true, frames: 128), 0, "sub-frame jitter is not a gap")
    }

    func testSkippedCyclesCountTheirFrames() {
        var detector = AudioIOGapDetector()
        _ = detector.observe(sampleTime: 0, valid: true, frames: 128)
        XCTAssertEqual(detector.observe(sampleTime: 384, valid: true, frames: 128), 256, "two cycles missing")
        XCTAssertEqual(detector.observe(sampleTime: 512, valid: true, frames: 128), 0)
        XCTAssertEqual(detector.observe(sampleTime: 1_280, valid: true, frames: 128), 640)
    }

    func testInvalidTimestampsAndBackwardsClocksReanchorWithoutAGap() {
        var detector = AudioIOGapDetector()
        _ = detector.observe(sampleTime: 0, valid: true, frames: 128)
        XCTAssertEqual(detector.observe(sampleTime: 9_999, valid: false, frames: 128), 0)
        XCTAssertNil(detector.expected)
        XCTAssertEqual(detector.observe(sampleTime: 50_000, valid: true, frames: 128), 0, "re-anchored after an invalid stamp")
        XCTAssertEqual(detector.observe(sampleTime: .nan, valid: true, frames: 128), 0)
        XCTAssertEqual(detector.observe(sampleTime: 10, valid: true, frames: 128), 0)
        XCTAssertEqual(detector.observe(sampleTime: 0, valid: true, frames: 128), 0, "a clock reset backwards is not a gap")
        XCTAssertEqual(detector.observe(sampleTime: 128, valid: true, frames: 128), 0)
        XCTAssertEqual(detector.observe(sampleTime: 256, valid: true, frames: 0), 0)
        XCTAssertNil(detector.expected, "an empty cycle re-anchors")
    }

    // MARK: Fades

    func testFadeLengthIsFiveMillisecondsAtCommonRates() {
        XCTAssertEqual(AudioDirectFade.frames(sampleRate: 48_000), 240)
        XCTAssertEqual(AudioDirectFade.frames(sampleRate: 44_100), 221)
        XCTAssertEqual(AudioDirectFade.frames(sampleRate: 96_000), 480)
        XCTAssertEqual(AudioDirectFade.frames(sampleRate: .nan), 240)
    }

    func testFadeInReachesFullLevelOnItsLastFrame() {
        for (rate, length) in [(48_000.0, 240), (44_100.0, 221)] {
            var fade = AudioDirectFade(sampleRate: rate)
            XCTAssertEqual(fade.length, length)
            var gains: [Float] = []
            for _ in 0..<(length + 2) { gains.append(fade.nextGain()) }
            XCTAssertEqual(gains[0], 1 / Float(length), accuracy: 1e-6)
            XCTAssertLessThan(gains[length - 2], 1)
            XCTAssertEqual(gains[length - 1], 1)
            XCTAssertEqual(gains[length], 1)
            XCTAssertTrue(fade.isSteady)
        }
    }

    func testFadeOutTakesExactlyItsLengthAndHasNoWayBack() {
        for (rate, length) in [(48_000.0, 240), (44_100.0, 221)] {
            var fade = AudioDirectFade(sampleRate: rate)
            for _ in 0..<length { _ = fade.nextGain() }
            fade.stop()
            for frame in 0..<(length - 1) {
                XCTAssertGreaterThan(fade.nextGain(), 0, "frame \(frame) of \(length)")
                XCTAssertFalse(fade.finished)
            }
            XCTAssertEqual(fade.nextGain(), 0)
            XCTAssertTrue(fade.finished)
            fade.restart()
            XCTAssertTrue(fade.finished, "a gap after a stop does not fade back in")
            XCTAssertEqual(fade.nextGain(), 0)
        }
    }

    func testAGapRestartsTheFadeInAndBuffersAreShaped() {
        var fade = AudioDirectFade(sampleRate: 48_000)
        for _ in 0..<300 { _ = fade.nextGain() }
        XCTAssertTrue(fade.isSteady)
        fade.restart()
        XCTAssertEqual(fade.position, 0)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(repeating: 1, count: 480); right.initialize(repeating: -1, count: 480)
        fade.apply(left: left, right: right, frames: 480)
        XCTAssertEqual(left[0], 1 / 240, accuracy: 1e-6)
        XCTAssertEqual(right[119], -0.5, accuracy: 1e-6)
        XCTAssertEqual(left[239], 1)
        XCTAssertEqual(left[479], 1)
        // A stop mid fade-in fades out from where it was.
        var partial = AudioDirectFade(sampleRate: 48_000)
        for _ in 0..<100 { _ = partial.nextGain() }
        partial.stop()
        for _ in 0..<99 { _ = partial.nextGain() }
        XCTAssertFalse(partial.finished)
        XCTAssertEqual(partial.nextGain(), 0)
        XCTAssertTrue(partial.finished)
    }

    // MARK: Policy

    private func decide(_ session: AirPlayDirectPolicy.Kind?, direct: Bool = true, same: Bool = true,
                        playing: Bool = false, muted: Bool = false, objects: Bool = true,
                        idle: TimeInterval = 0) -> AirPlayDirectPolicy.Decision {
        AirPlayDirectPolicy.decide(session: session, wantsDirect: direct, sameDevice: same, playing: playing,
                                   muted: muted, hasProcessObjects: objects, idleSeconds: idle)
    }

    func testDirectAttachesOnlyWhilePlayingOrMuted() {
        XCTAssertEqual(decide(nil, playing: true), .attach)
        XCTAssertEqual(decide(nil, muted: true), .attach, "a muted app must never leak sound")
        XCTAssertEqual(decide(nil), .wait)
        XCTAssertEqual(decide(nil, playing: true, objects: false), .wait)
        XCTAssertEqual(decide(nil, muted: true, objects: false), .wait)
        XCTAssertEqual(decide(nil, direct: false), .attach, "a queued destination keeps the existing rules")
    }

    func testDirectSessionsDetachAfterThirtyIdleSecondsUnlessMuted() {
        XCTAssertEqual(decide(.direct, playing: true, idle: 600), .keep)
        XCTAssertEqual(decide(.direct, idle: 29.9), .keep)
        XCTAssertEqual(decide(.direct, idle: 30), .detach)
        XCTAssertEqual(decide(.direct, muted: true, idle: 600), .keep)
        XCTAssertEqual(decide(.queued, direct: false, idle: 600), .keep, "queued sessions keep today's lifetime")
    }

    func testKindOrDeviceMismatchRecreates() {
        XCTAssertEqual(decide(.direct, direct: false, playing: true), .recreate, "the target is now a local device")
        XCTAssertEqual(decide(.queued, direct: true, playing: true), .recreate, "the target is now AirPlay in direct mode")
        XCTAssertEqual(decide(.direct, same: false, playing: true), .recreate, "the AirPlay device ID or UID changed")
        XCTAssertEqual(decide(.direct, same: false, muted: true), .recreate)
        XCTAssertEqual(decide(.queued, direct: false, same: false), .keep, "moveOutput handles local to local")
    }

    // MARK: Migration

    func testMigrationReenablesEffectsTheFuseTurnedOffOnce() {
        defaults.set(false, forKey: AirPlayDirectMigration.processingKey)
        defaults.set("Repeated HomePod HAL deadline faults", forKey: AirPlayDirectMigration.safetyReasonKey)
        XCTAssertTrue(AirPlayDirectMigration.run(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: AirPlayDirectMigration.safetyReasonKey))
        XCTAssertEqual(defaults.object(forKey: AirPlayDirectMigration.processingKey) as? Bool, true)
        XCTAssertTrue(defaults.bool(forKey: AirPlayDirectMigration.doneKey))
        // Runs once: a later fuse trip is not undone at the next launch.
        defaults.set(false, forKey: AirPlayDirectMigration.processingKey)
        defaults.set("again", forKey: AirPlayDirectMigration.safetyReasonKey)
        XCTAssertFalse(AirPlayDirectMigration.run(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: AirPlayDirectMigration.processingKey) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: AirPlayDirectMigration.safetyReasonKey), "again")
    }

    func testMigrationLeavesAUsersOwnChoiceAlone() {
        defaults.set(false, forKey: AirPlayDirectMigration.processingKey)
        XCTAssertFalse(AirPlayDirectMigration.run(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: AirPlayDirectMigration.processingKey) as? Bool, false)
        XCTAssertTrue(defaults.bool(forKey: AirPlayDirectMigration.doneKey))
        XCTAssertFalse(AirPlayDirectMigration.run(defaults: defaults))
    }

    func testDirectPathIsOnUnlessExplicitlyDisabled() {
        XCTAssertTrue(AirPlayDirectStream.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AirPlayDirectStream.enabledKey)
        XCTAssertFalse(AirPlayDirectStream.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AirPlayDirectStream.enabledKey)
        XCTAssertTrue(AirPlayDirectStream.isEnabled(defaults: defaults))
    }

    // MARK: Diagnostics

    func testDirectSessionDiagnosticsCarryItsCounters() {
        let counters = AirPlayDirectCounters(
            callbacks: 1_000, frames: 128_000, capturedFrames: 128_000, ioGaps: 2, ioGapFrames: 384, overloads: 1,
            costTicks: 50_000_000, costCycles: 1_000, costMaxTicks: 200_000, secondsPerTick: 1e-9,
            bufferFrames: 128, configuredIOFrames: 128, oversizedCycles: 0, sampleRate: 44_100, peak: 0.5, wired: true)
        let stats = AirPlayDirectStream.diagnostics(statistics: counters.json, bundleID: "com.google.Chrome", tapRewrites: 3)
        let payload = AudioDiagnostics.payload(captures: ["42": stats], outputs: [:], log: AudioEventLog())
        guard let captures = payload["captures"] as? [String: [String: Any]], let entry = captures["42"] else {
            return XCTFail("the direct session is missing from captures")
        }
        XCTAssertEqual(entry["direct"] as? Bool, true)
        XCTAssertEqual(entry["airPlay"] as? Bool, true)
        XCTAssertEqual(entry["bundleID"] as? String, "com.google.Chrome")
        XCTAssertEqual(entry["tapRewrites"] as? Int, 3)
        XCTAssertEqual(entry["callbacks"] as? UInt64, 1_000)
        XCTAssertEqual(entry["frames"] as? UInt64, 128_000)
        XCTAssertEqual(entry["ioGaps"] as? UInt64, 2)
        XCTAssertEqual(entry["ioGapFrames"] as? UInt64, 384)
        XCTAssertEqual(entry["overloads"] as? UInt64, 1)
        XCTAssertEqual(entry["renderCostMeanMicros"] as? Double, 50)
        XCTAssertEqual(entry["renderCostMaxMicros"] as? Double, 200)
        XCTAssertEqual(entry["bufferFrames"] as? UInt64, 128)
        XCTAssertEqual(entry["sampleRate"] as? Double, 44_100)
        XCTAssertEqual(entry["peak"] as? Double, 0.5)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: payload), "the payload must stay serialisable")
        XCTAssertEqual(AirPlayDirectCounters().json["renderCostMeanMicros"] as? Double, 0, "no cycles yet")
    }
}
