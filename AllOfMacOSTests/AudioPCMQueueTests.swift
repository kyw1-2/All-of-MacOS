import XCTest
@testable import AllOfMacOS

final class AudioPCMQueueTests: XCTestCase {
    func testLargeOutputSliceWaitsForEnoughPCMInsteadOfRepeatedPartialBlocks() {
        let queue = StereoPCMQueue(capacity: 8192)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        defer { output.deallocate() }
        queue.write(frames: 300) { _ in (0.25, -0.25) }
        XCTAssertEqual(queue.render(into: output, frames: 1024, ratio: 1,
            targetFrames: 256, driftLimit: 0, fadeFrames: 0), 0)
        XCTAssertEqual(queue.queuedFrames, 300, "Priming must not consume a partial slice")
        XCTAssertEqual(queue.statistics["underruns"], 0)
        queue.write(frames: 730) { _ in (0.25, -0.25) }
        XCTAssertEqual(queue.render(into: output, frames: 1024, ratio: 1,
            targetFrames: 256, driftLimit: 0, fadeFrames: 0), 1024)
        XCTAssertEqual(output[0], 0.25)
        XCTAssertEqual(output[2047], -0.25)
        XCTAssertEqual(queue.statistics["underruns"], 0)
    }

    func testLargeSlicesAtNonUnitySampleRateStayPrimedAcrossPacketBoundaries() {
        let queue = StereoPCMQueue(capacity: 16384)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { output.deallocate() }
        let ratio = 44100.0 / 48000.0
        queue.write(frames: 4096) { _ in (0.25, -0.25) }
        var sourceFraction = 0.0
        for _ in 0..<1000 {
            XCTAssertEqual(queue.render(into: output, frames: 2048, ratio: ratio,
                targetFrames: 256, driftLimit: 0, fadeFrames: 0), 2048)
            sourceFraction += 2048 * ratio
            let count = Int(sourceFraction)
            sourceFraction -= Double(count)
            XCTAssertEqual(queue.write(frames: count) { _ in (0.25, -0.25) }, count)
        }
        XCTAssertEqual(queue.statistics["underruns"], 0)
        XCTAssertEqual(queue.statistics["droppedFrames"], 0)
    }

    func testWraparoundPreservesEveryStereoFrameWithoutGapsOrRepeats() {
        let queue = StereoPCMQueue(capacity: 2048)
        var next = 0
        func push(_ count: Int) {
            let base = next
            XCTAssertEqual(queue.write(frames: count) { (Float(base + $0), -Float(base + $0)) }, count)
            next += count
        }
        push(1536)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { output.deallocate() }
        var expected = 0
        for _ in 0..<1000 {
            XCTAssertEqual(queue.render(into: output, frames: 256, ratio: 1,
                targetFrames: 1024, driftLimit: 0, fadeFrames: 0), 256)
            for frame in 0..<256 {
                XCTAssertEqual(output[frame * 2], Float(expected))
                XCTAssertEqual(output[frame * 2 + 1], -Float(expected))
                expected += 1
            }
            push(256)
        }
        XCTAssertEqual(queue.statistics["droppedFrames"], 0)
        XCTAssertEqual(queue.statistics["underruns"], 0)
    }

    func testClearDropsOnlyOldAudioAndRetainsNewlyPublishedFrames() {
        let queue = StereoPCMQueue(capacity: 8192)
        queue.write(frames: 2048) { _ in (0.1, 0.2) }
        queue.requestClear()
        queue.write(frames: 2048) { _ in (0.6, -0.6) }
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        defer { output.deallocate() }
        XCTAssertEqual(queue.render(into: output, frames: 512, ratio: 1,
            targetFrames: 1024, driftLimit: 0, fadeFrames: 0), 512)
        for frame in 0..<512 {
            XCTAssertEqual(output[frame * 2], 0.6)
            XCTAssertEqual(output[frame * 2 + 1], -0.6)
        }
    }

    func testConcurrentProducerConsumerAndHealthReadsPreserveFrameOrder() {
        let queue = StereoPCMQueue(capacity: 1_048_576)
        let total = 500_000, initial = 250_000
        queue.write(frames: initial) { (Float($0), -Float($0)) }
        let group = DispatchGroup()
        let mismatch = AudioAtomicCounter()
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            var base = initial
            while base < total {
                let count = min(1024, total - base), offset = base
                queue.write(frames: count) { (Float(offset + $0), -Float(offset + $0)) }
                base += count
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            let output = UnsafeMutablePointer<Float>.allocate(capacity: 512)
            defer { output.deallocate(); group.leave() }
            var expected = 0
            let limit = ((total - 2) / 256) * 256
            while expected < limit {
                let filled = queue.render(into: output, frames: 256, ratio: 1,
                    targetFrames: initial, driftLimit: 0, fadeFrames: 0)
                for frame in 0..<filled {
                    if output[frame * 2] != Float(expected) || output[frame * 2 + 1] != -Float(expected) { mismatch.add() }
                    expected += 1
                }
            }
        }
        for _ in 0..<10_000 { _ = queue.statistics }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(mismatch.load(), 0)
        XCTAssertEqual(queue.statistics["droppedFrames"], 0)
        XCTAssertEqual(queue.statistics["underruns"], 0)
    }
}