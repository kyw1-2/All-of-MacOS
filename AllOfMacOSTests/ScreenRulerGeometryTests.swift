import CoreGraphics
import XCTest
@testable import AllOfMacOS

/// Points and pixels at 1×, 2× and 3×, and global → display → image on a
/// layout of displays with different scales.
final class ScreenRulerGeometryTests: XCTestCase {
    // A 1440×900 pt Retina primary, a 1920×1080 pt 1× display above and to
    // the right of it, and a 1280×800 pt 3× display to its left, lower down.
    private let primary = ScreenRulerDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    private let external = ScreenRulerDisplay(id: 2, frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080), scale: 1)
    private let left = ScreenRulerDisplay(id: 3, frame: CGRect(x: -1280, y: 100, width: 1280, height: 800), scale: 3)

    func testPointsAndPixelsAtOneTwoAndThreeTimes() {
        XCTAssertEqual(ScreenRulerGeometry.value(pixels: 240, scale: 1, unit: .points), 240)
        XCTAssertEqual(ScreenRulerGeometry.value(pixels: 240, scale: 2, unit: .points), 120)
        XCTAssertEqual(ScreenRulerGeometry.value(pixels: 240, scale: 3, unit: .points), 80)
        XCTAssertEqual(ScreenRulerGeometry.value(pixels: 241, scale: 2, unit: .points), 120.5)
        XCTAssertEqual(ScreenRulerGeometry.value(pixels: 100, scale: 3, unit: .points), 100.0 / 3, accuracy: 1e-9)
        for scale in [1, 2, 3] as [CGFloat] {
            XCTAssertEqual(ScreenRulerGeometry.value(pixels: 241, scale: scale, unit: .pixels), 241, "pixels never scale")
            XCTAssertEqual(ScreenRulerGeometry.pixels(fromPoints: ScreenRulerGeometry.points(fromPixels: 90, scale: scale),
                                                      scale: scale), 90, accuracy: 1e-9)
        }
        XCTAssertEqual(primary.pixelWidth, 2880)
        XCTAssertEqual(primary.pixelHeight, 1800)
        XCTAssertEqual(left.pixelWidth, 3840)
        XCTAssertEqual(external.pixelWidth, 1920)
    }

    func testAppKitPointsBecomeTopLeftGlobalPoints() {
        // NSEvent.mouseLocation counts up from the primary's bottom edge.
        XCTAssertEqual(ScreenRulerGeometry.globalPoint(fromAppKit: CGPoint(x: 100, y: 900), primaryHeight: 900), CGPoint(x: 100, y: 0))
        XCTAssertEqual(ScreenRulerGeometry.globalPoint(fromAppKit: CGPoint(x: 100, y: 0.5), primaryHeight: 900), CGPoint(x: 100, y: 899.5))
        XCTAssertEqual(ScreenRulerGeometry.appKitPoint(fromGlobal: CGPoint(x: 5, y: 899.5), primaryHeight: 900), CGPoint(x: 5, y: 0.5))
        // The external display's NSScreen frame (above the primary) in global points.
        let appKitExternal = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(ScreenRulerGeometry.globalRect(fromAppKit: appKitExternal, primaryHeight: 900),
                       CGRect(x: 1440, y: -180, width: 1920, height: 1080))
    }

    func testGlobalToDisplayToImageOnEveryDisplay() {
        let displays = [primary, external, left]
        // Primary, 2×: half points land on the next pixel.
        let p = CGPoint(x: 100.25, y: 50.75)
        XCTAssertEqual(ScreenRulerGeometry.display(containing: p, in: displays)?.id, 1)
        XCTAssertEqual(primary.localPoint(fromGlobal: p), p)
        XCTAssertEqual(primary.pixel(atGlobal: p), ScreenRulerPixel(x: 200, y: 101))
        // External, 1×, above the primary's top edge (negative global y).
        let e = CGPoint(x: 1500, y: -100)
        XCTAssertEqual(ScreenRulerGeometry.display(containing: e, in: displays)?.id, 2)
        XCTAssertEqual(external.localPoint(fromGlobal: e), CGPoint(x: 60, y: 80))
        XCTAssertEqual(external.pixel(atGlobal: e), ScreenRulerPixel(x: 60, y: 80))
        // Left, 3×, negative global x.
        let l = CGPoint(x: -1279.5, y: 100.4)
        XCTAssertEqual(ScreenRulerGeometry.display(containing: l, in: displays)?.id, 3)
        XCTAssertEqual(left.localPoint(fromGlobal: l).x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(left.localPoint(fromGlobal: l).y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(left.pixel(atGlobal: l), ScreenRulerPixel(x: 1, y: 1))
        // And back: a pixel boundary and a pixel centre as global points.
        XCTAssertEqual(left.globalPoint(fromLocal: left.localPoint(pixelX: 3, pixelY: 6)), CGPoint(x: -1279, y: 102))
        XCTAssertEqual(primary.globalCenter(of: ScreenRulerPixel(x: 200, y: 101)), CGPoint(x: 100.25, y: 50.75))
        XCTAssertEqual(external.globalCenter(of: ScreenRulerPixel(x: 60, y: 80)), CGPoint(x: 1500.5, y: -99.5))
        XCTAssertEqual(left.globalRect(ScreenRulerPixelRect(x: 3, y: 6, width: 30, height: 9)),
                       CGRect(x: -1279, y: 102, width: 10, height: 3))
    }

    func testDisplayEdgesAreHalfOpenAndPixelsStayInsideTheImage() {
        let displays = [primary, external, left]
        // The seam between the primary and the external display belongs to the external one.
        XCTAssertEqual(ScreenRulerGeometry.display(containing: CGPoint(x: 1440, y: 10), in: displays)?.id, 2)
        XCTAssertEqual(ScreenRulerGeometry.display(containing: CGPoint(x: 1439.9, y: 10), in: displays)?.id, 1)
        // A point in the gap below the external display goes to the nearest display.
        XCTAssertEqual(ScreenRulerGeometry.display(containing: CGPoint(x: 1500, y: 950), in: displays)?.id, 2)
        // The far edge clamps to the last pixel.
        XCTAssertEqual(primary.pixel(atGlobal: CGPoint(x: 1440, y: 900)), ScreenRulerPixel(x: 2879, y: 1799))
        XCTAssertEqual(primary.pixel(atGlobal: CGPoint(x: -5, y: -5)), ScreenRulerPixel(x: 0, y: 0))
        XCTAssertEqual(primary.clamped(CGPoint(x: 2000, y: -40)), CGPoint(x: 1439.75, y: 0))
        XCTAssertTrue(primary.contains(primary.clamped(CGPoint(x: 2000, y: 2000))))
    }

    func testPixelRectsSpanBothCornerPixelsAndClampToTheImage() {
        let rect = ScreenRulerPixelRect(spanning: ScreenRulerPixel(x: 30, y: 4), ScreenRulerPixel(x: 10, y: 20))
        XCTAssertEqual(rect, ScreenRulerPixelRect(x: 10, y: 4, width: 21, height: 17))
        XCTAssertEqual(rect.clamped(width: 25, height: 10), ScreenRulerPixelRect(x: 10, y: 4, width: 15, height: 6))
        XCTAssertTrue(rect.clamped(width: 5, height: 5).isEmpty)
        XCTAssertEqual(primary.localRect(ScreenRulerPixelRect(x: 3, y: 5, width: 240, height: 88)),
                       CGRect(x: 1.5, y: 2.5, width: 120, height: 44))
    }

    func testASnapshotTakesItsScaleFromTheCapturedImage() throws {
        // Asked for 2×, the image came back at 1×: the image decides.
        let bitmap = try XCTUnwrap(ScreenRulerBitmap(width: 100, height: 50, rgba: [UInt8](repeating: 255, count: 100 * 50 * 4)))
        let snapshot = ScreenRulerSnapshot(display: ScreenRulerDisplay(id: 9, frame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2),
                                           bitmap: bitmap)
        XCTAssertEqual(snapshot.display.scale, 1)
        XCTAssertEqual(snapshot.display.pixelWidth, 100)
        XCTAssertEqual(snapshot.display.pixelHeight, 50)
    }
}
