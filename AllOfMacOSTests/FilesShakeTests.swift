import AppKit
import XCTest
@testable import AllOfMacOS

/// Shake detection on synthetic pointer traces (60 samples a second, times in
/// seconds), and the file-drag check on a private pasteboard. No real mouse
/// events, no event monitors.
@MainActor
final class FilesShakeTests: XCTestCase {
    /// Samples a path made of horizontal strokes: (distance in points, seconds).
    private func trace(_ strokes: [(CGFloat, TimeInterval)], jitter: CGFloat = 0, start: TimeInterval = 100) -> [(CGFloat, TimeInterval)] {
        var samples: [(CGFloat, TimeInterval)] = [(0, start)]
        var x: CGFloat = 0
        var time = start
        var step = 0
        for (distance, duration) in strokes {
            let count = max(1, Int((duration * 60).rounded()))
            for index in 1...count {
                time += duration / Double(count)
                step += 1
                let wobble = jitter == 0 ? 0 : jitter * CGFloat(sin(Double(step) * 1.7))
                samples.append((x + distance * CGFloat(index) / CGFloat(count) + wobble, time))
            }
            x += distance
        }
        return samples
    }

    private func detects(_ samples: [(CGFloat, TimeInterval)], _ sensitivity: FilesShakeSensitivity = .medium) -> Bool {
        var detector = FilesShakeDetector(sensitivity: sensitivity)
        return samples.contains { detector.add(x: $0.0, time: $0.1) }
    }

    func testAQuickShakeIsDetected() {
        let shake = trace([(80, 0.12), (-80, 0.12), (80, 0.12), (-80, 0.12), (80, 0.12)])
        XCTAssertTrue(detects(shake))
        XCTAssertTrue(detects(shake, .high))
    }

    func testAShakeAfterANormalDragIsDetected() {
        let samples = trace([(300, 0.6), (70, 0.1), (-70, 0.1), (70, 0.1), (-70, 0.1), (70, 0.1)])
        XCTAssertTrue(detects(samples))
    }

    func testANormalDragIsNotAShake() {
        XCTAssertFalse(detects(trace([(600, 1.0)], jitter: 2)))
        XCTAssertFalse(detects(trace([(300, 0.5), (-60, 0.3), (400, 0.6)], jitter: 1.5)), "one correction is not a shake")
        XCTAssertFalse(detects(trace([(300, 0.5), (-60, 0.3), (400, 0.6)], jitter: 1.5), .high))
    }

    func testSlowBackAndForthIsNotAShake() {
        let slow = trace([(120, 0.6), (-120, 0.6), (120, 0.6), (-120, 0.6), (120, 0.6)])
        XCTAssertFalse(detects(slow))
        XCTAssertFalse(detects(slow, .high))
    }

    func testSmallWobbleIsNotAShake() {
        let wobble = trace([(12, 0.08), (-12, 0.08), (12, 0.08), (-12, 0.08), (12, 0.08), (-12, 0.08)])
        XCTAssertFalse(detects(wobble))
        XCTAssertFalse(detects(wobble, .high))
    }

    func testSensitivityMovesTheThreshold() {
        let small = trace([(30, 0.1), (-30, 0.1), (30, 0.1), (-30, 0.1), (30, 0.1)])
        XCTAssertFalse(detects(small, .medium))
        XCTAssertTrue(detects(small, .high))
        let medium = trace([(50, 0.1), (-50, 0.1), (50, 0.1), (-50, 0.1), (50, 0.1)])
        XCTAssertTrue(detects(medium, .medium))
        XCTAssertFalse(detects(medium, .low))
        let wide = trace([(90, 0.12), (-90, 0.12), (90, 0.12), (-90, 0.12), (90, 0.12), (-90, 0.12)])
        XCTAssertTrue(detects(wide, .low))
    }

    func testTheDetectorStartsOverAfterAShake() {
        var detector = FilesShakeDetector(sensitivity: .medium)
        let shake = trace([(80, 0.12), (-80, 0.12), (80, 0.12), (-80, 0.12), (80, 0.12)])
        var hits = 0
        for sample in shake where detector.add(x: sample.0, time: sample.1) { hits += 1 }
        XCTAssertEqual(hits, 1, "one shake opens the shelf once")
        detector.reset()
        XCTAssertFalse(detector.add(x: 10, time: 200))
    }

    func testOnlyANewDragWithFilesCounts() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AOMFilesShakeTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let baseline = pasteboard.changeCount
        XCTAssertFalse(FilesShakeMonitor.isFileDrag(baseline: baseline, pasteboard: pasteboard), "nothing new on the drag pasteboard")
        pasteboard.clearContents()
        pasteboard.setString("selected text", forType: .string)
        XCTAssertFalse(FilesShakeMonitor.isFileDrag(baseline: baseline, pasteboard: pasteboard), "a text drag is not a file drag")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: NSTemporaryDirectory()) as NSURL])
        XCTAssertTrue(FilesShakeMonitor.isFileDrag(baseline: baseline, pasteboard: pasteboard))
        XCTAssertFalse(FilesShakeMonitor.isFileDrag(baseline: pasteboard.changeCount, pasteboard: pasteboard),
                       "files left over from an earlier drag don't count")
    }
}
