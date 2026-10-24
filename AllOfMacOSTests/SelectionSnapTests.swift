import XCTest
@testable import AllOfMacOS

/// Smart snapping (CleanShot's selection snapping): edges within 6 pt of a
/// window or display edge stick to it; farther points are left alone.
final class SelectionSnapTests: XCTestCase {
    private let guides = SelectionGeometry.SnapGuides(rects: [CGRect(x: 100, y: 200, width: 400, height: 300),
                                                              CGRect(x: 0, y: 0, width: 1440, height: 900)])

    func testNearbyEdgesSnap() {
        XCTAssertEqual(SelectionGeometry.snapped(CGPoint(x: 104, y: 497), to: guides), CGPoint(x: 100, y: 500))
        XCTAssertEqual(SelectionGeometry.snapped(CGPoint(x: 1436, y: 3), to: guides), CGPoint(x: 1440, y: 0))
    }

    func testFarPointsAndEachAxisAreIndependent() {
        XCTAssertEqual(SelectionGeometry.snapped(CGPoint(x: 300, y: 350), to: guides), CGPoint(x: 300, y: 350))
        XCTAssertEqual(SelectionGeometry.snapped(CGPoint(x: 498, y: 350), to: guides), CGPoint(x: 500, y: 350))
    }

    func testNoGuidesMeansNoChange() {
        XCTAssertEqual(SelectionGeometry.snapped(CGPoint(x: 101, y: 1), to: .init()), CGPoint(x: 101, y: 1))
    }

    func testDefaultIsOn() {
        let key = "AOMCaptureSnapSelection"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(CaptureSettings.snapsSelection)
    }
}
