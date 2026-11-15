import XCTest
import CoreAudio
@testable import AllOfMacOS

/// The audio control gather/apply split, without audio hardware: the gate's
/// coalescing and stale-snapshot rules, and the snapshot lookups the apply
/// step uses instead of CoreAudio reads.
final class AudioControlSnapshotTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AudioControlSnapshotTests"

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

    // MARK: Gate

    func testOnlyOneBackgroundGatherRunsAndARequestMeanwhileRunsOneMore() {
        var gate = AudioControlSyncGate()
        XCTAssertEqual(gate.beginBackground(), 1)
        XCTAssertNil(gate.beginBackground(), "a second gather must not start while one is in flight")
        XCTAssertNil(gate.beginBackground())
        XCTAssertTrue(gate.dirty)
        XCTAssertTrue(gate.finishBackground(), "requests during the gather coalesce into exactly one more")
        XCTAssertFalse(gate.inFlight)
        XCTAssertFalse(gate.dirty)
        XCTAssertEqual(gate.beginBackground(), 2)
        XCTAssertFalse(gate.finishBackground(), "no request arrived: nothing more to run")
    }

    func testSnapshotsApplyInIssueOrderAndAnOvertakenOneIsDropped() {
        var gate = AudioControlSyncGate()
        let background = gate.beginBackground()!
        let inline = gate.beginInline()
        XCTAssertGreaterThan(inline, background)
        XCTAssertTrue(gate.inFlight, "an inline gather does not touch the background slot")
        XCTAssertTrue(gate.accept(inline))
        _ = gate.finishBackground()
        XCTAssertFalse(gate.accept(background), "a snapshot older than the applied one is stale")
        XCTAssertEqual(gate.applied, inline)
        XCTAssertFalse(gate.accept(inline), "the same snapshot never applies twice")
        let next = gate.beginBackground()!
        XCTAssertTrue(gate.accept(next))
    }

    // MARK: Snapshot lookups

    func testPlayingOwnersComeFromTheGatheredRunningOutputSet() {
        var snapshot = AudioControlSnapshot()
        snapshot.objectsByOwner = [10: [1, 2], 20: [3], 30: []]
        snapshot.runningOutput = [2, 99]
        let running = snapshot.runningOutput
        let owners = AudioPlaybackActivity.playingOwners(snapshot.objectsByOwner) { running.contains($0) }
        XCTAssertEqual(owners, [10])
    }

    func testTargetOutputUsesAConnectedRouteOtherwiseTheDefaultOutput() {
        var snapshot = AudioControlSnapshot()
        snapshot.devices = [AudioOutputDevice(id: 40, uid: "speakers", name: "Speakers"),
                            AudioOutputDevice(id: 41, uid: "homepod", name: "HomePod")]
        snapshot.defaultOutputUID = "speakers"
        XCTAssertEqual(snapshot.targetOutputUID(for: "com.example.player", defaults: defaults), "speakers")
        defaults.set("homepod", forKey: "AOMAudioRoute_com.example.player")
        XCTAssertEqual(snapshot.targetOutputUID(for: "com.example.player", defaults: defaults), "homepod")
        defaults.set("unplugged", forKey: "AOMAudioRoute_com.example.player")
        XCTAssertEqual(snapshot.targetOutputUID(for: "com.example.player", defaults: defaults), "speakers",
                       "a disconnected route falls back to the default output; the preference is kept")
        XCTAssertEqual(defaults.string(forKey: "AOMAudioRoute_com.example.player"), "unplugged")
        snapshot.defaultOutputUID = nil
        XCTAssertNil(snapshot.targetOutputUID(for: "com.example.player", defaults: defaults))
    }

    func testTransportAndSoftwareGainAreLookupsWithUnityAndLocalDefaults() {
        var snapshot = AudioControlSnapshot()
        let homePod = AudioOutputDevice(id: 41, uid: "homepod", name: "HomePod")
        let speakers = AudioOutputDevice(id: 40, uid: "speakers", name: "Speakers")
        snapshot.devices = [speakers, homePod]
        snapshot.transport = [41: kAudioDeviceTransportTypeAirPlay, 40: kAudioDeviceTransportTypeBuiltIn]
        snapshot.softwareGains = ["speakers": 0.5]
        XCTAssertTrue(snapshot.isAirPlay(homePod))
        XCTAssertFalse(snapshot.isAirPlay(speakers))
        XCTAssertFalse(snapshot.isAirPlay(AudioOutputDevice(id: 7, uid: "unknown", name: "Unknown")),
                       "an unread transport is not AirPlay")
        XCTAssertEqual(snapshot.softwareGain(uid: "speakers"), 0.5)
        XCTAssertEqual(snapshot.softwareGain(uid: "homepod"), 1)
        XCTAssertEqual(snapshot.device(uid: "homepod"), homePod)
        XCTAssertNil(snapshot.device(uid: "unplugged"))
    }

    func testEmptySnapshotMeansNoProcessDataNotAnEmptyProcessList() {
        let snapshot = AudioControlSnapshot.empty
        XCTAssertFalse(snapshot.swept)
        XCTAssertNil(snapshot.processObjects, "nil keeps the 'failed read is not an empty list' rule")
        XCTAssertNil(snapshot.apps)
        XCTAssertEqual(snapshot.sequence, 0)
    }

    @available(macOS 14.2, *)
    func testAirPlayBypassFollowsTheGatheredDefaultTransport() {
        XCTAssertTrue(AppAudioEngine.shouldBypassAirPlayCapture(defaultTransport: kAudioDeviceTransportTypeAirPlay,
                                                                routeTransport: nil))
        XCTAssertFalse(AppAudioEngine.shouldBypassAirPlayCapture(defaultTransport: kAudioDeviceTransportTypeBuiltIn,
                                                                 routeTransport: nil))
        XCTAssertFalse(AppAudioEngine.shouldBypassAirPlayCapture(defaultTransport: nil, routeTransport: nil))
    }

    // MARK: Owner cache

    @available(macOS 14.2, *)
    func testOwnerResolutionResetIsSafeFromConcurrentQueues() {
        DispatchQueue.concurrentPerform(iterations: 64) { _ in AppAudioEngine.resetOwnerResolution() }
    }

    // MARK: Diagnostics timings

    func testTimingStatsReportGatherMeanAndApplyMaxSinceReset() {
        var stats = AudioControlTimingStats()
        XCTAssertEqual(stats.json, ["controlGatherMeanMS": 0, "controlApplyMaxMS": 0])
        stats.recordGather(ms: 4)
        stats.recordGather(ms: 8)
        stats.recordGather(ms: .nan)
        stats.recordApply(ms: 0.4)
        stats.recordApply(ms: 1.23456)
        stats.recordApply(ms: 0.2)
        stats.recordApply(ms: -1)
        XCTAssertEqual(stats.gatherCount, 2)
        XCTAssertEqual(stats.json["controlGatherMeanMS"], 6)
        XCTAssertEqual(stats.json["controlApplyMaxMS"], 1.235)
        stats.reset()
        XCTAssertEqual(stats, AudioControlTimingStats())
    }

    func testHostTimeConversionIsMonotonicAndNeverNegative() {
        let start = mach_absolute_time()
        let end = start + 10_000_000
        let ms = AudioHostTime.milliseconds(from: start, to: end)
        XCTAssertGreaterThan(ms, 0)
        XCTAssertEqual(AudioHostTime.milliseconds(from: end, to: start), 0)
        XCTAssertLessThan(AudioHostTime.milliseconds(from: start, to: start + 1_000), ms)
    }

    func testDiagnosticsPayloadCarriesControlTimings() {
        let log = AudioEventLog()
        let payload = AudioDiagnostics.payload(captures: [:], outputs: [:],
                                               control: ["controlGatherMeanMS": 3.5, "controlApplyMaxMS": 0.8], log: log)
        XCTAssertEqual(payload["controlGatherMeanMS"] as? Double, 3.5)
        XCTAssertEqual(payload["controlApplyMaxMS"] as? Double, 0.8)
        XCTAssertNotNil(payload["sinceReset"], "the existing keys are unchanged")
        XCTAssertNil(AudioDiagnostics.payload(captures: [:], outputs: [:], log: log)["controlApplyMaxMS"],
                     "the keys appear only when the engine supplies them")
    }
}
