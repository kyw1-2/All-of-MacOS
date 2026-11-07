import XCTest
@testable import AllOfMacOS

final class TextActionsReaderRegressionTests: XCTestCase {
    private func walk(_ nodes: [TextSelectionAttributes]) -> TextSelectionAttributes {
        TextSelectionReader.probe(start: 0, metadata: { index in
            var metadata = nodes[index]
            metadata.selectedText = nil
            return metadata
        }, selection: { index, metadata in
            var result = metadata
            result.selectedText = nodes[index].selectedText
            return result
        }, parent: { $0 + 1 < nodes.count ? $0 + 1 : nil }).attributes
    }

    func testTextSurvivesEveryCollectionAncestor() {
        for role in ["AXList", "AXTable", "AXOutline", "AXGrid"] {
            let result = walk([
                .init(role: "AXStaticText", selectedText: "selected list item"),
                .init(role: role), .init(role: "AXWebArea"), .init(role: "AXWindow")
            ])
            XCTAssertNil(TextActionsGate.check(result), role)
            XCTAssertTrue(result.isTextTarget)
            XCTAssertTrue(result.isVerifiedContext)
            // Native table editors need no AXWebArea ancestor.
            XCTAssertNil(TextActionsGate.check(walk([
                .init(role: "AXTextField", selectedText: "editable cell"),
                .init(role: role), .init(role: "AXWindow")
            ])))
        }
    }

    func testWebAreaSelectionAboveListAndContentListSelection() {
        XCTAssertNil(TextActionsGate.check(walk([
            .init(role: "AXStaticText"), .init(role: "AXList"),
            .init(role: "AXWebArea", selectedText: "markdown list"), .init(role: "AXWindow")
        ])))
        for subrole in ["AXContentList", "AXDescriptionList"] {
            let result = walk([.init(role: "AXList", subrole: subrole, selectedText: "content"), .init(role: "AXWindow")])
            XCTAssertNil(TextActionsGate.check(result))
        }
        XCTAssertNil(TextActionsGate.check(walk([
            .init(role: "AXTable", selectedText: "selected table text"), .init(role: "AXWindow")
        ])))
    }

    func testFileListsWithoutTextStillBlock() {
        for role in ["AXList", "AXTable", "AXOutline", "AXGrid", "AXBrowser", "AXImage"] {
            let result = walk([.init(role: role), .init(role: "AXWindow")])
            XCTAssertTrue(TextActionsGate.isBlocked(result), role)
            XCTAssertTrue(result.isVerifiedContext, "The tree was fully inspected, but is still non-text")
        }
    }

    func testDeepMediaAncestorOverridesLeafSelection() {
        var nodes = [TextSelectionAttributes(role: "AXStaticText", selectedText: "stale")]
        nodes += Array(repeating: .init(role: "AXGroup"), count: 18)
        nodes += [.init(role: "AXVideo", isBlocked: true), .init(role: "AXWebArea")]
        XCTAssertTrue(TextActionsGate.isBlocked(walk(nodes)))
        nodes[19] = .init(role: "AXGroup")
        nodes.append(.init(role: "AXWindow"))
        XCTAssertNil(TextActionsGate.check(walk(nodes)))
    }

    func testImageInsidePlayerStillFindsMediaAncestor() {
        let result = walk([.init(role: "AXImage"), .init(role: "AXGroup"),
            .init(role: "AXVideo", isBlocked: true), .init(role: "AXWindow")])
        XCTAssertEqual(result.role, "AXVideo")
        XCTAssertTrue(TextActionsGate.isBlocked(result))
    }

    func testEmptyNativeTableEditorAndFocusedWrapperAreDistinguished() {
        let editor = walk([.init(role: "AXTextField", selectedText: ""), .init(role: "AXTable"), .init(role: "AXWindow")])
        XCTAssertFalse(TextActionsGate.isBlocked(editor))
        XCTAssertTrue(editor.isTextTarget)
        let button = walk([.init(role: "AXButton"), .init(role: "AXTextArea", selectedText: "old"), .init(role: "AXWindow")])
        XCTAssertFalse(button.isTextTarget, "A focused editor ancestor is not a text hit")
    }

    func testProtectedFocusedNodeNeverReadsTextOrParent() {
        for node in [TextSelectionAttributes(role: "AXVideo", isBlocked: true),
                     .init(role: "AXTextField", subrole: "AXSecureTextField", isBlocked: true)] {
            let result = TextSelectionReader.probe(start: 0, metadata: { _ in node }, selection: { _, metadata in
                XCTFail("Protected nodes must stop before selection IPC")
                return metadata
            }, parent: { _ in XCTFail("Protected focus must not fall through to its WebArea"); return nil })
            XCTAssertTrue(TextActionsGate.isBlocked(result.attributes))
        }
    }

    func testCyclesDepthAndTimeBudgetFailClosed() {
        let leaf = TextSelectionAttributes(role: "AXStaticText", selectedText: "old selection")
        for cycle in [true, false] {
            let result = TextSelectionReader.probe(start: 0, metadata: { _ in leaf },
                selection: { _, metadata in metadata }, parent: { cycle ? $0 : $0 + 1 })
            XCTAssertTrue(TextActionsGate.isBlocked(result.attributes))
            XCTAssertFalse(result.attributes.isVerifiedContext)
        }
        let result = TextSelectionReader.probe(start: 0, metadata: { _ in leaf },
            selection: { _, metadata in metadata }, parent: { _ in nil }, expired: { true })
        XCTAssertTrue(TextActionsGate.isBlocked(result.attributes))
    }

    func testFreshFocusedDragMayEndOnImageButNeverOnMediaOrPassword() {
        let final = TextSelectionAttributes(role: "AXTextArea", selectedText: "new selection", isVerifiedContext: true)
        func accepts(_ role: String?, start: Bool = true, text: String? = "old") -> Bool {
            TextActionsGate.mayUseFocusedDragSelection(final, sameElement: true, initialText: text,
                initialRange: nil, initialBounds: nil, startedOnText: start, endpointRole: role)
        }
        XCTAssertTrue(accepts("AXImage"))
        XCTAssertTrue(accepts("AXTable"))
        XCTAssertFalse(accepts("AXVideo"))
        XCTAssertFalse(accepts("AXSecureTextField"))
        XCTAssertFalse(accepts(nil))
        XCTAssertFalse(accepts("AXImage", start: false))
        XCTAssertFalse(accepts("AXImage", text: "new selection"))
        XCTAssertFalse(accepts("AXImage", text: nil))
    }
}
