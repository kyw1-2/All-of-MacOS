import XCTest
@testable import AllOfMacOS

/// 3.3.2: the rest of Swish 1.13's snapping options — the 3 × 2 and 3 × 3
/// grids, almost maximize, the ⌃⌥ hotkeys, drag to unsnap, re-snapping after
/// display changes, the Stage Manager offset, resizing adjacent windows and
/// the preview animation speed. Pure: no trackpad, Accessibility or windows.
final class SwishSnapGridTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    private func step(_ from: SwishSnap.Place?, _ direction: SwishSnap.Direction, _ grid: SwishSnap.Grid,
                      almost: Bool = false, tier: Int = 1) -> SwishSnap.Move {
        SwishSnap.step(from: from, stroke: .init(direction, tier: tier), grid: grid, almost: almost)
    }

    private func at(_ layout: CustomSnapZone.Layout) -> SwishSnap.Place { SwishSnap.Place(layout)! }
    private func at(_ cell: SwishGridCell) -> SwishSnap.Place { .grid(cell) }
    private func to(_ cell: SwishGridCell) -> SwishSnap.Move { .to(.grid(cell)) }

    private func assertRect(_ rect: CGRect?, _ expected: CGRect, accuracy: CGFloat = 0.001,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let rect else { return XCTFail("nil rect", file: file, line: line) }
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Grid cells

    func testCellsAreKeptInLowestTermsAndConvertToLayouts() {
        XCTAssertEqual(SwishGridCell(columns: 2, rows: 2, column: 0, row: 0, rowSpan: 2), SwishGridCell(.leftHalf))
        XCTAssertEqual(SwishGridCell.ninth(0, 0, rowSpan: 3), SwishGridCell(.leftThird), "three ninths stacked are a third")
        XCTAssertEqual(SwishGridCell.sixth(1, 0, columnSpan: 2).layout, nil)
        XCTAssertEqual(SwishGridCell(columns: 3, rows: 2, column: 1, row: 0, columnSpan: 2, rowSpan: 2).layout, .rightTwoThirds)
        XCTAssertEqual(SwishGridCell(columns: 4, rows: 4, column: 0, row: 0, columnSpan: 4, rowSpan: 4), .full)
        for layout in CustomSnapZone.Layout.allCases {
            guard let cell = SwishGridCell(layout) else {
                XCTAssertTrue([.center, .nextDisplay].contains(layout), "\(layout)")
                continue
            }
            XCTAssertEqual(cell.layout, layout, "\(layout) round trip")
            XCTAssertEqual(SwishSnap.targetFrame(place: .grid(cell), visible: visible, margin: 8),
                           SwishSnap.targetFrame(layout: layout, visible: visible, margin: 8), "\(layout)")
        }
        XCTAssertEqual(SwishSnap.Place(.center), .center)
        XCTAssertNil(SwishSnap.Place(.nextDisplay))
        // Out of range positions are clamped into the grid.
        XCTAssertEqual(SwishGridCell(columns: 3, rows: 2, column: 5, row: -1), .sixth(2, 0))
    }

    func testSixthAndNinthFrames() {
        assertRect(SwishSnap.targetFrame(place: .grid(.sixth(1, 1)), visible: visible, margin: 0),
                   CGRect(x: 480, y: 462.5, width: 480, height: 437.5))
        assertRect(SwishSnap.targetFrame(place: .grid(.sixth(1, 1)), visible: visible, margin: 8),
                   CGRect(x: 488, y: 470.5, width: 464, height: 421.5))
        assertRect(SwishSnap.targetFrame(place: .grid(.ninth(2, 2)), visible: visible, margin: 0),
                   CGRect(x: 960, y: 25 + 875.0 * 2 / 3, width: 480, height: 875.0 / 3))
        assertRect(SwishSnap.targetFrame(place: .grid(.ninth(0, 0, columnSpan: 2, rowSpan: 2)), visible: visible, margin: 0),
                   CGRect(x: 0, y: 25, width: 960, height: 875.0 * 2 / 3))
    }

    func testEachGridListsItsCellsSmallestFirst() {
        XCTAssertEqual(SwishSnap.Grid.twoByTwo.cells.count, 9, "halves, quarters, maximize")
        XCTAssertEqual(SwishSnap.Grid.threeByTwo.cells.count, 24, "plus thirds, two thirds, sixths and two sixths")
        XCTAssertEqual(SwishSnap.Grid.threeByThree.cells.count, 44, "plus thirds, ninths and their spans")
        for grid in SwishSnap.Grid.allCases {
            let areas = grid.cells.map(\.area)
            XCTAssertEqual(areas, areas.sorted(), "\(grid)")
            XCTAssertEqual(grid.cells.last, .full)
            XCTAssertTrue(grid.cells.allSatisfy(grid.contains), "\(grid)")
        }
        XCTAssertFalse(SwishSnap.Grid.twoByTwo.contains(SwishGridCell(.leftThird)!))
        XCTAssertFalse(SwishSnap.Grid.threeByTwo.contains(.ninth(0, 0)))
        XCTAssertFalse(SwishSnap.Grid.threeByThree.contains(.sixth(0, 0)))
        XCTAssertTrue(SwishSnap.Grid.threeByThree.contains(SwishGridCell(.topLeft)!), "quarters are in every grid")
    }

    func testEveryCellIsRecognisedFromItsFrame() {
        for grid in SwishSnap.Grid.allCases {
            for margin: CGFloat in [0, 8] {
                for cell in grid.cells {
                    let frame = SwishSnap.targetFrame(place: .grid(cell), visible: visible, margin: margin)
                    XCTAssertEqual(SwishSnap.place(of: frame.offsetBy(dx: 5, dy: -4), visible: visible, margin: margin, grid: grid),
                                   .grid(cell), "\(grid) \(cell) margin \(margin)")
                }
            }
        }
        // A sixth is free-floating in the 2 × 2 grid, a ninth in 3 × 2.
        let sixth = SwishSnap.targetFrame(place: .grid(.sixth(0, 0)), visible: visible, margin: 0)
        XCTAssertNil(SwishSnap.place(of: sixth, visible: visible, margin: 0, grid: .twoByTwo))
        let ninth = SwishSnap.targetFrame(place: .grid(.ninth(1, 1)), visible: visible, margin: 0)
        XCTAssertNil(SwishSnap.place(of: ninth, visible: visible, margin: 0, grid: .threeByTwo))
        // The minimum-size fallback still finds a quarter a large window hangs from.
        XCTAssertEqual(SwishSnap.place(of: CGRect(x: 0, y: 25, width: 720, height: 600), visible: visible, margin: 0,
                                       grid: .threeByThree), at(.topLeft))
    }

    // MARK: 3 × 2: thirds and sixths

    /// N337: down takes the lower half of a third; up maximizes (3.3.2–3.3.6:
    /// the upper sixth).
    func testThirdsSwipedVerticallyTakeTheirUpperOrLowerHalf() {
        XCTAssertEqual(step(at(.leftThird), .up, .threeByTwo), .cell(.maximize))
        XCTAssertEqual(step(at(.leftThird), .down, .threeByTwo), to(.sixth(0, 1)))
        XCTAssertEqual(step(at(.centerThird), .up, .threeByTwo), .cell(.maximize))
        XCTAssertEqual(step(at(.rightThird), .down, .threeByTwo), to(.sixth(2, 1)))
        XCTAssertEqual(step(at(.leftTwoThirds), .up, .threeByTwo), .cell(.maximize))
        XCTAssertEqual(step(at(.rightTwoThirds), .down, .threeByTwo), to(.sixth(1, 1, columnSpan: 2)))
        // Halves still become bottom quarters, and sideways the 3.3.1 table holds.
        XCTAssertEqual(step(at(.leftHalf), .down, .threeByTwo), .cell(.bottomLeft))
        XCTAssertEqual(step(at(.leftHalf), .up, .threeByTwo), .cell(.maximize))
        XCTAssertEqual(step(at(.leftHalf), .left, .threeByTwo), .cell(.leftThird))
        XCTAssertEqual(step(at(.leftThird), .left, .threeByTwo), .cell(.leftTwoThirds))
        XCTAssertEqual(step(at(.leftTwoThirds), .right, .threeByTwo), .cell(.rightHalf))
    }

    func testSixthsMoveBetweenCellsAndGrowTowardAnEdge() {
        XCTAssertEqual(step(at(.sixth(0, 0)), .down, .threeByTwo), to(.sixth(0, 1)))
        XCTAssertEqual(step(at(.sixth(0, 1)), .up, .threeByTwo), .cell(.maximize), "N337")
        XCTAssertEqual(step(at(.sixth(0, 0)), .right, .threeByTwo), to(.sixth(1, 0)))
        XCTAssertEqual(step(at(.sixth(1, 0)), .right, .threeByTwo), to(.sixth(2, 0)))
        XCTAssertEqual(step(at(.sixth(2, 0)), .left, .threeByTwo), to(.sixth(1, 0)))
        // Toward a side edge: the whole column (its third).
        XCTAssertEqual(step(at(.sixth(0, 0)), .left, .threeByTwo), .cell(.leftThird))
        XCTAssertEqual(step(at(.sixth(2, 1)), .right, .threeByTwo), .cell(.rightThird))
        // Down toward the bottom edge: one cell wider; N337: never the whole
        // bottom half (the window is put back instead). Up maximizes.
        XCTAssertEqual(step(at(.sixth(0, 1)), .down, .threeByTwo), to(.sixth(0, 1, columnSpan: 2)))
        XCTAssertEqual(step(at(.sixth(2, 1)), .down, .threeByTwo), to(.sixth(1, 1, columnSpan: 2)))
        XCTAssertEqual(step(at(.sixth(0, 1, columnSpan: 2)), .down, .threeByTwo), .restore)
        XCTAssertEqual(step(at(.sixth(1, 1)), .down, .threeByTwo), .restore, "the middle of an edge would span it")
        XCTAssertEqual(step(at(.sixth(0, 0)), .up, .threeByTwo), .cell(.maximize))
        XCTAssertEqual(step(at(.sixth(1, 0)), .up, .threeByTwo), .cell(.maximize))
        XCTAssertEqual(step(at(.topHalf), .up, .threeByTwo), .cell(.maximize))
        XCTAssertEqual(step(at(.bottomHalf), .down, .threeByTwo), .restore)
        // Two sixths side by side.
        XCTAssertEqual(step(at(.sixth(0, 0, columnSpan: 2)), .right, .threeByTwo), to(.sixth(1, 0, columnSpan: 2)))
        XCTAssertEqual(step(at(.sixth(1, 0, columnSpan: 2)), .right, .threeByTwo), .cell(.rightTwoThirds))
        XCTAssertEqual(step(at(.sixth(0, 0, columnSpan: 2)), .left, .threeByTwo), .cell(.leftTwoThirds))
        XCTAssertEqual(step(at(.sixth(0, 0, columnSpan: 2)), .down, .threeByTwo), to(.sixth(0, 1, columnSpan: 2)))
        XCTAssertEqual(step(at(.sixth(0, 1, columnSpan: 2)), .up, .threeByTwo), .cell(.maximize))
        // An L-shape still picks a quarter outright.
        XCTAssertEqual(SwishSnap.step(from: at(.sixth(1, 1)), stroke: .init(.left, cross: .up), grid: .threeByTwo), .cell(.topLeft))
    }

    // MARK: 3 × 3: ninths, two-ninths and four-ninths

    /// N337: down steps through the rows; up maximizes from every ninth.
    func testThirdsSwipedVerticallyBecomeNinthsAndNinthsStepThroughTheRows() {
        XCTAssertEqual(step(at(.leftThird), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(.leftThird), .down, .threeByThree), to(.ninth(0, 2)))
        XCTAssertEqual(step(at(.centerThird), .down, .threeByThree), to(.ninth(1, 2)))
        XCTAssertEqual(step(at(.leftTwoThirds), .down, .threeByThree), to(.ninth(0, 2, columnSpan: 2)))
        XCTAssertEqual(step(at(.ninth(0, 0)), .down, .threeByThree), to(.ninth(0, 1)))
        XCTAssertEqual(step(at(.ninth(0, 1)), .down, .threeByThree), to(.ninth(0, 2)))
        XCTAssertEqual(step(at(.ninth(0, 2)), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(.ninth(1, 1)), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(.ninth(1, 1)), .left, .threeByThree), to(.ninth(0, 1)))
        // Free windows and halves behave as on every grid.
        XCTAssertEqual(step(nil, .left, .threeByThree, tier: 2), .cell(.leftThird))
        XCTAssertEqual(step(at(.leftHalf), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(.leftHalf), .down, .threeByThree), .cell(.bottomLeft))
        XCTAssertEqual(step(at(.leftHalf), .left, .threeByThree), .cell(.leftThird))
    }

    func testANinthGrowsToTwoNinthsThenFourNinths() {
        // Toward the edge it touches: one cell along it (N337: up maximizes,
        // so only the bottom edge and the sides)…
        XCTAssertEqual(step(at(.ninth(0, 0)), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(.ninth(0, 2)), .down, .threeByThree), to(.ninth(0, 2, columnSpan: 2)))
        XCTAssertEqual(step(at(.ninth(0, 0)), .left, .threeByThree), to(.ninth(0, 0, rowSpan: 2)))
        // …then toward the other edge: four-ninths, whichever came first.
        XCTAssertEqual(step(at(.ninth(0, 0, columnSpan: 2)), .left, .threeByThree), to(.ninth(0, 0, columnSpan: 2, rowSpan: 2)))
        XCTAssertEqual(step(at(.ninth(0, 1, rowSpan: 2)), .down, .threeByThree), to(.ninth(0, 1, columnSpan: 2, rowSpan: 2)))
        XCTAssertEqual(step(at(.ninth(2, 2)), .down, .threeByThree), to(.ninth(1, 2, columnSpan: 2)))
        XCTAssertEqual(step(at(.ninth(1, 2, columnSpan: 2)), .right, .threeByThree), to(.ninth(1, 1, columnSpan: 2, rowSpan: 2)))
        // Four-ninths move a cell, and grow on into two thirds.
        let fourNinths = at(.ninth(0, 0, columnSpan: 2, rowSpan: 2))
        XCTAssertEqual(step(fourNinths, .right, .threeByThree), to(.ninth(1, 0, columnSpan: 2, rowSpan: 2)))
        XCTAssertEqual(step(fourNinths, .down, .threeByThree), to(.ninth(0, 1, columnSpan: 2, rowSpan: 2)))
        XCTAssertEqual(step(fourNinths, .left, .threeByThree), .cell(.leftTwoThirds))
        let topTwoThirds = SwishGridCell(columns: 1, rows: 3, column: 0, row: 0, rowSpan: 2)
        XCTAssertEqual(step(fourNinths, .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(topTwoThirds), .up, .threeByThree), .cell(.maximize))
        // A middle cell spans the edge; a row of the grid moves and splits.
        let topRow = SwishGridCell(columns: 1, rows: 3, column: 0, row: 0)
        XCTAssertEqual(step(at(.ninth(1, 2)), .down, .threeByThree), to(topRow.shifted(rows: 2)))
        XCTAssertEqual(step(at(.ninth(1, 0)), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(.ninth(0, 1)), .left, .threeByThree), .cell(.leftThird))
        XCTAssertEqual(step(at(topRow), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(topRow), .down, .threeByThree), to(topRow.shifted(rows: 1)))
        XCTAssertEqual(step(at(topRow.shifted(rows: 1)), .left, .threeByThree), to(.ninth(0, 1)))
        XCTAssertEqual(step(at(topRow.shifted(rows: 2)), .down, .threeByThree), .restore)
    }

    /// Whatever a swipe does, it lands on a cell of the grid in use, so 2 × 2
    /// never reaches a third and 3 × 2 never a ninth.
    func testEveryStepStaysInItsGrid() {
        for grid in SwishSnap.Grid.allCases {
            for almost in [false, true] {
                let starts: [SwishSnap.Place?] = [nil, .center, .almostMaximize] + grid.cells.map { .grid($0) }
                for start in starts {
                    for direction: SwishSnap.Direction in [.left, .right, .up, .down] {
                        for tier in [1, 2] {
                            let move = step(start, direction, grid, almost: almost, tier: tier)
                            guard let place = move.destination else { continue }
                            XCTAssertTrue(SwishSnap.usable(place, grid: grid, almost: almost),
                                          "\(grid) almost \(almost): \(String(describing: start)) \(direction)\(tier) → \(place)")
                            if grid == .twoByTwo { XCTAssertFalse(SwishSnap.isThird(place), "\(place)") }
                        }
                    }
                }
            }
        }
    }

    func testCellsFromAnotherGridAreFreeFloating() {
        XCTAssertEqual(step(at(.sixth(0, 0)), .left, .twoByTwo), .cell(.leftHalf))
        XCTAssertEqual(step(at(.sixth(0, 0)), .up, .threeByThree), .cell(.maximize))
        XCTAssertEqual(step(at(.ninth(0, 0)), .left, .threeByTwo), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.move(at: at(.sixth(0, 0)), stroke: .init(.down), modifiers: [], options: .init()),
                       .action(.minimize), "a sixth left from 3 × 2 minimizes in 2 × 2, like a free window")
        let sixths = SwishSnap.GestureOptions(grid: .threeByTwo)
        XCTAssertEqual(SwishSnap.move(at: at(.sixth(0, 0)), stroke: .init(.down), modifiers: [], options: sixths),
                       to(.sixth(0, 1)))
    }

    func testMovesNameTheirLayoutWhenTheyHaveOne() {
        XCTAssertEqual(SwishSnap.Move.to(.grid(SwishGridCell(.leftHalf)!)), .cell(.leftHalf))
        XCTAssertEqual(SwishSnap.Move.to(.center), .cell(.center))
        XCTAssertEqual(SwishSnap.Move.to(.almostMaximize), .place(.almostMaximize))
        XCTAssertEqual(SwishSnap.Move.cell(.topLeft).destination, .grid(SwishGridCell(.topLeft)!))
        XCTAssertNil(SwishSnap.Move.restore.destination)
    }

    func testGestureOptionsKeepTheThirdsSwitch() {
        XCTAssertEqual(SwishSnap.GestureOptions().grid, .twoByTwo)
        XCTAssertEqual(SwishSnap.GestureOptions(thirds: true).grid, .threeByTwo)
        var options = SwishSnap.GestureOptions(grid: .threeByThree)
        XCTAssertTrue(options.thirds)
        options.thirds = true
        XCTAssertEqual(options.grid, .threeByThree, "turning thirds on keeps a grid that has them")
        options.thirds = false
        XCTAssertEqual(options.grid, .twoByTwo)
    }

    // MARK: Almost maximize

    func testAlmostMaximizeLeavesAboutThreePercentAndAtLeastSixteenPoints() {
        assertRect(SwishSnap.almostMaximizeFrame(visible: visible, margin: 0),
                   CGRect(x: 43.2, y: 51.25, width: 1353.6, height: 822.5))
        let small = CGRect(x: 0, y: 25, width: 400, height: 300)
        assertRect(SwishSnap.almostMaximizeFrame(visible: small, margin: 0), CGRect(x: 16, y: 41, width: 368, height: 268))
        assertRect(SwishSnap.almostMaximizeFrame(visible: small, margin: 24), CGRect(x: 24, y: 49, width: 352, height: 252))
        let frame = SwishSnap.almostMaximizeFrame(visible: visible, margin: 0)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.001)
        XCTAssertEqual(SwishSnap.targetFrame(place: .almostMaximize, visible: visible, margin: 0), frame)
    }

    /// The choice for "swipe up again": almost maximize, then maximize (a
    /// second swipe up never goes to the top half or a sixth).
    func testSwipingUpAlmostMaximizesThenMaximizes() {
        XCTAssertEqual(step(nil, .up, .twoByTwo, almost: true), .place(.almostMaximize))
        XCTAssertEqual(step(.almostMaximize, .up, .twoByTwo, almost: true), .cell(.maximize))
        XCTAssertEqual(step(at(.maximize), .up, .twoByTwo, almost: true), .cell(.maximize))
        XCTAssertEqual(step(.almostMaximize, .up, .threeByTwo, almost: true), .cell(.maximize), "in 3 × 2 too")
        XCTAssertEqual(step(at(.topHalf), .up, .threeByTwo, almost: true), .place(.almostMaximize))
        XCTAssertEqual(step(at(.bottomRight), .up, .twoByTwo, almost: true), .place(.almostMaximize), "N337")
        XCTAssertEqual(step(at(SwishGridCell(columns: 1, rows: 3, column: 0, row: 0)), .up, .threeByThree, almost: true),
                       .place(.almostMaximize))
        XCTAssertEqual(step(nil, .up, .twoByTwo, almost: true, tier: 2), .place(.almostMaximize),
                       "N334: a longer swipe almost-maximizes too, never the top half")
        XCTAssertEqual(step(.almostMaximize, .down, .twoByTwo, almost: true), .restore)
        XCTAssertEqual(step(.almostMaximize, .left, .twoByTwo, almost: true), .cell(.leftHalf))
        XCTAssertEqual(step(.almostMaximize, .right, .threeByThree, almost: true), .cell(.rightHalf))
        // Off: a remembered almost-maximize is free-floating, and up maximizes.
        XCTAssertEqual(step(nil, .up, .twoByTwo), .cell(.maximize))
        XCTAssertEqual(step(.almostMaximize, .up, .twoByTwo), .cell(.maximize))
        let almost = SwishSnap.GestureOptions(almostMaximize: true)
        XCTAssertEqual(SwishSnap.move(at: .almostMaximize, stroke: .init(.down), modifiers: [], options: almost), .restore,
                       "an almost-maximized window is snapped: down puts it back instead of minimizing")
        XCTAssertEqual(SwishSnap.move(at: .almostMaximize, stroke: .init(.down), modifiers: [], options: .init()),
                       .action(.minimize))
    }

    func testAnAlmostMaximizedWindowIsRecognised() {
        let frame = SwishSnap.almostMaximizeFrame(visible: visible, margin: 0)
        XCTAssertEqual(SwishSnap.place(of: frame, visible: visible, margin: 0, grid: .twoByTwo, almost: true), .almostMaximize)
        XCTAssertNil(SwishSnap.place(of: frame, visible: visible, margin: 0, grid: .twoByTwo, almost: false))
        // On a small display the two frames are 16 pt apart: each keeps its own.
        let small = CGRect(x: 0, y: 25, width: 400, height: 300)
        XCTAssertEqual(SwishSnap.place(of: small, visible: small, margin: 0, grid: .twoByTwo, almost: true), at(.maximize))
        XCTAssertEqual(SwishSnap.place(of: SwishSnap.almostMaximizeFrame(visible: small, margin: 0), visible: small, margin: 0,
                                       grid: .twoByTwo, almost: true), .almostMaximize)
    }

    // MARK: Keyboard hotkeys

    func testHotkeysMapTheirKeysToSwipes() {
        let chord: NSEvent.ModifierFlags = [.control, .option]
        func direction(_ key: UInt16, _ scheme: SwishSnap.HotkeyScheme,
                       _ flags: NSEvent.ModifierFlags = [.control, .option]) -> SwishSnap.Direction? {
            SwishSnap.hotkeyDirection(keyCode: key, modifiers: flags, scheme: scheme)
        }
        XCTAssertEqual(direction(123, .arrows), .left)
        XCTAssertEqual(direction(124, .arrows), .right)
        XCTAssertEqual(direction(126, .arrows), .up)
        XCTAssertEqual(direction(125, .arrows), .down)
        XCTAssertEqual(direction(125, .arrows, chord.union([.function, .numericPad])), .down, "arrow keys carry fn")
        XCTAssertEqual(direction(13, .wasd), .up)
        XCTAssertEqual(direction(0, .wasd), .left)
        XCTAssertEqual(direction(1, .wasd), .down)
        XCTAssertEqual(direction(2, .wasd), .right)
        XCTAssertEqual(direction(34, .ijkl), .up)
        XCTAssertEqual(direction(38, .ijkl), .left)
        XCTAssertEqual(direction(40, .ijkl), .down)
        XCTAssertEqual(direction(37, .ijkl), .right)
        XCTAssertEqual(direction(4, .hjkl), .left)
        XCTAssertEqual(direction(38, .hjkl), .down)
        XCTAssertEqual(direction(40, .hjkl), .up)
        XCTAssertEqual(direction(37, .hjkl), .right)
        XCTAssertNil(direction(123, .off))
        XCTAssertNil(direction(123, .wasd), "another scheme's key")
        XCTAssertNil(direction(123, .arrows, [.control]), "⌃ alone is Mission Control's")
        XCTAssertNil(direction(123, .arrows, [.control, .option, .command]))
        XCTAssertNil(direction(123, .arrows, [.control, .option, .shift]))
        XCTAssertNil(direction(31, .arrows))
    }

    // MARK: Drag to unsnap

    func testDragToUnsnapRestoresTheSizeUnderThePointer() {
        let snapped = CGRect(x: 720, y: 25, width: 720, height: 875)            // right half
        let original = CGSize(width: 800, height: 600)
        // Grabbed a quarter of the way along the title bar, 15 pt below the top.
        let frame = SwishSnap.unsnapDragFrame(snapped: snapped, original: original,
                                              grab: CGPoint(x: 900, y: 40), pointer: CGPoint(x: 1000, y: 60))
        XCTAssertEqual(frame, CGRect(x: 800, y: 45, width: 800, height: 600))
        XCTAssertEqual((CGFloat(1000) - frame.minX) / frame.width, 0.25, accuracy: 1e-9, "same share of the title bar")
        // The ends of the title bar stay the ends; a grab outside is clamped.
        XCTAssertEqual(SwishSnap.unsnapDragFrame(snapped: snapped, original: original, grab: CGPoint(x: 720, y: 30),
                                                 pointer: CGPoint(x: 700, y: 30)).minX, 700)
        XCTAssertEqual(SwishSnap.unsnapDragFrame(snapped: snapped, original: original, grab: CGPoint(x: 2000, y: 30),
                                                 pointer: CGPoint(x: 1500, y: 30)).maxX, 1500)
    }

    // MARK: Re-snapping after display changes

    func testResnapPutsAWindowBackInItsPlaceOnTheDisplayItIsNowOn() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A right half from a display that went away, moved by macOS onto the main one.
        XCTAssertEqual(SwishSnap.resnapFrame(place: at(.rightHalf), current: CGRect(x: 300, y: 100, width: 960, height: 800),
                                             screens: [main], areas: [visible], margin: 0),
                       CGRect(x: 720, y: 25, width: 720, height: 875))
        // Already in place: nothing to do.
        XCTAssertNil(SwishSnap.resnapFrame(place: at(.rightHalf), current: CGRect(x: 720, y: 25, width: 720, height: 875),
                                           screens: [main], areas: [visible], margin: 0))
        // A new resolution: the sixth is recomputed on the larger area.
        let larger = CGRect(x: 0, y: 25, width: 1680, height: 1025)
        assertRect(SwishSnap.resnapFrame(place: at(.sixth(0, 0)), current: CGRect(x: 0, y: 25, width: 480, height: 437.5),
                                         screens: [CGRect(x: 0, y: 0, width: 1680, height: 1050)], areas: [larger], margin: 0),
                   CGRect(x: 0, y: 25, width: 560, height: 512.5))
        // Two displays: the one holding most of the window.
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let rightArea = CGRect(x: 1440, y: 25, width: 1920, height: 1055)
        XCTAssertEqual(SwishSnap.resnapFrame(place: .almostMaximize, current: CGRect(x: 1500, y: 100, width: 900, height: 700),
                                             screens: [main, right], areas: [visible, rightArea], margin: 0),
                       SwishSnap.almostMaximizeFrame(visible: rightArea, margin: 0))
        XCTAssertNil(SwishSnap.resnapFrame(place: at(.leftHalf), current: .zero, screens: [], areas: [], margin: 0))
    }

    // MARK: Stage Manager offset

    func testTheStageManagerOffsetInsetsTheLeftEdgeOnlyWhileItIsOn() {
        let area = SwishSnap.stageManagerArea(visible, offset: 120, stageManager: true)
        XCTAssertEqual(area, CGRect(x: 120, y: 25, width: 1320, height: 875))
        XCTAssertEqual(SwishSnap.targetFrame(layout: .leftHalf, visible: area, margin: 0), CGRect(x: 120, y: 25, width: 660, height: 875))
        XCTAssertEqual(SwishSnap.stageManagerArea(visible, offset: 120, stageManager: false), visible)
        XCTAssertEqual(SwishSnap.stageManagerArea(visible, offset: 0, stageManager: true), visible)
        XCTAssertEqual(SwishSnap.stageManagerArea(visible, offset: 5000, stageManager: true).minX, 720, "never more than half")
    }

    // MARK: Resizing adjacent windows

    private let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
    private let rightHalf = CGRect(x: 720, y: 25, width: 720, height: 875)

    func testSharedEdgesAreFoundWithinTheTolerance() {
        XCTAssertEqual(SwishSnap.sharedEdge(of: leftHalf, with: rightHalf), .right)
        XCTAssertEqual(SwishSnap.sharedEdge(of: rightHalf, with: leftHalf), .left)
        let topLeft = CGRect(x: 0, y: 25, width: 720, height: 437.5)
        let bottomLeft = CGRect(x: 0, y: 462.5, width: 720, height: 437.5)
        XCTAssertEqual(SwishSnap.sharedEdge(of: topLeft, with: bottomLeft), .bottom)
        XCTAssertEqual(SwishSnap.sharedEdge(of: bottomLeft, with: topLeft), .top)
        XCTAssertNil(SwishSnap.sharedEdge(of: topLeft, with: CGRect(x: 720, y: 462.5, width: 720, height: 437.5)),
                     "only a corner in common")
        XCTAssertNil(SwishSnap.sharedEdge(of: leftHalf, with: rightHalf.offsetBy(dx: 30, dy: 0)), "30 pt apart")
        // An 8 pt margin leaves 16 pt between cells; the tolerance allows for it.
        let marginLeft = leftHalf.insetBy(dx: 8, dy: 8), marginRight = rightHalf.insetBy(dx: 8, dy: 8)
        XCTAssertNil(SwishSnap.sharedEdge(of: marginLeft, with: marginRight, tolerance: 8))
        XCTAssertEqual(TitleBarWindowSnap.adjacencyTolerance(margin: 8), 24)
        XCTAssertEqual(SwishSnap.sharedEdge(of: marginLeft, with: marginRight,
                                            tolerance: TitleBarWindowSnap.adjacencyTolerance(margin: 8)), .right)
    }

    func testAResizedEdgeIsTold() {
        XCTAssertEqual(SwishSnap.resizedEdges(from: leftHalf, to: CGRect(x: 0, y: 25, width: 800, height: 875)), [.right])
        XCTAssertEqual(SwishSnap.resizedEdges(from: rightHalf, to: CGRect(x: 650, y: 25, width: 790, height: 875)), [.left])
        XCTAssertEqual(SwishSnap.resizedEdges(from: leftHalf, to: CGRect(x: 0, y: 25, width: 800, height: 700)), [.right, .bottom])
        XCTAssertEqual(SwishSnap.resizedEdges(from: leftHalf, to: leftHalf.offsetBy(dx: 100, dy: 0)), [], "moved, not resized")
        XCTAssertEqual(SwishSnap.resizedEdges(from: leftHalf, to: leftHalf), [])
    }

    func testTheNeighbourFollowsTheEdgeAndKeepsTheGap() {
        let wider = CGRect(x: 0, y: 25, width: 800, height: 875)
        XCTAssertEqual(SwishSnap.followingFrame(neighbour: rightHalf, resizedBefore: leftHalf, resizedAfter: wider, edge: .right),
                       CGRect(x: 800, y: 25, width: 640, height: 875))
        XCTAssertEqual(SwishSnap.followingFrame(neighbour: leftHalf, resizedBefore: rightHalf,
                                                resizedAfter: CGRect(x: 650, y: 25, width: 790, height: 875), edge: .left),
                       CGRect(x: 0, y: 25, width: 650, height: 875))
        let topLeft = CGRect(x: 0, y: 25, width: 720, height: 437.5)
        let bottomLeft = CGRect(x: 0, y: 462.5, width: 720, height: 437.5)
        XCTAssertEqual(SwishSnap.followingFrame(neighbour: bottomLeft, resizedBefore: topLeft,
                                                resizedAfter: CGRect(x: 0, y: 25, width: 720, height: 500), edge: .bottom),
                       CGRect(x: 0, y: 525, width: 720, height: 375))
        // With an 8 pt margin the 16 pt gap is kept.
        let marginLeft = leftHalf.insetBy(dx: 8, dy: 8), marginRight = rightHalf.insetBy(dx: 8, dy: 8)
        XCTAssertEqual(SwishSnap.followingFrame(neighbour: marginRight, resizedBefore: marginLeft,
                                                resizedAfter: CGRect(x: 8, y: 33, width: 784, height: 859), edge: .right),
                       CGRect(x: 808, y: 33, width: 624, height: 859))
        // Never squeezed below the minimum.
        XCTAssertNil(SwishSnap.followingFrame(neighbour: rightHalf, resizedBefore: leftHalf,
                                              resizedAfter: CGRect(x: 0, y: 25, width: 1380, height: 875), edge: .right))
    }

    func testOnlyOneResizedWindowMovesItsNeighbours() {
        let wider = CGRect(x: 0, y: 25, width: 800, height: 875)
        XCTAssertEqual(SwishSnap.adjacentMoves(before: ["a": leftHalf, "b": rightHalf], after: ["a": wider, "b": rightHalf]),
                       ["b": CGRect(x: 800, y: 25, width: 640, height: 875)])
        // Both changed, or the window was moved rather than resized: nothing.
        XCTAssertEqual(SwishSnap.adjacentMoves(before: ["a": leftHalf, "b": rightHalf],
                                               after: ["a": wider, "b": rightHalf.offsetBy(dx: 0, dy: 40)]), [:])
        XCTAssertEqual(SwishSnap.adjacentMoves(before: ["a": leftHalf, "b": rightHalf],
                                               after: ["a": leftHalf.offsetBy(dx: 60, dy: 0), "b": rightHalf]), [:])
        XCTAssertEqual(SwishSnap.adjacentMoves(before: ["a": leftHalf, "b": rightHalf], after: ["a": leftHalf, "b": rightHalf]), [:])
        // A left half beside two right quarters: both quarters follow.
        let topRight = CGRect(x: 720, y: 25, width: 720, height: 437.5)
        let bottomRight = CGRect(x: 720, y: 462.5, width: 720, height: 437.5)
        XCTAssertEqual(SwishSnap.adjacentMoves(before: ["a": leftHalf, "b": topRight, "c": bottomRight],
                                               after: ["a": wider, "b": topRight, "c": bottomRight]),
                       ["b": CGRect(x: 800, y: 25, width: 640, height: 437.5),
                        "c": CGRect(x: 800, y: 462.5, width: 640, height: 437.5)])
        // Resizing the top-right quarter's bottom edge moves only the quarter below it.
        let shorter = CGRect(x: 720, y: 25, width: 720, height: 400)
        XCTAssertEqual(SwishSnap.adjacentMoves(before: ["a": leftHalf, "b": topRight, "c": bottomRight],
                                               after: ["a": leftHalf, "b": shorter, "c": bottomRight]),
                       ["c": CGRect(x: 720, y: 425, width: 720, height: 475)])
    }

    func testOnlyWindowsWhoseSharedEdgeIsNearThePointerAreRead() {
        let frames = ["a": leftHalf, "b": CGRect(x: 720, y: 25, width: 720, height: 437.5),
                      "c": CGRect(x: 720, y: 462.5, width: 720, height: 437.5)]
        XCTAssertEqual(SwishSnap.edgeCandidates(at: CGPoint(x: 722, y: 300), frames: frames), ["a", "b"])
        XCTAssertEqual(SwishSnap.edgeCandidates(at: CGPoint(x: 718, y: 700), frames: frames), ["a", "c"])
        XCTAssertEqual(SwishSnap.edgeCandidates(at: CGPoint(x: 1000, y: 462), frames: frames), ["b", "c"])
        XCTAssertEqual(SwishSnap.edgeCandidates(at: CGPoint(x: 300, y: 400), frames: frames), [])
        XCTAssertEqual(SwishSnap.edgeCandidates(at: CGPoint(x: 722, y: 300), frames: ["a": leftHalf]), [])
    }

    // MARK: Preview animation

    func testTheAnimationSpeedScalesOrRemovesEveryDuration() {
        XCTAssertEqual(SwishSnap.animationDuration(0.1, speed: .normal, reduceMotion: false, movesFrame: true), 0.1)
        XCTAssertEqual(SwishSnap.animationDuration(0.1, speed: .fast, reduceMotion: false, movesFrame: true), 0.05)
        XCTAssertEqual(SwishSnap.animationDuration(0.16, speed: .off, reduceMotion: false, movesFrame: false), 0)
        XCTAssertEqual(SwishSnap.animationDuration(0.12, speed: .normal, reduceMotion: true, movesFrame: true), 0,
                       "Reduce Motion: the frame never slides")
        XCTAssertEqual(SwishSnap.animationDuration(0.16, speed: .fast, reduceMotion: true, movesFrame: false), 0.08,
                       "fades still run")
    }

    // MARK: Settings

    func testTheNewSettingsDefaultsAndRanges() {
        let suite = "aom.test.swishgrid.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TitleBarWindowSnap.grid(defaults), .twoByTwo)
        defaults.set(true, forKey: TitleBarWindowSnap.thirdsKey)
        XCTAssertEqual(TitleBarWindowSnap.grid(defaults), .threeByTwo, "the 3.3.2 Thirds switch still counts")
        defaults.set("3x3", forKey: TitleBarWindowSnap.gridKey)
        XCTAssertEqual(TitleBarWindowSnap.grid(defaults), .threeByThree)
        defaults.set("2x2", forKey: TitleBarWindowSnap.gridKey)
        XCTAssertEqual(TitleBarWindowSnap.grid(defaults), .twoByTwo, "a chosen grid wins over the old switch")
        defaults.set("bogus", forKey: TitleBarWindowSnap.gridKey)
        XCTAssertEqual(TitleBarWindowSnap.grid(defaults), .threeByTwo)
        XCTAssertFalse(TitleBarWindowSnap.almostMaximizeOn(defaults))
        defaults.set(true, forKey: TitleBarWindowSnap.almostKey)
        XCTAssertEqual(TitleBarWindowSnap.gestureOptions(defaults), SwishSnap.GestureOptions(grid: .threeByTwo, almostMaximize: true))
        XCTAssertEqual(TitleBarWindowSnap.hotkeyScheme(defaults), .off)
        XCTAssertFalse(TitleBarWindowSnap.hotkeysWanted(defaults))
        defaults.set("hjkl", forKey: TitleBarWindowSnap.hotkeysKey)
        XCTAssertFalse(TitleBarWindowSnap.hotkeysWanted(defaults), "only while the snap is on")
        defaults.set(true, forKey: TitleBarWindowSnap.enabledKey)
        XCTAssertTrue(TitleBarWindowSnap.hotkeysWanted(defaults))
        defaults.set("bogus", forKey: TitleBarWindowSnap.hotkeysKey)
        XCTAssertEqual(TitleBarWindowSnap.hotkeyScheme(defaults), .off)
        XCTAssertTrue(TitleBarWindowSnap.dragUnsnapOn(defaults))
        XCTAssertTrue(TitleBarWindowSnap.resnapOn(defaults))
        XCTAssertTrue(TitleBarWindowSnap.resizeAdjacentOn(defaults))
        XCTAssertEqual(TitleBarWindowSnap.animationSpeed(defaults), .normal)
        defaults.set("fast", forKey: TitleBarWindowSnap.animationKey)
        XCTAssertEqual(TitleBarWindowSnap.animationSpeed(defaults), .fast)
        defaults.set("bogus", forKey: TitleBarWindowSnap.animationKey)
        XCTAssertEqual(TitleBarWindowSnap.animationSpeed(defaults), .normal)
        XCTAssertEqual(TitleBarWindowSnap.stageManagerOffset(defaults), 0)
        defaults.set(500.0, forKey: TitleBarWindowSnap.stageManagerOffsetKey)
        XCTAssertEqual(TitleBarWindowSnap.stageManagerOffset(defaults), 200)
        defaults.set(-5.0, forKey: TitleBarWindowSnap.stageManagerOffsetKey)
        XCTAssertEqual(TitleBarWindowSnap.stageManagerOffset(defaults), 0)
        XCTAssertEqual(TitleBarWindowSnap.margin(defaults), 0)
        defaults.set(30.0, forKey: TitleBarWindowSnap.marginKey)
        XCTAssertEqual(TitleBarWindowSnap.margin(defaults), 24, "the slider's range")
        defaults.set(12.0, forKey: TitleBarWindowSnap.marginKey)
        XCTAssertEqual(TitleBarWindowSnap.margin(defaults), 12)
        for key in [TitleBarWindowSnap.gridKey, TitleBarWindowSnap.almostKey, TitleBarWindowSnap.hotkeysKey,
                    TitleBarWindowSnap.dragUnsnapKey, TitleBarWindowSnap.resnapKey, TitleBarWindowSnap.animationKey,
                    TitleBarWindowSnap.stageManagerOffsetKey, TitleBarWindowSnap.resizeAdjacentKey] {
            XCTAssertTrue(PresetManager.isBackedUpSetting(key), key)
            XCTAssertEqual(PresetManager.settingArea(key), "Title-bar snap", key)
        }
    }

    // MARK: History

    func testTheHistoryRemembersSixthsAndKeepsTheOriginalThroughAResnap() {
        var history = SwishSnapHistory()
        let original = CGRect(x: 100, y: 100, width: 700, height: 500)
        let sixth = SwishSnap.Place.grid(.sixth(0, 1))
        let frame = CGRect(x: 0, y: 462.5, width: 480, height: 437.5)
        history.recordSnap(key: "w", from: original, to: frame, place: sixth)
        XCTAssertEqual(history.place(key: "w", current: frame), sixth)
        XCTAssertNil(history.cell(key: "w", current: frame), "a sixth has no tiling layout")
        let moved = frame.offsetBy(dx: 1440, dy: 0)
        history.moveSnapped(key: "w", to: moved)
        XCTAssertEqual(history.place(key: "w", current: moved), sixth, "re-snapped, still in its place")
        XCTAssertEqual(history.restoreFrame(key: "w", current: moved), original, "an unsnap still goes back to the start")
        history.recordSnap(key: "v", from: original, to: CGRect(x: 0, y: 25, width: 720, height: 875), layout: .leftHalf)
        XCTAssertEqual(history.place(key: "v", current: CGRect(x: 0, y: 25, width: 720, height: 875)), at(.leftHalf))
        XCTAssertEqual(history.cell(key: "v", current: CGRect(x: 0, y: 25, width: 720, height: 875)), .leftHalf)
    }
}
