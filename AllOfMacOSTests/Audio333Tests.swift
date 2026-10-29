import XCTest
import CoreAudio
@testable import AllOfMacOS

/// 3.3.3 audio work (audit A01–A03, parity S04/S06). Synthetic signals and
/// virtual clocks only: no audio hardware, no device setting is touched.
final class Audio333Tests: XCTestCase {
    // MARK: - Helpers

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Host ticks for a simulated time in seconds (never 0).
    private func ticks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1e9 * Double(Self.timebase.denom) / Double(Self.timebase.numer)) + 1000
    }

    private func render(_ bridge: AirPlayPCMBridge, frames: Int, sampleTime: Double, at seconds: Double) -> [Float] {
        var buffer = [Float](repeating: 0, count: frames * 2)
        buffer.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            withUnsafeMutablePointer(to: &list) {
                bridge.render(frames: frames, output: $0, sampleTime: sampleTime, hostTime: ticks(seconds))
            }
        }
        return buffer
    }

    /// Pushes `frames` of a sine (both channels) into the bridge, as the mix clock does.
    private func push(_ bridge: AirPlayPCMBridge, phase: inout Double, frames: Int, at seconds: Double,
                      frequency: Double = 1000, amplitude: Float = 0.5) {
        var block = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(phase))
            block[frame * 2] = value; block[frame * 2 + 1] = value
            phase += 2 * .pi * frequency / 48000
        }
        block.withUnsafeBufferPointer { bridge.push($0.baseAddress!, frames: frames, hostTime: ticks(seconds)) }
    }

    private func counter(_ statistics: [String: Any], _ key: String) -> UInt64 {
        statistics[key] as? UInt64 ?? 0
    }

    /// Deterministic jitter in 0..<1 (a small LCG; no randomness between runs).
    private struct Jitter {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    // MARK: - A01: 128-frame device cycles

    /// The HomePod keeps AOM at 128-frame IO (a cycle every 2.67 ms). The
    /// mix clock still pushes 480-frame blocks every 10 ms (with up to 1 ms
    /// of jitter). At the drift measured live (−418 ppm, audio-health.json of
    /// the installed 3.3.2) and at +300 ppm the bridge neither trims nor runs
    /// dry, holds its 150 ms target, and the drift loop settles on the drift
    /// without wobbling at the 128-frame rhythm.
    func testTheBridgeHoldsItsTargetAt128FrameCyclesWithDrift() {
        // (drift, push jitter, allowed spread of the correction over the last 10 s)
        for (ppm, jitterSeconds, allowedSpread) in [(-418.0, 0.0, 5.0), (300.0, 0.0, 5.0),
                                                   (-418.0, 0.001, 100.0), (300.0, 0.001, 100.0)] {
            let bridge = AirPlayPCMBridge()
            bridge.configure(outputRate: 48000, deviceFrames: 128)
            bridge.prime()
            var jitter = Jitter()
            var phase = 0.0, sampleTime = 0.0
            let cycleSeconds = 128.0 / 48000
            // Device seconds per 480-frame block: a faster mix clock (ppm > 0) pushes sooner.
            let blockSeconds = 0.01 / (1 + ppm / 1e6)
            var nextBlock = 0.0, blockIndex = 0.0, cycle = 0.0
            var late: [Double] = []
            while cycle * cycleSeconds < 36 {
                let now = cycle * cycleSeconds
                if nextBlock <= now {
                    push(bridge, phase: &phase, frames: 480, at: nextBlock)
                    blockIndex += 1
                    nextBlock = blockIndex * blockSeconds + jitter.next() * jitterSeconds
                    continue
                }
                _ = render(bridge, frames: 128, sampleTime: sampleTime, at: now)
                sampleTime += 128
                cycle += 1
                if now >= 26, Int(cycle) % 75 == 0 {
                    late.append(bridge.statistics["driftCorrectionPPM"] as? Double ?? .nan)
                }
            }
            let stats = bridge.statistics
            XCTAssertEqual(counter(stats, "underruns"), 0, "\(ppm) ppm: never dry")
            XCTAssertEqual(counter(stats, "trims"), 0, "\(ppm) ppm: never trimmed")
            XCTAssertEqual(counter(stats, "deviceCycleGaps"), 0)
            let queued = Double(counter(stats, "queuedFrames"))
            XCTAssertEqual(queued, 7200, accuracy: 900, "\(ppm) ppm: the level sits at the 150 ms target")
            let mean = late.reduce(0, +) / Double(max(1, late.count))
            let spread = (late.max() ?? 0) - (late.min() ?? 0)
            XCTAssertEqual(mean, ppm, accuracy: 40, "the loop follows the drift")
            // Without jitter nothing is left of the 480/128-frame sawtooth's
            // alias; with 1 ms of push jitter the correction moves by a few
            // tens of ppm at most (0.1 cent is 58 ppm).
            XCTAssertLessThan(spread, allowedSpread, "\(ppm) ppm, jitter \(jitterSeconds) s: no wobble")
            print("A01 drift \(ppm) ppm, jitter \(jitterSeconds * 1000) ms: correction \(String(format: "%.1f", mean)) ppm, spread "
                  + "\(String(format: "%.2f", spread)) ppm, level \(Int(queued)) frames")
        }
    }

    /// A gap in the device's sample time (the HAL skipped AOM's cycle) is a
    /// hole on the receiver. The bridge comes back from silence with a 5 ms
    /// fade instead of resuming mid-waveform, and skips nothing: after the
    /// fade its output is sample for sample the output of a bridge that saw
    /// no gap.
    func testAHALGapFadesBackInAndTheStreamContinues() {
        let gapped = AirPlayPCMBridge(), reference = AirPlayPCMBridge()
        for bridge in [gapped, reference] {
            bridge.configure(outputRate: 48000, deviceFrames: 128)
            bridge.prime()
        }
        var phaseA = 0.0, phaseB = 0.0, timeA = 0.0, timeB = 0.0
        var outA: [Float] = [], outB: [Float] = []
        let gapCycle = 120
        for cycle in 0..<200 {
            let now = Double(cycle) * 128 / 48000
            push(gapped, phase: &phaseA, frames: 128, at: now)
            push(reference, phase: &phaseB, frames: 128, at: now)
            if cycle == gapCycle { timeA += 256 } // the HAL skipped two cycles
            outA += render(gapped, frames: 128, sampleTime: timeA, at: now + 0.0001)
            outB += render(reference, frames: 128, sampleTime: timeB, at: now + 0.0001)
            timeA += 128; timeB += 128
        }
        let start = gapCycle * 128 * 2
        let fade = Int(48000 * AirPlayPCMBridge.gapFadeSeconds)
        XCTAssertEqual(Array(outA[..<start]), Array(outB[..<start]), "nothing changes before the gap")
        XCTAssertEqual(Array(outA[(start + fade * 2)...]), Array(outB[(start + fade * 2)...]),
                       "after the fade the stream is the same: nothing skipped or repeated")
        XCTAssertGreaterThan(outB[start..<(start + fade * 2)].map { abs($0) }.max() ?? 0, 0.4, "the sine plays there")
        XCTAssertLessThan(abs(outA[start]), 0.001, "back from silence, not mid-waveform")
        var gain: Float = 0
        for frame in 0..<fade {
            let a = outA[start + frame * 2], b = outB[start + frame * 2]
            XCTAssertLessThanOrEqual(abs(a), abs(b) + 1e-6)
            guard abs(b) > 0.05 else { continue }
            let now = a / b
            XCTAssertGreaterThanOrEqual(now, gain - 1e-4, "the gain only rises")
            gain = now
        }
        let stats = gapped.statistics
        XCTAssertEqual(counter(stats, "deviceCycleGaps"), 1)
        XCTAssertEqual(counter(stats, "deviceGapFrames"), 256)
        XCTAssertEqual(counter(stats, "gapFadeIns"), 1)
        XCTAssertEqual(counter(reference.statistics, "gapFadeIns"), 0)
    }

    /// The HAL callback's work is bounded whatever happens: per 128-frame
    /// cycle the kernel computes the cycle's frames, and on an event (start,
    /// trim crossfade, clear, underrun) at most one fade more. Times are
    /// measured and printed (debug build; the live HAL analytics on this Mac
    /// report AOM's client IO at 18–22 µs per cycle).
    func testTheBridgeCallbackDoesBoundedWorkAt128FrameCycles() {
        let bridge = AirPlayPCMBridge()
        bridge.configure(outputRate: 48000, deviceFrames: 128)
        bridge.prime()
        let fade = 240
        var phase = 0.0, time = 0.0
        var worst = 0
        var lastWork = counter(bridge.statistics, "resampledFrames")
        var durations: [Double] = []
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func cycle(push frames: Int, measure: Bool = false) {
            let now = time / 48000
            if frames > 0 { push(bridge, phase: &phase, frames: frames, at: now) }
            let begin = mach_absolute_time()
            _ = render(bridge, frames: 128, sampleTime: time, at: now + 0.0001)
            let elapsed = mach_absolute_time() - begin
            if measure { durations.append(Double(elapsed) * Double(timebase.numer) / Double(timebase.denom) / 1000) }
            time += 128
            let work = counter(bridge.statistics, "resampledFrames")
            worst = max(worst, Int(work - lastWork))
            lastWork = work
        }
        for _ in 0..<300 { cycle(push: 128) }                // start-up
        for _ in 0..<2000 { cycle(push: 128, measure: true) } // steady state
        cycle(push: 40000)                                     // a backlog: trim with a crossfade
        for _ in 0..<50 { cycle(push: 128) }
        bridge.discard()                                       // a clear: fade out, restart
        for _ in 0..<120 { cycle(push: 128) }
        for _ in 0..<200 { cycle(push: 0) }                    // run dry: an underrun
        for _ in 0..<120 { cycle(push: 128) }                  // and back
        let stats = bridge.statistics
        XCTAssertGreaterThanOrEqual(counter(stats, "trims"), 1)
        XCTAssertGreaterThanOrEqual(counter(stats, "clears"), 1)
        XCTAssertGreaterThanOrEqual(counter(stats, "underruns"), 1)
        XCTAssertLessThanOrEqual(worst, 128 + 2 * fade, "an event costs at most a fade more than a cycle")
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2], p99 = sorted[sorted.count * 99 / 100]
        let cycleMicros = 128.0 / 48000 * 1e6
        XCTAssertLessThan(median, cycleMicros / 2, "a debug build still uses well under half a cycle")
        let cost = bridge.renderCost
        print("A01 callback cost at 128 frames (debug build): median \(String(format: "%.1f", median)) µs, "
              + "p99 \(String(format: "%.1f", p99)) µs, worst event work \(worst) frames; bridge mean "
              + "\(String(format: "%.1f", cost.meanMicros)) µs, max \(String(format: "%.1f", cost.maximumMicros)) µs "
              + "of a \(String(format: "%.0f", cycleMicros)) µs cycle")
        XCTAssertGreaterThan(cost.callbacks, 2000)
        XCTAssertNotNil(stats["renderCycleLoadPercent"] as? Double)
    }

    // MARK: - A02: output moves

    private func capture(_ transport: AppAudioTransport, phase: inout Double, frames: Int, frequency: Double = 440) {
        var packet = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(0.5 * sin(phase))
            packet[frame * 2] = value; packet[frame * 2 + 1] = value
            phase += 2 * .pi * frequency / 48000
        }
        packet.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            withUnsafePointer(to: &list) { transport.capture($0) }
        }
    }

    private func pull(_ transport: AppAudioTransport, _ mixer: MixerBox, frames: Int, consumer: UInt64) -> [Float] {
        var output = [Float](repeating: 0, count: frames * 2)
        output.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            withUnsafeMutablePointer(to: &list) {
                transport.render(frames: frames, output: $0, mixer: mixer, allowWaiting: true, consumer: consumer)
            }
        }
        return output
    }

    private func pulled(_ transport: AppAudioTransport) -> UInt64 { transport.statistics["pulledFrames"] as? UInt64 ?? 0 }

    /// An app moves from output A (512-frame callbacks) to output B (480).
    /// Only one of them pulls at any time: A renders to the end of a 5 ms
    /// fade-out and stops, B continues with the next frame, fading in. A
    /// reference transport replays exactly the pulls that happened with one
    /// consumer: outside the two fades the moved stream is that stream sample
    /// for sample, so nothing was pulled twice, skipped or run through the
    /// DSP twice.
    func testAnOutputMoveHandsTheStreamOverWithoutPullingTwice() {
        let moved = AppAudioTransport(sampleRate: 48000), reference = AppAudioTransport(sampleRate: 48000)
        let movedMixer = MixerBox(gain: 1, muted: false), referenceMixer = MixerBox(gain: 1, muted: false)
        let a: UInt64 = 0, b = moved.makeConsumer()
        let fade = AppAudioTransport.handoverFadeFrames
        var phaseM = 0.0, phaseR = 0.0
        var nextCapture = 0.0, nextA = 0.3 * 512 / 48000, nextB = 0.7 * 480 / 48000
        var handoverRequested = false
        var pullers: [UInt64] = []
        var aLastPull: (out: [Float], ref: [Float], frames: Int)?
        var bFirstPull: (out: [Float], ref: [Float])?
        var exactMismatches = 0, silentCallsWithAudio = 0
        while min(nextCapture, nextA, nextB) < 2 {
            if nextCapture <= min(nextA, nextB) {
                capture(moved, phase: &phaseM, frames: 512)
                capture(reference, phase: &phaseR, frames: 512)
                nextCapture += 512.0 / 48000
                continue
            }
            let isA = nextA <= nextB
            let now = isA ? nextA : nextB
            if isA { nextA += 512.0 / 48000 } else { nextB += 480.0 / 48000 }
            if now >= 1, !handoverRequested { moved.beginHandover(to: b); handoverRequested = true }
            let consumer = isA ? a : b
            let before = pulled(moved)
            let out = pull(moved, movedMixer, frames: isA ? 512 : 480, consumer: consumer)
            let count = Int(pulled(moved) - before)
            guard count > 0 else {
                if out.contains(where: { $0 != 0 }) { silentCallsWithAudio += 1 }
                continue
            }
            let ref = pull(reference, referenceMixer, frames: count, consumer: 0)
            XCTAssertTrue(out[(count * 2)...].allSatisfy { $0 == 0 }, "nothing after what was pulled")
            pullers.append(consumer)
            if isA, count < 512 {
                aLastPull = (Array(out[..<(count * 2)]), ref, count)
            } else if !isA, bFirstPull == nil {
                bFirstPull = (Array(out[..<(count * 2)]), ref)
                if Array(out[(fade * 2)..<(count * 2)]) != Array(ref[(fade * 2)...]) { exactMismatches += 1 }
            } else if Array(out[..<(count * 2)]) != ref {
                exactMismatches += 1
            }
        }
        // One switch, A to B, never both.
        let switches = zip(pullers, pullers.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(switches, 1, "the stream has one owner at a time")
        XCTAssertEqual(pullers.first, a); XCTAssertEqual(pullers.last, b)
        XCTAssertEqual(silentCallsWithAudio, 0, "a consumer that does not pull is silent")
        XCTAssertEqual(exactMismatches, 0, "outside the fades the stream is the single-consumer stream")
        XCTAssertEqual(pulled(moved), pulled(reference), "nothing was pulled twice")
        let state = moved.handoverState
        XCTAssertEqual(state.owner, b); XCTAssertEqual(state.pending, 0)
        XCTAssertEqual(state.completed, 1); XCTAssertEqual(state.takeovers, 0)
        // A's last pull is exactly its fade-out; B's first one fades in.
        guard let last = aLastPull, let first = bFirstPull else { return XCTFail("no hand-over happened") }
        XCTAssertEqual(last.frames, fade)
        var gain: Float = 1
        for frame in 0..<fade {
            let out = last.out[frame * 2], ref = last.ref[frame * 2]
            XCTAssertLessThanOrEqual(abs(out), abs(ref) + 1e-6)
            if abs(ref) > 0.05 { XCTAssertLessThanOrEqual(out / ref, gain + 1e-4); gain = out / ref }
        }
        XCTAssertLessThan(abs(last.out[(fade - 1) * 2]), 0.001, "A ends in silence")
        XCTAssertLessThan(abs(first.out[0]), 0.001, "B starts from silence")
        gain = 0
        for frame in 0..<fade {
            let out = first.out[frame * 2], ref = first.ref[frame * 2]
            XCTAssertLessThanOrEqual(abs(out), abs(ref) + 1e-6)
            if abs(ref) > 0.05 { XCTAssertGreaterThanOrEqual(out / ref, gain - 1e-4); gain = out / ref }
        }
        // And A, still called by its bus for a moment, stays silent.
        let after = pulled(moved)
        XCTAssertTrue(pull(moved, movedMixer, frames: 512, consumer: a).allSatisfy { $0 == 0 })
        XCTAssertEqual(pulled(moved), after)
    }

    /// The old output stopped rendering (its device went away): the new one
    /// does not wait for a fade-out that cannot come. Within the timeout it
    /// stays silent and pulls nothing; then it takes over, from silence.
    func testAMoveAwayFromAStoppedOutputTakesOverAfterTheTimeout() {
        let transport = AppAudioTransport(sampleRate: 48000)
        let mixer = MixerBox(gain: 1, muted: false)
        var phase = 0.0
        for _ in 0..<60 {
            capture(transport, phase: &phase, frames: 512)
            _ = pull(transport, mixer, frames: 512, consumer: 0)
        }
        let b = transport.makeConsumer()
        transport.beginHandover(to: b)
        capture(transport, phase: &phase, frames: 512)
        let before = pulled(transport)
        XCTAssertTrue(pull(transport, mixer, frames: 480, consumer: b).allSatisfy { $0 == 0 }, "A may still fade out")
        XCTAssertEqual(pulled(transport), before)
        usleep(UInt32(AppAudioTransport.handoverTimeout * 1_000_000) + 30_000)
        capture(transport, phase: &phase, frames: 512)
        let out = pull(transport, mixer, frames: 480, consumer: b)
        XCTAssertEqual(pulled(transport), before + 480, "B took over")
        XCTAssertLessThan(abs(out[0]), 0.001, "from silence")
        XCTAssertGreaterThan(out[(300 * 2)...].map { abs($0) }.max() ?? 0, 0.3, "and plays the stream")
        let state = transport.handoverState
        XCTAssertEqual(state.owner, b); XCTAssertEqual(state.takeovers, 1); XCTAssertEqual(state.completed, 0)
        XCTAssertTrue(pull(transport, mixer, frames: 512, consumer: 0).allSatisfy { $0 == 0 }, "A, back late, is silent")
        XCTAssertEqual(pulled(transport), before + 480)
    }
}
