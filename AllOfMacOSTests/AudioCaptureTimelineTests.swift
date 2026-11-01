import XCTest
import CoreAudio
@testable import AllOfMacOS

final class AudioCaptureTimelineTests: XCTestCase {
    func testSampleClockFindsMissingPacketsWithoutUsingCallbackArrivalTime() {
        var timeline = AudioCaptureTimeline()
        XCTAssertEqual(timeline.observe(sampleTime: 0, frames: 128, sampleRate: 48000), .continuous)
        XCTAssertEqual(timeline.observe(sampleTime: 256, frames: 1024, sampleRate: 48000), .gap(128))
        XCTAssertEqual(timeline.observe(sampleTime: 1280, frames: 512, sampleRate: 48000), .continuous)
    }

    func testInvalidEmptyAndRestartedTimestampsNeverBecomeHugeHoles() {
        var timeline = AudioCaptureTimeline()
        XCTAssertEqual(timeline.observe(sampleTime: 10000, frames: 1024, sampleRate: 48000), .continuous)
        XCTAssertEqual(timeline.observe(sampleTime: 0, frames: 1024, sampleRate: 48000), .reset)
        XCTAssertEqual(timeline.observe(sampleTime: .nan, frames: 1024, sampleRate: 48000), .continuous)
        XCTAssertEqual(timeline.observe(sampleTime: 50000, frames: 1024, sampleRate: 48000), .continuous)
        XCTAssertEqual(timeline.observe(sampleTime: 0, frames: 0, sampleRate: 48000), .continuous)
        XCTAssertEqual(timeline.observe(sampleTime: 51024, frames: 128, sampleRate: 48000), .continuous)
        XCTAssertEqual(timeline.observe(sampleTime: 1e30, frames: 128, sampleRate: 48000), .reset)
        timeline.reset()
        XCTAssertEqual(timeline.observe(sampleTime: 0, frames: 128, sampleRate: 48000), .continuous)
    }

    func testTransportPreservesShortMissingTimeAndUsesSeparateCaptureEventRing() {
        let transport = AppAudioTransport(sampleRate: 48000, bufferedForAirPlay: true)
        var samples = [Float](repeating: 0.25, count: 2048)
        func capture(at time: Double) {
            samples.withUnsafeMutableBufferPointer { data in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: 8192, mData: data.baseAddress))
                withUnsafePointer(to: &list) { transport.capture($0, sampleTime: time) }
            }
        }
        capture(at: 0)
        capture(at: 1152)
        XCTAssertEqual(transport.statistics["capturedFrames"] as? UInt64, 2176)
        XCTAssertEqual(transport.statistics["captureGapFrames"] as? UInt64, 128)
        XCTAssertEqual(transport.statistics["captureGaps"] as? UInt64, 1)
        XCTAssertEqual(transport.statistics["softenedDropouts"] as? UInt64, 1)
        var cursor: UInt64 = 0
        let records = transport.captureEvents.read(from: &cursor).records
        XCTAssertEqual(records.map(\.kind), [AudioEventKind.captureGap.rawValue])
        XCTAssertEqual(records.first?.value, 128)
        XCTAssertEqual(transport.events.count, 0, "capture must not write the consumer's SPSC ring")
        capture(at: 100000)
        XCTAssertEqual(transport.statistics["captureClockResets"] as? UInt64, 1)
        XCTAssertEqual(transport.statistics["captureGapFrames"] as? UInt64, 128,
                       "a long pause must not synthesize an unbounded zero buffer")
    }
    func testConfirmedShortHolesFadeBothEdgesWithoutChangingDuration() {
        for gap in [1, 16, 31, 128, 1024] {
            let softener = AudioDropoutSoftener()
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
            defer { buffer.deallocate() }
            var heard: [Float] = []
            func process(_ count: Int, _ value: Float) {
                softener.process(frames: count, sampleRate: 48000, output: buffer) { _ in (value, value) }
                heard += (0..<count).map { buffer[$0 * 2] }
            }
            process(2048, 0.5)
            softener.fadeOutPendingAudio()
            process(gap, 0)
            softener.fadeInNextAudio()
            process(2048, -0.5)
            let jumps = zip(heard.dropFirst(1024), heard.dropFirst(1025)).map { abs($1 - $0) }
            XCTAssertLessThan(jumps.max() ?? 0, 0.02, "confirmed \(gap)-frame hole has no hard splice")
            XCTAssertEqual(heard.count, 4096 + gap)
            XCTAssertEqual(heard.last, -0.5)
        }
    }

    func testRouteGenerationResetsCaptureClockAndLocalPathDoesNotInsertHoles() {
        let transport = AppAudioTransport(sampleRate: 48000, bufferedForAirPlay: true)
        var samples = [Float](repeating: 0.2, count: 256)
        func capture(_ time: Double) {
            samples.withUnsafeMutableBufferPointer { data in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: 1024, mData: data.baseAddress))
                withUnsafePointer(to: &list) { transport.capture($0, sampleTime: time) }
            }
        }
        capture(1000)
        transport.updateSampleRate(44100)
        capture(0)
        XCTAssertEqual(transport.statistics["captureClockResets"] as? UInt64, 0)
        transport.setBufferedForAirPlay(false)
        capture(256)
        capture(512)
        XCTAssertEqual(transport.statistics["captureGapFrames"] as? UInt64, 0)
        XCTAssertEqual(transport.statistics["capturedFrames"] as? UInt64, 512)
    }

}
