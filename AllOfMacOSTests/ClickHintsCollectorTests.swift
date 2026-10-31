import ApplicationServices
import XCTest
@testable import AllOfMacOS

/// An Accessibility snapshot for the collector: nodes with attributes,
/// actions and children, read like the live tree (one read per node).
final class ClickHintsFixture: ClickHintsTreeReader {
    typealias Node = Int

    struct Entry {
        var attributes: ClickHintsAttributes?
        var actions: [String] = []
        var settable = false
        var children: [Int] = []
        /// What a table or list reports as visible rows or children.
        var visibleChildren: [Int]?
    }

    private(set) var nodes: [Int: Entry] = [:]
    private(set) var reads = 0
    private(set) var actionReads = 0
    var readBudget = Int.max

    var isExhausted: Bool { reads >= readBudget }

    @discardableResult
    func add(_ id: Int, _ role: String, _ frame: CGRect?, subrole: String? = nil, enabled: Bool? = nil, title: String? = nil,
             actions: [String] = [], settable: Bool = false, parent: Int? = nil, visibleOnly: Bool = false) -> Int {
        nodes[id] = Entry(attributes: ClickHintsAttributes(role: role, subrole: subrole, frame: frame, enabled: enabled, title: title),
                          actions: actions, settable: settable)
        if let parent, var entry = nodes[parent] {
            if visibleOnly { entry.visibleChildren = (entry.visibleChildren ?? []) + [id] }
            entry.children.append(id)
            nodes[parent] = entry
        }
        return id
    }

    func attributes(of node: Int) -> ClickHintsAttributes? {
        reads += 1
        return nodes[node]?.attributes
    }

    func children(of node: Int, role: String) -> [Int] {
        guard let entry = nodes[node] else { return [] }
        if [kAXTableRole, kAXOutlineRole, kAXListRole].contains(role), let visible = entry.visibleChildren { return visible }
        return entry.children
    }

    func actions(of node: Int) -> [String] {
        actionReads += 1
        return nodes[node]?.actions ?? []
    }

    func isValueSettable(_ node: Int) -> Bool { nodes[node]?.settable ?? false }
    func element(of node: Int) -> AXUIElement? { nil }
    func identifier(of node: Int, index: Int) -> Int { node }
}

final class ClickHintsCollectorTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

    private func collect(_ fixture: ClickHintsFixture, root: Int = 0, window: CGRect? = nil,
                         limits: ClickHintsCollector.Limits = .init()) -> ClickHintsCollection {
        ClickHintsCollector.collect(root: root, reader: fixture, window: window ?? self.window, screens: screens, limits: limits)
    }

    private func ids(_ collection: ClickHintsCollection) -> Set<Int> { Set(collection.targets.map(\.id)) }

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 60, _ h: CGFloat = 24) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testRolesAndActionsThatGetHints() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXButtonRole, box(10, 10), parent: 0)
        f.add(2, "AXLink", box(80, 10), parent: 0)
        f.add(3, kAXCheckBoxRole, box(150, 10), parent: 0)
        f.add(4, kAXRadioButtonRole, box(220, 10), subrole: "AXTabButton", parent: 0)
        f.add(5, kAXPopUpButtonRole, box(290, 10), parent: 0)
        f.add(6, kAXMenuButtonRole, box(360, 10), parent: 0)
        f.add(7, kAXTextFieldRole, box(10, 60, 200), parent: 0)
        f.add(8, kAXTextAreaRole, box(10, 100, 300, 120), parent: 0)
        f.add(9, kAXComboBoxRole, box(220, 60), parent: 0)
        f.add(10, kAXSliderRole, box(290, 60), parent: 0)
        f.add(11, kAXDisclosureTriangleRole, box(360, 60, 12, 12), parent: 0)
        f.add(12, kAXGroupRole, box(400, 100, 100, 40), actions: [kAXPressAction], parent: 0)
        f.add(13, kAXImageRole, box(400, 160, 40, 40), actions: [kAXConfirmAction], parent: 0)
        f.add(14, kAXGroupRole, box(400, 220, 100, 40), actions: ["AXScrollToVisible"], parent: 0)
        f.add(15, kAXStaticTextRole, box(400, 280), actions: [kAXPressAction], parent: 0)
        f.add(16, kAXImageRole, box(400, 320, 40, 40), parent: 0)
        f.add(17, kAXTextFieldRole, box(10, 240, 200), subrole: kAXSecureTextFieldSubrole, parent: 0)
        f.add(18, kAXIncrementorRole, box(520, 10, 14, 22), parent: 0)

        let found = ids(collect(f))
        XCTAssertEqual(found, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 18])
        XCTAssertFalse(found.contains(17), "never over password fields")
        let kinds = Dictionary(uniqueKeysWithValues: collect(f).targets.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds[1], .control)
        XCTAssertEqual(kinds[7], .text)
        XCTAssertEqual(kinds[12], .pressable)
    }

    func testOnlyEnabledVisibleLargeEnoughTargetsInsideTheWindow() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXButtonRole, box(10, 10), enabled: false, parent: 0)              // disabled
        f.add(2, kAXButtonRole, box(10, 50, 3, 3), parent: 0)                        // too small
        f.add(3, kAXButtonRole, box(900, 50), parent: 0)                             // outside the window
        f.add(4, kAXButtonRole, box(780, 50, 60), parent: 0)                         // half inside: kept, clipped
        f.add(5, kAXButtonRole, box(10, 90, 0, 0), parent: 0)                        // zero size
        f.add(6, kAXButtonRole, box(10, 130), enabled: true, parent: 0)
        f.add(7, kAXButtonRole, box(796, 90, 60), parent: 0)                         // only a 4 × 24 sliver
        f.add(8, kAXButtonRole, box(797, 130, 60), parent: 0)                        // a 3 pt sliver: too small

        let collection = collect(f)
        XCTAssertEqual(ids(collection), [4, 6, 7])
        let clipped = collection.targets.first { $0.id == 4 }
        XCTAssertEqual(clipped?.visibleFrame, CGRect(x: 780, y: 50, width: 20, height: 24))
        XCTAssertEqual(clipped?.clickPoint, CGPoint(x: 790, y: 62), "clicks land in the visible part")
    }

    func testOffScreenTargetsAreSkipped() {
        // A window that hangs off the left edge of the only display.
        let f = ClickHintsFixture()
        let offset = CGRect(x: -300, y: 0, width: 800, height: 600)
        f.add(0, kAXWindowRole, offset)
        f.add(1, kAXButtonRole, box(-200, 10), parent: 0)
        f.add(2, kAXButtonRole, box(100, 10), parent: 0)
        XCTAssertEqual(ids(collect(f, window: offset)), [2])
    }

    func testContainersWithoutAFrameStillLeadToTheirChildren() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXGroupRole, nil, parent: 0)
        f.add(2, kAXGroupRole, CGRect(x: 0, y: 0, width: 0, height: 0), parent: 1)
        f.add(3, kAXButtonRole, box(10, 10), parent: 2)
        XCTAssertEqual(ids(collect(f)), [3])
    }

    func testAContainerOutsideTheWindowTakesItsSubtreeWithIt() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXGroupRole, box(1000, 0, 200, 200), parent: 0)
        for id in 2...50 { f.add(id, kAXButtonRole, box(10, 10), parent: 1) }
        let collection = collect(f)
        XCTAssertTrue(collection.targets.isEmpty)
        XCTAssertEqual(f.reads, 2, "the 49 children were never read")
    }

    func testScrollAreasClipTheirContent() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXScrollAreaRole, box(0, 100, 400, 200), parent: 0)
        f.add(2, kAXButtonRole, box(10, 60), parent: 1)     // scrolled up, out of view
        f.add(3, kAXButtonRole, box(10, 150), parent: 1)    // in view
        f.add(4, kAXButtonRole, box(10, 320), parent: 1)    // scrolled down, out of view
        f.add(5, kAXButtonRole, box(10, 290), parent: 1)    // half under the bottom edge
        f.add(6, kAXButtonRole, box(10, 340), parent: 0)    // outside the scroll area, in the window
        let collection = collect(f)
        XCTAssertEqual(ids(collection), [3, 5, 6])
        XCTAssertEqual(collection.targets.first { $0.id == 5 }?.visibleFrame.height, 10)
    }

    func testTablesReadOnlyTheirVisibleRows() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXTableRole, box(0, 0, 400, 600), parent: 0)
        for row in 0..<2_000 {
            f.add(100 + row, kAXRowRole, box(0, CGFloat(row) * 24, 400, 24), parent: 1, visibleOnly: row >= 10 && row < 12)
        }
        let collection = collect(f)
        XCTAssertEqual(ids(collection), [110, 111])
        XCTAssertLessThan(f.reads, 10)
    }

    func testAButtonInsideACellKeepsOneHint() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXListRole, box(0, 0, 400, 400), parent: 0)
        // A cell (outside a row) whose button fills most of it: one hint, the button.
        f.add(2, kAXCellRole, box(0, 0, 100, 40), parent: 1)
        f.add(3, kAXButtonRole, box(4, 4, 92, 32), parent: 2)
        // A row with a small checkbox and an editable field: three hints.
        f.add(4, kAXRowRole, box(0, 50, 400, 30), parent: 1)
        f.add(5, kAXCheckBoxRole, box(4, 56, 16, 16), parent: 4)
        f.add(6, kAXCellRole, box(30, 50, 200, 30), parent: 4)
        f.add(7, kAXTextFieldRole, box(32, 52, 190, 24), settable: true, parent: 6)
        // A row whose name is a text field that can't be edited (Finder): one hint, the row.
        f.add(8, kAXRowRole, box(0, 90, 400, 30), parent: 1)
        f.add(9, kAXCellRole, box(0, 90, 200, 30), parent: 8)
        f.add(10, kAXTextFieldRole, box(24, 92, 170, 24), parent: 9)
        f.add(11, kAXImageRole, box(4, 92, 16, 16), parent: 9)

        XCTAssertEqual(ids(collect(f)), [3, 4, 5, 7, 8])
    }

    func testNestedPressablesKeepTheInnerOne() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXGroupRole, box(0, 0, 200, 100), actions: [kAXPressAction], parent: 0)
        f.add(2, kAXGroupRole, box(5, 5, 190, 90), actions: [kAXPressAction], parent: 1)
        // A small link inside the inner group is a separate target.
        f.add(3, "AXLink", box(10, 10, 40, 16), parent: 2)
        XCTAssertEqual(ids(collect(f)), [2, 3])
    }

    func testLookalikeFramesKeepTheMoreSpecificTarget() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXImageRole, box(10, 10, 40, 40), actions: [kAXPressAction], parent: 0)
        f.add(2, kAXButtonRole, box(10, 10, 40, 41), parent: 0)
        f.add(3, kAXButtonRole, box(100, 10, 40, 40), parent: 0)
        f.add(4, kAXButtonRole, box(100, 10, 40, 40), parent: 0)
        XCTAssertEqual(ids(collect(f)), [2, 3])
    }

    func testControlsAreLeaves() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXComboBoxRole, box(10, 10, 200, 24), parent: 0)
        f.add(2, kAXTextFieldRole, box(10, 10, 180, 24), parent: 1)
        f.add(3, kAXButtonRole, box(190, 10, 20, 24), parent: 1)
        f.add(4, "AXLink", box(10, 50, 100, 20), parent: 0)
        f.add(5, kAXButtonRole, box(12, 52, 20, 16), parent: 4)
        XCTAssertEqual(ids(collect(f)), [1, 4])
        XCTAssertEqual(f.reads, 3, "nothing inside a combo box or a link is read")
    }

    func testTheBudgetEndsHugeTreesEarly() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        for id in 1...5_000 { f.add(id, kAXButtonRole, box(CGFloat(id % 30) * 25, CGFloat(id / 30 % 24) * 25, 20, 20), parent: 0) }
        f.readBudget = 200
        let collection = collect(f)
        XCTAssertTrue(collection.truncated)
        XCTAssertLessThanOrEqual(collection.visited, 200)
        XCTAssertFalse(collection.targets.isEmpty, "what was found so far is still shown")

        let capped = ClickHintsFixture()
        capped.add(0, kAXWindowRole, window)
        for id in 1...500 { capped.add(id, kAXButtonRole, box(10, 10, 20, 20), parent: 0) }
        var limits = ClickHintsCollector.Limits()
        limits.maxNodes = 50
        XCTAssertTrue(collect(capped, limits: limits).truncated)
    }

    func testMenuBarAndDockItems() {
        let f = ClickHintsFixture()
        let everywhere = CGRect(x: 0, y: 0, width: 1440, height: 900)
        f.add(0, kAXMenuBarRole, CGRect(x: 0, y: 0, width: 1440, height: 24))
        f.add(1, kAXMenuBarItemRole, box(10, 0, 30, 24), parent: 0)
        f.add(2, kAXMenuBarItemRole, box(50, 0, 50, 24), title: "File", parent: 0)
        f.add(3, kAXMenuBarItemRole, box(110, 0, 50, 24), enabled: false, parent: 0)
        let menus = ClickHintsCollector.collect(root: 0, reader: f, window: everywhere, screens: screens, tier: .menuBar)
        XCTAssertEqual(Set(menus.targets.map(\.id)), [1, 2])
        XCTAssertTrue(menus.targets.allSatisfy { $0.tier == .menuBar })

        let dock = ClickHintsFixture()
        dock.add(0, kAXApplicationRole, nil)
        dock.add(1, kAXListRole, CGRect(x: 300, y: 840, width: 800, height: 60), parent: 0)
        dock.add(2, ClickHintsAX.dockItem, box(310, 846, 48, 48), subrole: "AXApplicationDockItem", parent: 1)
        dock.add(3, ClickHintsAX.dockItem, box(370, 846, 8, 48), subrole: ClickHintsAX.separatorDockItem, parent: 1)
        dock.add(4, ClickHintsAX.dockItem, box(390, 846, 48, 48), subrole: "AXTrashDockItem", parent: 1)
        let items = ClickHintsCollector.collect(root: 0, reader: dock, window: everywhere, screens: screens, tier: .dock)
        XCTAssertEqual(Set(items.targets.map(\.id)), [2, 4])
    }

    func testActionsAreReadOnlyForRolesThatNeedThem() {
        let f = ClickHintsFixture()
        f.add(0, kAXWindowRole, window)
        f.add(1, kAXButtonRole, box(10, 10), parent: 0)
        f.add(2, kAXStaticTextRole, box(10, 50), parent: 0)
        f.add(3, kAXGroupRole, box(10, 90), actions: [kAXPressAction], parent: 0)
        let collection = collect(f)
        XCTAssertEqual(f.actionReads, 1, "only the group's actions are asked for")
        XCTAssertEqual(collection.targets.first { $0.id == 3 }?.actions, [kAXPressAction])
    }

    func testRankingPutsWindowContentFirstThenTheNearest() {
        func target(_ id: Int, _ frame: CGRect, _ tier: ClickHintsTier) -> ClickHintsTarget {
            ClickHintsTarget(element: nil, attributes: ClickHintsAttributes(role: kAXButtonRole), kind: .control, tier: tier,
                             frame: frame, visibleFrame: frame, actions: nil, id: id)
        }
        let targets = [
            target(0, box(500, 500), .window),
            target(1, box(0, 0), .dock),
            target(2, box(10, 10), .window),
            target(3, box(0, 0), .menuBar),
            target(4, box(100, 100), .window)   // contains the pointer
        ]
        let order = ClickHintsCollector.rank(targets, reference: CGPoint(x: 120, y: 110))
        XCTAssertEqual(order, [4, 2, 0, 3, 1])
    }
}
