import XCTest
@testable import AllOfMacOS

/// Text Actions: where the bar goes (screen edges, the menu bar, several
/// displays) and how it pages.
final class TextActionsPlacementTests: XCTestCase {
    /// A 1440 × 900 main display with a 25 pt menu bar and a 70 pt Dock.
    private let main = TextActionScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
    /// A 1920 × 1080 display to the left (negative x).
    private let left = TextActionScreen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
    /// A display above the main one.
    private let above = TextActionScreen(frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
                                         visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 875))
    private let size = CGSize(width: 300, height: 32)

    private func origin(_ selection: CGRect, pointer: CGPoint?, position: TextActionBarPosition = .above,
                        screens: [TextActionScreen]? = nil) -> CGPoint? {
        let screens = screens ?? [main, left, above]
        guard let anchor = TextActionBarPlacement.anchor(selection: selection, pointer: pointer, screens: screens) else { return nil }
        return TextActionBarPlacement.origin(for: size, anchor: anchor, pointer: pointer, screens: screens, position: position)
    }

    func testAccessibilityRectsBecomeAppKitRects() {
        XCTAssertEqual(TextActionBarPlacement.appKitRect(CGRect(x: 100, y: 100, width: 50, height: 20), primaryHeight: 900),
                       CGRect(x: 100, y: 780, width: 50, height: 20))
        // A display above the main one has negative Accessibility y.
        XCTAssertEqual(TextActionBarPlacement.appKitRect(CGRect(x: 200, y: -500, width: 60, height: 18), primaryHeight: 900),
                       CGRect(x: 200, y: 1382, width: 60, height: 18))
    }

    func testTheBarSitsAboveTheSelectionCentredOnThePointer() {
        let selection = CGRect(x: 600, y: 400, width: 200, height: 18)
        XCTAssertEqual(origin(selection, pointer: CGPoint(x: 790, y: 405)), CGPoint(x: 640, y: 426))
        // The centre stays over the selection even when the pointer ran past its end.
        XCTAssertEqual(origin(selection, pointer: CGPoint(x: 830, y: 405)), CGPoint(x: 650, y: 426))
    }

    func testBelowWhenAsked() {
        let selection = CGRect(x: 600, y: 400, width: 200, height: 18)
        XCTAssertEqual(origin(selection, pointer: CGPoint(x: 700, y: 405), position: .below), CGPoint(x: 550, y: 360))
    }

    func testTheMenuBarIsNeverCovered() throws {
        // A selection in the first line under the menu bar: no room above, so below.
        let top = CGRect(x: 600, y: 858, width: 100, height: 14)
        let placed = try XCTUnwrap(origin(top, pointer: CGPoint(x: 650, y: 865)))
        XCTAssertEqual(placed.y, 858 - 8 - 32)
        XCTAssertLessThanOrEqual(placed.y + size.height, main.visibleFrame.maxY)
        // Even when neither side fits, the bar stays under the menu bar.
        let tall = CGRect(x: 600, y: 80, width: 100, height: 790)
        let squeezed = try XCTUnwrap(origin(tall, pointer: nil, screens: [main]))
        XCTAssertLessThanOrEqual(squeezed.y + size.height, main.visibleFrame.maxY - TextActionBarPlacement.margin)
        XCTAssertGreaterThanOrEqual(squeezed.y, main.visibleFrame.minY + TextActionBarPlacement.margin)
    }

    func testTheDockEdgeFlipsABarBelowToAbove() throws {
        let low = CGRect(x: 600, y: 80, width: 100, height: 14)
        let placed = try XCTUnwrap(origin(low, pointer: CGPoint(x: 650, y: 86), position: .below))
        XCTAssertEqual(placed.y, 80 + 14 + 8, "no room above the Dock: the bar goes above the text")
    }

    func testLeftAndRightEdgesKeepTheBarOnScreen() throws {
        let leftEdge = try XCTUnwrap(origin(CGRect(x: 2, y: 400, width: 40, height: 16), pointer: CGPoint(x: 10, y: 405)))
        XCTAssertEqual(leftEdge.x, TextActionBarPlacement.margin)
        let rightEdge = try XCTUnwrap(origin(CGRect(x: 1400, y: 400, width: 38, height: 16), pointer: CGPoint(x: 1430, y: 405)))
        XCTAssertEqual(rightEdge.x, 1440 - 300 - TextActionBarPlacement.margin)
    }

    func testABarWiderThanTheScreenStartsAtTheLeftMargin() {
        let tiny = TextActionScreen(frame: CGRect(x: 0, y: 0, width: 200, height: 400), visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 380))
        let anchor = CGRect(x: 50, y: 100, width: 20, height: 16)
        let placed = TextActionBarPlacement.origin(for: size, anchor: anchor, pointer: CGPoint(x: 60, y: 108), screens: [tiny], position: .above)
        XCTAssertEqual(placed.x, TextActionBarPlacement.margin)
    }

    func testTheDisplayToTheLeft() throws {
        let placed = try XCTUnwrap(origin(CGRect(x: -1900, y: 500, width: 80, height: 16), pointer: CGPoint(x: -1890, y: 505),
                                          position: .below))
        XCTAssertEqual(placed, CGPoint(x: -1920 + TextActionBarPlacement.margin, y: 500 - 8 - 32))
    }

    func testTheDisplayAbove() throws {
        // Accessibility gives (300, -400) for text 400 pt below the top of the display above.
        let selection = TextActionBarPlacement.appKitRect(CGRect(x: 300, y: -400, width: 120, height: 16), primaryHeight: 900)
        let placed = try XCTUnwrap(origin(selection, pointer: CGPoint(x: 360, y: selection.midY)))
        XCTAssertTrue(above.visibleFrame.contains(CGRect(origin: placed, size: size)), "the bar stays on the display above: \(placed)")
        XCTAssertEqual(placed.y, selection.maxY + 8)
    }

    func testThePointersDisplayWinsNearABorder() {
        let anchor = CGRect(x: -2, y: 400, width: 4, height: 16)
        XCTAssertEqual(TextActionBarPlacement.screen(for: anchor, pointer: CGPoint(x: -1, y: 405), screens: [main, left]), left)
        XCTAssertEqual(TextActionBarPlacement.screen(for: anchor, pointer: CGPoint(x: 1, y: 405), screens: [main, left]), main)
    }

    func testStaleBoundsFarFromThePointerAreIgnored() throws {
        // A window moved after the read: the bounds sit far from the pointer.
        let anchor = try XCTUnwrap(TextActionBarPlacement.anchor(selection: CGRect(x: 100, y: 100, width: 80, height: 16),
                                                                  pointer: CGPoint(x: 900, y: 600), screens: [main]))
        XCTAssertEqual(anchor.midX, 900, accuracy: 1)
        XCTAssertEqual(anchor.height, TextActionBarPlacement.lineHeight)
    }

    func testATallSelectionKeepsToThePointersLine() throws {
        let paragraph = CGRect(x: 100, y: 200, width: 600, height: 300)
        let anchor = try XCTUnwrap(TextActionBarPlacement.anchor(selection: paragraph, pointer: CGPoint(x: 400, y: 320), screens: [main]))
        XCTAssertEqual(anchor.minX, 100)
        XCTAssertEqual(anchor.width, 600)
        XCTAssertEqual(anchor.midY, 320, accuracy: 0.5)
    }

    func testNoBoundsUsesThePointerAndNothingGivesNothing() throws {
        let anchor = try XCTUnwrap(TextActionBarPlacement.anchor(selection: nil, pointer: CGPoint(x: 500, y: 500), screens: [main]))
        XCTAssertEqual(anchor.midX, 500, accuracy: 1)
        XCTAssertNil(TextActionBarPlacement.anchor(selection: nil, pointer: nil, screens: [main]))
        XCTAssertNil(TextActionBarPlacement.anchor(selection: CGRect(x: 5_000, y: 5_000, width: 10, height: 10), pointer: nil,
                                                   screens: [main]), "bounds on no display are not believed")
        XCTAssertNil(TextActionBarPlacement.anchor(selection: CGRect(x: 10, y: 10, width: 10, height: 0), pointer: nil,
                                                   screens: [main]), "zero height")
    }

    @MainActor
    func testSelectionToolbarIsAboveNativeStatusBarPopovers() {
        XCTAssertGreaterThanOrEqual(TextActionBarController.selectionPanelLevel.rawValue,
                                    NSWindow.Level.popUpMenu.rawValue,
                                    "ChatGPT's native selection menu must not cover the AOM toolbar")
        XCTAssertGreaterThan(TextActionBarController.selectionPanelLevel.rawValue,
                             NSWindow.Level.statusBar.rawValue)
    }

    func testPaging() {
        XCTAssertEqual(TextActionBarPaging.pages(widths: [40, 40, 40], maxWidth: 300, chevron: 24), [0..<3])
        XCTAssertEqual(TextActionBarPaging.pages(widths: Array(repeating: 40, count: 12), maxWidth: 300, chevron: 24), [0..<6, 6..<12])
        XCTAssertEqual(TextActionBarPaging.pages(widths: Array(repeating: 40, count: 20), maxWidth: 300, chevron: 24),
                       [0..<6, 6..<12, 12..<18, 18..<20], "middle pages leave room for both chevrons")
        XCTAssertEqual(TextActionBarPaging.pages(widths: [500, 40], maxWidth: 300, chevron: 24), [0..<1, 1..<2],
                       "an item wider than the bar still gets a page")
        XCTAssertEqual(TextActionBarPaging.pages(widths: [], maxWidth: 300, chevron: 24), [])
    }
}
