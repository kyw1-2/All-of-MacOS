import XCTest
import CoreAudio
@testable import AllOfMacOS

final class AudioPipelineTests: XCTestCase {
    private func withStereoBuffer<T>(_ samples: inout [Float], _ body: (UnsafeMutablePointer<AudioBufferList>) -> T) -> T {
        samples.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            return withUnsafeMutablePointer(to: &list, body)
        }
    }

    /// Exercises the production capture -> resample -> app EQ -> master EQ ->
    /// summing bus -> AirPlay PCM resampler path. No hardware or user defaults.
    private func pipeline(app: AudioEQ = AudioEQ(), master: AudioEQ = AudioEQ(),
                          gain: Float = 1, muted: Bool = false, outputRate: Double = 48000) -> (Double, Double) {
        let transport = AppAudioTransport(sampleRate: 48000, bufferedForAirPlay: true)
        let mixer = MixerBox(gain: gain, muted: muted)
        mixer.setEffects(app: app, master: master, appBoost: 0, masterBoost: 0)
        let bus = AppAudioRenderBus()
        bus.add(id: UUID()) { transport.render(frames: $0, output: $1, mixer: mixer) }
        let bridge = AirPlayPCMBridge()
        let outputFrames = Int(outputRate / 100)
        bridge.configure(outputRate: outputRate, deviceFrames: outputFrames)
        bridge.prime()
        var input = [Float](repeating: 0, count: 960)
        var local = input
        var remote = [Float](repeating: 0, count: outputFrames * 2)
        var leftEnergy: Double = 0, rightEnergy: Double = 0, samples = 0
        for block in 0..<160 {
            for frame in 0..<480 {
                let t = Double(block * 480 + frame) / 48000
                input[frame * 2] = Float(sin(2 * .pi * 1000 * t)) * 0.05
                input[frame * 2 + 1] = Float(sin(2 * .pi * 4000 * t)) * 0.05
            }
            withStereoBuffer(&input) { transport.capture(UnsafePointer($0)) }
            withStereoBuffer(&local) { bus.render(frames: 480, output: $0) }
            local.withUnsafeBufferPointer { bridge.push($0.baseAddress!, frames: 480) }
            withStereoBuffer(&remote) { bridge.render(frames: outputFrames, output: $0) }
            if block >= 100 {
                for frame in 0..<outputFrames {
                    leftEnergy += pow(Double(remote[frame * 2]), 2)
                    rightEnergy += pow(Double(remote[frame * 2 + 1]), 2)
                    samples += 1
                }
            }
        }
        XCTAssertTrue(transport.activity.recent)
        XCTAssertTrue(transport.activity.rendering)
        return (sqrt(leftEnergy / Double(samples)), sqrt(rightEnergy / Double(samples)))
    }

    func testEQGainAndMuteSurviveTheFullHomePodPCMPathAtBothDeviceRates() {
        var appBands = AudioEQ.presetFlat; appBands[5] = 6
        var masterBands = AudioEQ.presetFlat; masterBands[5] = -3
        for rate in [44100.0, 48000.0] {
            let flat = pipeline(outputRate: rate)
            let filtered = pipeline(app: AudioEQ(gains: appBands), master: AudioEQ(gains: masterBands), outputRate: rate)
            let db = 20 * log10(filtered.0 / flat.0)
            print("HomePod PCM \(Int(rate)) Hz: app +6 dB + master -3 dB at 1 kHz = \(db) dB")
            let headroomDB = 20 * log10(Double(AudioEQ.headroomGain(app: AudioEQ(gains: appBands), master: AudioEQ(gains: masterBands))))
            XCTAssertEqual(db, 3 + headroomDB, accuracy: 0.12)
            XCTAssertLessThan(abs(20 * log10(filtered.1 / flat.1) - headroomDB), 0.5, "Stereo histories must stay independent")
            let half = pipeline(gain: 0.5, outputRate: rate)
            XCTAssertEqual(half.0 / flat.0, 0.5, accuracy: 0.005)
            let mute = pipeline(muted: true, outputRate: rate)
            XCTAssertEqual(mute.0, 0); XCTAssertEqual(mute.1, 0)
        }
    }

    func testIdleTransportDoesNotClaimCaptureOrOutputAndPrimingNeedsRealFrames() {
        let transport = AppAudioTransport(sampleRate: 48000)
        XCTAssertFalse(transport.activity.recent)
        XCTAssertFalse(transport.activity.rendering)
        var output = [Float](repeating: 1, count: 960)
        withStereoBuffer(&output) { transport.render(frames: 480, output: $0, mixer: MixerBox(gain: 1, muted: false)) }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
        XCTAssertEqual(transport.activity.rendered, 0)
        XCTAssertFalse(transport.activity.rendering)
    }

    func testWatchdogAllowsIdleAndBriefGapsButReleasesSustainedCaptureAndOutputStalls() {
        var watchdog = AudioActivityWatchdog()
        for time in [0.0, 10, 100] {
            XCTAssertNil(watchdog.failure(playing: false, capturing: false, rendering: false, now: time))
        }
        XCTAssertNil(watchdog.failure(playing: true, capturing: false, rendering: false, now: 101))
        XCTAssertNil(watchdog.failure(playing: true, capturing: false, rendering: false, now: 106))
        XCTAssertEqual(watchdog.failure(playing: true, capturing: false, rendering: false, now: 107), .capture)
        XCTAssertNil(watchdog.failure(playing: true, capturing: true, rendering: true, now: 108))
        XCTAssertNil(watchdog.failure(playing: true, capturing: true, rendering: false, now: 109))
        XCTAssertEqual(watchdog.failure(playing: true, capturing: true, rendering: false, now: 115), .output)
        XCTAssertNil(watchdog.failure(playing: true, capturing: true, rendering: true, now: 116))
        XCTAssertNil(watchdog.failure(playing: true, capturing: true, rendering: false, now: 117))
    }

    func testChangingEffectsRetunesTheExistingMixerWithoutLosingGainOrMute() {
        let box = MixerBox(gain: 0.5, muted: false)
        var bands = AudioEQ.presetFlat; bands[5] = 6
        var input = [Float](repeating: 0.1, count: 960), output = input
        withStereoBuffer(&input) { source in
            withStereoBuffer(&output) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
        }
        XCTAssertEqual(output[0], 0.05, accuracy: 0.001)
        box.setEffects(app: AudioEQ(gains: bands), master: AudioEQ(), appBoost: 0, masterBoost: 0)
        XCTAssertEqual(box.gain, 0.5)
        box.muted = true
        withStereoBuffer(&input) { source in
            withStereoBuffer(&output) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
        }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
        box.muted = false
        box.setEffects(app: AudioEQ(), master: AudioEQ(), appBoost: 0, masterBoost: 0)
        withStereoBuffer(&input) { source in
            withStereoBuffer(&output) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
        }
        XCTAssertEqual(output[0], 0.05, accuracy: 0.001)
    }

    func testHotEQAndSummedAppsDoNotFlattenWaveforms() {
        func signal(eq: AudioEQ, appCount: Int) -> [Double] {
            let bus = AppAudioRenderBus()
            var tone = [Float](repeating: 0, count: 960)
            for _ in 0..<appCount {
                let box = MixerBox(gain: 1, muted: false, eq: eq)
                bus.add(id: UUID()) { _, output in
                    self.withStereoBuffer(&tone) { Mixer.mix(input: UnsafePointer($0), output: output, box: box) }
                }
            }
            var output = tone, result: [Double] = []
            for block in 0..<100 {
                for frame in 0..<480 {
                    let value = Float(sin(2 * .pi * 1000 * Double(block * 480 + frame) / 48000)) * 0.8
                    tone[frame * 2] = value; tone[frame * 2 + 1] = value * 0.5
                }
                withStereoBuffer(&output) { bus.render(frames: 480, output: $0) }
                if block >= 50 {
                    for frame in 0..<480 {
                        XCTAssertEqual(output[frame * 2 + 1], output[frame * 2] * 0.5, accuracy: 0.00001)
                        result.append(Double(output[frame * 2]))
                    }
                }
            }
            return result
        }
        func amplitude(_ signal: [Double], frequency: Double) -> Double {
            var real = 0.0, imaginary = 0.0
            for (index, sample) in signal.enumerated() {
                let phase = 2 * Double.pi * frequency * Double(index) / 48000
                real += sample * cos(phase); imaginary += sample * sin(phase)
            }
            return 2 * hypot(real, imaginary) / Double(signal.count)
        }
        var bands = AudioEQ.presetFlat; bands[5] = 12
        for (eq, count) in [(AudioEQ(gains: bands), 1), (AudioEQ(gains: Array(repeating: 12, count: 10)), 1), (AudioEQ(), 2)] {
            let output = signal(eq: eq, appCount: count)
            let fundamental = amplitude(output, frequency: 1000)
            let harmonic = amplitude(output, frequency: 3000) / fundamental
            print("Hot EQ / sum: apps=\(count), third harmonic=\(harmonic * 100)%, peak=\(output.map(abs).max()!)")
            XCTAssertGreaterThan(fundamental, 0.1, "Attenuating to silence is not a fix")
            XCTAssertLessThan(harmonic, 0.003, "Hard clipping adds a strong third harmonic")
            XCTAssertLessThanOrEqual(output.map(abs).max()!, 0.981)
            XCTAssertEqual(output.filter { abs($0) >= 0.9999 }.count, 0)
        }
    }

    func testLimiterKeepsFiniteStereoOutputWithInvalidOrExtremeSamples() {
        let limiter = AudioPeakLimiter()
        for value in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 2, -2, 0.2] {
            var left = value, right = value
            limiter.process(left: &left, right: &right)
            XCTAssertTrue(left.isFinite && right.isFinite)
            XCTAssertLessThanOrEqual(abs(left), 0.981)
            XCTAssertEqual(left, right)
        }
    }
}

@MainActor
final class AudioAutomationInputTests: XCTestCase {
    @available(macOS 14.2, *)
    func testTapOwnsNativeMuteUntilTeardownAndCannotRestoreSharedHelpersByBundleID() {
        let description = AppAudioEngine.captureDescription(processIDs: [11, 22], bundleID: "test.audio.owner")
        XCTAssertEqual(description.muteBehavior, .muted)
        XCTAssertTrue(description.isPrivate)
        XCTAssertFalse(description.isExclusive)
        XCTAssertEqual(description.processes, [11, 22])
        if #available(macOS 26.0, *) {
            XCTAssertEqual(description.bundleIDs, ["test.audio.owner"])
            XCTAssertFalse(description.isProcessRestoreEnabled)
        }
    }

    func testPIDCannotWrapTruncateOrUseBooleanAndNeverFallsBackSilently() throws {
        XCTAssertNil(try AutomationMCP.validatedAudioPID(nil))
        XCTAssertEqual(try AutomationMCP.validatedAudioPID(NSNumber(value: 1234)), 1234)
        for bad: Any in [true, false, -1, 0, 1.5, Double.nan, Double.infinity, Double(Int32.max) + 1, 4294968530.0, "1234"] {
            XCTAssertThrowsError(try AutomationMCP.validatedAudioPID(bad))
        }
    }
}
