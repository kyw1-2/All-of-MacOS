import AppKit
import XCTest
@testable import AllOfMacOS

final class MenuShelfTests: XCTestCase {
    private func item(_ name: String, owner: String, index: Int) -> AOMMenuShelfItem {
        AOMMenuShelfItem(pid: pid_t(100 + index), ownerBundleID: owner,
                         ownerName: owner, title: name, axIdentifier: name,
                         ordinal: index)
    }

    func testPinnedItemsFirstAndSearchIsCaseInsensitive() {
        let a = item("Wi-Fi", owner: "com.apple.controlcenter", index: 0)
        let b = item("Capture", owner: "com.kyw.allofmacos", index: 1)
        let c = item("VPN", owner: "com.example.vpn", index: 2)
        XCTAssertEqual(AOMMenuShelfPolicy.ordered([a, b, c], pinned: [c.id], query: "").map(\.id).first, c.id)
        XCTAssertEqual(AOMMenuShelfPolicy.ordered([a, b, c], pinned: [], query: "vPn").map(\.id), [c.id])
        XCTAssertEqual(AOMMenuShelfPolicy.ordered([a, b, c, a], pinned: [], query: "").count, 3)
        XCTAssertEqual(AOMMenuShelfPolicy.ordered([a], pinned: [], query: "CONTROL").count, 1)
    }

    func testNotchHoverOnlyUsesTopCenterBand() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertTrue(AOMMenuShelfPolicy.safeHoverZone(CGPoint(x: 720, y: 895), screen: screen))
        XCTAssertFalse(AOMMenuShelfPolicy.safeHoverZone(CGPoint(x: 720, y: 700), screen: screen))
        XCTAssertFalse(AOMMenuShelfPolicy.safeHoverZone(CGPoint(x: 80, y: 895), screen: screen))
        XCTAssertFalse(AOMMenuShelfPolicy.safeHoverZone(CGPoint(x: 720, y: 905), screen: screen))
        XCTAssertFalse(AOMMenuShelfPolicy.safeHoverZone(CGPoint(x: 150, y: 150),
                                                       screen: CGRect(x: 0, y: 0, width: 200, height: 200)))
    }

}
