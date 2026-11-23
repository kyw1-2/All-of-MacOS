import PDFKit
import XCTest
@testable import AllOfMacOS

/// 7.12: Codex's 2026-11-23 specs (FIX-1, FIX-2, NEW-1, UX-1, NEW-2 and the
/// 30-app spec's top three) and the HomePod glitch advisor.
final class AOM712Tests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AOM712-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func touch(_ name: String, in directory: URL? = nil, _ text: String = "x") throws -> URL {
        let url = (directory ?? folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: NEW-1 — named shelves

    @MainActor
    func testOldShelfBecomesOneDefaultShelfWithItsItemsTwice() throws {
        let file = try touch("a.txt")
        let legacy = folder.appendingPathComponent("shelf.json")
        let item = FilesShelfItem(path: FilesPath.key(file.path), added: Date(timeIntervalSince1970: 1_700_000_000), received: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([item]).write(to: legacy)

        let first = FilesShelfStore(fileURL: legacy)
        XCTAssertEqual(first.shelves.count, 1)
        XCTAssertEqual(first.activeShelf.name, FilesShelfLibrary.defaultName)
        XCTAssertEqual(first.items, [item], "id, order, path and received flag are kept")
        let second = FilesShelfStore(fileURL: legacy)
        XCTAssertEqual(second.shelves.count, 1, "opening again never makes a second Default Shelf")
        XCTAssertEqual(second.items, [item])
    }

    @MainActor
    func testShelvesShareAFileAndAMoveUpdatesEveryShelf() throws {
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let file = try touch("견적.pdf")
        let a = store.activeID
        let b = store.createShelf(named: "발표 준비").id
        store.activate(a)
        let added = store.add([file])
        store.copy(Set(added.map(\.id)), to: b)
        XCTAssertEqual(store.shelf(b)?.items.count, 1)
        XCTAssertTrue(store.isReferenced(file.path, outside: a))

        let moved = folder.appendingPathComponent("Moved/견적.pdf")
        store.relocate(added[0].id, to: moved)
        XCTAssertEqual(store.shelf(b)?.items.first?.path, FilesPath.key(moved.path), "B follows the file AOM moved")

        let deleted = try XCTUnwrap(store.deleteShelf(a))
        XCTAssertEqual(store.shelves.count, 1)
        XCTAssertEqual(store.shelf(b)?.items.count, 1, "deleting A leaves B's item")
        store.restoreShelf(deleted)
        XCTAssertEqual(store.shelves.count, 2)
        XCTAssertNil(store.deleteShelf(b).flatMap { _ in store.deleteShelf(a) }, "the last shelf can't be deleted")
    }

    @MainActor
    func testFilesAddedLaterGoToTheShelfTheyWereDroppedOn() throws {
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let a = store.activeID
        _ = store.createShelf(named: "B")
        let file = try touch("late.png")
        store.add([file], received: true, to: a)
        XCTAssertTrue(store.items.isEmpty, "B, the active shelf, stays as it was")
        XCTAssertEqual(store.shelf(a)?.items.first?.received, true)
        XCTAssertEqual(FilesShelfStore.uniqueName("B", among: ["B", "b 2"]), "B 3")
    }

    // MARK: FIX-1 — a stopped ZIP leaves nothing

    func testStoppedCompressLeavesNoArchiveAndNoWorkingFile() async throws {
        let big = folder.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: Data((0..<(24 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) }))
        let handle = FilesProcess.Handle()
        let task = Task { try await FilesFileActions.compress([big], handle: handle) }
        try await Task.sleep(nanoseconds: 30_000_000)
        handle.cancel()
        _ = try? await task.value
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".zip") }, "no ZIP under the finished name: \(names)")
        XCTAssertFalse(names.contains { $0.contains("aom-partial") }, "no working file: \(names)")
    }

    func testFinishedCompressNeverReplacesAFileThatTookTheName() async throws {
        let file = try touch("Report.pdf", "pdf")
        _ = try touch("Report.pdf.zip", "keep me")
        let archive = try await FilesFileActions.compress([file], handle: FilesProcess.Handle())
        XCTAssertEqual(archive.lastPathComponent, "Report.pdf 2.zip")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Report.pdf.zip"), encoding: .utf8), "keep me")
    }

    // MARK: FIX-2 — missing files are counted

    @MainActor
    func testCopyCountsTheMissingFile() async throws {
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let controller = FilesShelfPanelController(store: store)
        let destination = folder.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = try ["a.txt", "b.txt", "견적.pdf"].map { try touch($0, in: folder.appendingPathComponent("In")) }
        store.add(files)
        try FileManager.default.removeItem(at: files[2])
        XCTAssertEqual(controller.requestedItems.count, 3, "the missing file is still asked for")
        controller.runTransfer(controller.requestedItems, to: destination, move: false)
        try await waitUntil("the copy") { controller.model.progress == nil && controller.model.message != nil }
        let text = try XCTUnwrap(controller.model.message?.text)
        XCTAssertTrue(text.hasPrefix("Copied 2 of 3 items to Out."), text)
        XCTAssertTrue(text.contains("견적.pdf"), text)
        XCTAssertEqual(FilesShelfPanelController.missingMessage([FilesShelfItem(path: files[2].path, added: Date())], of: 3),
                       "“견적.pdf” missing — 1 of 3")
    }

    // MARK: UX-1 — Previous in a snippet's questions

    func testPreviousQuestionKeepsDraftsAndAnswers() {
        let fields = [SnippetField(name: "수신인", kind: .text, sections: []), SnippetField(name: "인사말", kind: .text, sections: [])]
        var request = PaletteSnippetForm.Request(snippetID: UUID(), fields: fields)
        XCTAssertFalse(request.canGoBack)
        request.answer("김철수")
        XCTAssertTrue(request.canGoBack)
        request.back(draft: "안녕하세요 반갑")
        XCTAssertEqual(request.currentName, "수신인")
        XCTAssertEqual(request.restoredText, "김철수", "the earlier answer comes back to edit")
        request.answer("김영희")
        XCTAssertEqual(request.restoredText, "안녕하세요 반갑", "the next question's draft is kept")
        XCTAssertEqual(request.values["수신인"], "김영희")
    }

    // MARK: NEW-2 — PDF text rules

    func testPDFTextValuesAndDates() {
        let text = "청구서\n공급자: 한빛상사\n발행일 2026년 11월 3일\n금액 120,000원"
        XCTAssertEqual(FolderRulePDFText.value(after: "공급자", in: text), "한빛상사")
        XCTAssertNil(FolderRulePDFText.value(after: "거래처", in: text))
        let date = FolderRulePDFText.singleDate(in: text)
        XCTAssertEqual(date.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) },
                       DateComponents(year: 2026, month: 11, day: 3))
        XCTAssertNil(FolderRulePDFText.singleDate(in: text + "\n납기 2026-11-20"), "two dates need review")
        XCTAssertEqual(FolderRulePDFText.dates(in: "Nov 3, 2026 and 2026.11.03").count, 1, "the same day counts once")
    }

    func testTextPDFIsReadWithoutRecognitionAndRenamesSafely() throws {
        let url = folder.appendingPathComponent("scan.pdf")
        try makePDF(url, text: "청구서 공급자: 한빛/상사 발행일 2026-11-03")
        let before = FolderRulePDFText.recognitionCount
        let content = FolderRulePDFText.readUncached(url, recognizesScans: true)
        XCTAssertEqual(content.state, .read)
        XCTAssertEqual(FolderRulePDFText.recognitionCount, before, "a text PDF needs no OCR")

        var info = FolderRuleFileInfo(url: url, contentType: "com.adobe.pdf")
        info.pdf = content
        let rule = FolderRule(folderID: UUID(), name: "청구서", conditions: [FolderRuleCondition(attribute: .pdfText, values: ["청구서"])],
                              actions: [FolderRuleAction(kind: .rename, pattern: "{after:공급자}_{pdfdate}")])
        XCTAssertTrue(rule.readsPDFText)
        XCTAssertTrue(FolderRuleMatcher.matches(rule, info, now: Date()))
        let value = FolderRulePDFText.value(after: "공급자", in: content.text)
        XCTAssertTrue(value?.hasPrefix("한빛/상사") == true)
        let context = FolderRulePatterns.Context(info: info, now: Date())
        let name = FolderRulePatterns.fileName("{after:공급자}_{pdfdate}", context)
        XCTAssertNotNil(name)
        XCTAssertFalse(name?.contains("/") ?? true, "a slash in the value stays inside one file name")
        XCTAssertTrue(name?.hasSuffix(".pdf") ?? false)
    }

    func testUnreadablePDFNeedsReviewAndBlocksLaterRules() {
        var info = FolderRuleFileInfo(url: folder.appendingPathComponent("locked.pdf"), contentType: "com.adobe.pdf")
        info.pdf = FolderRulePDFContent(state: .locked)
        let rule = FolderRule(folderID: UUID(), name: "청구서", conditions: [FolderRuleCondition(attribute: .pdfText, values: ["청구서"])],
                              actions: [FolderRuleAction(kind: .moveToTrash)])
        XCTAssertFalse(FolderRuleMatcher.matches(rule, info, now: Date()))
        XCTAssertEqual(FolderRulesRunner.reviewReason(rule, info, now: Date()), "the PDF is password protected")
        let other = FolderRule(folderID: UUID(), name: "Images", conditions: [.kind(.image)], actions: [FolderRuleAction(kind: .moveToTrash)])
        XCTAssertNil(FolderRulesRunner.reviewReason(other, info, now: Date()), "a rule that doesn't read PDFs is unaffected")
    }

    private func makePDF(_ url: URL, text: String) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 40, y: 780)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
    }

    // MARK: 30-app #1 — saved searches

    func testFileQueryParsesConditionsAndRoundTrips() {
        let query = PaletteFileQuery.parse("in:\"~/My Docs\" kind:pdf modified:7d 견적 서")
        XCTAssertEqual(query.folder, "~/My Docs")
        XCTAssertEqual(query.kind, .pdf)
        XCTAssertEqual(query.within, 7 * 86_400)
        XCTAssertEqual(query.name, "견적 서")
        XCTAssertEqual(PaletteFileQuery.parse(query.text), query)
        XCTAssertEqual(PaletteFileQuery.parse("종류:이미지 수정:2주").kind, .image)
        XCTAssertEqual(PaletteFileQuery.parse("kind:nonsense report").name, "kind:nonsense report")
        XCTAssertTrue(PaletteFileQuery.parse("   ").isEmpty)
    }

    @MainActor
    func testSavedSearchesKeepConditionsNotResults() {
        let defaults = UserDefaults(suiteName: "AOM712-\(UUID().uuidString)")!
        let store = PaletteSavedSearches(defaults: defaults)
        store.save("이번 주 견적서", query: PaletteFileQuery.parse("kind:pdf modified:7d 견적"))
        store.save("이번 주 견적서", query: PaletteFileQuery.parse("kind:pdf modified:14d 견적"))
        XCTAssertEqual(store.searches.count, 1, "the same name replaces")
        XCTAssertEqual(PaletteSavedSearches(defaults: defaults).searches.first?.query.within, 14 * 86_400)
    }

    // MARK: 30-app #2 — clipboard compare

    func testDiffMarksTheChangedDigitAndKeepsGraphemes() {
        let changes = PaletteTextDiff.changes("결제액 120,000원", "결제액 125,000원")
        guard case .changed(let old, let new, let oldSpan, let newSpan) = changes.first else { return XCTFail("\(changes)") }
        XCTAssertEqual(PaletteTextDiff.marked(old, oldSpan), "결제액 12[0],000원")
        XCTAssertEqual(PaletteTextDiff.marked(new, newSpan), "결제액 12[5],000원")
        XCTAssertTrue(PaletteTextDiff.changes("같다\n", "같다\n").isEmpty)
        XCTAssertEqual(PaletteTextDiff.changes("a\nb", "a\nb\n").count, 1, "a newline at the end is a change")
        let emoji = PaletteTextDiff.changes("👍🏽 좋아요", "👍🏿 좋아요")
        if case .changed(_, let new, _, let span) = emoji.first {
            XCTAssertEqual(PaletteTextDiff.marked(new, span), "[👍🏿] 좋아요", "an emoji with its skin tone is one character")
        } else { XCTFail("\(emoji)") }
    }

    // MARK: 30-app #3 — free times

    func testFreeSlotsSkipBusyTimeAndBusyAllDayEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 7))!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 23 + day, hour: hour, minute: minute))!
        }
        let busy = [PaletteFreeSlots.Busy(start: at(0, 9, 30), end: at(0, 10, 30), isAllDay: false, isFree: false),
                    PaletteFreeSlots.Busy(start: at(1, 0), end: at(2, 0), isAllDay: true, isFree: false),
                    PaletteFreeSlots.Busy(start: at(2, 0), end: at(3, 0), isAllDay: true, isFree: true)]
        let slots = PaletteFreeSlots.slots(busy: busy, now: monday, days: 3, minutes: 60,
                                           hours: .init(start: 540, end: 720), calendar: calendar)
        let monday9to12 = slots.filter { calendar.isDate($0.start, inSameDayAs: monday) }.map { calendar.component(.hour, from: $0.start) * 60 + calendar.component(.minute, from: $0.start) }
        XCTAssertEqual(monday9to12, [630, 660], "09:00 and 10:00 clash with 09:30–10:30; 10:30 and 11:00 fit")
        XCTAssertFalse(slots.contains { calendar.isDate($0.start, inSameDayAs: at(1, 9)) }, "a busy all-day event takes the day")
        XCTAssertTrue(slots.contains { calendar.isDate($0.start, inSameDayAs: at(2, 9)) }, "a Free all-day event blocks nothing")
        let text = PaletteFreeSlots.text([slots[0]], korean: true, calendar: calendar)
        XCTAssertTrue(text.hasPrefix("월요일 11/23 10:30–11:30"), text)
        XCTAssertTrue(PaletteFreeSlots.stillFree([slots[0]], busy: busy + [.init(start: at(0, 11), end: at(0, 11, 15), isAllDay: false, isFree: false)],
                                                 calendar: calendar).isEmpty, "a meeting booked meanwhile drops it")
    }

    // MARK: HomePod advisor

    func testRecentOverloadsAreReadFromTheirDetails() {
        let now = Date()
        let recent = AudioGlitchAdvisor.recent([
            (now.addingTimeInterval(-60), "kAudioDeviceProcessorOverload · load 4.8 · memory warn · swap 7.2 GB · thermal nominal"),
            (now.addingTimeInterval(-120), "kAudioDeviceProcessorOverload · load 15.0 · memory warn · swap 7.6 GB · thermal nominal"),
            (now.addingTimeInterval(-300), "kAudioDeviceProcessorOverload · load 2.0 · memory normal · swap 1.0 GB · thermal nominal"),
            (now.addingTimeInterval(-4000), "kAudioDeviceProcessorOverload · memory warn"),
        ], now: now)
        XCTAssertEqual(recent.overloads, 3)
        XCTAssertEqual(recent.underMemoryPressure, 2)
        XCTAssertEqual(recent.swapRange, 1.0...7.6)
        XCTAssertTrue(recent.mostlyMemory)
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(AudioGlitchAdvisor.runaway([("Google Chrome", 3 * gb), ("UlanziDeck", 2_600_000_000)], physical: 8 * gb)?.name, "UlanziDeck",
                       "browsers are left out; a deck app at 2.6 GB is named")
        XCTAssertNil(AudioGlitchAdvisor.runaway([("Notes", 300_000_000)], physical: 8 * gb))
        XCTAssertTrue(AudioGlitchAdvisor.shouldNotify(stamps: [now, now.addingTimeInterval(-60), now.addingTimeInterval(-500)],
                                                      now: now, underPressure: true, lastNotice: nil))
        XCTAssertFalse(AudioGlitchAdvisor.shouldNotify(stamps: [now, now, now], now: now, underPressure: true, lastNotice: now.addingTimeInterval(-600)))
        XCTAssertFalse(AudioGlitchAdvisor.shouldNotify(stamps: [now, now, now], now: now, underPressure: false, lastNotice: nil))
    }
}
