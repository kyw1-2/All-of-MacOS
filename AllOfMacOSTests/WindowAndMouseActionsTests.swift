import XCTest
@testable import AllOfMacOS

/// The window geometry the new thirds, sixths and move actions rely on, plus
/// the classification of the mouse actions that synthesise pointer events.
final class WindowAndMouseActionsTests: XCTestCase {
    private let visible = CGRect(x: 100, y: 50, width: 1200, height: 800)

    private func frame(_ type: ActionType) -> CGRect {
        let w = visible.width, h = visible.height, x0 = visible.minX, y0 = visible.minY
        switch type {
        case .snapWindowLeftThird: return CGRect(x: x0, y: y0, width: w/3, height: h)
        case .snapWindowCenterThird: return CGRect(x: x0 + w/3, y: y0, width: w/3, height: h)
        case .snapWindowRightThird: return CGRect(x: x0 + w*2/3, y: y0, width: w/3, height: h)
        case .snapWindowLeftTwoThirds: return CGRect(x: x0, y: y0, width: w*2/3, height: h)
        case .snapWindowRightTwoThirds: return CGRect(x: x0 + w/3, y: y0, width: w*2/3, height: h)
        case .snapWindowTopLeftSixth: return CGRect(x: x0, y: y0, width: w/3, height: h/2)
        case .snapWindowTopCenterSixth: return CGRect(x: x0 + w/3, y: y0, width: w/3, height: h/2)
        case .snapWindowTopRightSixth: return CGRect(x: x0 + w*2/3, y: y0, width: w/3, height: h/2)
        case .snapWindowBottomLeftSixth: return CGRect(x: x0, y: y0 + h/2, width: w/3, height: h/2)
        case .snapWindowBottomCenterSixth: return CGRect(x: x0 + w/3, y: y0 + h/2, width: w/3, height: h/2)
        case .snapWindowBottomRightSixth: return CGRect(x: x0 + w*2/3, y: y0 + h/2, width: w/3, height: h/2)
        default: return .zero
        }
    }

    func testThirdsTileTheVisibleWidthExactly() {
        let left = frame(.snapWindowLeftThird)
        let center = frame(.snapWindowCenterThird)
        let right = frame(.snapWindowRightThird)
        XCTAssertEqual(left.maxX, center.minX, accuracy: 0.001)
        XCTAssertEqual(center.maxX, right.minX, accuracy: 0.001)
        XCTAssertEqual(right.maxX, visible.maxX, accuracy: 0.001)
        XCTAssertEqual(left.width, visible.width/3, accuracy: 0.001)
    }

    func testSixthsTileTheVisibleAreaWithoutGapsOrOverlap() {
        let all: [ActionType] = [.snapWindowTopLeftSixth, .snapWindowTopCenterSixth, .snapWindowTopRightSixth,
                                 .snapWindowBottomLeftSixth, .snapWindowBottomCenterSixth, .snapWindowBottomRightSixth]
        let frames = all.map(frame)
        for f in frames {
            XCTAssertEqual(f.width, visible.width/3, accuracy: 0.001)
            XCTAssertEqual(f.height, visible.height/2, accuracy: 0.001)
        }
        let area = frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, visible.width * visible.height, accuracy: 1)
        for (i, a) in frames.enumerated() {
            for b in frames[(i+1)...] {
                XCTAssertTrue(a.intersection(b).isNull || a.intersection(b).isEmpty,
                              "sixths must not overlap")
            }
        }
    }

    func testTwoThirdsAreComplementsOfTheOppositeThird() {
        XCTAssertEqual(frame(.snapWindowLeftTwoThirds).width, visible.width*2/3, accuracy: 0.001)
        XCTAssertEqual(frame(.snapWindowLeftTwoThirds).maxX,
                       frame(.snapWindowRightThird).minX, accuracy: 0.001)
        XCTAssertEqual(frame(.snapWindowRightTwoThirds).minX,
                       frame(.snapWindowLeftThird).maxX, accuracy: 0.001)
    }

    func testNewWindowActionsAllReportTheWindowManagementCategory() {
        let new: [ActionType] = [.snapWindowLeftThird, .snapWindowCenterThird, .snapWindowRightThird,
                                 .snapWindowLeftTwoThirds, .snapWindowRightTwoThirds,
                                 .snapWindowTopLeftSixth, .snapWindowTopCenterSixth, .snapWindowTopRightSixth,
                                 .snapWindowBottomLeftSixth, .snapWindowBottomCenterSixth, .snapWindowBottomRightSixth,
                                 .moveWindowLeft, .moveWindowRight, .moveWindowUp, .moveWindowDown,
                                 .bringWindowToFront, .maximizeWindowUnderCursor,
                                 .minimizeWindowUnderCursor, .closeWindowUnderCursor]
        for action in new { XCTAssertEqual(action.category, .windowManagement, action.rawValue) }
    }

    func testMouseActionsAreClassifiedAndEveryOneHasAnIcon() {
        let mouse = ActionType.allCases.filter { $0.category == .mouseActions }
        XCTAssertEqual(mouse.count, 14, "the mouse family is the 14 synthesised pointer actions")
        XCTAssertTrue(mouse.allSatisfy { !$0.iconName.isEmpty })
        XCTAssertEqual(Set(mouse).count, 14)
        for action in mouse { XCTAssertFalse(action.rawValue.isEmpty) }
    }

    func testEveryActionTypeBelongsToExactlyOneCategory() {
        // A new case must never fall through a switch: the category mapping is
        // exhaustive, so this fails loudly if one is added without a home.
        for action in ActionType.allCases {
            XCTAssertFalse(action.category.rawValue.isEmpty, action.rawValue)
        }
    }

    func testMouseParametersSurviveEncoding() throws {
        var parameters = ActionParameters()
        parameters.mouseX = 0.25
        parameters.mouseY = 0.75
        parameters.scrollAmount = 5
        let decoded = try JSONDecoder().decode(ActionParameters.self, from: JSONEncoder().encode(parameters))
        XCTAssertEqual(decoded.mouseX, 0.25)
        XCTAssertEqual(decoded.mouseY, 0.75)
        XCTAssertEqual(decoded.scrollAmount, 5)
    }
}
