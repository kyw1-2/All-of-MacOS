import XCTest
@testable import AllOfMacOS

/// Pills sit on their element's top-left corner, stay whole on the display
/// that shows that corner, land on that display's pixel grid and don't hide
/// each other.
final class ClickHintsPlacementTests: XCTestCase {
    // A 2× built-in display, a 1× display above-right of it (negative y) and
    // a 3× display to its left (negative x), in Accessibility coordinates.
    private let builtIn = ClickHintsDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    private let external = ClickHintsDisplay(id: 2, frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080), scale: 1)
    private let studio = ClickHintsDisplay(id: 3, frame: CGRect(x: -1280, y: 100, width: 1280, height: 720), scale: 3)
    private let pill = CGSize(width: 22, height: 22)

    private func place(_ anchors: [CGRect], displays: [ClickHintsDisplay]? = nil) -> [ClickHintsPlacedPill?] {
        ClickHintsPlacement.place(anchors: anchors, sizes: anchors.map { _ in pill }, displays: displays ?? [builtIn, external, studio])
    }

    func testAPillSitsOnTheCornerOnThePixelGrid() throws {
        let placed = try XCTUnwrap(place([CGRect(x: 100.3, y: 200.7, width: 80, height: 24)])[0])
        XCTAssertEqual(placed.displayID, 1)
        // 3 pt up and left of the corner, rounded to half points on a 2× display.
        XCTAssertEqual(placed.frame.origin, CGPoint(x: 97.5, y: 197.5))
        XCTAssertEqual(placed.frame.size, pill)
        XCTAssertEqual(placed.localFrame, placed.frame)
    }

    func testPillsStayWholeOnTheirDisplay() throws {
        let anchors = [
            CGRect(x: 1430, y: 400, width: 10, height: 10),     // right edge
            CGRect(x: 0, y: 0, width: 50, height: 20),          // top-left corner (the offset would leave the display)
            CGRect(x: 600, y: 895, width: 40, height: 5),       // bottom edge
            CGRect(x: 1439, y: 899, width: 1, height: 1)        // bottom-right pixel
        ]
        let placed = place(anchors, displays: [builtIn])
        for case let pill? in placed {
            XCTAssertTrue(builtIn.frame.contains(pill.frame), "\(pill.frame) leaves the display")
        }
        XCTAssertEqual(placed[0]?.frame.maxX, 1440)
        XCTAssertEqual(placed[1]?.frame.origin, .zero)
        XCTAssertEqual(placed[2]?.frame.maxY, 900)
    }

    func testEachDisplayGetsItsOwnPillsInItsOwnPixels() throws {
        let anchors = [
            CGRect(x: 2000.4, y: -100.6, width: 80, height: 30),   // the 1× display above-right
            CGRect(x: -600.2, y: 300.2, width: 80, height: 30),    // the 3× display on the left
            CGRect(x: 700, y: 450, width: 80, height: 30)          // the 2× built-in display
        ]
        let placed = place(anchors).map { try? XCTUnwrap($0) }
        let one = try XCTUnwrap(placed[0]), three = try XCTUnwrap(placed[1]), two = try XCTUnwrap(placed[2])
        XCTAssertEqual(one.displayID, 2)
        XCTAssertEqual(one.frame.origin, CGPoint(x: 1997, y: -104), "whole points at 1×")
        XCTAssertEqual(one.localFrame.origin, CGPoint(x: 557, y: 76), "from the display's own top-left corner")
        XCTAssertEqual(three.displayID, 3)
        XCTAssertEqual(three.frame.minX * 3, (three.frame.minX * 3).rounded(), accuracy: 1e-9, "thirds of a point at 3×")
        XCTAssertEqual(three.frame.minY * 3, (three.frame.minY * 3).rounded(), accuracy: 1e-9)
        XCTAssertEqual(three.localFrame.minX, three.frame.minX + 1280, accuracy: 1e-9)
        XCTAssertEqual(two.displayID, 1)
        XCTAssertEqual(two.frame.origin, CGPoint(x: 697, y: 447))
    }

    func testAnElementAcrossTwoDisplaysFollowsItsCorner() throws {
        // Starts 20 pt before the built-in display's right edge.
        let placed = try XCTUnwrap(place([CGRect(x: 1420, y: 300, width: 200, height: 40)])[0])
        XCTAssertEqual(placed.displayID, 1)
        XCTAssertTrue(builtIn.frame.contains(placed.frame))
        // A corner where no display is (above the built-in display, left of
        // the 1× one) goes to the display with most of the element.
        let gap = try XCTUnwrap(place([CGRect(x: 1400, y: -50, width: 200, height: 40)], displays: [builtIn, external])[0])
        XCTAssertEqual(gap.displayID, 2)
        XCTAssertTrue(external.frame.contains(gap.frame))
    }

    func testStackedPillsMayTouch() throws {
        // Rows 22 pt apart with 22 pt pills: touching, not overlapping, so none moves.
        let anchors = (0..<4).map { CGRect(x: 100, y: 100 + CGFloat($0) * 22, width: 200, height: 22) }
        let placed = place(anchors).compactMap { $0 }
        XCTAssertEqual(Set(placed.map(\.frame.minX)), [97])
    }

    func testOverlappingPillsMoveRight() throws {
        let anchors = [
            CGRect(x: 100, y: 100, width: 200, height: 30),
            CGRect(x: 100, y: 100, width: 16, height: 16),   // the same corner (a triangle in a row)
            CGRect(x: 104, y: 102, width: 16, height: 16)    // nearly the same corner
        ]
        let placed = place(anchors).compactMap { $0 }
        XCTAssertEqual(placed.count, 3)
        XCTAssertEqual(placed[1].frame.minX, placed[0].frame.maxX + ClickHintsPlacement.gap)
        for (index, a) in placed.enumerated() {
            for b in placed[(index + 1)...] { XCTAssertFalse(a.frame.intersects(b.frame), "\(a.frame) \(b.frame)") }
        }
    }

    func testANudgeNeverLeavesTheDisplay() throws {
        let anchors = [CGRect(x: 1420, y: 50, width: 20, height: 20), CGRect(x: 1420, y: 50, width: 20, height: 20)]
        let placed = place(anchors, displays: [builtIn]).compactMap { $0 }
        XCTAssertEqual(placed.count, 2)
        XCTAssertTrue(placed.allSatisfy { builtIn.frame.contains($0.frame) })
    }

    func testFitKeepsLargePillsOnTheGrid() {
        let fitted = ClickHintsPlacement.fit(CGRect(x: 1430.3, y: 10.2, width: 23.5, height: 22), in: builtIn.frame, scale: 2)
        XCTAssertLessThanOrEqual(fitted.maxX, 1440)
        XCTAssertEqual(fitted.minX * 2, (fitted.minX * 2).rounded())
        let tiny = ClickHintsPlacement.fit(CGRect(x: 5, y: 5, width: 3000, height: 22), in: builtIn.frame, scale: 2)
        XCTAssertEqual(tiny.minX, 0, "a pill wider than the display keeps its corner on it")
    }

    func testNoDisplayMeansNoPill() {
        XCTAssertEqual(ClickHintsPlacement.place(anchors: [CGRect(x: 0, y: 0, width: 10, height: 10)], sizes: [pill], displays: []),
                       [nil])
    }
}
