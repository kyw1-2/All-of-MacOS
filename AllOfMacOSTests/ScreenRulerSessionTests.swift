import CoreGraphics
import XCTest
@testable import AllOfMacOS

/// The overlay's state machine (hover → drag → hold → copy → exit) and the
/// geometry it draws, on synthetic screens. Nothing here reads the screen,
/// moves the pointer or touches the clipboard.
final class ScreenRulerSessionTests: XCTestCase {
    /// A 100 × 50 pt Retina display: white, with a grey 40 × 20 pt button at (20, 10) pt.
    private func buttonScreen() -> ScreenRulerSnapshot {
        var canvas = ScreenRulerCanvas(width: 200, height: 100)
        canvas.fill(ScreenRulerPixelRect(x: 40, y: 20, width: 80, height: 40), (128, 128, 128))
        return canvas.snapshot(id: 1, scale: 2)
    }

    func testHoverDragHoldCopyExit() throws {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        XCTAssertEqual(session.phase, .hovering)

        // Hover inside the button: its size, edge to edge.
        session.move(to: CGPoint(x: 30, y: 15))
        let live = try XCTUnwrap(session.live)
        XCTAssertEqual(live.pixel, ScreenRulerPixel(x: 60, y: 30))
        XCTAssertEqual(live.horizontal.length, 80)
        XCTAssertEqual(live.vertical.length, 40)
        XCTAssertEqual(session.focus, .distances(live))
        XCTAssertEqual(session.copyText(), "40 × 20")

        // Drag a box around the button: it shrinks to the button.
        session.press(at: CGPoint(x: 10, y: 5))
        XCTAssertEqual(session.phase, .dragging)
        XCTAssertNil(session.live, "the crosshair gives way to the box")
        session.move(to: CGPoint(x: 70, y: 40))
        XCTAssertEqual(session.dragArea?.rect, ScreenRulerPixelRect(x: 20, y: 10, width: 121, height: 71))
        XCTAssertEqual(session.dragArea?.snapped, false)
        session.release(at: CGPoint(x: 70, y: 40))
        XCTAssertEqual(session.phase, .hovering)
        XCTAssertNil(session.dragArea)
        let area = try XCTUnwrap(session.area)
        XCTAssertEqual(area.rect, ScreenRulerPixelRect(x: 40, y: 20, width: 80, height: 40))
        XCTAssertTrue(area.snapped)
        XCTAssertEqual(session.focus, .area(area))

        // ⇧ keeps it; a second ⇧ does not keep it twice.
        XCTAssertEqual(session.hold(), .area(area))
        XCTAssertNil(session.hold())
        XCTAssertEqual(session.held, [.area(area)])

        // ⌘C copies the box in focus; Space switches the unit it is copied in.
        XCTAssertEqual(session.copyText(), "40 × 20")
        session.toggleUnit()
        XCTAssertEqual(session.unit, .pixels)
        XCTAssertEqual(session.copyText(), "80 × 40")
        XCTAssertEqual(session.lastCopied, "80 × 40")

        // Esc: nothing responds afterwards.
        session.exit()
        XCTAssertEqual(session.phase, .exited)
        XCTAssertFalse(session.isActive)
        session.press(at: CGPoint(x: 10, y: 5))
        XCTAssertEqual(session.phase, .exited)
        session.move(to: CGPoint(x: 5, y: 5))
        XCTAssertEqual(session.area, area, "input after exit changes nothing")
        XCTAssertNil(session.copyText())
        XCTAssertNil(session.nudgedPointer(dx: 1, dy: 0))
    }

    func testAClickWithoutDraggingOnlyClearsTheBox() {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        session.press(at: CGPoint(x: 10, y: 5))
        session.release(at: CGPoint(x: 70, y: 40))
        XCTAssertNotNil(session.area)
        // Moving less than the slop is a click.
        session.press(at: CGPoint(x: 80, y: 45))
        session.release(at: CGPoint(x: 81, y: 46))
        XCTAssertNil(session.area)
        XCTAssertEqual(session.phase, .hovering)
        XCTAssertNotNil(session.live, "the crosshair is back where the click ended")
        XCTAssertEqual(session.copyText(), session.live.map { ScreenRulerFormat.copyText(for: .distances($0), unit: .points, format: .times) })
    }

    func testOptionOrTheSettingKeepsTheBoxAsDrawn() {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        session.press(at: CGPoint(x: 10, y: 5))
        session.release(at: CGPoint(x: 70, y: 40), keepsAsDrawn: true)
        XCTAssertEqual(session.area?.rect, ScreenRulerPixelRect(x: 20, y: 10, width: 121, height: 71))
        XCTAssertEqual(session.area?.snapped, false)

        var unsnapped = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions(snapsArea: false))
        unsnapped.press(at: CGPoint(x: 10, y: 5))
        unsnapped.release(at: CGPoint(x: 70, y: 40))
        XCTAssertEqual(unsnapped.area?.snapped, false)

        // A box around nothing stays as drawn.
        var empty = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        empty.press(at: CGPoint(x: 70, y: 2))
        empty.release(at: CGPoint(x: 95, y: 8))
        XCTAssertEqual(empty.area?.snapped, false)
        XCTAssertEqual(empty.area?.rect, ScreenRulerPixelRect(x: 140, y: 4, width: 51, height: 13))
    }

    func testShiftKeepsTheDistancesAtThePointerAndMoreCanBeAdded() throws {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        session.move(to: CGPoint(x: 30, y: 15))
        let first = try XCTUnwrap(session.focus)
        XCTAssertEqual(session.hold(), first)
        XCTAssertNil(session.hold(), "the same measurement is kept once")
        session.move(to: CGPoint(x: 5, y: 20))
        let second = try XCTUnwrap(session.hold())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(session.held, [first, second])
        XCTAssertTrue(session.removeLastHeld())
        XCTAssertEqual(session.held, [first])
        // No keeping in the middle of a drag.
        session.press(at: CGPoint(x: 10, y: 5))
        XCTAssertNil(session.hold())
    }

    func testTheGapBesideTheButtonRunsToTheScreenEdge() throws {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        session.move(to: CGPoint(x: 10, y: 20))
        let live = try XCTUnwrap(session.live)
        XCTAssertEqual(live.horizontal, ScreenRulerSpan(lower: 0, upper: 40, reachesLowerBorder: true, reachesUpperBorder: false))
        XCTAssertEqual(ScreenRulerMeasurement.distances(live).size(in: .points).width, 20)
        XCTAssertEqual(session.pointerColorHex, "#FFFFFF")
    }

    func testArrowsMoveThePointerByOnePixelOfTheDisplayUnderIt() throws {
        let external = ScreenRulerCanvas(width: 200, height: 100).snapshot(id: 2, scale: 1, origin: CGPoint(x: 100, y: 0))
        var session = ScreenRulerSession(snapshots: [buttonScreen(), external], options: ScreenRulerOptions())
        // 2×: one pixel is half a point.
        session.move(to: CGPoint(x: 30, y: 15))
        XCTAssertEqual(session.nudgedPointer(dx: 1, dy: 0), CGPoint(x: 30.75, y: 15.25))
        XCTAssertEqual(session.nudgedPointer(dx: 0, dy: -10), CGPoint(x: 30.25, y: 10.25))
        // 1×: one pixel is a point.
        session.move(to: CGPoint(x: 150.2, y: 30.7))
        XCTAssertEqual(session.nudgedPointer(dx: 0, dy: -1), CGPoint(x: 150.5, y: 29.5))
        // Never past the display's edge.
        session.move(to: CGPoint(x: 299.5, y: 0.2))
        XCTAssertEqual(session.nudgedPointer(dx: 10, dy: -10), CGPoint(x: 299.5, y: 0.5))
    }

    func testADragKeepsToTheDisplayItStartedOn() throws {
        let external = ScreenRulerCanvas(width: 200, height: 100).snapshot(id: 2, scale: 1, origin: CGPoint(x: 100, y: 0))
        var session = ScreenRulerSession(snapshots: [buttonScreen(), external], options: ScreenRulerOptions())
        session.press(at: CGPoint(x: 90, y: 10))
        session.move(to: CGPoint(x: 150, y: 30))
        let drag = try XCTUnwrap(session.dragArea)
        XCTAssertEqual(drag.display.id, 1)
        XCTAssertEqual(drag.rect, ScreenRulerPixelRect(x: 180, y: 20, width: 20, height: 41))
        session.release(at: CGPoint(x: 150, y: 30))
        XCTAssertEqual(session.area?.display.id, 1)
        // Hovering then follows the pointer onto the other display.
        session.move(to: CGPoint(x: 150, y: 30))
        XCTAssertEqual(session.live?.display.id, 2)
        XCTAssertEqual(session.live?.horizontal.length, 200)
    }

    // MARK: - Drawing geometry

    func testTheCrosshairSitsOnThePixelGrid() throws {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        session.move(to: CGPoint(x: 30, y: 15))
        let live = try XCTUnwrap(session.live)
        let marks = ScreenRulerLayout.marks(for: live, unit: .points, showsBoth: false)
        // One device pixel thick (0.5 pt at 2×), over exactly the measured pixels.
        XCTAssertEqual(marks.lines[0], CGRect(x: 20, y: 15, width: 40, height: 0.5))
        XCTAssertEqual(marks.lines[1], CGRect(x: 30, y: 10, width: 0.5, height: 20))
        XCTAssertEqual(marks.lines.count, 6, "two lines and four end ticks")
        XCTAssertEqual(marks.lines[2], CGRect(x: 20, y: 12, width: 0.5, height: 7))
        XCTAssertEqual(marks.lines[3], CGRect(x: 59.5, y: 12, width: 0.5, height: 7))
        for rect in marks.lines {
            for value in [rect.minX, rect.minY, rect.width, rect.height] {
                XCTAssertEqual((value * 2).rounded(), value * 2, "\(rect) is on the 2× pixel grid")
            }
        }
        XCTAssertEqual(marks.labels.map(\.text), ["40 pt", "20 pt"])
        XCTAssertEqual(marks.labels[0].side, .above)
        XCTAssertEqual(marks.labels[1].side, .right)
        // Increase Contrast: two pixels thick.
        XCTAssertEqual(ScreenRulerLayout.marks(for: live, unit: .points, showsBoth: false, increasedContrast: true).lines[0].height, 1)
    }

    func testNoTickWhereARunReachesTheScreenEdge() throws {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        // Above the button: white to the left, right and top edges, the button below.
        session.move(to: CGPoint(x: 30, y: 2))
        let marks = ScreenRulerLayout.marks(for: try XCTUnwrap(session.live), unit: .pixels, showsBoth: false)
        XCTAssertEqual(marks.lines.count, 3, "two lines and the one tick at the edge found below the pointer")
        XCTAssertEqual(marks.labels.map(\.text), ["200 px", "20 px"])
    }

    func testABoxIsDashedWhileDraggingAndLabelledUnderneath() throws {
        var session = ScreenRulerSession(snapshots: [buttonScreen()], options: ScreenRulerOptions())
        session.press(at: CGPoint(x: 10, y: 5))
        session.move(to: CGPoint(x: 70, y: 40))
        let dragging = ScreenRulerLayout.marks(for: try XCTUnwrap(session.dragArea), dragging: true, unit: .points, showsBoth: true)
        XCTAssertTrue(dragging.dashed)
        XCTAssertEqual(dragging.box, CGRect(x: 10, y: 5, width: 60.5, height: 35.5))
        XCTAssertEqual(dragging.labels.first?.text, "60.5 × 35.5 pt · 121 × 71 px")
        session.release(at: CGPoint(x: 70, y: 40))
        let done = ScreenRulerLayout.marks(for: .area(try XCTUnwrap(session.area)), unit: .points, showsBoth: false)
        XCTAssertFalse(done.dashed)
        XCTAssertEqual(done.box, CGRect(x: 20, y: 10, width: 40, height: 20))
        XCTAssertEqual(done.labels, [ScreenRulerLabel(text: "40 × 20 pt", anchor: CGPoint(x: 40, y: 30), side: .below)])
    }

    func testLabelsFlipAwayFromTheDisplayEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        let size = CGSize(width: 30, height: 14)
        // Room above: it sits above, centred.
        XCTAssertEqual(ScreenRulerLayout.labelFrame(size: size, for: ScreenRulerLabel(text: "", anchor: CGPoint(x: 50, y: 30), side: .above), in: bounds),
                       CGRect(x: 35, y: 12, width: 30, height: 14))
        // No room above the top edge: it goes below.
        XCTAssertEqual(ScreenRulerLayout.labelFrame(size: size, for: ScreenRulerLabel(text: "", anchor: CGPoint(x: 50, y: 5), side: .above), in: bounds).minY, 9)
        // No room right of the right edge: it goes left.
        XCTAssertEqual(ScreenRulerLayout.labelFrame(size: size, for: ScreenRulerLabel(text: "", anchor: CGPoint(x: 90, y: 25), side: .right), in: bounds).minX, 56)
        // No room below the bottom: above. And always inside the display.
        XCTAssertEqual(ScreenRulerLayout.labelFrame(size: size, for: ScreenRulerLabel(text: "", anchor: CGPoint(x: 2, y: 48), side: .below), in: bounds),
                       CGRect(x: 0, y: 30, width: 30, height: 14))
    }
}
