import XCTest
import CoreAudio
@testable import AllOfMacOS

/// HomePod crackle audit, second follow-up (3.3.2): the IO-size re-request
/// policy, the App Nap guard, like-with-like format classification, the tap
/// membership debounce and Overdrive's network release. Pure logic and
/// synthetic signals only; no audio hardware.
final class AirPlayRobustnessTests: XCTestCase {
    // MARK: IO buffer re-request

    /// 3.3.2 review: only a device running AOM below its size is asked again
    /// (a cycle gap at 1024 frames is not a reason: a HAL that restarts IO on
    /// a same-size set would turn one gap into a click every 30 s), and one
    /// that keeps refusing is asked less and less often.
    func testIOBufferIsRequestedAgainOnlyWhileSmallAndBacksOff() {
        typealias R = AirPlayOutputRenderer
        XCTAssertEqual(R.ioRerequestInterval, 30)
        XCTAssertTrue(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: false,
                                                secondsSinceLastRequest: 30), "fell back to the default size")
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 1024, preferred: 1024, cycleGapsGrew: true,
                                                 secondsSinceLastRequest: 45), "skipped cycles at full size: no re-request")
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 1024, preferred: 1024, cycleGapsGrew: false,
                                                 secondsSinceLastRequest: 3600), "nothing wrong: never asks")
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: true,
                                                 secondsSinceLastRequest: 29.9), "at most once every 30 s")
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 512, preferred: 512, cycleGapsGrew: false,
                                                 secondsSinceLastRequest: 60), "the device's own maximum is enough")
        // A device that keeps AOM small: 30 s, 60 s, 120 s … at most 10 minutes.
        XCTAssertEqual(R.ioRerequestDelay(afterUnheededRequests: 0), 30)
        XCTAssertEqual(R.ioRerequestDelay(afterUnheededRequests: 1), 60)
        XCTAssertEqual(R.ioRerequestDelay(afterUnheededRequests: 3), 240)
        XCTAssertEqual(R.ioRerequestDelay(afterUnheededRequests: 40), 600)
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: false,
                                                 secondsSinceLastRequest: 59, unheededRequests: 1))
        XCTAssertTrue(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: false,
                                                secondsSinceLastRequest: 60, unheededRequests: 1))
        // 3.4.0: a device that ignored two re-requests (a HomePod keeps 128
        // frames) is not asked again by this output; each set on its running
        // IO may restart it (a click). Until 3.4.0: 9 in the first hour, then 6 an hour.
        var asked = 0, unheeded = 0, since = 0.0
        for _ in stride(from: 0.0, to: 3600, by: 30) {
            since += 30
            if R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: false,
                                         secondsSinceLastRequest: since, unheededRequests: unheeded) {
                asked += 1; unheeded += 1; since = 0
            }
        }
        XCTAssertEqual(asked, R.maximumUnheededIORequests, "30 s, then 60 s, then never again within the hour")
        XCTAssertFalse(R.shouldRerequestIOBuffer(configured: 128, preferred: 1024, cycleGapsGrew: false,
                                                 secondsSinceLastRequest: 3600, unheededRequests: 2))
    }

    func testTheBridgeExposesSkippedCycles() {
        let bridge = AirPlayPCMBridge()
        bridge.configure(outputRate: 48000, deviceFrames: 512)
        bridge.prime()
        var buffer = [Float](repeating: 0, count: 1024)
        for time in [0.0, 512, 2048] {
            buffer.withUnsafeMutableBufferPointer { pointer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                withUnsafeMutablePointer(to: &list) { bridge.render(frames: 512, output: $0, sampleTime: time) }
            }
        }
        XCTAssertEqual(bridge.deviceCycleGaps, 1)
    }

    // MARK: App Nap guard

    func testTheNapGuardIsHeldOnceAndReleasedOnce() {
        final class Token: NSObject {}
        var begun = 0, ended = 0
        var reasons: [String] = []
        var guardian: AirPlayNapGuard? = AirPlayNapGuard(reason: "mix",
            begin: { reasons.append($0); begun += 1; return Token() }, end: { _ in ended += 1 })
        XCTAssertFalse(guardian!.isHeld)
        guardian!.acquire(); guardian!.acquire()
        XCTAssertTrue(guardian!.isHeld)
        XCTAssertEqual(begun, 1, "idempotent: one activity per output")
        guardian!.release(); guardian!.release()
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(guardian!.isHeld)
        guardian!.acquire()
        guardian = nil
        XCTAssertEqual(begun, 2)
        XCTAssertEqual(ended, 2, "a guard that goes away releases its activity")
        XCTAssertEqual(reasons, ["mix", "mix"])
        XCTAssertTrue(AirPlayNapGuard.options.contains(.latencyCritical))
        // 3.3.2 review: no idle-sleep block of its own (coreaudiod and
        // AirPlayXPCHelper already hold one while the AirPlay IO runs).
        XCTAssertTrue(AirPlayNapGuard.options.contains(.userInitiatedAllowingIdleSystemSleep))
        XCTAssertFalse(AirPlayNapGuard.options.contains(.idleSystemSleepDisabled))
        XCTAssertFalse(AirPlayNapGuard.options.contains(.userInitiated), ".userInitiated includes the idle-sleep block")
    }

    func testTheRealNapGuardBeginsAndEndsAnActivity() {
        let guardian = AirPlayNapGuard(reason: "AOM test")
        guardian.acquire()
        XCTAssertTrue(guardian.isHeld)
        guardian.release()
        XCTAssertFalse(guardian.isHeld)
    }

    // MARK: Format classification

    /// A device whose nominal rate (44.1 kHz) differs from the AUHAL's
    /// hardware format (48 kHz). With one configured rate for both, every
    /// notification after a reconfigure read as a format change again.
    func testReadingsRightAfterAReconfigureClassifyAsNoChange() {
        typealias R = AirPlayOutputRenderer
        let applied = 44100.0
        let baseline = R.baseline(appliedRate: applied, nominalRate: 44100, deviceRate: 48000, channels: 2)
        XCTAssertEqual(baseline, R.ConfigurationBaseline(nominalRate: 44100, deviceRate: 48000, channels: 2))
        XCTAssertEqual(R.classify(alive: 1, frames: 1024, nominalRate: 44100, deviceRate: 48000, channels: 2,
                                  baseline: baseline, configuredFrames: 1024), .none)
        // The single-rate comparison it replaces would restart the unit again.
        XCTAssertEqual(R.classify(alive: 1, frames: 1024, nominalRate: 44100, deviceRate: 48000, channels: 2,
                                  configuredRate: applied, configuredFrames: 1024, configuredChannels: 2), .format)
        // Real changes are still seen.
        XCTAssertEqual(R.classify(alive: 1, frames: 1024, nominalRate: 48000, deviceRate: 48000, channels: 2,
                                  baseline: baseline, configuredFrames: 1024), .format)
        XCTAssertEqual(R.classify(alive: 1, frames: 1024, nominalRate: 44100, deviceRate: 48000, channels: 6,
                                  baseline: baseline, configuredFrames: 1024), .format)
        XCTAssertEqual(R.classify(alive: 1, frames: 128, nominalRate: 44100, deviceRate: 48000, channels: 2,
                                  baseline: baseline, configuredFrames: 1024), .bufferSize(128))
        XCTAssertEqual(R.classify(alive: 0, frames: 1024, nominalRate: 44100, deviceRate: 48000, channels: 2,
                                  baseline: baseline, configuredFrames: 1024), .lost)
        XCTAssertEqual(R.classify(alive: 1, frames: nil, nominalRate: nil, deviceRate: nil, channels: nil,
                                  baseline: baseline, configuredFrames: 1024), .none, "failed reads are transient")
        // Failed baseline reads fall back to the applied rate.
        XCTAssertEqual(R.baseline(appliedRate: 48000, nominalRate: nil, deviceRate: nil, channels: 2),
                       R.ConfigurationBaseline(nominalRate: 48000, deviceRate: 48000, channels: 2))
    }

    // MARK: Tap membership debounce

    func testAFlappingHelperDoesNotRewriteTheTap() {
        var debounce = TapMembershipDebounce()
        let current: Set<AudioObjectID> = [10, 11]
        // A silent helper appears and disappears on alternate syncs.
        for sync in 0..<10 {
            let proposed: Set<AudioObjectID> = sync % 2 == 0 ? [10, 11, 12] : [10, 11]
            XCTAssertNil(debounce.propose(proposed, current: current, outputting: [10]), "sync \(sync)")
        }
        // Gone for a moment, back the next sync: no rewrite either.
        XCTAssertNil(debounce.propose([10], current: current, outputting: []))
        XCTAssertNil(debounce.propose([10, 11], current: current, outputting: []))
        XCTAssertNil(debounce.pending)
    }

    func testAStableChangeIsAppliedOnTheSecondSync() {
        var debounce = TapMembershipDebounce()
        XCTAssertEqual(TapMembershipDebounce.confirmations, 2)
        XCTAssertNil(debounce.propose([10, 12], current: [10, 11], outputting: [10]))
        XCTAssertEqual(debounce.propose([10, 12], current: [10, 11], outputting: [10]), [10, 12])
        XCTAssertNil(debounce.pending, "settled after applying")
        // A different set in between restarts the count.
        XCTAssertNil(debounce.propose([10, 13], current: [10, 12], outputting: []))
        XCTAssertNil(debounce.propose([10, 14], current: [10, 12], outputting: []))
        XCTAssertEqual(debounce.propose([10, 14], current: [10, 12], outputting: []), [10, 14])
    }

    func testANewPlayingHelperJoinsAtOnce() {
        var debounce = TapMembershipDebounce()
        XCTAssertEqual(debounce.propose([10, 11, 12], current: [10, 11], outputting: [12]), [10, 11, 12],
                       "otherwise it plays natively, unmuted, beside the captured copy")
    }

    func testAMemberStillPlayingIsNeverDropped() {
        var debounce = TapMembershipDebounce()
        // 11 is missing from the snapshot but still running output.
        for _ in 0..<5 { XCTAssertNil(debounce.propose([10], current: [10, 11], outputting: [11])) }
        // 11 leaves for good while 12 (silent) arrives: 11 stays, 12 waits.
        XCTAssertNil(debounce.propose([10, 12], current: [10, 11], outputting: [11]))
        XCTAssertEqual(debounce.propose([10, 12], current: [10, 11], outputting: [11]), [10, 11, 12])
        // An empty snapshot is never applied.
        XCTAssertNil(debounce.propose([], current: [10], outputting: []))
        XCTAssertNil(debounce.propose([], current: [10], outputting: []))
    }

    // MARK: Overdrive on AirPlay

    /// A 40 Hz tone overdriven 4× into the per-app limiter: with the network
    /// bus's 150 ms release the gain does not follow the bass cycles the way
    /// the 25 ms reference release does.
    func testOverdriveOnAirPlayUsesTheNetworkRelease() {
        func residual(release: Double) -> Double {
            let overdrive = AudioVolumeOverdrive(sampleRate: 48000, chunk: 512, releaseSeconds: release)
            let frames = 96000
            var left = (0..<frames).map { Float(0.5 * sin(2 * .pi * 40 * Double($0) / 48000)) }
            var right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    var offset = 0
                    while offset < frames {
                        let count = min(480, frames - offset)
                        overdrive.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset,
                                          frames: count, multiplier: 4)
                        offset += count
                    }
                }
            }
            let tail = left[48000...]
            var ss = 0.0, cc = 0.0, sc = 0.0, sx = 0.0, cx = 0.0
            for (n, x) in tail.enumerated() {
                let w = 2 * Double.pi * 40 * Double(n) / 48000
                let s = sin(w), c = cos(w)
                ss += s * s; cc += c * c; sc += s * c; sx += s * Double(x); cx += c * Double(x)
            }
            let det = ss * cc - sc * sc
            let a = (sx * cc - cx * sc) / det, b = (cx * ss - sx * sc) / det
            var error = 0.0, power = 0.0
            for (n, x) in tail.enumerated() {
                let w = 2 * Double.pi * 40 * Double(n) / 48000
                let model = a * sin(w) + b * cos(w)
                error += (Double(x) - model) * (Double(x) - model)
                power += model * model
            }
            return 10 * log10(max(1e-30, error / power))
        }
        let fast = residual(release: 0.025), slow = residual(release: AppAudioRenderBus.networkRelease)
        print("40 Hz overdriven 4×: distortion \(fast) dB (25 ms), \(slow) dB (150 ms)")
        XCTAssertLessThan(slow, fast - 6, "the network release keeps an overdriven bass note cleaner")

        let mixer = MixerBox(gain: 1, muted: false)
        XCTAssertFalse(mixer.usesNetworkDynamics, "local outputs keep the reference release")
        mixer.usesNetworkDynamics = true
        XCTAssertTrue(mixer.usesNetworkDynamics)
        mixer.usesNetworkDynamics = false
        XCTAssertFalse(mixer.usesNetworkDynamics)
    }


    // MARK: - 3.4.2 HomePod overload recovery

    func testObservedIsolatedHomePodFaultsDoNotDestroyHealthyStreams() {
        var evidence = AirPlayOverloadRecoveryEvidence()
        // Actual 3.4.5 intervals: tiny shared-device gaps led to four full
        // output/tap rebuilds although all PCM queues and the mixer were healthy.
        var total: UInt64 = 0
        for (index, entry) in [(233.0, 284), (337.0, 256), (1108.0, 268), (1660.0, 256)].enumerated() {
            total += UInt64(entry.1)
            XCTAssertFalse(evidence.observe(overloads: UInt64(index + 1), gaps: UInt64(index + 1),
                gapFrames: total, now: entry.0, startedAt: 0))
        }
    }

    func testSustainedCorrelatedFailuresRecoverOnceAndConsumeEvidence() {
        var evidence = AirPlayOverloadRecoveryEvidence()
        XCTAssertFalse(evidence.observe(overloads: 1, gaps: 1, gapFrames: 256, now: 20, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 2, gaps: 2, gapFrames: 512, now: 23, startedAt: 0))
        XCTAssertTrue(evidence.observe(overloads: 3, gaps: 3, gapFrames: 768, now: 26, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 3, gaps: 3, gapFrames: 768, now: 26.1, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 4, gaps: 4, gapFrames: 1024, now: 27, startedAt: 0))
    }

    func testOverloadNotificationCanArriveBeforeOrAfterGap() {
        var evidence = AirPlayOverloadRecoveryEvidence()
        for n in 1...3 {
            let time = 20 + Double(n)
            if n % 2 == 0 {
                XCTAssertFalse(evidence.observe(overloads: UInt64(n), gaps: UInt64(n - 1),
                    gapFrames: UInt64((n - 1) * 256), now: time, startedAt: 0))
            } else {
                XCTAssertFalse(evidence.observe(overloads: UInt64(n - 1), gaps: UInt64(n),
                    gapFrames: UInt64(n * 256), now: time, startedAt: 0))
            }
            XCTAssertEqual(evidence.observe(overloads: UInt64(n), gaps: UInt64(n),
                gapFrames: UInt64(n * 256), now: time + 0.1, startedAt: 0), n == 3)
        }
    }

    func testStartupStaleTinyAndResetEvidenceCannotAccumulateIntoRecovery() {
        var evidence = AirPlayOverloadRecoveryEvidence()
        for n in 1...3 {
            XCTAssertFalse(evidence.observe(overloads: UInt64(n), gaps: UInt64(n),
                gapFrames: UInt64(n * 256), now: Double(n), startedAt: 0))
        }
        XCTAssertFalse(evidence.observe(overloads: 4, gaps: 4, gapFrames: 1024, now: 20, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 5, gaps: 5, gapFrames: 1280, now: 25, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 6, gaps: 6, gapFrames: 1536, now: 40, startedAt: 0),
                       "older episodes expire")
        XCTAssertFalse(evidence.observe(overloads: 7, gaps: 7, gapFrames: 1600, now: 41, startedAt: 0),
                       "64-frame gap is not a severe episode")
        XCTAssertFalse(evidence.observe(overloads: 0, gaps: 0, gapFrames: 0, now: 42, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 1, gaps: 1, gapFrames: 256, now: 43, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 2, gaps: 1, gapFrames: 256, now: 44, startedAt: 0))
        XCTAssertFalse(evidence.observe(overloads: 2, gaps: 2, gapFrames: 512, now: 47, startedAt: 0),
                       "notification correlation expires")
    }

    func testFailedDevicePropertyReadDoesNotTearDownPlayingOutput() {
        XCTAssertEqual(AirPlayOutputRenderer.classify(alive: nil, frames: nil, nominalRate: nil,
            deviceRate: nil, channels: nil, configuredRate: 48000, configuredFrames: 128,
            configuredChannels: 2), .none)
        XCTAssertEqual(AirPlayOutputRenderer.classify(alive: 0, frames: nil, nominalRate: nil,
            deviceRate: nil, channels: nil, configuredRate: 48000, configuredFrames: 128,
            configuredChannels: 2), .lost)
    }

    func testHomePodRecoveryBudgetSurvivesOutputReplacement() {
        var budget = AirPlayOverloadRecoveryBudget()
        XCTAssertTrue(budget.allow(now: 100))
        XCTAssertFalse(budget.allow(now: 101))
        XCTAssertFalse(budget.allow(now: 129.9))
        for time in [130.0, 160.0, 190.0, 220.0, 250.0] {
            XCTAssertTrue(budget.allow(now: time), "up to six recoveries, 30 seconds apart")
        }
        XCTAssertFalse(budget.allow(now: 280), "no more than six automatic restarts in ten minutes")
        XCTAssertTrue(budget.allow(now: 701), "old attempts expire and recovery becomes available")
        XCTAssertFalse(budget.allow(now: 700), "a timebase rollback cannot bypass cooldown")
    }
}
