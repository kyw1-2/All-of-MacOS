import Foundation
import XCTest
@testable import AllOfMacOS

final class StudioTimelineTests: XCTestCase {
    func testTrimSamplesSourceTimeWithoutMovingExistingZooms() {
        let keyframes = [
            AOMStudioZoomKeyframe(time: 10, magnification: 2, focusX: 0.2, focusY: 0.3),
            AOMStudioZoomKeyframe(time: 14, magnification: 3, focusX: 0.8, focusY: 0.7)
        ]
        let trimStart = 12.0
        let outputTime = 0.0
        let focus = AOMStudioTimeline.sampledFocus(at: trimStart + outputTime, keyframes: keyframes)
        XCTAssertEqual(focus.magnification, 2.5, accuracy: 0.000001)
        XCTAssertEqual(focus.x, 0.5, accuracy: 0.000001)
        XCTAssertEqual(focus.y, 0.5, accuracy: 0.000001)
        XCTAssertEqual(keyframes.map(\.time), [10, 14])
        // A second trim chooses another point in the same source animation.
        let later = AOMStudioTimeline.sampledFocus(at: 14, keyframes: keyframes)
        XCTAssertEqual(later.magnification, 3)
        XCTAssertEqual(later.x, 0.8)
        XCTAssertEqual(later.y, 0.7)
    }

    func testLastDuplicateZoomWinsAtBoundaryAndDuringInterpolation() {
        let edits = [
            AOMStudioZoomKeyframe(time: 2, magnification: 2, focusX: 0.1, focusY: 0.1),
            AOMStudioZoomKeyframe(time: 4, magnification: 1),
            AOMStudioZoomKeyframe(time: 2, magnification: 3, focusX: 0.7, focusY: 0.9)
        ]
        for _ in 0..<10 {
            let exact = AOMStudioTimeline.sampledFocus(at: 2, keyframes: edits)
            XCTAssertEqual(exact.magnification, 3)
            XCTAssertEqual(exact.x, 0.7)
            XCTAssertEqual(exact.y, 0.9)
            XCTAssertEqual(AOMStudioTimeline.sampledFocus(at: 1, keyframes: edits).magnification,
                           2, accuracy: 0.000001)
            XCTAssertEqual(AOMStudioTimeline.sampledFocus(at: 3, keyframes: edits).magnification,
                           2, accuracy: 0.000001)
        }
    }

    func testInvalidZoomsAreIgnoredAndValidValuesAreBounded() {
        let edits = [
            AOMStudioZoomKeyframe(time: -1, magnification: 2),
            AOMStudioZoomKeyframe(time: .nan, magnification: 2),
            AOMStudioZoomKeyframe(time: 0, magnification: .infinity),
            AOMStudioZoomKeyframe(time: 1, magnification: 99, focusX: -4, focusY: 4)
        ]
        let focus = AOMStudioTimeline.sampledFocus(at: 1, keyframes: edits)
        XCTAssertEqual(focus.magnification, 4)
        XCTAssertEqual(focus.x, 0)
        XCTAssertEqual(focus.y, 1)
        XCTAssertEqual(AOMStudioTimeline.sampledFocus(at: .nan, keyframes: edits),
                       AOMStudioTimeline.Focus(magnification: 1, x: 0.5, y: 0.5))
    }

    func testTopLeftViewportAndCursorProjectionShareEdgeClampAndPadding() {
        let focus = AOMStudioTimeline.Focus(magnification: 2, x: 0, y: 0)
        let center = AOMStudioTimeline.viewportCenter(for: focus)
        XCTAssertEqual(center.x, 0.25)
        XCTAssertEqual(center.y, 0.25)
        let topLeft = AOMStudioTimeline.projectedPoint(.zero, focus: focus, padding: 0.1)
        XCTAssertEqual(topLeft.x, 0.1, accuracy: 0.000001)
        XCTAssertEqual(topLeft.y, 0.1, accuracy: 0.000001)
        let bottomRight = AOMStudioTimeline.projectedPoint(
            CGPoint(x: 0.5, y: 0.5), focus: focus, padding: 0.1)
        XCTAssertEqual(bottomRight.x, 0.9, accuracy: 0.000001)
        XCTAssertEqual(bottomRight.y, 0.9, accuracy: 0.000001)
        let projectedCenter = AOMStudioTimeline.projectedPoint(center, focus: focus, padding: 0.1)
        XCTAssertEqual(projectedCenter.x, 0.5, accuracy: 0.000001)
        XCTAssertEqual(projectedCenter.y, 0.5, accuracy: 0.000001)
        // Positive Y remains downward in the shared top-left coordinate space.
        XCTAssertLessThan(topLeft.y, projectedCenter.y)
        let opposite = AOMStudioTimeline.Focus(magnification: 2, x: 1, y: 1)
        XCTAssertEqual(AOMStudioTimeline.viewportCenter(for: opposite), CGPoint(x: 0.75, y: 0.75))
        XCTAssertEqual(AOMStudioTimeline.projectedPoint(CGPoint(x: 1, y: 1), focus: opposite, padding: 0.1),
                       CGPoint(x: 0.9, y: 0.9))
    }

    func testUnzoomedProjectionAndPaddingLimits() {
        let focus = AOMStudioTimeline.Focus(magnification: 1, x: 0, y: 1)
        let point = CGPoint(x: 0.2, y: 0.8)
        XCTAssertEqual(AOMStudioTimeline.viewportCenter(for: focus), CGPoint(x: 0.5, y: 0.5))
        let withoutPadding = AOMStudioTimeline.projectedPoint(point, focus: focus, padding: -1)
        XCTAssertEqual(withoutPadding.x, point.x, accuracy: 0.000001)
        XCTAssertEqual(withoutPadding.y, point.y, accuracy: 0.000001)
        let capped = AOMStudioTimeline.projectedPoint(point, focus: focus, padding: 1)
        XCTAssertEqual(capped.x, 0.32, accuracy: 0.000001)
        XCTAssertEqual(capped.y, 0.68, accuracy: 0.000001)
    }

    func testDwellSuggestionsStayInsideSourceTrimAndBoundMagnification() {
        let track = AOMCursorTrack(points: (0...10).map {
            AOMCursorPoint(time: 10 + Double($0) * 0.1, x: 0.2, y: 0.8)
        })
        let suggestions = AOMStudioTimeline.suggestedZooms(track: track, start: 10, end: 11.2,
                                                          magnification: 99)
        XCTAssertEqual(suggestions.count, 4)
        XCTAssertEqual(suggestions.first?.time, 10)
        XCTAssertEqual(suggestions.first?.magnification, 1)
        XCTAssertEqual(suggestions.last?.magnification, 1)
        XCTAssertTrue(suggestions.allSatisfy { (10...11.2).contains($0.time) })
        XCTAssertTrue(suggestions.allSatisfy { (1...3).contains($0.magnification) })
        XCTAssertEqual(suggestions.map(\.time), suggestions.map(\.time).sorted())
        for suggestion in suggestions {
            XCTAssertEqual(suggestion.focusX, 0.2, accuracy: 0.000001)
            XCTAssertEqual(suggestion.focusY, 0.8, accuracy: 0.000001)
        }
    }

    func testHiddenSamplesAndLargeGapsDoNotCreateDwellSuggestions() {
        let hidden = AOMCursorTrack(points: (0...10).map {
            AOMCursorPoint(time: Double($0) * 0.1, x: 0.5, y: 0.5, visible: false)
        })
        XCTAssertTrue(AOMStudioTimeline.suggestedZooms(track: hidden, start: 0, end: 2).isEmpty)
        let interrupted = AOMCursorTrack(points: (0...10).map {
            AOMCursorPoint(time: Double($0) * 0.1, x: 0.5, y: 0.5,
                           visible: $0 == 5 ? false : true)
        })
        XCTAssertTrue(AOMStudioTimeline.suggestedZooms(track: interrupted, start: 0, end: 2).isEmpty)
        let sparse = AOMCursorTrack(points: (0...4).map {
            AOMCursorPoint(time: Double($0) * 0.4, x: 0.5, y: 0.5)
        })
        XCTAssertTrue(AOMStudioTimeline.suggestedZooms(track: sparse, start: 0, end: 2).isEmpty)
        let moving = AOMCursorTrack(points: (0...9).map {
            AOMCursorPoint(time: Double($0) * 0.1, x: Double($0) * 0.1, y: 0.5)
        })
        XCTAssertTrue(AOMStudioTimeline.suggestedZooms(track: moving, start: 0, end: 2).isEmpty)
    }

    func testDwellRejectsInvalidTracksAndRanges() {
        let invalid = AOMCursorTrack(points: [
            AOMCursorPoint(time: 1, x: 0.5, y: 0.5),
            AOMCursorPoint(time: 0, x: 0.5, y: 0.5)
        ])
        XCTAssertTrue(AOMStudioTimeline.suggestedZooms(track: invalid, start: 0, end: 2).isEmpty)
        let empty = AOMCursorTrack(points: [])
        XCTAssertTrue(AOMStudioTimeline.suggestedZooms(track: empty, start: 2, end: 1).isEmpty)
        XCTAssertTrue(AOMStudioTimeline.suggestedZooms(track: empty, start: .nan, end: 2).isEmpty)
    }

    func testCursorVisibilityTransitionsDoNotSmearAcrossHiddenInterval() throws {
        let track = AOMCursorTrack(points: [
            AOMCursorPoint(time: 1, x: 0.1, y: 0.2),
            AOMCursorPoint(time: 1.2, x: 0.1, y: 0.2, visible: false),
            AOMCursorPoint(time: 2, x: 0.9, y: 0.8),
            AOMCursorPoint(time: 2.1, x: 0.9, y: 0.8)
        ])
        XCTAssertNil(track.smoothedPosition(at: 0.99))
        XCTAssertNotNil(track.smoothedPosition(at: 1))
        let beforeExit = try XCTUnwrap(track.smoothedPosition(at: 1.19))
        XCTAssertEqual(beforeExit.x, 0.1, accuracy: 0.000001)
        XCTAssertNil(track.smoothedPosition(at: 1.2))
        XCTAssertNil(track.smoothedPosition(at: 1.7))
        let entered = try XCTUnwrap(track.smoothedPosition(at: 2))
        XCTAssertEqual(entered.x, 0.9, accuracy: 0.000001)
        XCTAssertEqual(entered.y, 0.8, accuracy: 0.000001)
        let following = try XCTUnwrap(track.smoothedPosition(at: 2.05))
        XCTAssertEqual(following.x, 0.9, accuracy: 0.000001)
        XCTAssertEqual(following.y, 0.8, accuracy: 0.000001)
    }

    func testCursorStopsAfterSamplingCutoffInsteadOfFreezingForever() {
        let track = AOMCursorTrack(points: [AOMCursorPoint(time: 1, x: 0.3, y: 0.7)])
        XCTAssertNotNil(track.smoothedPosition(at: 1.25))
        XCTAssertNil(track.smoothedPosition(at: 1.251))
        XCTAssertNil(track.smoothedPosition(at: 100))
        XCTAssertNil(track.smoothedPosition(at: .nan))
        let hidden = AOMCursorTrack(points: [AOMCursorPoint(time: 1, x: 0.3, y: 0.7, visible: false)])
        XCTAssertNil(hidden.smoothedPosition(at: 1))
        XCTAssertNil(hidden.smoothedPosition(at: 1.1))
    }

    func testCursorSamplingUsesExplicitSourceTimeAfterTrim() throws {
        let track = AOMCursorTrack(points: [
            AOMCursorPoint(time: 0, x: 0.1, y: 0.1),
            AOMCursorPoint(time: 0.1, x: 0.1, y: 0.1, visible: false),
            AOMCursorPoint(time: 10, x: 0.8, y: 0.7),
            AOMCursorPoint(time: 10.1, x: 0.8, y: 0.7)
        ])
        let trimStart = 10.0
        let outputTime = 0.05
        let cursor = try XCTUnwrap(track.smoothedPosition(at: trimStart + outputTime))
        XCTAssertEqual(cursor.x, 0.8, accuracy: 0.000001)
        XCTAssertEqual(cursor.y, 0.7, accuracy: 0.000001)
    }

    func testSidecarRoundTripAndLegacyVisibility() throws {
        try withTemporaryMovie { movie in
            let legacy = Data("{\"points\":[{\"time\":0,\"x\":0.3,\"y\":0.7}]}".utf8)
            try legacy.write(to: AOMCursorTrack.sidecarURL(for: movie))
            let track = try XCTUnwrap(AOMCursorTrack.read(for: movie))
            XCTAssertNil(track.points.first?.visible)
            XCTAssertNotNil(track.smoothedPosition(at: 0))
            let hidden = AOMCursorTrack(points: [AOMCursorPoint(time: 0, x: 0.3, y: 0.7, visible: false)])
            try hidden.write(for: movie)
            XCTAssertEqual(AOMCursorTrack.read(for: movie)?.points, hidden.points)
        }
    }

    func testSidecarRejectsInvalidChronologyCoordinatesAndExcessSamples() throws {
        try withTemporaryMovie { movie in
            let invalidTracks = [
                AOMCursorTrack(points: [AOMCursorPoint(time: 2, x: 0.5, y: 0.5),
                                       AOMCursorPoint(time: 1, x: 0.5, y: 0.5)]),
                AOMCursorTrack(points: [AOMCursorPoint(time: -1, x: 0.5, y: 0.5)]),
                AOMCursorTrack(points: [AOMCursorPoint(time: 0, x: 1.1, y: 0.5)]),
                AOMCursorTrack(points: Array(repeating: AOMCursorPoint(time: 0, x: 0.5, y: 0.5),
                                            count: 60_001))
            ]
            for track in invalidTracks {
                XCTAssertFalse(track.isValid)
                XCTAssertThrowsError(try track.write(for: movie))
                try JSONEncoder().encode(track).write(to: AOMCursorTrack.sidecarURL(for: movie))
                XCTAssertNil(AOMCursorTrack.read(for: movie))
            }
            let nonfinite = AOMCursorTrack(points: [AOMCursorPoint(time: .nan, x: 0.5, y: 0.5)])
            XCTAssertFalse(nonfinite.isValid)
            XCTAssertThrowsError(try nonfinite.write(for: movie))
        }
    }

    func testSidecarRejectsOversizedButOtherwiseValidJSON() throws {
        try withTemporaryMovie { movie in
            var data = Data("{\"points\":[]}".utf8)
            data.append(Data(repeating: 0x20, count: 8_000_001 - data.count))
            try data.write(to: AOMCursorTrack.sidecarURL(for: movie))
            XCTAssertNil(AOMCursorTrack.read(for: movie))
        }
    }

    private func withTemporaryMovie(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AOM-StudioTimelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("source.mp4"))
    }
}
