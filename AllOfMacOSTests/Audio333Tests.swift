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
}
