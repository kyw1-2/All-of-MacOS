import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.1: the defects an outside audit and Codex's audio review found and this
/// release confirmed in the code (`docs/review-7.1-audit.md`).
final class AOM71FixTests: XCTestCase {
    func testDischargeStopsForGoodAtItsTarget() {
        // Codex's reproduction: (71 %, AC) → (70 %, battery) → (71 %, AC) cut
        // true → false → true, a micro-cycle while the helper kept ticking.
        var policy = DischargePolicy()
        XCTAssertTrue(policy.cutsAdapter(percent: 71, target: 70, onAC: true))
        XCTAssertFalse(policy.cutsAdapter(percent: 70, target: 70, onAC: false))
        XCTAssertFalse(policy.cutsAdapter(percent: 71, target: 70, onAC: true), "the restored adapter never restarts it")
        XCTAssertFalse(policy.cutsAdapter(percent: 95, target: 70, onAC: true))
        XCTAssertTrue(policy.completed)
        var next = DischargePolicy()
        XCTAssertTrue(next.cutsAdapter(percent: 95, target: 70, onAC: true), "a new discharge starts fresh")
    }

    func testBatteryIsWatchedOnlyWhileAnOperationRuns() {
        XCTAssertTrue(HardwareCareModel.needsBackgroundWatch(topUpRestore: 80, dischargeTarget: nil, terminating: false))
        XCTAssertTrue(HardwareCareModel.needsBackgroundWatch(topUpRestore: nil, dischargeTarget: 70, terminating: false))
        XCTAssertFalse(HardwareCareModel.needsBackgroundWatch(topUpRestore: nil, dischargeTarget: nil, terminating: false))
        XCTAssertFalse(HardwareCareModel.needsBackgroundWatch(topUpRestore: 80, dischargeTarget: 70, terminating: true))
    }

    func testAPartialFolderPassKeepsOtherFoldersWaiting() {
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
        let desktop = URL(fileURLWithPath: "/Users/me/Desktop")
        XCTAssertTrue(FolderRuleStability.covers(desktop, recursive: false, path: "/Users/me/Desktop/a.png"))
        XCTAssertFalse(FolderRuleStability.covers(desktop, recursive: false, path: "/Users/me/Desktop/Sub/b.png"),
                       "a nested watched folder keeps its own records")
        XCTAssertTrue(FolderRuleStability.covers(desktop, recursive: true, path: "/Users/me/Desktop/Sub/b.png"))
        XCTAssertFalse(FolderRuleStability.covers(desktop, recursive: true, path: "/Users/me/DesktopOld/c.png"))

        var stability = FolderRuleStability()
        let now = Date()
        for url in [downloads.appendingPathComponent("big.zip"), desktop.appendingPathComponent("gone.png"),
                    desktop.appendingPathComponent("kept.png")] {
            var info = FolderRuleFileInfo(url: url, name: url.lastPathComponent)
            info.size = 10
            info.dateModified = now
            _ = stability.isStable(info, now: now)
        }
        XCTAssertEqual(stability.observations.count, 3)
        stability.prune(inFolders: [(desktop, false)], keeping: [desktop.appendingPathComponent("kept.png").path])
        XCTAssertEqual(Set(stability.observations.keys), [downloads.appendingPathComponent("big.zip").path,
                                                           desktop.appendingPathComponent("kept.png").path],
                       "the Downloads record survives a Desktop pass")
    }

    func testGapFadeInSurvivesSilenceAfterTheGap() {
        // Codex's reproduction, queued AirPlay path: warm at 0.5, fade out
        // for a confirmed gap, 128 zeros, arm the fade, k more zeros, then
        // 0.5. Shipped 7.0 started at 0.5 (a step) for k ≥ 1.
        for extra in [0, 1, 31, 32, 96] {
            let softener = AudioDropoutSoftener()
            var out: [Float] = []
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
            defer { scratch.deallocate() }
            func feed(_ frames: Int, _ value: Float) {
                softener.process(frames: frames, sampleRate: 48000, output: scratch) { _ in (value, value) }
                for frame in 0..<frames { out.append(scratch[frame * 2]) }
            }
            feed(512, 0.5)
            softener.fadeOutPendingAudio()
            feed(128, 0)
            softener.fadeInNextAudio()
            if extra > 0 { feed(extra, 0) }
            feed(512, 0.5)
            guard let lastZero = out.lastIndex(of: 0), lastZero + 1 < out.count else { return XCTFail("no gap in output") }
            XCTAssertLessThan(out[lastZero + 1], 0.01, "a ramp, not a step, after \(extra) silent frames")
        }
    }

    func testVolumeTrackSplitsAtTheDetent() {
        XCTAssertEqual(AppAudioMixerService.volumeSplit(4).gain, 1)
        XCTAssertEqual(AppAudioMixerService.volumeSplit(4).overdrive, 4)
        XCTAssertEqual(AppAudioMixerService.volumeSplit(0.5).gain, 0.5)
        XCTAssertEqual(AppAudioMixerService.volumeSplit(0.5).overdrive, 1, "back under 100 % clears the overdrive")
        XCTAssertEqual(AppAudioMixerService.volumeSplit(1.03).overdrive, 1.05, accuracy: 0.0001)
        XCTAssertEqual(AppAudioMixerService.volumeSplit(.nan).gain, 0)
    }

    func testDirectCaptureAndRenderingAreSeparateFacts() {
        XCTAssertTrue(AirPlayDirectStream.isRecent(1_000, now: 1_000 + 100_000_000, secondsPerTick: 1e-9), "0.1 s ago")
        XCTAssertFalse(AirPlayDirectStream.isRecent(1_000, now: 1_000 + 300_000_000, secondsPerTick: 1e-9), "0.3 s ago")
        XCTAssertFalse(AirPlayDirectStream.isRecent(0, now: 5, secondsPerTick: 1e-9), "never")
    }

    func testOverloadEventsCarryTheSystemState() {
        let detail = AudioSystemLoad.describe(load: 13.26, memoryPressure: 2, swappedGB: 9.7, thermal: .serious)
        XCTAssertEqual(detail, "kAudioDeviceProcessorOverload · load 13.3 · memory warn · swap 9.7 GB · thermal serious")
        XCTAssertEqual(AudioSystemLoad.describe(load: nil, memoryPressure: nil, swappedGB: nil, thermal: .nominal),
                       "kAudioDeviceProcessorOverload · thermal nominal")
    }

    func testNewerTokenFormatsAreSecrets() {
        let fake = "abcdefghijklmnopqrstuvwxyzABCDEFGH1234567890"
        for token in ["github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "ASIA4EXAMPLE7ZZQKEYX",
                      "sk_live_" + fake.prefix(28), "rk_live_" + fake.prefix(28), "whsec_" + fake.prefix(30),
                      "hf_" + fake.prefix(34), "npm_" + fake.prefix(36), "pypi-AgEIcHlwaS5vcmc" + fake.prefix(30)] {
            XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: "key: \(token) end"), token)
        }
        XCTAssertFalse(ClipboardSecretScanner.containsSecret(inText: "ASIAPACIFICREGIONS map"), "no digit: plain text")
    }

    @MainActor
    func testPasteAsksAgainWhenTheFirstActivationIsDropped() async {
        var activations = 0
        var step = 0
        let outcome = await ClipboardPasteDelivery.deliver(version: 1, environment: .init(
            relinquishFocus: {}, targetIsAlive: { true },
            targetIsFrontmost: { activations >= 2 && step > 20 },
            activateTarget: { activations += 1; return true },
            clipboardVersion: { 1 }, send: { true }),
            wait: { step += 1 })
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(activations, 2, "the initial request and one more at 150 ms")
    }
}
