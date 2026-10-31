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

    /// One block through the softener: the block as it would be queued, and
    /// whether any gain was written.
    private func shape(_ softener: inout AudioDropoutSoftener, _ block: [Float]) -> (out: [Float], shaped: Bool) {
        let gains = UnsafeMutablePointer<Float>.allocate(capacity: block.count)
        defer { gains.deallocate() }
        gains.initialize(repeating: 7, count: block.count)
        let shaped = softener.shape(frames: block.count, sampleRate: rate, gains: gains) { (block[$0], block[$0]) }
        return (shaped ? block.indices.map { block[$0] * gains[$0] } : block, shaped)
    }

    private func largestStep(_ samples: [Float]) -> Float {
        zip(samples.dropFirst(), samples).map { abs($0 - $1) }.max() ?? 0
    }

    func testAHoleInsideABlockBecomesADip() {
        var block = sine(1024)
        // 128 frames (one HomePod IO cycle) of exact zeros from a crest of the sine.
        for frame in 396..<524 { block[frame] = 0 }
        XCTAssertGreaterThan(largestStep(block), 0.4, "unshaped, the hole's edge is a step of about the amplitude")
        var softener = AudioDropoutSoftener()
        let result = shape(&softener, block)
        XCTAssertTrue(result.shaped)
        XCTAssertEqual(softener.softened, 1)
        // The sine's own largest step is 2π · 1000 / 48000 · 0.5 ≈ 0.065.
        XCTAssertLessThan(largestStep(result.out), 0.08)
        XCTAssertEqual(result.out[250], block[250], "audio before the 2 ms fade is untouched")
        XCTAssertEqual(result.out[700], block[700], "audio after the 2 ms fade-in is untouched")
    }

    func testAudioWithoutAHoleIsLeftAlone() {
        var softener = AudioDropoutSoftener()
        XCTAssertFalse(shape(&softener, sine(1024, start: 12)).shaped)
        var nearlyHole = sine(1024, start: 12)
        for frame in 396..<404 { nearlyHole[frame] = 0 }
        XCTAssertFalse(shape(&softener, nearlyHole).shaped, "fewer than 32 zeros are not a dropout")
        XCTAssertEqual(softener.softened, 0)
    }

    func testQuietAudioRunningIntoZerosIsLeftAlone() {
        var softener = AudioDropoutSoftener()
        var block = sine(1024, amplitude: 0.0005)   // −66 dBFS, the end of a decoder's fade-out
        for frame in 512..<640 { block[frame] = 0 }
        XCTAssertFalse(shape(&softener, block).shaped)
    }

    func testAPauseEndsSoftlyAndTheNextSoundStartsAsItIs() {
        var softener = AudioDropoutSoftener()
        var first = sine(1024)
        for frame in 516..<1024 { first[frame] = 0 }
        XCTAssertGreaterThan(largestStep(first), 0.4)
        let stop = shape(&softener, first)
        XCTAssertTrue(stop.shaped, "an abrupt stop is faded out")
        XCTAssertLessThan(largestStep(stop.out), 0.08)
        // 120 ms more of silence: a pause, not a dropout.
        for _ in 0..<5 { XCTAssertFalse(shape(&softener, [Float](repeating: 0, count: 1152)).shaped) }
        XCTAssertFalse(shape(&softener, sine(1024, start: 12)).shaped, "what follows a pause is not faded in")
        XCTAssertEqual(softener.softened, 0)
    }

    func testAHoleAcrossTwoBlocksFadesBackInTheNextOne() {
        var softener = AudioDropoutSoftener()
        var first = sine(1024)
        for frame in 960..<1024 { first[frame] = 0 }
        var second = sine(1024, start: 1024)
        for frame in 0..<64 { second[frame] = 0 }
        XCTAssertGreaterThan(largestStep(first + second), 0.4)
        let a = shape(&softener, first)
        let b = shape(&softener, second)
        XCTAssertTrue(a.shaped, "the edge into the hole is faded out")
        XCTAssertTrue(b.shaped, "the edge out of it is faded in")
        XCTAssertEqual(softener.softened, 1)
        XCTAssertLessThan(largestStep(a.out + b.out), 0.08)
    }

    func testTheTransportShapesADropoutBeforeItIsQueued() {
        let transport = AppAudioTransport(sampleRate: rate, bufferedForAirPlay: true)
        let wave = sine(1024)
        var interleaved = [Float](repeating: 0, count: 2048)
        for frame in 0..<1024 where !(396..<524).contains(frame) {
            interleaved[frame * 2] = wave[frame]
            interleaved[frame * 2 + 1] = wave[frame]
        }
        interleaved.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                                       mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            transport.capture(&list)
        }
        XCTAssertEqual(transport.statistics["softenedDropouts"] as? UInt64, 1)
        XCTAssertEqual(transport.statistics["capturedFrames"] as? UInt64, 1024, "every frame is still queued")
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
