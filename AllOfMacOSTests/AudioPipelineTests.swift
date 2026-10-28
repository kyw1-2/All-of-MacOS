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
        mixer.setEffects(app: app, master: master, appBoost: 0)
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

    func testOutputBoostProcessesSummedAudioAndAppBoostRemainsIndependent() {
        func render(appBoost: Int, outputBoost: Int, sources: Int) -> Float {
            let bus = AppAudioRenderBus()
            bus.setBoostLevel(outputBoost)
            for _ in 0..<sources {
                let box = MixerBox(gain: 1, muted: false)
                box.setEffects(app: AudioEQ(), master: AudioEQ(), appBoost: appBoost)
                bus.add(id: UUID()) { frames, output in
                    var input = [Float](repeating: 0.05, count: frames * 2)
                    self.withStereoBuffer(&input) { Mixer.mix(input: UnsafePointer($0), output: output, box: box) }
                }
            }
            var output = [Float](repeating: 0, count: 960)
            for _ in 0..<100 { withStereoBuffer(&output) { bus.render(frames: 480, output: $0) } }
            return output.last!
        }
        let dry = render(appBoost: 0, outputBoost: 0, sources: 2)
        let app = render(appBoost: 1, outputBoost: 0, sources: 2)
        let output = render(appBoost: 0, outputBoost: 1, sources: 2)
        let both = render(appBoost: 1, outputBoost: 1, sources: 2)
        XCTAssertEqual(dry, 0.1, accuracy: 0.001)
        XCTAssertGreaterThan(app, dry * 1.2)
        XCTAssertGreaterThan(output, dry * 1.2)
        XCTAssertGreaterThan(both, max(app, output) * 1.15)
        XCTAssertLessThanOrEqual(both, 0.98)
    }

    func testOutputBoostUsesTheCombinedSignalAndCanBeDisabled() {
        let bus = AppAudioRenderBus()
        bus.setBoostLevel(1)
        for _ in 0..<2 {
            bus.add(id: UUID()) { frames, output in
                let buffers = UnsafeMutableAudioBufferListPointer(output)
                let data = buffers[0].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<(frames * 2) { data[i] = 0.15 }
            }
        }
        // Reference: the summed 0.3 signal through Magic Boost and the limiter.
        let boost = AudioMagicBoost(sampleRate: 48000)
        let limiter = AudioLookaheadLimiter(sampleRate: 48000, ceiling: AppAudioRenderBus.ceiling)
        var referenceLeft = [Float](repeating: 0.3, count: 480), referenceRight = referenceLeft
        var output = [Float](repeating: 0, count: 960)
        for _ in 0..<100 {
            withStereoBuffer(&output) { bus.render(frames: 480, output: $0) }
            for i in 0..<480 { referenceLeft[i] = 0.3; referenceRight[i] = 0.3 }
            referenceLeft.withUnsafeMutableBufferPointer { l in
                referenceRight.withUnsafeMutableBufferPointer { r in
                    boost.process(left: l.baseAddress!, right: r.baseAddress!, frames: 480, enabled: true)
                    limiter.process(left: l.baseAddress!, right: r.baseAddress!, frames: 480)
                }
            }
        }
        XCTAssertEqual(output.last!, referenceLeft.last!, accuracy: 0.001)
        XCTAssertGreaterThan(output.last!, 0.33, "Magic Boost raises the combined signal")
        bus.setBoostLevel(0)
        for _ in 0..<100 { withStereoBuffer(&output) { bus.render(frames: 480, output: $0) } }
        XCTAssertEqual(output.last!, 0.3, accuracy: 0.001)
    }

    func testChangingOutputBoostDoesNotInterruptTheRenderBus() {
        let bus = AppAudioRenderBus()
        bus.add(id: UUID()) { frames, output in
            let data = UnsafeMutableAudioBufferListPointer(output)[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<(frames * 2) { data[i] = 0.04 }
        }
        let started = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            started.wait()
            for i in 0..<100_000 { bus.setBoostLevel(i % 4) }
            done.leave()
        }
        started.signal()
        var samples = [Float](repeating: 0, count: 128)
        for block in 0..<1000 {
            withStereoBuffer(&samples) { bus.render(frames: 64, output: $0) }
            // The first block is the limiter's 64-frame lookahead latency.
            if block > 0 { XCTAssertTrue(samples.allSatisfy { $0.isFinite && $0 > 0 }) }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
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

    func testZeroFrameCaptureIsNotPlaybackAndPausedCallbacksDoNotDisconnect() {
        let transport = AppAudioTransport(sampleRate: 48000)
        var backing: [Float] = [0, 0]
        backing.withUnsafeMutableBufferPointer { pointer in
            var packet = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: 0, mData: pointer.baseAddress))
            withUnsafePointer(to: &packet) { transport.capture($0) }
        }
        XCTAssertEqual(transport.activity.captured, 0)
        XCTAssertFalse(transport.activity.recent, "Zero-frame callbacks cannot arm capture activity")

        var watchdog = AudioActivityWatchdog()
        for time in [0.0, 6.0, 12.0] {
            XCTAssertNil(watchdog.failure(playing: false, capturing: true,
                                         rendering: false, now: time),
                         "Pausing or switching video streams must not tear down output")
        }
        XCTAssertNil(watchdog.failure(playing: true, capturing: true, rendering: false, now: 13))
        XCTAssertEqual(watchdog.failure(playing: true, capturing: true,
                                        rendering: false, now: 19), .output)
        backing = [0.25, -0.25]
        withStereoBuffer(&backing) { transport.capture(UnsafePointer($0)) }
        XCTAssertEqual(transport.activity.captured, 1)
        XCTAssertTrue(transport.activity.recent)
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
        box.setEffects(app: AudioEQ(gains: bands), master: AudioEQ(), appBoost: 0)
        XCTAssertEqual(box.gain, 0.5)
        box.muted = true
        withStereoBuffer(&input) { source in
            withStereoBuffer(&output) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
        }
        XCTAssertTrue(output.suffix(480).allSatisfy { $0 == 0 }, "Mute settles after a short click-free ramp")
        box.muted = false
        box.setEffects(app: AudioEQ(), master: AudioEQ(), appBoost: 0)
        withStereoBuffer(&input) { source in
            withStereoBuffer(&output) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
        }
        XCTAssertEqual(output[output.count - 2], 0.05, accuracy: 0.001)
    }

    func testGainDeviceVolumeAndMuteAreContinuousAcrossSmallCallbacks() {
        let box = MixerBox(gain: 1, muted: false)
        var input = [Float](repeating: 0.5, count: 128)
        var output = input
        func block() {
            withStereoBuffer(&input) { source in
                withStereoBuffer(&output) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
            }
        }
        block()
        var previous: Float = 0.5
        for (gain, device, mute, expected): (Float, Float, Bool, Float) in [
            (0.2, 1, false, 0.1), (0.2, 0.5, false, 0.05),
            (0.2, 0.5, true, 0), (1, 1, false, 0.5)
        ] {
            box.gain = gain; box.deviceGain = device; box.muted = mute
            for _ in 0..<5 {
                block()
                for frame in 0..<64 {
                    XCTAssertLessThan(abs(output[frame * 2] - previous), 0.003)
                    XCTAssertEqual(output[frame * 2], output[frame * 2 + 1])
                    previous = output[frame * 2]
                }
            }
            XCTAssertEqual(previous, expected, accuracy: 0.00001)
        }
    }

    func testLiveEQChangesCrossfadeWithoutResettingAnActiveTransition() {
        let box = MixerBox(gain: 1, muted: false)
        var input = [Float](repeating: 0.3, count: 128), output = input
        var previous: Float = 0.3
        for block in 0..<60 {
            if block == 2 || block == 3 || block == 4 {
                var bands = AudioEQ.presetFlat
                bands[5] = block == 3 ? -12 : 12
                box.setEffects(app: AudioEQ(gains: bands), master: AudioEQ(), appBoost: 0)
            }
            if block == 30 {
                box.setEffects(app: AudioEQ(), master: AudioEQ(), appBoost: 0)
            }
            withStereoBuffer(&input) { source in
                withStereoBuffer(&output) { Mixer.mix(input: UnsafePointer(source), output: $0, box: box) }
            }
            for frame in 0..<64 {
                let value = output[frame * 2]
                XCTAssertTrue(value.isFinite)
                XCTAssertLessThan(abs(value - previous), 0.01, "EQ changes must not insert a sample jump")
                XCTAssertEqual(value, output[frame * 2 + 1])
                previous = value
            }
        }
        XCTAssertEqual(previous, 0.3, accuracy: 0.0001)
    }

    func testAirPlayDeviceQueuesIsolateSlowReceiversAndSerializeReplacements() {
        let slow = AirPlayDeviceQueues.queue(for: 900001)
        let replacement = AirPlayDeviceQueues.queue(for: 900001)
        let other = AirPlayDeviceQueues.queue(for: 900002)
        XCTAssertTrue(slow === replacement)
        XCTAssertFalse(slow === other)
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "slow teardown entered")
        let unrelated = expectation(description: "other receiver continues")
        let replacementDone = expectation(description: "replacement starts after teardown")
        slow.async {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }
        wait(for: [entered], timeout: 2)
        replacement.async { replacementDone.fulfill() }
        other.async { unrelated.fulfill() }
        wait(for: [unrelated], timeout: 2)
        gate.signal()
        wait(for: [replacementDone], timeout: 2)
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
        let limiter = AudioLookaheadLimiter(sampleRate: 48000, ceiling: 0.98)
        var left: [Float] = [], right: [Float] = []
        for value in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 2, -2, 0.2] {
            left += Array(repeating: value, count: 100); right += Array(repeating: value, count: 100)
        }
        // 100 ms: the release reaches -20 dB of the remaining distance every 25 ms.
        left += Array(repeating: 0.2, count: 4800); right += Array(repeating: 0.2, count: 4800)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                limiter.process(left: l.baseAddress!, right: r.baseAddress!, frames: l.count)
            }
        }
        for (l, r) in zip(left, right) {
            XCTAssertTrue(l.isFinite && r.isFinite)
            XCTAssertLessThanOrEqual(abs(l), 0.98)
            XCTAssertEqual(l, r)
        }
        XCTAssertEqual(left.last!, 0.2, accuracy: 0.02, "The limiter releases back to unity")
    }

    private func sine(_ frequency: Double, amplitude: Float, frames: Int, start: Int = 0) -> [Float] {
        (0..<frames).map { Float(sin(2 * .pi * frequency * Double(start + $0) / 48000)) * amplitude }
    }

    private func amplitude(_ signal: ArraySlice<Float>, frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (index, sample) in signal.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48000
            real += Double(sample) * cos(phase); imaginary += Double(sample) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(signal.count)
    }

    private func boosted(_ input: [Float], boost: AudioMagicBoost, enabled: Bool = true) -> [Float] {
        var left = input, right = input
        var offset = 0
        while offset < input.count {
            let count = min(480, input.count - offset)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    boost.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: count, enabled: enabled)
                }
            }
            offset += count
        }
        return left
    }

    func testMagicBoostLooksAheadSoALoudEntranceIsNeverClipped() {
        // Two seconds of quiet audio let the gain climb, then a full-scale tone
        // starts abruptly: lookahead must pull the gain down before it is heard.
        let quiet = sine(220, amplitude: 0.02, frames: 96000)
        let loud = sine(1000, amplitude: 1.0, frames: 48000, start: 96000)
        let output = boosted(quiet + loud, boost: AudioMagicBoost(sampleRate: 48000))
        let peak = output.map(abs).max()!
        print("Magic Boost loud entrance peak = \(peak)")
        XCTAssertLessThan(peak, 0.95, "No overshoot: the detector runs 512 frames ahead of the output")
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        let settled = output[(96000 + 24000)...]
        let harmonic = amplitude(settled, frequency: 3000) / amplitude(settled, frequency: 1000)
        XCTAssertLessThan(harmonic, 0.01, "Gain riding must not distort a steady tone")
    }

    func testMagicBoostRaisesQuietAudioWithoutClimbingOverSilence() {
        let boost = AudioMagicBoost(sampleRate: 48000)
        let quiet = sine(440, amplitude: 0.05, frames: 96000)
        let raised = boosted(quiet, boost: boost)
        func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(x.count)) }
        XCTAssertGreaterThan(rms(raised[48000...]), rms(quiet[48000...]) * 3, "Quiet passages get tremendous volume")
        let gainBeforeSilence = boost.gain
        _ = boosted([Float](repeating: 0, count: 48000), boost: boost)
        XCTAssertLessThan(boost.gain - gainBeforeSilence, 0.5, "Digital silence must not ramp the gain up")
        let resumed = boosted(sine(440, amplitude: 0.8, frames: 24000), boost: boost)
        XCTAssertLessThan(resumed.map(abs).max()!, 0.95, "Sound returning after silence is not blasted")
    }

    func testMagicBoostEnablesAndDisablesWithoutAJump() {
        let boost = AudioMagicBoost(sampleRate: 48000)
        let input = sine(200, amplitude: 0.3, frames: 48000)
        var output: [Float] = []
        for block in 0..<100 {
            let slice = Array(input[(block * 480)..<min(input.count, block * 480 + 480)])
            output += boosted(slice, boost: boost, enabled: block >= 10 && block < 60)
        }
        let maximumStep = zip(output.dropFirst(), output).map { abs($0 - $1) }.max()!
        let inputStep = zip(input.dropFirst(), input).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(maximumStep, inputStep * 4, "Crossfades, not clicks")
        XCTAssertFalse(boost.isActive, "Disabled Magic Boost returns to a zero-latency bypass")
        XCTAssertEqual(output.last!, input.last!, accuracy: 0.000_01)
    }

    func testLookaheadLimiterHoldsTheCeilingWithoutFlatteningPeaks() {
        let limiter = AudioLookaheadLimiter(sampleRate: 48000, ceiling: 0.977)
        var left = sine(1000, amplitude: 2.0, frames: 48000)
        var right = left.map { $0 * 0.5 }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                limiter.process(left: l.baseAddress!, right: r.baseAddress!, frames: l.count)
            }
        }
        XCTAssertLessThanOrEqual(left.map(abs).max()!, 0.977)
        let settled = left[24000...]
        let harmonic = amplitude(settled, frequency: 3000) / amplitude(settled, frequency: 1000)
        print("Lookahead limiter +6 dB sine: third harmonic = \(harmonic * 100)%")
        XCTAssertLessThan(harmonic, 0.003, "A lookahead gain curve does not clip the waveform")
        for (l, r) in zip(left[24000...], right[24000...]) { XCTAssertEqual(r, l * 0.5, accuracy: 0.00001) }
    }

    func testVolumeOverdriveReaches400PercentAndLimitsPeaks() {
        func overdriven(_ amplitude: Float, multiplier: Float) -> [Float] {
            let stage = AudioVolumeOverdrive(sampleRate: 48000, chunk: 512)
            var left = sine(500, amplitude: amplitude, frames: 48000), right = left
            var offset = 0
            while offset < left.count {
                let count = min(512, left.count - offset)
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        stage.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: count, multiplier: multiplier)
                    }
                }
                offset += count
            }
            return left
        }
        let quiet = overdriven(0.1, multiplier: 4)
        XCTAssertEqual(Double(quiet[24000...].map(abs).max()!), 0.4, accuracy: 0.01, "400 % is four times the amplitude")
        let hot = overdriven(0.5, multiplier: 4)
        XCTAssertLessThanOrEqual(hot.map(abs).max()!, 0.995, "Overdriven peaks are limited, not clipped")
        let unity = overdriven(0.5, multiplier: 1)
        XCTAssertEqual(unity, sine(500, amplitude: 0.5, frames: 48000), "100 % is an exact bypass")
    }

    func testStoredVolumeAbove100PercentMigratesToVolumeOverdrive() {
        let defaults = UserDefaults(suiteName: "aom.test.overdrive.\(UUID().uuidString)")!
        defaults.set(1.5, forKey: "AOMAudioGain_test.app")
        defaults.set(0.4, forKey: "AOMAudioGain_test.quiet")
        AppAudioPreferences.migrateToSoundSourceModel(defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: "AOMAudioGain_test.app"), 1)
        XCTAssertEqual(AppAudioPreferences.overdrive(bundleID: "test.app", defaults: defaults), 1.5)
        XCTAssertEqual(defaults.double(forKey: "AOMAudioGain_test.quiet"), 0.4, accuracy: 0.0001)
        XCTAssertEqual(AppAudioPreferences.overdrive(bundleID: "test.quiet", defaults: defaults), 1)
        XCTAssertTrue(AppAudioPreferences.setGain(1.8, bundleID: "test.auto", defaults: defaults))
        XCTAssertEqual(defaults.double(forKey: "AOMAudioGain_test.auto"), 1)
        XCTAssertEqual(AppAudioPreferences.overdrive(bundleID: "test.auto", defaults: defaults), 1.8, accuracy: 0.0001)
    }

    /// The production mix path (bus → AirPlayMixThread → bridge) with one
    /// constant source; nothing is played.
    private static func startMixClock() -> (AirPlayMixThread, AirPlayPCMBridge) {
        let bus = AppAudioRenderBus()
        bus.add(id: UUID()) { frames, output in
            let data = UnsafeMutableAudioBufferListPointer(output)[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<(frames * 2) { data[i] = 0.1 }
        }
        let bridge = AirPlayPCMBridge()
        bridge.configure(outputRate: 48000, deviceFrames: 128)
        let thread = AirPlayMixThread(bus: bus, bridge: bridge)
        thread.start()
        return (thread, bridge)
    }

    private static func describe(_ report: AirPlayMixTimeline.Report, _ thread: AirPlayMixThread) -> String {
        func ms(_ value: UInt64?) -> String { value.map { String(format: "%.2f ms", Double($0) / 1e6) } ?? "n/a" }
        let scheduling = report.scheduling.map {
            "\($0.realtime ? "realtime" : "timeshare") priority \($0.priority) (host maximum \($0.maximumPriority))"
        } ?? "unknown"
        let origin = Double(report.startRequestedAt ?? 0)
        let wakes = report.wakes.prefix(12).map {
            String(format: "+%.1f late %.1f rendered %d burst %.2f lag %.1f", (Double($0.at) - origin) / 1e6,
                   Double($0.late) / 1e6, $0.rendered, Double($0.burst) / 1e6, Double($0.lagAfter) / 1e6)
        }
        return "start→thread \(ms(report.threadStart)), start→first block \(ms(report.firstMix)); promotion " +
            "\(thread.isRealtime ? "accepted" : "refused"), scheduler: \(scheduling); \(report.wakes.count) wake-ups, " +
            "\(report.lateWakes) > 20 ms late, \(report.budgetLimitedWakes) budget-limited, max delay " +
            "\(ms(thread.maximumMixDelay.load())), realigns \(thread.delayedMixResets.load()). First wake-ups, ms after start(): " +
            wakes.joined(separator: "; ")
    }

    /// The original check, thresholds unchanged: in 0.5 s a realtime mix
    /// clock delivers more than 0.4 s and less than 0.7 s of audio without
    /// realigning.
    ///
    /// Audit F12: it failed 4/4 in the audit (13,920–15,840 frames). The
    /// mix thread's own scheduler reading showed why: the test process ran
    /// under a background clamp, the promotion was accepted but the thread
    /// ran timeshare at priority 4, and every wake-up came ~120–200 ms late
    /// (work/audit-20261028/s3). With wake-ups that coarse no clock can be
    /// sampled at an arbitrary 0.5 s instant — the thread is simply not
    /// allowed to run in between — so this check applies only while the
    /// scheduler really runs the thread realtime, as it does in the app (its
    /// mix thread shows 97R). Otherwise it is skipped with that reading, never
    /// passed; `testAirPlayMixClockSustains48kHzAfterWarmUp` then still
    /// checks the supply.
    func testRealtimeAirPlayMixClockKeepsTheBridgeFed() throws {
        // Whether the host clamps this process at all, read on this ordinary
        // thread, so the decision does not depend on the mix code: a refused
        // or broken promotion fails below instead of being skipped.
        let host = AirPlayMixScheduling.current()
        let (thread, bridge) = Self.startMixClock()
        Thread.sleep(forTimeInterval: 0.5)
        thread.stop()
        let report = thread.timeline.report()
        let captured = bridge.statistics["capturedFrames"] as? UInt64 ?? 0
        print("Realtime mix thread: \(captured) frames in 0.5 s; \(Self.describe(report, thread))")
        if let host, host.hostClamped {
            throw XCTSkip("The host clamps this test process: an ordinary thread may run at most at priority " +
                          "\(host.maximumPriority), and the mix thread ran " +
                          "\(report.scheduling.map { "\($0.realtime ? "realtime" : "timeshare") at priority \($0.priority)" } ?? "unread") " +
                          "with \(report.lateWakes) of \(report.wakes.count) wake-ups > 20 ms late. A 0.5 s instant says nothing " +
                          "about the clock there, and a 150 ms bridge would run dry between such wake-ups. Run under the " +
                          "application policy (`taskpolicy -a swift test`) for this check; " +
                          "testAirPlayMixClockSustains48kHzAfterWarmUp still checks the clock's long-run rate here.")
        }
        XCTAssertTrue(thread.isRealtime, "The realtime promotion is accepted")
        XCTAssertEqual(report.scheduling?.realtime, true, "The scheduler runs the mix thread realtime")
        XCTAssertFalse(report.wakes.contains { !$0.realtime }, "At every wake-up")
        XCTAssertGreaterThan(captured, 19_200, "At least 0.4 s of audio must be produced in 0.5 s")
        XCTAssertLessThan(captured, 33_600, "The clock does not run ahead of real time")
        XCTAssertEqual(thread.delayedMixResets.load(), 0)
        XCTAssertLessThan(thread.maximumMixDelay.load(), 20_000_000,
                          "No wake-up is more than 20 ms late, far inside the bridge's 150 ms")
    }

    /// Audit F12, start-up and sustained supply told apart from the mix
    /// thread's own timeline, in any environment. Start-up: the first block
    /// within 250 ms of `start()`. Steady state (after a 250 ms warm-up, at
    /// least 1 s): 48,000 frames/s ±5 %, every wake-up leaves the clock caught
    /// up (≤ 20 ms behind), never ahead of real time, no realign. Where the
    /// host demotes the thread and delays its wake-ups this holds only
    /// because a demoted thread is not time-budgeted (AirPlayMixSchedule).
    func testAirPlayMixClockSustains48kHzAfterWarmUp() {
        let hostClamped = AirPlayMixScheduling.current()?.hostClamped ?? false
        let (thread, _) = Self.startMixClock()
        let deadline = AirPlayMixTimeline.now() + 8_000_000_000
        while AirPlayMixTimeline.now() < deadline {
            let report = thread.timeline.report()
            if let first = report.firstMixAt, let last = report.wakes.last, last.end >= first + 2_000_000_000 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        thread.stop()
        let report = thread.timeline.report()
        let rate = report.sustainedRate(warmUp: 250_000_000)
        print("Mix clock supply: \(rate.map { String(format: "%.0f frames/s over %.2f s (%d wake-ups), worst lag after a wake-up %.1f ms", $0.framesPerSecond, Double($0.span) / 1e9, $0.wakes, Double($0.worstLagAfterWake) / 1e6) } ?? "n/a"); \(Self.describe(report, thread))")
        XCTAssertLessThan(report.firstMix ?? .max, 250_000_000, "Start-up: the first block is mixed within 250 ms")
        guard let rate, let origin = report.firstMixAt else { return XCTFail("No steady-state interval was recorded") }
        XCTAssertGreaterThanOrEqual(rate.span, 1_000_000_000, "At least 1 s of steady state is measured")
        XCTAssertEqual(rate.framesPerSecond, 48_000, accuracy: 2_400, "Steady-state supply is 48,000 frames/s ±5 %")
        XCTAssertLessThanOrEqual(rate.worstLagAfterWake, 20_000_000, "Every wake-up catches the clock up")
        for wake in report.wakes {
            let allowed = (wake.end &- origin) / AirPlayMixThread.periodNanoseconds + 2
            XCTAssertLessThanOrEqual(wake.totalBlocks, allowed, "Never ahead of real time")
        }
        XCTAssertEqual(thread.delayedMixResets.load(), 0)
        // The rate is judged at burst ends. Between wake-ups the bridge only
        // stays fed if they are well inside its 150 ms; that holds wherever
        // the host does not clamp the process (the app's case).
        if !hostClamped {
            XCTAssertLessThan(thread.maximumMixDelay.load(), 20_000_000, "No wake-up is more than 20 ms late")
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