import XCTest
@testable import AllOfMacOS

/// Swish-style title-bar two-finger snap. Pure recognition and geometry only —
/// no trackpad, Accessibility or overlay windows are touched.
final class TitleBarSnapTests: XCTestCase {
    private func touch(_ id: Int, _ x: Float, _ y: Float) -> TouchPoint {
        TouchPoint(id: id, x: x, y: y, size: 1, pressure: 0)
    }

    // MARK: Direction and tiers

    func testDirectionNeedsADominantAxisPastTheEngageDistance() {
        XCTAssertNil(SwishSnap.direction(dx: 0.03, dy: 0.0, engage: 0.05, ratio: 1.3), "too small")
        XCTAssertNil(SwishSnap.direction(dx: 0.08, dy: 0.07, engage: 0.05, ratio: 1.3), "too diagonal")
        XCTAssertEqual(SwishSnap.direction(dx: 0.10, dy: 0.0, engage: 0.05, ratio: 1.3), .right)
        XCTAssertEqual(SwishSnap.direction(dx: -0.10, dy: 0.02, engage: 0.05, ratio: 1.3), .left)
        // Trackpad Y grows downward, so dy > 0 feels like pulling the window down.
        XCTAssertEqual(SwishSnap.direction(dx: 0.0, dy: 0.12, engage: 0.05, ratio: 1.3), .down)
        XCTAssertEqual(SwishSnap.direction(dx: 0.01, dy: -0.12, engage: 0.05, ratio: 1.3), .up)
    }

    func testTierGrowsWithTheLongerSwipe() {
        XCTAssertEqual(SwishSnap.tier(dx: 0.10, dy: 0, tier2: 0.16), 1)
        XCTAssertEqual(SwishSnap.tier(dx: 0.18, dy: 0, tier2: 0.16), 2)
        XCTAssertEqual(SwishSnap.tier(dx: 0, dy: -0.20, tier2: 0.16), 2)
    }

    func testLayoutMapping() {
        XCTAssertEqual(SwishSnap.layout(for: .left, tier: 1), .leftHalf)
        XCTAssertEqual(SwishSnap.layout(for: .left, tier: 2), .leftThird)
        XCTAssertEqual(SwishSnap.layout(for: .right, tier: 1), .rightHalf)
        XCTAssertEqual(SwishSnap.layout(for: .right, tier: 2), .rightThird)
        XCTAssertEqual(SwishSnap.layout(for: .up, tier: 1), .maximize)
        XCTAssertEqual(SwishSnap.layout(for: .up, tier: 2), .topHalf)
        XCTAssertEqual(SwishSnap.layout(for: .down, tier: 1), .center)
        XCTAssertEqual(SwishSnap.layout(for: .down, tier: 2), .bottomHalf)
    }

    // MARK: Title-bar hit test and geometry

    func testTitleBarHitOnlyInsideTheTopBand() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)   // AX top-left
        XCTAssertTrue(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 400, y: 210), windowFrame: window))
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 400, y: 400), windowFrame: window), "body, not title bar")
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: CGPoint(x: 50, y: 210), windowFrame: window), "left of the window")
        XCTAssertFalse(SwishSnap.titleBarHit(pointerTopLeft: .zero, windowFrame: .zero))
    }

    func testTargetFrameAndMargin() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let left = SwishSnap.targetFrame(layout: .leftHalf, visible: visible, margin: 0)
        XCTAssertEqual(left, CGRect(x: 0, y: 25, width: 720, height: 875))
        let maxed = SwishSnap.targetFrame(layout: .maximize, visible: visible, margin: 8)
        XCTAssertEqual(maxed, CGRect(x: 8, y: 33, width: 1424, height: 859))
    }

    func testAccessibilityRectToAppKitFlipsTheOrigin() {
        let axRect = CGRect(x: 100, y: 50, width: 400, height: 300)   // top-left, 50 from the top
        let appKit = SwishSnap.appKitRect(axRect, primaryTop: 1000)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 650, width: 400, height: 300))
    }

    // MARK: Recognizer state machine

    func testRecognizerEngagesRefinesAndCommits() {
        let recognizer = TitleBarSnapRecognizer()
        var begins: [(SwishSnap.Direction, Int)] = []
        var updates: [(SwishSnap.Direction, Int)] = []
        var commits = 0, cancels = 0
        recognizer.onBegin = { begins.append(($0, $1)) }
        recognizer.onUpdate = { updates.append(($0, $1)) }
        recognizer.onCommit = { commits += 1 }
        recognizer.onCancel = { cancels += 1 }

        // Two fingers land, then slide right past the engage distance.
        recognizer.feed(contacts: [touch(1, 0.40, 0.50), touch(2, 0.42, 0.50)], timestamp: 0)
        recognizer.feed(contacts: [touch(1, 0.50, 0.50), touch(2, 0.52, 0.50)], timestamp: 0.02)
        XCTAssertEqual(begins.count, 1)
        XCTAssertEqual(begins.first?.0, .right); XCTAssertEqual(begins.first?.1, 1)

        // Slide further right → tier 2 (right third).
        recognizer.feed(contacts: [touch(1, 0.62, 0.50), touch(2, 0.64, 0.50)], timestamp: 0.04)
        XCTAssertEqual(updates.last?.1, 2)

        // Lift both fingers → commit once.
        recognizer.feed(contacts: [], timestamp: 0.06)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(cancels, 0)
    }

    func testRecognizerCancelsWhenFingersLiftBeforeEngaging() {
        let recognizer = TitleBarSnapRecognizer()
        var begins = 0, commits = 0, cancels = 0
        recognizer.onBegin = { _, _ in begins += 1 }
        recognizer.onCommit = { commits += 1 }
        recognizer.onCancel = { cancels += 1 }
        recognizer.feed(contacts: [touch(1, 0.50, 0.50), touch(2, 0.52, 0.50)], timestamp: 0)
        recognizer.feed(contacts: [touch(1, 0.505, 0.50), touch(2, 0.525, 0.50)], timestamp: 0.02) // barely moved
        recognizer.feed(contacts: [touch(1, 0.50, 0.50)], timestamp: 0.04)                          // one finger left
        XCTAssertEqual(begins, 0)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancels, 1)
    }

    func testThreeFingersNeverEngage() {
        let recognizer = TitleBarSnapRecognizer()
        var begins = 0
        recognizer.onBegin = { _, _ in begins += 1 }
        recognizer.feed(contacts: [touch(1, 0.4, 0.5), touch(2, 0.5, 0.5), touch(3, 0.6, 0.5)], timestamp: 0)
        recognizer.feed(contacts: [touch(1, 0.6, 0.5), touch(2, 0.7, 0.5), touch(3, 0.8, 0.5)], timestamp: 0.02)
        XCTAssertEqual(begins, 0)
    }
}
