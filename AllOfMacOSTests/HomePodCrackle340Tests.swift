import CoreAudio
import XCTest
@testable import AllOfMacOS

/// 3.4.0 (HomePod crackle): a dropout inside an app's own audio (its IO
/// missed a cycle, so the tap delivers exact zeros) becomes a short dip
/// instead of a click, and the realtime buffers stay resident. Synthetic
/// signals only; nothing touches an audio device.
final class HomePodCrackle340Tests: XCTestCase {
    private let rate = 48000.0

    /// A 1 kHz sine (both channels), `frames` long from frame `start`.
    private func sine(_ frames: Int, start: Int = 0, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * 1000 * Double(start + $0) / rate)) }
    }

    /// Preserve streaming state across arbitrary capture packet boundaries,
    /// then drain just the fixed lookahead. No real audio device is touched.
    private func shape(_ input: [Float], packet: Int = 128, rate: Double = 48000,
                       shapesUnverifiedHoles: Bool = true) -> (out: [Float], count: UInt64) {
        let softener = AudioDropoutSoftener(shapesUnverifiedHoles: shapesUnverifiedHoles)
        let work = UnsafeMutablePointer<Float>.allocate(capacity: packet * 2)
        defer { work.deallocate() }
        let delay = Int(rate * AudioDropoutSoftener.fadeSeconds) + AudioDropoutSoftener.minimumRun
        var output: [Float] = []
        var offset = 0
        while offset < input.count + delay {
            let count = min(packet, input.count + delay - offset)
            softener.process(frames: count, sampleRate: rate, output: work) { index in
                let frame = offset + index
                let value: Float = frame < input.count ? input[frame] : 0
                return (value, value)
            }
            output += (0..<count).map { work[$0 * 2] }
            offset += count
        }
        return (Array(output.dropFirst(delay)), softener.softened)
    }

    private func largestStep(_ samples: [Float]) -> Float {
        zip(samples.dropFirst(), samples).map { abs($0 - $1) }.max() ?? 0
    }

    func testDropoutAtEveryCallbackOffsetHasTwoSoftEdges() {
        // Previously an exact callback boundary, or fewer than 32 zeros at
        // the end of a callback, left a full-scale falling step.
        for offset in 0..<128 {
            var input = [Float](repeating: 0.5, count: 2048)
            let start = 512 + offset
            for index in start..<(start + 128) { input[index] = 0 }
            let result = shape(input)
            XCTAssertEqual(result.count, 1, "offset \(offset)")
            XCTAssertLessThan(largestStep(Array(result.out[256..<1536])), 0.01, "offset \(offset)")
            XCTAssertEqual(result.out[start - 97], 0.5)
            XCTAssertEqual(result.out[start + 128 + 96], 0.5)
        }
    }

    func testPacketSizeDoesNotChangeAudio() {
        var input = sine(8192, start: 12)
        for hole in [127..<255, 1020..<1148, 1536..<1664, 1710..<1838, 4096..<4224] {
            for frame in hole { input[frame] = 0 }
        }
        let reference = shape(input, packet: 8192)
        XCTAssertLessThan(largestStep(reference.out), 0.08)
        for packet in [1, 17, 64, 128, 240, 480, 1024] {
            let result = shape(input, packet: packet)
            XCTAssertEqual(result.out, reference.out, "packet \(packet)")
            XCTAssertEqual(result.count, reference.count)
        }
    }

    func testAudioWithoutAHoleIsBitExactAfterTheFixedDelay() {
        let input = sine(4096, start: 12)
        let result = shape(input)
        // The artificial end of the test is itself a pause: exclude its fade.
        XCTAssertEqual(Array(result.out.dropLast(96)), Array(input.dropLast(96)))
        XCTAssertEqual(result.count, 0)
    }

    func testShortZeroRunsAndQuietAudioAreNotMistakenForDropouts() {
        var input = sine(2048, start: 12)
        for frame in 396..<404 { input[frame] = 0 }
        let short = shape(input)
        XCTAssertEqual(Array(short.out.dropLast(96)), Array(input.dropLast(96)))
        XCTAssertEqual(short.count, 0)
        var quiet = sine(2048, amplitude: 0.0005)
        for frame in 512..<640 { quiet[frame] = 0 }
        XCTAssertEqual(shape(quiet).out, quiet)
    }

    func testNaturalSpeechPauseAndMusicalDecayAreNotMistakenForDropouts() {
        // Natural speech pauses or decaying instruments taper smoothly to zero
        // and rise smoothly from zero. They lack the step discontinuity of a
        // hard IO dropout and must not trigger false fade shaping.
        var input: [Float] = []
        // Fade out smoothly over 128 frames below discontinuityThreshold (0.02)
        for i in 0..<128 {
            let gain = Float(127 - i) / 127.0 * 0.015
            input.append(gain)
        }
        // Silence for 256 frames (exceeding minimumRun of 32)
        input += [Float](repeating: 0, count: 256)
        // Fade in smoothly over 128 frames below discontinuityThreshold (0.02)
        for i in 0..<128 {
            let gain = Float(i) / 127.0 * 0.015
            input.append(gain)
        }
        input += [Float](repeating: 0.1, count: 512)
        let result = shape(input)
        XCTAssertEqual(result.count, 0, "smoothly tapered silence must never count as a dropout")
    }

    func testLongPauseFadesOutButLeavesTheNextSoundAlone() {
        let input = [Float](repeating: 0.5, count: 512)
            + [Float](repeating: 0, count: 6000)
            + [Float](repeating: 0.5, count: 512)
        let result = shape(input)
        XCTAssertLessThan(largestStep(Array(result.out[256..<1024])), 0.01)
        XCTAssertEqual(result.out[6512], 0.5)
        XCTAssertEqual(result.count, 0)
    }

    func testLookaheadScalesWithRateAndHandlesStereoIndependently() {
        for rate in [8000.0, 44100, 48000, 96000, 192000, 384000] {
            let softener = AudioDropoutSoftener(shapesUnverifiedHoles: true)
            let count = 4096
            let output = UnsafeMutablePointer<Float>.allocate(capacity: count * 2)
            defer { output.deallocate() }
            softener.process(frames: count, sampleRate: rate, output: output) { frame in
                (1024..<1152).contains(frame) ? (0, 0) : (0.5, -0.25)
            }
            let delay = Int(rate * 0.002) + 32
            XCTAssertEqual(softener.delayFrames, delay)
            XCTAssertEqual(softener.softened, 1)
            for frame in 0..<count {
                XCTAssertEqual(output[frame * 2 + 1], -output[frame * 2] / 2)
                if frame < delay { XCTAssertEqual(output[frame * 2], 0) }
            }
            let edge = (delay + 1024 - Int(rate * 0.002) - 1)..<(delay + 1152 + Int(rate * 0.002) + 1)
            XCTAssertLessThan(largestStep(edge.map { output[$0 * 2] }), 0.05)
        }
    }

    func testResetAndRateChangeNeverReplayDelayedAudio() {
        let softener = AudioDropoutSoftener()
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        defer { output.deallocate() }
        softener.process(frames: 1024, sampleRate: rate, output: output) { _ in (0.5, 0.5) }
        softener.reset()
        softener.process(frames: 1024, sampleRate: rate, output: output) { _ in (0, 0) }
        XCTAssertTrue((0..<2048).allSatisfy { output[$0] == 0 })
        softener.process(frames: 1024, sampleRate: rate, output: output) { _ in (0.5, 0.5) }
        softener.process(frames: 1024, sampleRate: 44100, output: output) { _ in (0, 0) }
        XCTAssertTrue((0..<2048).allSatisfy { output[$0] == 0 })
    }

    func testTransportProcessesHolesBeyondItsScratchLimitAndResetsOnRouteChange() {
        let transport = AppAudioTransport(sampleRate: rate, bufferedForAirPlay: true)
        var input = [Float](repeating: 0.5, count: 20000 * 2)
        for frame in 17000..<17128 { input[frame * 2] = 0; input[frame * 2 + 1] = 0 }
        func capture() {
            input.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                                           mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                transport.capture(&list)
            }
        }
        capture()
        // 3.4.8: the transport runs the default (production) softener, which
        // shapes only timestamp-confirmed gaps. An exact-zero run inside a
        // contiguous callback is content, so nothing is shaped and nothing is
        // counted; the large-callback accounting below is what this pins.
        XCTAssertEqual(transport.statistics["softenedDropouts"] as? UInt64, 0)
        XCTAssertEqual(transport.statistics["capturedFrames"] as? UInt64, 20000)
        XCTAssertEqual(transport.statistics["dropoutLookaheadFrames"] as? UInt64, 128)
        transport.setBufferedForAirPlay(false)
        capture()
        XCTAssertEqual(transport.statistics["softenedDropouts"] as? UInt64, 0)
        XCTAssertEqual(transport.statistics["dropoutLookaheadFrames"] as? UInt64, 0)
    }

    func testProductionSoftenerNeverShapesUnverifiedZeroRuns() {
        // 3.4.8: live 3.4.7 evidence showed 7,065 shappings in 19 minutes
        // (~6.1 Hz) while the capture timeline reported zero missing packets.
        // A hard 0.5 -> 0 step inside contiguous source audio is therefore not
        // proof of a missed IO cycle, and the production configuration must
        // leave it bit-exact behind the fixed lookahead delay.
        var hardStep = [Float](repeating: 0.5, count: 4096)
        for frame in 1024..<1152 { hardStep[frame] = 0 }
        let stepResult = shape(hardStep, shapesUnverifiedHoles: false)
        XCTAssertEqual(stepResult.count, 0)
        XCTAssertEqual(stepResult.out, hardStep)

        // Natural pauses, quiet passages and long rests likewise pass through.
        var quiet = sine(4096, amplitude: 0.0005)
        for frame in 512..<900 { quiet[frame] = 0 }
        XCTAssertEqual(shape(quiet, shapesUnverifiedHoles: false).out, quiet)

        var rest = [Float](repeating: 0.4, count: 1024)
            + [Float](repeating: 0, count: 3000)
            + [Float](repeating: 0.4, count: 1024)
        XCTAssertEqual(shape(rest, shapesUnverifiedHoles: false).out, rest)

        // Packet segmentation does not change that decision.
        for packet in [1, 17, 128, 1024] {
            XCTAssertEqual(shape(hardStep, packet: packet, shapesUnverifiedHoles: false).out, hardStep,
                           "packet \(packet)")
        }
    }

    func testProductionSoftenerStillShapesTimestampConfirmedGaps() {
        // The verified path (AppAudioTransport, capture timeline) keeps both
        // edges soft and counts one shaping per confirmed hole.
        let softener = AudioDropoutSoftener()
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        defer { buffer.deallocate() }
        var heard: [Float] = []
        func process(_ count: Int, _ value: Float) {
            softener.process(frames: count, sampleRate: rate, output: buffer) { _ in (value, value) }
            heard += (0..<count).map { buffer[$0 * 2] }
        }
        process(2048, 0.5)
        softener.fadeOutPendingAudio()
        process(128, 0)
        softener.fadeInNextAudio()
        process(2048, -0.5)
        XCTAssertEqual(softener.softened, 1)
        let jumps = zip(heard.dropFirst(1024), heard.dropFirst(1025)).map { abs($1 - $0) }
        XCTAssertLessThan(jumps.max() ?? 0, 0.02)
        XCTAssertEqual(heard.last, -0.5)
    }

    func testAQueueKeepsItsBuffersResidentAndReleasesThem() {
        _ = AudioSincKernel.shared
        let wiredBefore = AudioRealtimeMemory.wiredBytes
        let failuresBefore = AudioRealtimeMemory.failures
        var queue: StereoPCMQueue? = StereoPCMQueue(capacity: 8192)
        XCTAssertNotNil(queue)
        if AudioRealtimeMemory.failures == failuresBefore {
            // The ring alone: (capacity + mirror) stereo frames of Float.
            XCTAssertGreaterThanOrEqual(AudioRealtimeMemory.wiredBytes - wiredBefore, UInt64((8192 + 516) * 2 * 4))
        }
        queue = nil
        XCTAssertEqual(AudioRealtimeMemory.wiredBytes, wiredBefore, "a released queue unwires what it wired")
    }
}

/// Transport telemetry is sampled off the realtime audio callback.
final class AppAudioCrackleRecoveryTests: XCTestCase {
    func testNaturalSilenceAndIsolatedTransportGlitchesDoNotRestart() {
        var policy = AudioCrackleRecoveryPolicy()
        XCTAssertFalse(policy.observe(underruns: 0, trims: 0, captureGaps: 0, active: true))
        XCTAssertFalse(policy.observe(underruns: 1, trims: 0, captureGaps: 0, active: true))
        XCTAssertFalse(policy.observe(underruns: 1, trims: 0, captureGaps: 1, active: true))
        XCTAssertFalse(policy.observe(underruns: 4, trims: 0, captureGaps: 1, active: false))
        XCTAssertFalse(policy.observe(underruns: 4, trims: 0, captureGaps: 1, active: true))
    }

    func testRepeatedUnderrunsTriggerImmediateRecovery() {
        var policy = AudioCrackleRecoveryPolicy()
        XCTAssertFalse(policy.observe(underruns: 20, trims: 10, captureGaps: 0, active: true))
        XCTAssertTrue(policy.observe(underruns: 23, trims: 10, captureGaps: 0, active: true))
        XCTAssertFalse(policy.observe(underruns: 23, trims: 10, captureGaps: 0, active: true))
    }

    func testRepeatedTrimsAndConfirmedCaptureGapsTriggerRecovery() {
        var policy = AudioCrackleRecoveryPolicy()
        XCTAssertFalse(policy.observe(underruns: 0, trims: 0, captureGaps: 0, active: true))
        XCTAssertTrue(policy.observe(underruns: 0, trims: 2, captureGaps: 0, active: true))
        XCTAssertTrue(policy.observe(underruns: 0, trims: 2, captureGaps: 3, active: true))
        XCTAssertFalse(policy.observe(underruns: 0, trims: 0, captureGaps: 0, active: true))
    }
}
