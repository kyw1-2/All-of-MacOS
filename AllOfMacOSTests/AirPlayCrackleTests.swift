import XCTest
import CoreAudio
@testable import AllOfMacOS

/// HomePod crackle audit, follow-up (3.3.2). The installed 3.3.1 logged
/// "skipping cycle due to overload" on the HomePod at a 128-frame IO buffer
/// about sixteen times in six hours; these tests cover what is left in the
/// app's own path: an app's queue under a mix clock that renders in bursts,
/// the app chain's delay lines when its stream stops, the network limiter's
/// release, and the bridge counting the cycles the HAL skipped. Virtual clocks
/// and synthetic signals only; no audio hardware.
final class AirPlayCrackleTests: XCTestCase {
    private func capture(_ transport: AppAudioTransport, _ packet: inout [Float]) {
        packet.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            withUnsafePointer(to: &list) { transport.capture($0) }
        }
    }

    private func render(_ transport: AppAudioTransport, _ mixer: MixerBox, frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames * 2)
        output.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            withUnsafeMutablePointer(to: &list) { transport.render(frames: frames, output: $0, mixer: mixer, allowWaiting: true) }
        }
        return stride(from: 0, to: output.count, by: 2).map { output[$0] }
    }

    /// A tap delivering 1024-frame packets on time while the AirPlay mix
    /// clock wakes 150 ms late every second and catches up in one burst.
    /// Before the follow-up the app's queue (40 ms target, trims above three
    /// targets) skipped the burst's audio and then ran dry in it on every
    /// such wake-up: skip, gap, skip, gap.
    func testABurstyMixClockNeitherTrimsNorStarvesAnAirPlayApp() {
        let transport = AppAudioTransport(sampleRate: 48000, bufferedForAirPlay: true)
        let mixer = MixerBox(gain: 1, muted: false)
        var packet = [Float](repeating: 0, count: 2048)
        var captured = 0, blocks = 0
        var nextCapture = 0.0, nextBlock = 0.0, clock = 0.0
        var output: [Float] = []
        let blockSeconds = 480.0 / 48000
        while clock < 6 {
            // Every second the mix thread oversleeps by 150 ms.
            let wake = nextBlock + (blocks % 100 == 50 ? 0.15 : 0)
            while nextCapture <= wake {
                for frame in 0..<1024 {
                    let v = Float(0.5 * sin(2 * .pi * 1000 * Double(captured + frame) / 48000))
                    packet[frame * 2] = v; packet[frame * 2 + 1] = v
                }
                capture(transport, &packet)
                captured += 1024
                nextCapture += 1024.0 / 48000
            }
            // Catch up: every block that is due by now, back to back.
            repeat {
                output += render(transport, mixer, frames: 480)
                nextBlock += blockSeconds
                blocks += 1
            } while nextBlock <= wake
            clock = wake
        }
        let stats = transport.statistics
        XCTAssertEqual(stats["trims"] as? UInt64, 0, "a late wake-up is not a backlog")
        XCTAssertEqual(stats["underruns"] as? UInt64, 0, "and the burst never runs the queue dry")
        // After the start-up: no 10 ms window loses its level, no step is
        // larger than the 1 kHz sine's own.
        let steady = Array(output[48000...])
        let bound = Float(1.5 * 2 * 0.5 * sin(Double.pi * 1000 / 48000))
        var worstStep: Float = 0
        for index in 1..<steady.count { worstStep = max(worstStep, abs(steady[index] - steady[index - 1])) }
        XCTAssertLessThanOrEqual(worstStep, bound)
        var quiet = 0
        for start in stride(from: 0, to: steady.count - 480, by: 480) {
            let window = steady[start..<(start + 480)]
            let rms = (window.reduce(0) { $0 + Double($1 * $1) } / 480).squareRoot()
            if rms < 0.5 * 0.5 / 2.0.squareRoot() { quiet += 1 }
        }
        XCTAssertEqual(quiet, 0, "no gap in the stream")
    }

    /// 3.3.2 review: an AirPlay app queue starts at its target, so a stream
    /// that (re)starts never runs on the 40 ms margin it used to begin at
    /// while the ±0.2 % loop took about 20 s to grow it to 80 ms.
    func testAirPlayAppQueuesStartAtTheirTargetAndHold80ms() {
        XCTAssertEqual(AppAudioTransport.startFrames(rate: 48000, airPlay: true, largestPacket: 512, capacity: 65536), 3840)
        XCTAssertEqual(AppAudioTransport.startFrames(rate: 48000, airPlay: true, largestPacket: 2048, capacity: 65536), 4608,
                       "with large packets too: the start is the target")
        XCTAssertEqual(AppAudioTransport.targetFrames(rate: 48000, airPlay: true, largestPacket: 512, capacity: 65536), 3840)
        XCTAssertEqual(AppAudioTransport.targetFrames(rate: 48000, airPlay: true, largestPacket: 2048, capacity: 65536), 4608,
                       "two packets and a margin when the tap delivers large ones")
        XCTAssertEqual(AppAudioTransport.trimFloorFrames(rate: 48000, airPlay: true), 24000)
        XCTAssertNil(AppAudioTransport.startFrames(rate: 48000, airPlay: false, largestPacket: 512, capacity: 65536))
        XCTAssertEqual(AppAudioTransport.targetFrames(rate: 48000, airPlay: false, largestPacket: 512, capacity: 65536), 1200)
        XCTAssertEqual(AppAudioTransport.trimFloorFrames(rate: 48000, airPlay: false), 0, "local outputs as before")
    }

    /// Magic Boost outputs its input 512 frames later. When an app's stream
    /// stopped (an underrun, a clear, a pause), 3.3.2 stopped running the
    /// chain with the stream's last audio still in that delay line: the
    /// output jumped from full level to silence, and the stale audio started
    /// abruptly when the app played again. The chain now runs on silence
    /// until it is empty.
    func testTheAppChainEmptiesItsDelayLinesWhenItsStreamStops() {
        let transport = AppAudioTransport(sampleRate: 48000, bufferedForAirPlay: true)
        let mixer = MixerBox(gain: 1, muted: false, magicBoost: true)
        var packet = [Float](repeating: 0, count: 2048)
        var captured = 0
        var output: [Float] = []
        func play(seconds: Double, capturing: Bool) {
            let blocks = Int(seconds * 100)
            var produced = 0.0
            for _ in 0..<blocks {
                produced += 480
                while capturing && Double(captured) <= produced + 2048 {
                    for frame in 0..<1024 {
                        let v = Float(0.3 * sin(2 * .pi * 100 * Double(captured + frame) / 48000))
                        packet[frame * 2] = v; packet[frame * 2 + 1] = v
                    }
                    capture(transport, &packet)
                    captured += 1024
                }
                output += render(transport, mixer, frames: 480)
            }
        }
        play(seconds: 1, capturing: true)
        play(seconds: 0.3, capturing: false)       // the app pauses
        play(seconds: 1, capturing: true)          // and plays again
        var worst: Float = 0, at = 0
        for index in 1..<output.count where abs(output[index] - output[index - 1]) > worst {
            worst = abs(output[index] - output[index - 1]); at = index
        }
        XCTAssertLessThanOrEqual(worst, 0.03, "largest step \(worst) at frame \(at) of \(output.count)")
    }

    /// A 40 Hz tone at −0.3 dBFS on the AirPlay bus's limiter: the gain must
    /// not follow the bass cycles. A 25 ms release does (it recovers between
    /// two peaks 12.5 ms apart); the network bus's 150 ms one holds.
    func testTheNetworkLimiterDoesNotModulateBass() {
        func residual(release: Double) -> Double {
            let limiter = AudioLookaheadLimiter(sampleRate: 48000, ceiling: AppAudioRenderBus.networkCeiling,
                                                truePeak: true, releaseSeconds: release)
            let frames = 96000
            var left = (0..<frames).map { Float(0.966 * sin(2 * .pi * 40 * Double($0) / 48000)) }
            var right = left
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    var offset = 0
                    while offset < frames {
                        let count = min(480, frames - offset)
                        limiter.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, frames: count)
                        offset += count
                    }
                }
            }
            // Least-squares 40 Hz sine over the second half; the rest is
            // what the gain changes added.
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
        print("40 Hz at −0.3 dBFS through the −1 dBTP limiter: distortion \(fast) dB (25 ms), \(slow) dB (150 ms)")
        XCTAssertLessThan(slow, -40, "the network bus keeps a bass note clean")
        XCTAssertLessThan(slow, fast - 10, "and much cleaner than the 25 ms release")
        XCTAssertEqual(AppAudioRenderBus.networkRelease, 0.15)
    }

    /// The HAL skipping a cycle (an overload) shows up as a jump in the
    /// device's sample time, which the bridge now counts for diagnostics.
    func testTheBridgeCountsDeviceCyclesTheHALSkipped() {
        let bridge = AirPlayPCMBridge()
        bridge.configure(outputRate: 48000, deviceFrames: 1024)
        bridge.prime()
        var buffer = [Float](repeating: 0, count: 2048)
        func cycle(at sampleTime: Double) {
            buffer.withUnsafeMutableBufferPointer { pointer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
                withUnsafeMutablePointer(to: &list) { bridge.render(frames: 1024, output: $0, sampleTime: sampleTime) }
            }
        }
        for time in [0.0, 1024, 2048, 4096, 5120, 6144] { cycle(at: time) }
        XCTAssertEqual(bridge.statistics["deviceCycleGaps"] as? UInt64, 1, "one cycle skipped between 2048 and 4096")
        XCTAssertEqual(bridge.statistics["deviceGapFrames"] as? UInt64, 1024)
        cycle(at: 100)        // the device restarted: no gap
        cycle(at: 1124)
        cycle(at: -1)         // no valid sample time: ignored
        XCTAssertEqual(bridge.statistics["deviceCycleGaps"] as? UInt64, 1)
        XCTAssertEqual(AirPlayOutputRenderer.preferredIOFrames, 1024, "AOM's own IO on the HomePod, not the 128-frame default")
    }
}
