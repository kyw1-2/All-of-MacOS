import XCTest
@testable import AllOfMacOS

final class TextActionsReadDecisionTests: XCTestCase {
    func testUnsettledClicksRetryBeforeRejectionOrCopy() {
        for hasText in [false, true] {
            for unchanged in [false, true] {
                XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 0, blocked: false,
                    hasSelection: hasText, unchanged: unchanged, click: true, confirmed: false, mayCopy: true), .retry)
            }
        }
        XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 1, blocked: false,
            hasSelection: true, unchanged: false, click: true, confirmed: true, mayCopy: false), .present)
        XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 1, blocked: false,
            hasSelection: true, unchanged: true, click: true, confirmed: false, mayCopy: true), .ignore)
        XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 1, blocked: false,
            hasSelection: false, unchanged: false, click: true, confirmed: false, mayCopy: true), .copy)
        XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 1, blocked: false,
            hasSelection: false, unchanged: false, click: true, confirmed: false, mayCopy: false), .ignore)
    }

    func testProtectedSelectionsNeverRetryPresentOrCopy() {
        for attempt in [0, 1] {
            XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: attempt, blocked: true,
                hasSelection: true, unchanged: false, click: true, confirmed: true, mayCopy: true), .blocked)
        }
        XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 0, blocked: true,
            hasSelection: false, unchanged: false, click: true, confirmed: false, mayCopy: false, incomplete: true), .retry)
        XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 1, blocked: true,
            hasSelection: false, unchanged: false, click: true, confirmed: false, mayCopy: true, incomplete: true), .blocked)
    }

    func testMissingAnchorWideParagraphAndPostClickAnchorRace() {
        let paragraph = CGRect(x: 100, y: 100, width: 1200, height: 140)
        for anchor in [false, true] {
            XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .tripleClick,
                anchorAvailable: anchor, sameElement: anchor, initialRange: nil, finalRange: nil,
                initialText: "paragraph", finalText: "paragraph", finalBounds: paragraph,
                pointer: CGPoint(x: 500, y: 150), verifiedTextTarget: true))
        }
        XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: false, sameElement: false, initialRange: nil,
            finalRange: .init(location: 5, length: 4), initialText: nil, finalText: "word",
            finalBounds: nil, pointer: CGPoint(x: 500, y: 150), verifiedTextTarget: true, directTextSelection: true))
        XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: false, sameElement: false, initialRange: nil, finalRange: nil,
            initialText: nil, finalText: "word", finalBounds: nil,
            pointer: CGPoint(x: 500, y: 150), verifiedTextTarget: true, directTextSelection: true))
        XCTAssertFalse(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: false, sameElement: false, initialRange: nil,
            finalRange: .init(location: 5, length: 4), initialText: nil, finalText: "old WebArea word",
            finalBounds: nil, pointer: CGPoint(x: 500, y: 150), verifiedTextTarget: true))
        XCTAssertTrue(TextActionsGate.confirmedClickSelection(gesture: .doubleClick,
            anchorAvailable: false, sameElement: false, initialRange: nil, finalRange: nil,
            initialText: nil, finalText: "word", finalBounds: CGRect(x: 100, y: 100, width: 50, height: 20),
            pointer: CGPoint(x: 110, y: 110)))
        XCTAssertFalse(TextActionsGate.confirmedClickSelection(gesture: .tripleClick,
            anchorAvailable: false, sameElement: false, initialRange: nil, finalRange: nil,
            initialText: nil, finalText: "stale WebArea", finalBounds: paragraph,
            pointer: CGPoint(x: 500, y: 150)))
        // Click confirmation beats an unchanged snapshot only with local proof.
        XCTAssertEqual(TextActionsGate.disposition(automatic: true, attempt: 0, blocked: false,
            hasSelection: true, unchanged: true, click: true, confirmed: true, mayCopy: false), .present)
    }

    func testIdenticalWordsAtDifferentPositionsAndStaleAXWrappers() {
        let first = CGRect(x: 50, y: 100, width: 40, height: 18)
        let second = CGRect(x: 50, y: 300, width: 40, height: 18)
        for sameElement in [false, true] {
            XCTAssertFalse(TextActionsGate.isUnchangedSelection(anchor: nil, final: nil, sameElement: sameElement,
                initialText: "return", finalText: "return", initialBounds: first, finalBounds: second))
            XCTAssertTrue(TextActionsGate.isUnchangedSelection(anchor: nil, final: nil, sameElement: sameElement,
                initialText: "return", finalText: "return", initialBounds: first, finalBounds: first))
        }
        XCTAssertTrue(TextActionsGate.isUnchangedSelection(anchor: nil, final: nil, sameElement: false,
            initialText: "retained selection", finalText: "retained selection"),
            "Changing AX wrappers without geometry is not proof that a scrollbar drag selected text")
    }

    func testClickCopyRecoveryRequiresKnownHostAndVerifiedTextHit() {
        for gesture: TextSelectionMonitor.Gesture.Kind in [.doubleClick, .tripleClick] {
            XCTAssertTrue(TextActionsGate.mayUseCopyFallback(automatic: true, gesture: gesture,
                bundleID: "COM.OPENAI.CODEX", verifiedTextTarget: true))
            XCTAssertFalse(TextActionsGate.mayUseCopyFallback(automatic: true, gesture: gesture,
                bundleID: "com.openai.codex", verifiedTextTarget: false))
            XCTAssertFalse(TextActionsGate.mayUseCopyFallback(automatic: true, gesture: gesture,
                bundleID: "com.google.Chrome", verifiedTextTarget: true))
        }
    }

    @MainActor
    func testWordAndParagraphExpansionAreDrags() {
        for clicks in [2, 3] {
            XCTAssertEqual(TextSelectionMonitor.gesture(clickCount: clicks, distance: 500, flags: [], dragged: false,
                options: .init(drag: true, clicks: false)), .drag)
            XCTAssertNil(TextSelectionMonitor.gesture(clickCount: clicks, distance: 500, flags: [], dragged: false,
                options: .init(drag: false, clicks: true)))
            XCTAssertNil(TextSelectionMonitor.gesture(clickCount: clicks, distance: 500, flags: [], dragged: true,
                options: .init(drag: true, clicks: true)))
        }
    }
}
