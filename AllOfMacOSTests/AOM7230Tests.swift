import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.23.0 — DeepSeek's design reference of 2026-11-25 (on Drive,
/// AOM-Reports/2026-11-27) and the open items of 7.22.
@MainActor
final class AOM7230QuickEntryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    /// Thursday 26 November 2026, 10:00 in Seoul.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10))!
    }

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    func testKoreanTomorrowAtThreeIsAfternoon() throws {
        let sentence = try XCTUnwrap(QuickEntryParser.parse("내일 3시 회의", now: now, calendar: calendar))
        XCTAssertEqual(sentence.title, "회의")
        XCTAssertTrue(sentence.hasTime)
        let p = parts(sentence.date)
        XCTAssertEqual([p.day, p.hour, p.minute], [27, 15, 0])
    }

    func testEnglishMeridiemAndWeekday() throws {
        let lunch = try XCTUnwrap(QuickEntryParser.parse("lunch tomorrow 12pm", now: now, calendar: calendar))
        XCTAssertEqual(lunch.title, "lunch")
        XCTAssertEqual(parts(lunch.date).hour, 12)
        let review = try XCTUnwrap(QuickEntryParser.parse("금요일 오후 4시 30분 리뷰", now: now, calendar: calendar))
        XCTAssertEqual(review.title, "리뷰")
        XCTAssertEqual([parts(review.date).day, parts(review.date).hour, parts(review.date).minute], [27, 16, 30])
        let friday = try XCTUnwrap(QuickEntryParser.parse("demo on friday 9am", now: now, calendar: calendar))
        XCTAssertEqual(parts(friday.date).weekday, 6)
        XCTAssertEqual(parts(friday.date).hour, 9)
    }

    func testNextWeekAndMonthDayAndAllDay() throws {
        let next = try XCTUnwrap(QuickEntryParser.parse("다음 주 수요일 점심 약속", now: now, calendar: calendar))
        XCTAssertFalse(next.hasTime)
        XCTAssertEqual([parts(next.date).month, parts(next.date).day], [12, 2], "Wednesday of next week")
        let trip = try XCTUnwrap(QuickEntryParser.parse("12월 3일 9시 출장", now: now, calendar: calendar))
        XCTAssertEqual([parts(trip.date).month, parts(trip.date).day, parts(trip.date).hour], [12, 3, 9])
    }

    func testTimeOnlyInThePastIsTomorrowAndNonSentencesAreNil() throws {
        let early = try XCTUnwrap(QuickEntryParser.parse("standup 9:00", now: now, calendar: calendar))
        XCTAssertEqual(parts(early.date).day, 27)
        XCTAssertNil(QuickEntryParser.parse("3시", now: now, calendar: calendar), "no title")
        XCTAssertNil(QuickEntryParser.parse("hello world", now: now, calendar: calendar), "no time")
        XCTAssertNil(QuickEntryParser.parse("meeting 25:00", now: now, calendar: calendar))
    }

    func testShortcutClashSaysWhatWhyAndFix() {
        XCTAssertNil(ShortcutClashMessage.make("⌃⌥N", status: .active))
        let taken = ShortcutClashMessage.make("⌃⌥N", status: .failed(OSStatus(eventHotKeyExistsErr)))
        XCTAssertEqual(taken?.title, "⌃⌥N can't be used")
        XCTAssertTrue(taken?.why.contains("Another app") == true)
        XCTAssertTrue(ShortcutClashMessage.make("⌥Space", status: .failed(OSStatus(eventHotKeyExistsErr)), launcher: "launcher")?
            .why.contains("launcher") == true)
        XCTAssertFalse(QuickEntryShortcut.allCases.contains { $0.displayString == "⌃⌥Space" }, "macOS's input source key")
    }

    func testSymbolsSearch() {
        XCTAssertFalse(PaletteSymbols.matches("arrow").isEmpty)
        XCTAssertEqual(PaletteSymbols.matches("→").first?.glyph, "→")
        XCTAssertTrue(PaletteSymbols.matches("화살표").contains { $0.glyph == "→" })
        XCTAssertTrue(PaletteSymbols.matches("box drawings light horizontal").contains { $0.glyph == "─" }, "Unicode names")
        XCTAssertEqual(PaletteRecentSymbols.recorded("→", in: ["₩", "→"]), ["→", "₩"])
        XCTAssertEqual(Set(PaletteSymbols.all.map(\.glyph)).count, PaletteSymbols.all.count, "no duplicates")
    }
}

@MainActor
final class AOM7230FilesAndRulesTests: XCTestCase {
    func testHiddenSecretsAreNotFoundByTheirWords() {
        let entry = ClipboardEntry.captured(items: [[NSPasteboard.PasteboardType.string.rawValue: Data("token sk-test".utf8)]],
                                            sourceName: "Notes", sourceBundleID: "com.apple.Notes", at: Date())
        let free = ClipboardSearchQuery("sk-test")
        XCTAssertTrue(free.matches(entry, boards: []))
        XCTAssertFalse(free.matches(entry, boards: [], contentHidden: { _ in true }))
        XCTAssertTrue(ClipboardSearchQuery("from:Notes").matches(entry, boards: [], contentHidden: { _ in true }), "metadata still works")
        XCTAssertTrue(ClipboardSearchQuery("-sk-test").matches(entry, boards: [], contentHidden: { _ in true }))
    }

    func testCloudOnlyDetectionAndSummary() throws {
        XCTAssertTrue(FolderRuleFileReader.isCloudOnly(ubiquitous: false, status: nil, flags: FolderRuleFileReader.datalessFlag))
        XCTAssertTrue(FolderRuleFileReader.isCloudOnly(ubiquitous: true, status: .notDownloaded, flags: 0))
        XCTAssertFalse(FolderRuleFileReader.isCloudOnly(ubiquitous: true, status: .current, flags: 0))
        XCTAssertFalse(FolderRuleFileReader.isCloudOnly(ubiquitous: false, status: nil, flags: 0))
        XCTAssertEqual(FolderRulesRunner.cloudSummary(skipped: 3, downloading: 0), "Skipped 3 cloud-only files")
        XCTAssertEqual(FolderRulesRunner.cloudSummary(skipped: 0, downloading: 0), "")
        let old = try JSONDecoder().decode(FolderRulesConfig.self, from: Data(#"{"version":1,"isEnabled":true}"#.utf8))
        XCTAssertEqual(old.cloudFiles, .download)
        var config = FolderRulesConfig()
        config.cloudFiles = .skip
        let again = try JSONDecoder().decode(FolderRulesConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.cloudFiles, .skip)
    }

    func testScreenEdgeOpensTheShelfOnlyAtOuterEdges() {
        let left = CGRect(x: 0, y: 0, width: 1_440, height: 900), right = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        XCTAssertEqual(FilesEdgeDetector.edge(at: NSPoint(x: 0, y: 400), screens: [left, right]), .left(left))
        XCTAssertNil(FilesEdgeDetector.edge(at: NSPoint(x: 1_439, y: 400), screens: [left, right]), "another screen continues")
        XCTAssertEqual(FilesEdgeDetector.edge(at: NSPoint(x: 3_359, y: 500), screens: [left, right]), .right(right))
        XCTAssertNil(FilesEdgeDetector.edge(at: NSPoint(x: 700, y: 400), screens: [left]))
        XCTAssertEqual(FilesEdgeDetector.shelfPoint(for: .left(left), at: NSPoint(x: 0, y: 300)).x, 172)
    }

    func testDualPanePlanning() {
        let folder = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
        let a = URL(fileURLWithPath: "/tmp/a/Report.pdf"), b = URL(fileURLWithPath: "/tmp/a/Photo.png")
        let taken: Set<String> = ["/tmp/b/Report.pdf"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        XCTAssertEqual(FilesDualPanePlan.conflicts([a, b], in: folder, exists: exists), ["Report.pdf"])
        XCTAssertNil(FilesDualPanePlan.destination(for: a, in: folder, choice: .skip, exists: exists))
        XCTAssertEqual(FilesDualPanePlan.destination(for: a, in: folder, choice: .replace, exists: exists)?.lastPathComponent, "Report.pdf")
        XCTAssertEqual(FilesDualPanePlan.destination(for: a, in: folder, choice: .keepBoth, exists: exists)?.lastPathComponent, "Report 2.pdf")
        XCTAssertEqual(FilesDualPanePlan.destination(for: b, in: folder, choice: nil, exists: exists)?.lastPathComponent, "Photo.png")
        XCTAssertTrue(FilesDualPanePlan.isNoOp(a, into: URL(fileURLWithPath: "/tmp/a")))
        XCTAssertTrue(FilesDualPanePlan.isNoOp(URL(fileURLWithPath: "/tmp/a"), into: URL(fileURLWithPath: "/tmp/a/sub")), "into itself")
        XCTAssertFalse(FilesDualPanePlan.isNoOp(a, into: folder))
    }

    func testFailureReasonsByCause() {
        XCTAssertEqual(ConnectFailureReason.classify(URLError(.serverCertificateNotYetValid)), .clockSkew)
        XCTAssertEqual(ConnectFailureReason.classify(URLError(.cannotFindHost), host: "x.test"), .cannotFindServer("x.test"))
        XCTAssertEqual(ConnectFailureReason.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ConnectFailureReason.classify(status: 401), .auth)
        XCTAssertEqual(ConnectFailureReason.classify(status: 503), .serverError(503))
        XCTAssertNil(ConnectFailureReason.classify(status: 204))
        XCTAssertNotNil(ConnectFailureReason.clockSkew.settingsURL)
        XCTAssertEqual(ConnectFailureReason.cannotFindServer("x.test").title, "Can't find x.test")
    }

    func testPermissionRowsSayWhatFailsWithoutAccess() {
        XCTAssertEqual(PermissionsSettingsView.detail(.screenRecording, allowed: true), AOMPermission.screenRecording.explanation)
        XCTAssertTrue(PermissionsSettingsView.detail(.fullDiskAccess, allowed: false).contains("Without it: some leftovers"))
        XCTAssertFalse(AOMPermission.allCases.contains { $0.failureConsequence.isEmpty })
    }
}

@MainActor
final class AOM7230StudioMeetingTests: XCTestCase {
    func testCameraFadesInsideLongPausesOnly() {
        let hidden = AOMStudioTimeline.cameraHiddenRanges(silences: [1.0...2.0, 5.0...8.0])
        XCTAssertEqual(hidden, [[5.0, 8.0]], "a pause under 1.388 s keeps the camera")
        XCTAssertEqual(AOMStudioTimeline.cameraOpacity(at: 4.9, hidden: hidden), 1)
        XCTAssertEqual(AOMStudioTimeline.cameraOpacity(at: 6.5, hidden: hidden), 0)
        XCTAssertEqual(AOMStudioTimeline.cameraOpacity(at: 5.125, hidden: hidden), 0.5, accuracy: 0.001)
        XCTAssertEqual(AOMStudioTimeline.cameraOpacity(at: 8.0, hidden: hidden), 1)
    }

    func testZoomRangeAndSmoothing() {
        let range = AOMStudioTimeline.rangeKeyframes(start: 2, end: 5, magnification: 2, focusX: 0.3, focusY: 0.4, duration: 10)
        XCTAssertEqual(range.map(\.time), [1.6, 2, 5, 5.4])
        XCTAssertEqual(range.map(\.magnification), [1, 2, 2, 1])
        XCTAssertTrue(AOMStudioTimeline.rangeKeyframes(start: 2, end: 2.1, magnification: 2, focusX: 0.5, focusY: 0.5, duration: 10).isEmpty)
        let middle = AOMOneEuroFilter.parameters(smoothing: 0.5)
        XCTAssertEqual(middle.minCutoff, 1, accuracy: 0.0001)
        XCTAssertEqual(middle.beta, 8, accuracy: 0.0001)
        XCTAssertGreaterThan(AOMOneEuroFilter.parameters(smoothing: 0).minCutoff, AOMOneEuroFilter.parameters(smoothing: 1).minCutoff)
    }

    func testVoiceSplitIsConservative() {
        let two: [Double?] = [110, 115, 108, 220, 225, 112, 218, nil, 230]
        let groups = MeetingVoices.split(two)
        XCTAssertNotNil(groups)
        XCTAssertEqual(groups?[0], groups?[1])
        XCTAssertNotEqual(groups?[0], groups?[3])
        XCTAssertNil(groups?[7] ?? nil)
        XCTAssertNil(MeetingVoices.split([120, 125, 118, 130, 122, 127]), "one voice")
        XCTAssertNil(MeetingVoices.split([110, 220]), "too few lines")
        XCTAssertNil(MeetingVoices.split([110, 112, 114, 116, 118, 220]), "second voice too rare")
    }

    func testPitchOfASine() throws {
        let rate = 16_000.0
        let samples = (0..<16_000).map { Float(0.3 * sin(2 * Double.pi * 150 * Double($0) / rate)) }
        let pitch = try XCTUnwrap(MeetingVoices.pitch(samples, sampleRate: rate))
        XCTAssertEqual(pitch, 150, accuracy: 6)
        XCTAssertNil(MeetingVoices.pitch([Float](repeating: 0, count: 16_000), sampleRate: rate), "silence")
    }

    func testAppTrafficParsesTheSecondSampleMinusTheFirst() {
        let text = """
        ,bytes_in,bytes_out,
        Safari.100,1000,500,
        mDNSResponder.691,50,50,
        ,bytes_in,bytes_out,
        Safari.100,4000,700,
        mDNSResponder.691,50,50,
        curl.300,10,20,
        """
        let rows = AppTraffic.parse(text)
        XCTAssertEqual(rows.first?.name, "Safari")
        XCTAssertEqual(rows.first?.received, 3_000)
        XCTAssertEqual(rows.first?.sent, 200)
        XCTAssertEqual(rows.first { $0.name == "curl" }?.total, 0, "new process counts from its first reading")
        XCTAssertEqual(AppTraffic.parse(",bytes_in,bytes_out,\nA.1,1,1,"), [])
    }

    func testStorageColoring() {
        XCTAssertEqual(StorageColoring.kind(of: "Movie.MOV"), .video)
        XCTAssertEqual(StorageColoring.kind(of: "보고서.hwp"), .document)
        XCTAssertEqual(StorageColoring.kind(of: "Setup.dmg"), .archive)
        XCTAssertEqual(StorageColoring.kind(of: "README"), .other)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(StorageColoring.age(of: now.addingTimeInterval(-86_400), now: now), .week)
        XCTAssertEqual(StorageColoring.age(of: now.addingTimeInterval(-400 * 86_400), now: now), .older)
        XCTAssertEqual(StorageColoring.age(of: nil, now: now), .unknown)
    }

    func testScreenTextAreasAreWatchedApart() {
        let kinds: [SystemTriggerKind] = [.screenTextAppears(text: "Done", intervalSeconds: 9),
                                          .screenTextAppearsIn(text: "Error", intervalSeconds: 4, area: .frontWindow)]
        let needs = SignalSource.needs(for: kinds)
        XCTAssertTrue(needs.contains(.screenText(["done"], interval: 9)))
        XCTAssertTrue(needs.contains(.screenText(["error"], interval: 4, area: .frontWindow)))
        XCTAssertTrue(SystemSignalMatcher.matches(kinds[1], .screenTextAppeared(text: "error", area: .frontWindow)))
        XCTAssertFalse(SystemSignalMatcher.matches(kinds[1], .screenTextAppeared(text: "error")), "the display reading is another area")
        XCTAssertNotNil(TriggerValidation.systemProblem(for: .screenTextAppearsIn(text: "x", intervalSeconds: 5,
                                                                                 area: .region(x: 0, y: 0, width: 2, height: 2))))
        XCTAssertNil(TriggerValidation.systemProblem(for: .screenTextAppearsIn(text: "x", intervalSeconds: 5,
                                                                              area: .region(x: 0, y: 0, width: 200, height: 40))))
        let data = try? JSONEncoder().encode(kinds[1])
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(SystemTriggerKind.self, from: $0) }, kinds[1])
    }

    func testTypingAutoFixCandidates() {
        XCTAssertEqual(TypingAutoFix.candidate("dkssud", isEnglishWord: { _ in false }), "안녕")
        XCTAssertNil(TypingAutoFix.candidate("dkssud", isEnglishWord: { _ in true }), "a real English word stays")
        XCTAssertNil(TypingAutoFix.candidate("the", isEnglishWord: { _ in false }), "one syllable is too little to go on")
        XCTAssertNil(TypingAutoFix.candidate("qqqq", isEnglishWord: { _ in false }), "leftover jamo")
        XCTAssertNil(TypingAutoFix.candidate("dks1", isEnglishWord: { _ in false }))
    }

    func testPageArchetypes() {
        XCTAssertTrue(AOMMainTab.home.headerShowsMark)
        XCTAssertFalse(AOMMainTab.tools.headerShowsMark)
        XCTAssertEqual(AOMMainTab.audio.archetype, .instrument)
        XCTAssertEqual(AOMMainTab.snapping.archetype.maxWidth, 960)
        XCTAssertEqual(AOMSize.rowStandard, 30)
        XCTAssertEqual(AOMSize.rowDetail, 38)
    }
}
