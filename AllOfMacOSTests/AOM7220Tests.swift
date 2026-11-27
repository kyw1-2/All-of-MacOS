import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.22.0 — DeepSeek's 2026-11-26 commercial-app report applied:
/// clipboard secret protection and lifetimes, Scene automation, layout
/// conversion, recording polish and System Tools instruments.
@MainActor
final class AOM7220ClipboardTests: XCTestCase {
    private func entry(_ text: String, copied: Date, pinned: Bool = false) -> ClipboardEntry {
        var value = ClipboardEntry.captured(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]],
                                            sourceName: "Test", sourceBundleID: "com.test", at: copied)
        if pinned { value.pinboardIDs = [UUID()] }
        return value
    }

    func testExpiredItemsLeaveEvenWhenPinned() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var timed = entry("hello", copied: now)
        timed.expiresAt = now.addingTimeInterval(-1)
        var pinned = entry("pinned", copied: now, pinned: true)
        pinned.expiresAt = now.addingTimeInterval(-1)
        let fresh = entry("fresh", copied: now)
        var future = entry("later", copied: now)
        future.expiresAt = now.addingTimeInterval(60)
        let plan = Set(ClipboardStore.removalPlan([timed, pinned, fresh, future], limits: .init(), now: now))
        XCTAssertEqual(plan, [timed.id, pinned.id])
    }

    func testSecretLifetimeRemovesOnlyOldUnpinnedSecrets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = entry("sk-old", copied: now.addingTimeInterval(-25 * 3_600))
        let recent = entry("sk-new", copied: now.addingTimeInterval(-3_600))
        let pinned = entry("sk-pin", copied: now.addingTimeInterval(-48 * 3_600), pinned: true)
        let plain = entry("notes", copied: now.addingTimeInterval(-48 * 3_600))
        let isSecret: (ClipboardEntry) -> Bool = { $0.text?.hasPrefix("sk-") == true }
        let plan = Set(ClipboardStore.removalPlan([old, recent, pinned, plain], limits: .init(), now: now, isSecret: isSecret))
        XCTAssertEqual(plan, [old.id], "default lifetime is 24 hours, pinned and plain items stay")
        var off = ClipboardStore.Settings()
        off.secretLifetimeHours = 0
        XCTAssertTrue(ClipboardStore.removalPlan([old], limits: off, now: now, isSecret: isSecret).isEmpty)
    }

    func testOlderSettingsDecodeWithDefaultSecretLifetime() throws {
        let data = Data(#"{"enabled":true,"pasteDirectly":true,"plainText":false,"retentionDays":30,"ignoredApps":[],"maxEntries":1000,"maxBytes":1024}"#.utf8)
        let settings = try JSONDecoder().decode(ClipboardStore.Settings.self, from: data)
        XCTAssertEqual(settings.secretLifetimeHours, 24)
    }

    func testOlderEntriesDecodeWithoutLifetime() throws {
        let original = entry("hello", copied: Date())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "expiresAt"); json.removeValue(forKey: "burnAfterPaste")
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.expiresAt)
        XCTAssertFalse(decoded.pastesOnce)
    }

    func testLifetimeDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 22))!
        XCTAssertEqual(ClipboardStore.Lifetime.hour.expiry(from: now), now.addingTimeInterval(3_600))
        let tomorrow = ClipboardStore.Lifetime.tomorrow.expiry(from: now, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: tomorrow), DateComponents(day: 28, hour: 9))
        XCTAssertNil(ClipboardStore.Lifetime.pasteOnce.expiry(from: now))
        XCTAssertNil(ClipboardStore.Lifetime.never.expiry(from: now))
    }

    func testConcealedMaskNeverCarriesCharacters() {
        let mask = ClipboardConcealedContent.mask(length: 40, compact: false)
        XCTAssertEqual(mask.replacingOccurrences(of: " ", with: ""), String(repeating: "•", count: 24))
        XCTAssertEqual(ClipboardConcealedContent.mask(length: 3, compact: true).filter { $0 == "•" }.count, 8)
    }

    func testLifetimeSuffix() {
        let now = Date()
        var item = entry("x", copied: now)
        XCTAssertEqual(ClipboardPanelState.lifetimeStatus(.never, count: 1), "This item now follows the history limits.")
        item.burnAfterPaste = true
        XCTAssertEqual(ClipboardPanelState.lifetime(of: item), .pasteOnce)
        item.burnAfterPaste = nil
        item.expiresAt = now.addingTimeInterval(30 * 60)
        XCTAssertNil(ClipboardPanelState.lifetime(of: item))
    }
}

final class AOM7220AutomationTests: XCTestCase {
    func testHangulFromLatinKeys() {
        XCTAssertEqual(HangulLayoutConverter.toHangul("dkssud"), "안녕")
        XCTAssertEqual(HangulLayoutConverter.toHangul("gksrmf"), "한글")
        XCTAssertEqual(HangulLayoutConverter.toHangul("rkqt"), "값")
        XCTAssertEqual(HangulLayoutConverter.toHangul("rkqtl"), "갑시")
        XCTAssertEqual(HangulLayoutConverter.toHangul("dhk"), "와")
        XCTAssertEqual(HangulLayoutConverter.toHangul("Rhcl"), "꼬치")
        XCTAssertEqual(HangulLayoutConverter.toHangul("dkssud, gktpdy!"), "안녕, 하세요!")
        XCTAssertEqual(HangulLayoutConverter.toHangul("wlqdprktl"), "집에가시")
    }

    func testLatinFromHangul() {
        XCTAssertEqual(HangulLayoutConverter.toLatin("안녕"), "dkssud")
        XCTAssertEqual(HangulLayoutConverter.toLatin("값"), "rkqt")
        XCTAssertEqual(HangulLayoutConverter.toLatin("꽃"), "Rhkc")
        XCTAssertEqual(HangulLayoutConverter.toLatin("의자"), "dmlwk")
    }

    func testConvertPicksDirectionAndRoundTrips() {
        XCTAssertEqual(HangulLayoutConverter.direction(of: "dkssud"), .toHangul)
        XCTAssertEqual(HangulLayoutConverter.direction(of: "ㅎㅇ"), .toLatin)
        for word in ["안녕하세요", "한글", "값이", "읽다", "꽃밭", "의사"] {
            XCTAssertEqual(HangulLayoutConverter.toHangul(HangulLayoutConverter.toLatin(word)), word, word)
        }
        XCTAssertEqual(TextTransform.koreanEnglishLayout.apply("dkssud"), "안녕")
        XCTAssertTrue(HangulLayoutConverter.looksLikeMistypedKorean("dkssud"))
        XCTAssertFalse(HangulLayoutConverter.looksLikeMistypedKorean("qqq"))
    }

    func testMicrophoneAndScreenTextTriggersMatch() {
        XCTAssertTrue(SystemSignalMatcher.matches(.microphoneInUse(active: true), .microphone(active: true)))
        XCTAssertFalse(SystemSignalMatcher.matches(.microphoneInUse(active: true), .microphone(active: false)))
        XCTAssertTrue(SystemSignalMatcher.matches(.screenTextAppears(text: " Build  Failed ", intervalSeconds: 5),
                                                  .screenTextAppeared(text: "build failed")))
        let needs = SignalSource.needs(for: [.microphoneInUse(active: true), .screenTextAppears(text: "Done", intervalSeconds: 9),
                                             .screenTextAppears(text: "Error", intervalSeconds: 3)])
        XCTAssertTrue(needs.contains(.microphone))
        XCTAssertTrue(needs.contains(.screenText(["done", "error"], interval: 3)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: .screenTextAppears(text: "  ", intervalSeconds: 5)))
        XCTAssertNotNil(TriggerValidation.systemProblem(for: .screenTextAppears(text: "x", intervalSeconds: 1)))
        XCTAssertNil(TriggerValidation.systemProblem(for: .screenTextAppears(text: "x", intervalSeconds: 2)))
    }

    func testScreenTextFiresOnAppearanceOnly() {
        var watch = ScreenTextWatchSet(texts: ["done"])
        XCTAssertEqual(watch.appeared(in: "Done already"), [], "first reading is the baseline")
        XCTAssertEqual(watch.appeared(in: "Done already"), [])
        XCTAssertEqual(watch.appeared(in: "working"), [])
        XCTAssertEqual(watch.appeared(in: "All DONE"), ["done"])
    }

    func testTriggerKindsRoundTripThroughJSON() throws {
        for kind in [SystemTriggerKind.microphoneInUse(active: false), .screenTextAppears(text: "Ready", intervalSeconds: 7)] {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(SystemTriggerKind.self, from: data), kind)
        }
    }

    func testNewActionsHaveCatalogCopy() {
        for type in [ActionType.runScene, .convertKeyboardLayout, .toggleMeetingRecording] {
            XCTAssertTrue(ParityActions.handles(type), type.rawValue)
            XCTAssertNotEqual(type.description, type.rawValue)
        }
        XCTAssertEqual(ActionType.runScene.category, .workflow)
    }

    func testCaretPanelStaysOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 340, height: 160)
        let below = SnippetCaretGeometry.frame(size: size, caret: CGRect(x: 100, y: 600, width: 2, height: 16), visible: visible)
        XCTAssertEqual(below.maxY, 594, accuracy: 0.5, "below the caret")
        let above = SnippetCaretGeometry.frame(size: size, caret: CGRect(x: 100, y: 40, width: 2, height: 16), visible: visible)
        XCTAssertGreaterThan(above.minY, 56, "flips above when there's no room below")
        let right = SnippetCaretGeometry.frame(size: size, caret: CGRect(x: 1430, y: 600, width: 2, height: 16), visible: visible)
        XCTAssertLessThanOrEqual(right.maxX, visible.maxX)
        XCTAssertEqual(SnippetCaretGeometry.flipped(CGRect(x: 10, y: 100, width: 2, height: 20), primaryHeight: 900).minY, 780)
        let values = SnippetCaretForm.initialValues([SnippetField(name: "Size", kind: .choice(["S", "M"], defaultIndex: 1), sections: []),
                                                     SnippetField(name: "Sig", kind: .optional(defaultOn: true), sections: [])])
        XCTAssertEqual(values["Size"], "M")
        XCTAssertEqual(values["Sig"], SnippetField.on)
    }
}

final class AOM7220StudioTests: XCTestCase {
    func testSilentRangesKeepSpeechMargins() {
        // 1 s speech, 2 s silence, 1 s speech (10 ms frames).
        let levels = [Float](repeating: -12, count: 100) + [Float](repeating: -80, count: 200) + [Float](repeating: -12, count: 100)
        let ranges = AOMSilenceCutter.silentRanges(levels: levels)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].lowerBound, 1.3, accuracy: 0.001)
        XCTAssertEqual(ranges[0].upperBound, 2.7, accuracy: 0.001)
        // A 300 ms pause is under the 400 ms minimum.
        let short = [Float](repeating: -12, count: 100) + [Float](repeating: -80, count: 30) + [Float](repeating: -12, count: 100)
        XCTAssertTrue(AOMSilenceCutter.silentRanges(levels: short).isEmpty)
        XCTAssertTrue(AOMSilenceCutter.silentRanges(levels: [Float](repeating: -120, count: 500)).isEmpty, "no speech, nothing to cut")
    }

    func testRemovingSilencesSplitsClips() {
        let clips = [AOMStudioClip(start: 0, end: 10)]
        let next = AOMSilenceCutter.removing([2...3, 6...6.5], from: clips)
        XCTAssertEqual(next.map(\.start), [0, 3, 6.5])
        XCTAssertEqual(next.map(\.end), [2, 6, 10])
        XCTAssertEqual(AOMSilenceCutter.removedSeconds([2...3, 6...6.5], from: clips), 1.5, accuracy: 0.001)
        XCTAssertEqual(AOMSilenceCutter.boundaries(next), [2, 5])
        XCTAssertEqual(AOMSilenceCutter.levels(samples: [Float](repeating: 0, count: 320), frameLength: 160), [-120, -120])
    }

    func testOneEuroSmoothsJitterAndFollowsMotion() {
        var still: [AOMCursorPoint] = []
        for i in 0..<120 { still.append(AOMCursorPoint(time: Double(i) / 60, x: 0.5 + (i % 2 == 0 ? 0.004 : -0.004), y: 0.5)) }
        let smoothed = AOMOneEuroFilter.filter(still)
        XCTAssertLessThan(abs(smoothed.last!.x - 0.5), 0.002, "jitter at rest is damped")
        var moving: [AOMCursorPoint] = []
        for i in 0..<60 { moving.append(AOMCursorPoint(time: Double(i) / 60, x: Double(i) / 60, y: 0.5)) }
        XCTAssertGreaterThan(AOMOneEuroFilter.filter(moving).last!.x, 0.9, "fast motion is not lagged far")
    }

    func testZoomFollowsPointerOnlyWhileZoomed() {
        let track = AOMCursorTrack(points: (0..<60).map { AOMCursorPoint(time: Double($0) / 60, x: 0.8, y: 0.2) })
        let zoomed = AOMStudioTimeline.following(.init(magnification: 2, x: 0.5, y: 0.5), time: 0.9, track: track)
        XCTAssertEqual(zoomed.x, 0.8, accuracy: 0.01)
        XCTAssertEqual(zoomed.y, 0.2, accuracy: 0.01)
        let resting = AOMStudioTimeline.following(.init(magnification: 1, x: 0.5, y: 0.5), time: 0.9, track: track)
        XCTAssertEqual(resting.x, 0.5)
        XCTAssertEqual(AOMCursorSampler.recordingSpacing, 1.0 / 60, accuracy: 1e-9)
    }

    func testTranscriptLinesAndMarkdown() {
        let words: [(time: Double, duration: Double, text: String)] = [(0, 0.3, "안녕하세요"), (0.4, 0.3, "여러분"), (3, 0.2, "다음")]
        let lines = MeetingTranscript.lines(words: words, speaker: "Me", offset: 50)
        XCTAssertEqual(lines.map(\.text), ["안녕하세요 여러분", "다음"])
        XCTAssertEqual(lines.map(\.time), [50, 53])
        let markdown = MeetingTranscript.markdown(title: "Standup", startedAt: Date(timeIntervalSince1970: 0), duration: 65, lines: lines)
        XCTAssertTrue(markdown.contains("**[0:50] Me:** 안녕하세요 여러분"))
        XCTAssertTrue(markdown.contains("1:05"))
        XCTAssertEqual(MeetingTranscript.clock(3_725), "1:02:05")
        XCTAssertTrue(MeetingRecorder.folderName(title: "A/B: plan", at: Date(timeIntervalSince1970: 0)).hasSuffix(" A B  plan"))
    }
}

@MainActor
final class AOM7220ToolsTests: XCTestCase {
    func testThroughputRate() {
        let rate = NetworkThroughput.rate(previous: (1_000, 500), current: (3_000, 1_500), seconds: 2)
        XCTAssertEqual(rate.received, 1_000)
        XCTAssertEqual(rate.sent, 500)
        XCTAssertEqual(NetworkThroughput.rate(previous: (5_000, 0), current: (1_000, 0), seconds: 1).received, 0, "counter reset")
    }

    func testSunburstSegmentsShareTheTurn() {
        let root = StorageNode(name: "root", url: URL(fileURLWithPath: "/tmp/r"), kind: .folder, size: 100)
        let a = StorageNode(name: "a", url: URL(fileURLWithPath: "/tmp/r/a"), kind: .file, size: 75)
        let b = StorageNode(name: "b", url: URL(fileURLWithPath: "/tmp/r/b"), kind: .file, size: 25)
        var top = TopItems(keep: 10)
        top.add(a); top.add(b)
        root.finish(top, unreadable: false, unreadableHere: 0)
        let segments = StorageSunburstLayout.segments(root)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].end, 0.75, accuracy: 1e-9)
        let hit = StorageSunburstLayout.hit(CGPoint(x: 100, y: 70), center: CGPoint(x: 100, y: 100), hole: 20, ring: 30, in: segments)
        XCTAssertEqual(hit?.node.name, "a", "straight up is the start of the first segment")
        XCTAssertNil(StorageSunburstLayout.hit(CGPoint(x: 100, y: 95), center: CGPoint(x: 100, y: 100), hole: 20, ring: 30, in: segments))
    }

    func testCodeTokens() {
        let tokens = ClipboardCodeHighlighter.tokens("let x = \"hi\" // note\n42")
        XCTAssertEqual(tokens.first?.0, .keyword)
        XCTAssertTrue(tokens.contains { $0.0 == .string && $0.1 == "\"hi\"" })
        XCTAssertTrue(tokens.contains { $0.0 == .comment && $0.1 == "// note" })
        XCTAssertTrue(tokens.contains { $0.0 == .number && $0.1 == "42" })
        XCTAssertEqual(tokens.map { String($0.1) }.joined(), "let x = \"hi\" // note\n42")
    }

    func testMeaningQueryAndScore() {
        XCTAssertEqual(ClipboardPanelState.meaningQuery("~ api key from last month"), "api key from last month")
        XCTAssertEqual(ClipboardPanelState.meaningQuery("의미: 회의록"), "회의록")
        XCTAssertNil(ClipboardPanelState.meaningQuery("plain words"))
        XCTAssertNil(ClipboardPanelState.meaningQuery("~ "))
        XCTAssertEqual(ClipboardMeaningIndex.cosine([1, 0], [1, 0]), 1, accuracy: 1e-9)
        XCTAssertEqual(ClipboardMeaningIndex.blended(cosine: 0.5, lexical: true), 0.7, accuracy: 1e-9)
    }
}
