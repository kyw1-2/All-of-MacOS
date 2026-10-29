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

    // MARK: - A03: event log

    /// A producer thread pushes as fast as it can while a reader drains:
    /// every record read is whole (its fields belong together) and in order,
    /// and read + lost accounts for every push.
    func testTheEventRingHandsOverWholeRecordsWithoutLocks() {
        let ring = AudioEventRing(capacity: 64)
        let total: UInt64 = 200_000
        let producer = Thread {
            for index in 0..<total { ring.push(.cycleGap, value: index, extra: index &* 3, host: index + 1) }
        }
        producer.start()
        var cursor: UInt64 = 0, read: UInt64 = 0, lost: UInt64 = 0, last: UInt64?
        var torn = 0, disordered = 0
        while cursor < total {
            let result = ring.read(from: &cursor)
            lost += result.lost
            for record in result.records {
                read += 1
                if record.extra != record.value &* 3 || record.host != record.value + 1
                    || record.kind != AudioEventKind.cycleGap.rawValue { torn += 1 }
                if let last, record.value <= last { disordered += 1 }
                last = record.value
            }
        }
        XCTAssertEqual(torn, 0, "no record mixes two pushes")
        XCTAssertEqual(disordered, 0)
        XCTAssertEqual(read + lost, total, "everything is read or counted as lost")
        XCTAssertGreaterThan(read, 0)
    }

    func testTheEventLogKeepsTheLast200EventsWithWallClockTimes() {
        let log = AudioEventLog(polls: false)
        for index in 0..<250 { log.record(.tapRewrite, source: "app:test", value: Int64(index), detail: "\(index)") }
        var events = log.snapshot().events
        XCTAssertEqual(events.count, AudioEventLog.capacity)
        XCTAssertEqual(events.first?.detail, "50", "the oldest kept is the 51st")
        XCTAssertEqual(events.last?.detail, "249")
        XCTAssertEqual(events.map(\.value), (50..<250).map(Int64.init), "oldest first")
        // A realtime record keeps the time it happened, not the time it was read.
        let ring = AudioEventRing()
        log.register(name: "output:test", rings: [ring])
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let halfSecond = UInt64(0.5e9 * Double(timebase.denom) / Double(timebase.numer))
        ring.push(.cycleGap, value: 256, extra: 4096, host: mach_absolute_time() - halfSecond)
        log.poll()
        events = log.snapshot().events
        guard let gap = events.last else { return XCTFail("no event") }
        XCTAssertEqual(gap.kind, .cycleGap)
        XCTAssertEqual(gap.source, "output:test")
        XCTAssertEqual(gap.value, 256)
        XCTAssertEqual(gap.time.timeIntervalSinceNow, -0.5, accuracy: 0.15)
        XCTAssertEqual(gap.json["frames"] as? Int64, 256)
        XCTAssertNotNil((gap.json["time"] as? String)?.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}"#,
                                                              options: .regularExpression))
    }

    /// Counters outlive the outputs and sessions that produced them, and the
    /// "since last reset" snapshot starts again at a reset.
    func testSinceResetCountersSurviveTheOutputsThatProducedThem() {
        let log = AudioEventLog(polls: false)
        var first: UInt64 = 3
        let a = log.register(name: "output:a", rings: []) { ["output.underruns": first] }
        log.poll()
        first = 5
        log.unregister(a) // its last count is taken on the way out
        XCTAssertEqual(log.snapshot().sinceReset["output.underruns"], 5)
        var second: UInt64 = 2
        log.register(name: "output:b", rings: []) { ["output.underruns": second] }
        log.poll()
        XCTAssertEqual(log.snapshot().sinceReset["output.underruns"], 7, "a recreated output adds, it does not reset")
        log.resetCounters()
        XCTAssertNil(log.snapshot().sinceReset["output.underruns"])
        second = 4
        log.poll()
        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.sinceReset["output.underruns"], 2)
        XCTAssertEqual(snapshot.events.last?.kind, .countersReset)
        XCTAssertLessThan(abs(snapshot.resetAt.timeIntervalSinceNow), 2)
    }

    /// The realtime producers' events reach the log with their sources: a
    /// HAL gap (bridge), an output hand-over (transport), and one limiter
    /// engagement for a loud passage, released 2 s after it ended.
    func testRealtimeEventsReachTheLog() {
        let log = AudioEventLog(polls: false)
        let bridge = AirPlayPCMBridge()
        bridge.configure(outputRate: 48000, deviceFrames: 128)
        bridge.prime()
        log.register(name: "output:homepod", rings: [bridge.events]) { bridge.eventCounters }
        var phase = 0.0
        for (index, time) in [0.0, 128, 512, 640].enumerated() {
            push(bridge, phase: &phase, frames: 128, at: Double(index) * 0.003)
            _ = render(bridge, frames: 128, sampleTime: time, at: Double(index) * 0.003 + 0.0001)
        }
        let transport = AppAudioTransport(sampleRate: 48000)
        let mixer = MixerBox(gain: 1, muted: false)
        log.register(name: "app:test", rings: [transport.events]) { transport.eventCounters }
        for _ in 0..<20 {
            capture(transport, phase: &phase, frames: 512)
            _ = pull(transport, mixer, frames: 512, consumer: 0)
        }
        let next = transport.makeConsumer()
        transport.beginHandover(to: next)
        capture(transport, phase: &phase, frames: 512)
        _ = pull(transport, mixer, frames: 512, consumer: 0)
        let bus = AppAudioRenderBus()
        log.register(name: "output:speakers", rings: [bus.events]) { ["output.limiterEngagements": bus.limiterEngagements.load()] }
        var loud = true
        var sample = 0
        bus.add(id: UUID()) { frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<frames {
                let value: Float = loud ? Float(1.6 * sin(2 * Double.pi * 200 * Double(sample) / 48000)) : 0
                data[frame * 2] = value; data[frame * 2 + 1] = value
                sample += 1
            }
        }
        var output = [Float](repeating: 0, count: 1024)
        func renderBus(seconds: Double) {
            for _ in 0..<Int(seconds * 48000 / 512) {
                output.withUnsafeMutableBufferPointer { pointer in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                    withUnsafeMutablePointer(to: &list) { bus.render(frames: 512, output: $0, allowWaiting: true) }
                }
            }
        }
        renderBus(seconds: 1)
        loud = false
        renderBus(seconds: 2.5)
        log.poll()
        let snapshot = log.snapshot()
        let kinds = snapshot.events.map { "\($0.source) \($0.kind.name)" }
        XCTAssertTrue(kinds.contains("output:homepod cycleGap"), "\(kinds)")
        XCTAssertEqual(snapshot.events.first { $0.kind == .cycleGap }?.value, 256)
        XCTAssertTrue(kinds.contains("app:test handover"), "\(kinds)")
        XCTAssertEqual(kinds.filter { $0 == "output:speakers limiterEngaged" }.count, 1, "one loud passage, one engagement")
        XCTAssertEqual(kinds.filter { $0 == "output:speakers limiterReleased" }.count, 1)
        let released = snapshot.events.first { $0.kind == .limiterReleased }
        XCTAssertGreaterThan(released?.value ?? 0, 300, "about 4 dB of reduction for a sine 4 dB over the ceiling")
        XCTAssertEqual(snapshot.sinceReset["output.deviceCycleGaps"], 1)
        XCTAssertEqual(snapshot.sinceReset["output.limiterEngagements"], 1)
        XCTAssertEqual(snapshot.sinceReset["app.handovers"], 1)
    }

    func testTheDiagnosticsFileCarriesEventsAndSinceResetCounters() throws {
        let log = AudioEventLog(polls: false)
        log.record(.outputStarted, source: "output:test", value: 128, detail: "AirPlay 48000 Hz, 128-frame IO")
        log.register(name: "output:test", rings: []) { ["output.deviceCycleGaps": 2] }
        log.poll()
        let payload = AudioDiagnostics.payload(captures: [:], outputs: ["test": ["deviceCycleGaps": UInt64(2)]], log: log)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(decoded["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["kind"] as? String, "outputStarted")
        XCTAssertEqual(events.first?["detail"] as? String, "AirPlay 48000 Hz, 128-frame IO")
        let since = try XCTUnwrap(decoded["sinceReset"] as? [String: Any])
        XCTAssertNotNil(since["resetAt"] as? String)
        XCTAssertEqual((since["counters"] as? [String: Any])?["output.deviceCycleGaps"] as? Int, 2)
    }

    // MARK: - S06: Magic Boost presets

    /// The 3.3.2 Magic Boost, copied from the shipped code: what the Music
    /// preset must still produce sample for sample.
    private final class ReferenceBoost {
        let rateScale: Float, fadeStep: Float
        var delay = [Float](repeating: 0, count: 1024)
        var writeIndex = 0, filled = 0
        var gain: Float = 1, knee: Float = 1, mix: Float = 0
        init(sampleRate: Double) {
            rateScale = Float(44100 / sampleRate)
            fadeStep = Float(1 / (0.04 * sampleRate))
        }
        func process(_ left: inout [Float], _ right: inout [Float], frames: Int, enabled: Bool) {
            if !enabled && mix == 0 { if filled > 0 { reset() }; return }
            var silent = true
            for frame in 0..<frames where left[frame] != 0 || right[frame] != 0 { silent = false; break }
            let release = AudioMagicBoost.releaseRate * rateScale * (silent ? 0.01 : 1)
            let attack = AudioMagicBoost.attackRate * rateScale
            for frame in 0..<frames {
                let inputLeft = left[frame].isFinite ? left[frame] : 0
                let inputRight = right[frame].isFinite ? right[frame] : 0
                let slot = writeIndex * 2
                let delayedLeft = delay[slot], delayedRight = delay[slot + 1]
                delay[slot] = inputLeft; delay[slot + 1] = inputRight
                writeIndex += 1
                if writeIndex == 512 { writeIndex = 0 }
                if filled < 512 { filled += 1 }
                detect(inputLeft, attack, release); detect(inputRight, attack, release)
                if enabled {
                    if filled >= 512 && mix < 1 { mix = min(1, mix + fadeStep) }
                } else {
                    mix = max(0, mix - fadeStep)
                }
                let wet = AudioMagicBoost.outputGain(gain)
                left[frame] = inputLeft + (delayedLeft * wet - inputLeft) * mix
                right[frame] = inputRight + (delayedRight * wet - inputRight) * mix
            }
            if !enabled && mix == 0 { reset() }
        }
        private func detect(_ sample: Float, _ attack: Float, _ release: Float) {
            guard sample != 0 else { return }
            if abs(sample * gain) > AudioMagicBoost.threshold {
                gain = max(0.0001, gain - max(gain, 1) * attack)
                if knee > 1 { knee = max(1, knee - AudioMagicBoost.kneeAttackDrop) }
            } else {
                let next = gain + release * knee
                if next < AudioMagicBoost.maximumGain { gain = next }
                if knee < AudioMagicBoost.kneeCeiling { knee += AudioMagicBoost.kneeStep }
            }
        }
        private func reset() {
            delay = [Float](repeating: 0, count: 1024); writeIndex = 0; filled = 0; gain = 1; knee = 1; mix = 0
        }
    }

    private func sine(_ amplitude: Float, seconds: Double, frequency: Double = 220, phase: inout Double) -> [Float] {
        (0..<Int(seconds * 48000)).map { _ in
            defer { phase += 2 * .pi * frequency / 48000 }
            return amplitude * Float(sin(phase))
        }
    }

    /// Mono signal through a boost in 512-frame blocks; `switchAt` (frames)
    /// applies `preset` from that block on.
    private func boosted(_ signal: [Float], _ boost: AudioMagicBoost, enabledUntil: Int = .max,
                         switchAt: Int = .max, preset: Int = 0) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(signal.count)
        var left = [Float](repeating: 0, count: 512), right = left
        var index = 0
        while index < signal.count {
            let count = min(512, signal.count - index)
            if index >= switchAt { boost.setPreset(index: preset) }
            for frame in 0..<count { left[frame] = signal[index + frame]; right[frame] = signal[index + frame] }
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    boost.process(left: l.baseAddress!, right: r.baseAddress!, frames: count, enabled: index < enabledUntil)
                }
            }
            output += left[..<count]
            index += count
        }
        return output
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }

    func testMusicIsTheShippedMagicBoostSampleForSample() {
        var phase = 0.0
        let signal = sine(0.05, seconds: 1.5, phase: &phase) + sine(1.2, seconds: 0.5, phase: &phase)
            + [Float](repeating: 0, count: 9600) + sine(0.2, seconds: 1, phase: &phase)
        let enabledUntil = signal.count - 24000
        let current = AudioMagicBoost(sampleRate: 48000)
        let explicit = AudioMagicBoost(sampleRate: 48000)
        explicit.setPreset(index: AudioBoostPreset.index(of: "night"))
        explicit.setPreset(index: AudioBoostPreset.index(of: "music")) // before any audio: Music again
        let reference = ReferenceBoost(sampleRate: 48000)
        let a = boosted(signal, current, enabledUntil: enabledUntil)
        let b = boosted(signal, explicit, enabledUntil: enabledUntil)
        var expected: [Float] = []
        var left = [Float](repeating: 0, count: 512), right = left
        var index = 0
        while index < signal.count {
            let count = min(512, signal.count - index)
            for frame in 0..<count { left[frame] = signal[index + frame]; right[frame] = signal[index + frame] }
            reference.process(&left, &right, frames: count, enabled: index < enabledUntil)
            expected += left[..<count]
            index += count
        }
        XCTAssertEqual(a, expected, "the default is the 3.3.2 boost")
        XCTAssertEqual(b, expected, "and so is Music chosen explicitly")
        XCTAssertEqual(AudioBoostPreset.defaultID, "music")
        XCTAssertEqual(AudioBoostPreset.all.map(\.name), ["Music", "Speech", "Movie", "Night"])
    }

    /// Night holds loud audio lower and keeps quiet audio up: a smaller
    /// dynamic range than Music. Speech brings a quiet voice up sooner.
    func testNightNarrowsTheRangeAndSpeechLiftsAQuietVoiceSooner() {
        var phase = 0.0
        let loud = sine(0.9, seconds: 2, phase: &phase), quiet = sine(0.05, seconds: 3, phase: &phase)
        func levels(_ id: String) -> (loud: Float, quiet: Float) {
            let boost = AudioMagicBoost(sampleRate: 48000)
            boost.setPreset(index: AudioBoostPreset.index(of: id))
            let output = boosted(loud + quiet, boost)
            return (rms(output[(loud.count - 24000)..<loud.count]), rms(output[(output.count - 48000)...]))
        }
        let music = levels("music"), night = levels("night")
        let dryQuiet = rms(quiet[...])
        XCTAssertLessThan(night.loud, music.loud * 0.7, "Night holds loud audio at least 3 dB lower")
        XCTAssertLessThan(night.loud / night.quiet, music.loud / music.quiet, "a smaller range")
        XCTAssertGreaterThan(night.quiet, dryQuiet * 2, "quiet audio is still raised")
        func secondsToTriple(_ id: String) -> Double {
            let boost = AudioMagicBoost(sampleRate: 48000)
            boost.setPreset(index: AudioBoostPreset.index(of: id))
            let output = boosted(quiet, boost)
            for start in stride(from: 0, to: output.count - 4800, by: 4800)
            where rms(output[start..<(start + 4800)]) >= dryQuiet * 3 { return Double(start) / 48000 }
            return .infinity
        }
        let speech = secondsToTriple("speech"), reference = secondsToTriple("music")
        XCTAssertLessThan(speech, reference, "Speech lifts a quiet voice sooner (\(speech) s vs \(reference) s)")
        print("S06 loud/quiet RMS: Music \(music), Night \(night); 3× lift after Speech \(speech) s, Music \(reference) s")
    }

    /// Changing the preset while audio plays glides: no sample step larger
    /// than the signal's own.
    func testSwitchingThePresetWhilePlayingDoesNotStep() {
        var phase = 0.0
        let signal = sine(0.3, seconds: 3, phase: &phase)
        let boost = AudioMagicBoost(sampleRate: 48000)
        let output = boosted(signal, boost, switchAt: 48000 * 3 / 2, preset: AudioBoostPreset.index(of: "night"))
        func worstStep(_ range: Range<Int>) -> Float {
            var worst: Float = 0
            for index in range.dropFirst() { worst = max(worst, abs(output[index] - output[index - 1])) }
            return worst
        }
        let before = worstStep(48000..<72000), after = worstStep(72000..<96000)
        XCTAssertLessThanOrEqual(after, before * 1.5 + 0.005, "before \(before), after \(after)")
        XCTAssertEqual(boost.presetIndex, AudioBoostPreset.index(of: "night"))
    }

    func testBoostPresetsAreStoredPerAppAndForTheOutput() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Audio333Tests.\(UUID().uuidString)"))
        XCTAssertEqual(AudioBoostPreset.storedID(bundleID: "com.example.player", defaults: defaults), "music")
        AudioBoostPreset.store("night", bundleID: "com.example.player", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "AOMAudioMagicBoostPreset_com.example.player"), "night")
        XCTAssertEqual(AudioBoostPreset.storedID(bundleID: "com.example.player", defaults: defaults), "night")
        XCTAssertEqual(AudioBoostPreset.storedID(bundleID: nil, defaults: defaults), "music", "the output keeps its own")
        AudioBoostPreset.store("movie", bundleID: nil, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: AudioBoostPreset.masterKey), "movie")
        AudioBoostPreset.store("music", bundleID: "com.example.player", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "AOMAudioMagicBoostPreset_com.example.player"), "the default stores nothing")
        defaults.set("garbage", forKey: AudioBoostPreset.masterKey)
        XCTAssertEqual(AudioBoostPreset.storedID(bundleID: nil, defaults: defaults), "music", "an unknown id is Music")
        // An app's mixer takes its preset lock-free; the output limiter never
        // releases faster than its bus allows (AirPlay: 150 ms).
        let mixer = MixerBox(gain: 1, muted: false)
        mixer.boostPreset = AudioBoostPreset.index(of: "speech")
        XCTAssertEqual(mixer.boostPreset, 1)
        XCTAssertEqual(AppAudioRenderBus.limiterRelease(base: 0.15, preset: .speech), 0.15)
        XCTAssertEqual(AppAudioRenderBus.limiterRelease(base: 0.15, preset: .night), 0.2)
        XCTAssertEqual(AppAudioRenderBus.limiterRelease(base: 0.025, preset: .speech), 0.05)
        XCTAssertEqual(AppAudioRenderBus.limiterRelease(base: 0.025, preset: .music), 0.025)
    }
}
