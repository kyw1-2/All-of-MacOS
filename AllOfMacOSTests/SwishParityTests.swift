import XCTest
@testable import AllOfMacOS

/// 3.3.2 Swish follow-ups: diagonal swipes straight to a quarter (from the
/// top half or a maximized window too), the swipe sensitivity, and the
/// settings that come with them. Pure: no trackpad, Accessibility or windows.
final class SwishParityTests: XCTestCase {
    /// Positions in the snap's pad coordinates (y toward the bottom of the
    /// pad); TouchPoint's y grows toward the top, so it is flipped.
    private func pair(_ x: Float, _ y: Float) -> [TouchPoint] {
        [TouchPoint(id: 1, x: x - 0.01, y: 1 - y, size: 1, pressure: 0),
         TouchPoint(id: 2, x: x + 0.01, y: 1 - y, size: 1, pressure: 0)]
    }

    /// On the glass a 45° swipe is equal legs; in pad units (wider than tall)
    /// the horizontal leg is 1.5 times shorter.
    func testADiagonalSwipeOnTheGlassIsAQuarter() {
        let downLeft = SwishSnap.diagonal(dx: -0.045, dy: 0.06, engage: 0.05)
        XCTAssertNotNil(downLeft)
        XCTAssertEqual(downLeft.map(SwishSnap.layout(for:)), .bottomLeft)
        XCTAssertEqual(SwishSnap.diagonal(dx: 0.05, dy: -0.06, engage: 0.05).map(SwishSnap.layout(for:)), .topRight)
        XCTAssertEqual(SwishSnap.diagonal(dx: 0.05, dy: 0.06, engage: 0.05).map(SwishSnap.layout(for:)), .bottomRight)
        XCTAssertEqual(SwishSnap.diagonal(dx: -0.05, dy: -0.05, engage: 0.05).map(SwishSnap.layout(for:)), .topLeft)
        // About 29° on the glass is a sideways swipe with some drift, not a diagonal.
        XCTAssertNil(SwishSnap.diagonal(dx: 0.06, dy: 0.05, engage: 0.05))
        // Straight swipes with a natural wobble stay halves (and too short is nothing).
        XCTAssertNil(SwishSnap.diagonal(dx: 0.08, dy: 0.012, engage: 0.05))
        XCTAssertNil(SwishSnap.diagonal(dx: 0.01, dy: 0.09, engage: 0.05))
        XCTAssertNil(SwishSnap.diagonal(dx: 0.03, dy: 0.03, engage: 0.05))
    }

    /// The reported bug, the other way round: from the top half or a
    /// maximized window a single ↙ / ↘ swipe reaches a bottom quarter.
    func testFromTheTopOrMaximizedADiagonalReachesABottomQuarter() {
        let downLeft = SwishSnap.diagonal(dx: -0.05, dy: 0.06, engage: 0.05)!
        let downRight = SwishSnap.diagonal(dx: 0.05, dy: 0.06, engage: 0.05)!
        for start: CustomSnapZone.Layout? in [.maximize, .topHalf, .topLeft, .topRight, .leftHalf, nil] {
            XCTAssertEqual(SwishSnap.move(from: start, stroke: downLeft, thirds: false), .cell(.bottomLeft), "\(String(describing: start))")
            XCTAssertEqual(SwishSnap.move(from: start, stroke: downRight, thirds: false), .cell(.bottomRight), "\(String(describing: start))")
        }
        // Through the full mapping (Swish defaults): a diagonal never minimizes a free window.
        XCTAssertEqual(SwishSnap.move(from: nil, stroke: downLeft, modifiers: [], options: .init()), .cell(.bottomLeft))
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: downRight, modifiers: [], options: .init()), .cell(.bottomRight))
        // A straight swipe down from maximized still puts the window back.
        XCTAssertEqual(SwishSnap.move(from: .maximize, stroke: .init(.down), thirds: false), .restore)
    }

    /// 3.3.1 left a swipe between the axes unrecognised: nothing happened.
    func testTheRecognizerEngagesADiagonalAndKeepsItsQuarter() {
        let recognizer = TitleBarSnapRecognizer()
        recognizer.settleTime = 0
        var begins: [SwishSnap.Stroke] = [], updates: [SwishSnap.Stroke] = []
        var commits = 0
        recognizer.onBegin = { begins.append($0) }
        recognizer.onUpdate = { updates.append($0) }
        recognizer.onCommit = { commits += 1 }
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.47, 0.53), timestamp: 0.02)
        recognizer.feed(contacts: pair(0.45, 0.555), timestamp: 0.04)   // −0.05, +0.055 in pad units
        recognizer.feed(contacts: pair(0.42, 0.59), timestamp: 0.06)
        recognizer.feed(contacts: pair(0.39, 0.62), timestamp: 0.08)
        recognizer.feed(contacts: [], timestamp: 0.30)
        XCTAssertEqual(begins.count, 1)
        XCTAssertEqual(begins.first.map(SwishSnap.layout(for:)), .bottomLeft)
        XCTAssertTrue(updates.allSatisfy { SwishSnap.layout(for: $0) == .bottomLeft }, "no flicker back to a half: \(updates)")
        XCTAssertEqual(commits, 1)
    }

    func testAStraightSwipeIsStillAHalf() {
        let recognizer = TitleBarSnapRecognizer()
        recognizer.settleTime = 0
        var begins: [SwishSnap.Stroke] = []
        recognizer.onBegin = { begins.append($0) }
        recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
        recognizer.feed(contacts: pair(0.44, 0.505), timestamp: 0.05)
        XCTAssertEqual(begins, [.init(.left)])
    }

    func testSensitivityScalesTheEngageDistances() {
        XCTAssertEqual(TitleBarWindowSnap.distances(sensitivity: 1).engage, 0.05, accuracy: 1e-6)
        XCTAssertEqual(TitleBarWindowSnap.distances(sensitivity: 1).crossEngage, 0.06, accuracy: 1e-6)
        let quick = TitleBarWindowSnap.distances(sensitivity: TitleBarWindowSnap.sensitivityDefault)
        XCTAssertEqual(quick.engage, 0.04, accuracy: 1e-6, "3.3.2 default: engages after 4 % of the pad")
        XCTAssertEqual(quick.crossEngage, 0.048, accuracy: 1e-6)
        XCTAssertEqual(TitleBarWindowSnap.distances(sensitivity: 9).engage, 0.025, accuracy: 1e-6, "clamped to 2")
        XCTAssertEqual(TitleBarWindowSnap.distances(sensitivity: 0.1).engage, 0.1, accuracy: 1e-6, "clamped to 0.5")
        XCTAssertEqual(TitleBarWindowSnap.distances(sensitivity: .nan).engage, 0.05, accuracy: 1e-6)

        let defaults = UserDefaults(suiteName: "aom.test.swish.\(UUID().uuidString)")!
        XCTAssertEqual(TitleBarWindowSnap.sensitivity(defaults), 1.25)
        defaults.set(7.0, forKey: TitleBarWindowSnap.sensitivityKey)
        XCTAssertEqual(TitleBarWindowSnap.sensitivity(defaults), 2)
        defaults.set(0.8, forKey: TitleBarWindowSnap.sensitivityKey)
        XCTAssertEqual(TitleBarWindowSnap.sensitivity(defaults), 0.8)
        XCTAssertTrue(PresetManager.isBackedUpSetting(TitleBarWindowSnap.sensitivityKey))
    }

    /// The same 4.5 % swipe: nothing at 3.3.1's distance, a snap at Quick.
    func testAQuickSensitivityEngagesSooner() {
        func begins(engage: Float) -> Int {
            let recognizer = TitleBarSnapRecognizer()
            recognizer.settleTime = 0
            recognizer.engage = engage
            var count = 0
            recognizer.onBegin = { _ in count += 1 }
            recognizer.feed(contacts: pair(0.50, 0.50), timestamp: 0)
            recognizer.feed(contacts: pair(0.545, 0.50), timestamp: 0.05)
            return count
        }
        XCTAssertEqual(begins(engage: TitleBarWindowSnap.distances(sensitivity: 1).engage), 0)
        XCTAssertEqual(begins(engage: TitleBarWindowSnap.distances(sensitivity: TitleBarWindowSnap.sensitivityDefault).engage), 1)
    }

    /// Thirds stay off by default, and with them off no swipe reaches one.
    func testThirdsAreOffByDefaultAndNeverReachedWhenOff() {
        let defaults = UserDefaults(suiteName: "aom.test.swish.thirds.\(UUID().uuidString)")!
        XCTAssertFalse(TitleBarWindowSnap.gestureOptions(defaults).thirds)
        for start: CustomSnapZone.Layout? in [nil, .leftHalf, .rightHalf, .maximize, .leftThird] {
            for stroke in [SwishSnap.Stroke(.left, tier: 2), SwishSnap.Stroke(.right, tier: 2), SwishSnap.Stroke(.left), SwishSnap.Stroke(.right)] {
                if case .cell(let layout) = SwishSnap.move(from: start, stroke: stroke, thirds: false) {
                    XCTAssertFalse(SwishSnap.isThird(layout), "\(String(describing: start)) + \(stroke) → \(layout)")
                }
            }
        }
    }
}
