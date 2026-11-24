import XCTest
@testable import AllOfMacOS

/// 7.13: fixes checked against the GPT 7.12.1 spec (F01–F11, F17–F18,
/// UX3-05) and the Gemini 7.12.1 report, after each claim was verified in code.
final class AOM713Tests: XCTestCase {
    // MARK: Clipboard diff (F04–F06)

    func testEqualLongTextsHaveNoChanges() {
        let text = (0..<2_001).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertTrue(PaletteTextDiff.changes(text, text).isEmpty, "a 2,001-line text equals itself (was reported all changed)")
    }

    func testOneEditInALongTextIsExact() {
        var lines = (0..<10_000).map { "line \($0)" }
        let old = lines.joined(separator: "\n")
        lines[5_000] = "line five thousand"
        let changes = PaletteTextDiff.changes(old, lines.joined(separator: "\n"))
        XCTAssertEqual(changes.count, 1)
        if case .changed(let before, let after, _, _) = changes.first {
            XCTAssertEqual(before, "line 5000")
            XCTAssertEqual(after, "line five thousand")
        } else {
            XCTFail("expected one changed line")
        }
    }

    func testLargeDifferingMiddleUsesMyersAndStaysCorrect() {
        // 2,500 × 2,500 lines in the middle: above the LCS table's cap.
        let old = (0..<2_500).map { "a\($0)" } + ["keep"] + (0..<2_500).map { "b\($0)" }
        let new = (0..<2_500).map { "c\($0)" } + ["keep"] + (0..<2_500).map { "d\($0)" }
        let lines = PaletteTextDiff.lines(old.joined(separator: "\n"), new.joined(separator: "\n"))
        XCTAssertTrue(lines.contains(.same("keep")), "the shared line is found, not reported removed and added")
    }

    func testTrailingNewlineMarkerCantCollideWithText() {
        let literal = "a\n" + PaletteTextDiff.newlineAtEnd
        XCTAssertFalse(PaletteTextDiff.changes("a\n", literal).isEmpty, "text that spells the marker is not a newline")
        XCTAssertTrue(PaletteTextDiff.changes("a\r\nb\r\n", "a\nb\n").isEmpty, "CRLF reads as LF")
        XCTAssertEqual(PaletteTextDiff.changes("a\nb", "a\nb\n").count, 1)
        XCTAssertEqual(PaletteTextDiff.display(PaletteTextDiff.newlineAtEnd + "\n"), PaletteTextDiff.newlineAtEnd)
    }

    // MARK: Free times (F08)

    func testStillFreeDropsTimesThatStarted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = PaletteFreeSlots.Slot(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3_540))
        let future = PaletteFreeSlots.Slot(start: now.addingTimeInterval(3_600), end: now.addingTimeInterval(7_200))
        XCTAssertEqual(PaletteFreeSlots.stillFree([past, future], busy: [], now: now), [future])
        XCTAssertEqual(PaletteFreeSlots.stillFree([past, future], busy: []).count, 2, "without a clock only clashes count")
    }

    // MARK: HomePod code residency (F01–F02)

    func testRetainCodeWithTheSettingOffTakesNoReference() {
        let key = "AOMAudioWireCode"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(AudioRealtimeMemory.retainCode(), "a stream started with the setting off must not release later")
        XCTAssertEqual(AudioRealtimeMemory.touchedCodeBytes, 0)
    }

    // MARK: Folder rules (F11)

    func testRecognizedTextIsHiddenFromARuleThatDoesntRecognizeScans() {
        var info = FolderRuleFileInfo(url: URL(fileURLWithPath: "/tmp/scan.pdf"), contentType: "com.adobe.pdf")
        info.pdf = FolderRulePDFContent(state: .read, text: "청구서 2026-11-03", recognized: true)
        var plain = FolderRule(folderID: UUID(), name: "Text only", conditions: [FolderRuleCondition(attribute: .pdfText, values: ["청구서"])],
                               actions: [FolderRuleAction(kind: .moveToTrash)])
        plain.recognizesScans = false
        var ocr = plain
        ocr.recognizesScans = true
        XCTAssertTrue(FolderRuleMatcher.matches(ocr, info, now: Date()))
        XCTAssertFalse(FolderRuleMatcher.matches(plain, info, now: Date()), "OCR text read for another rule doesn't decide this one")
        XCTAssertNotNil(FolderRulesRunner.reviewReason(plain, info, now: Date()), "it is held for review as a page without text")
        XCTAssertEqual(info.seen(by: plain).pdf?.state, .noText)
        XCTAssertEqual(info.seen(by: ocr).pdf?.state, .read)
    }

    // MARK: Drop Shelf (F18)

    @MainActor
    func testTrashSummaryCountsWhatReallyMoved() {
        let ok = FilesShelfPanelController.trashSummary([], moved: 2, success: "Removed 2 items")
        XCTAssertEqual(ok.text, "Removed 2 items")
        XCTAssertEqual(ok.tone, .success)
        let failure = FilesTransfer.Failure(url: URL(fileURLWithPath: "/tmp/a.png"), reason: "it is locked")
        let partial = FilesShelfPanelController.trashSummary([failure], moved: 1,
                                                              success: "Deleted “Work” and moved 2 items AOM received to the Trash")
        XCTAssertEqual(partial.tone, .danger)
        XCTAssertTrue(partial.text.hasPrefix("Deleted “Work” — moved 1 item to the Trash"))
        XCTAssertTrue(partial.text.contains("a.png"))
    }
}
