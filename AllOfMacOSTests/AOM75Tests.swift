import JavaScriptCore
import PDFKit
import XCTest
import zlib
@testable import AllOfMacOS

/// 7.5: the Codex 7.4 audit's defects D01–D06, each with the failing case
/// it reproduced, and the file features F02, F03, F06, F07, F08.
@MainActor
final class AOM75Tests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AOM75-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: D01 duplicates checked again before the Trash

    private func duplicateSets(_ names: [String], bytes: Data) throws -> [FileTools.DuplicateSet] {
        for name in names { try bytes.write(to: scratch.appendingPathComponent(name)) }
        return FileTools.duplicateSets(FileTools.sizedFiles(in: scratch, minimumBytes: 1)) { try FileTools.sha256Hex(fileAt: $0) }
    }

    private func hash(_ url: URL) throws -> String { try FileTools.sha256Hex(fileAt: url) }

    func testD01ReplacedCopyIsHeldBack() throws {
        let sets = try duplicateSets(["A", "B"], bytes: Data(repeating: 65, count: 100_001))
        XCTAssertEqual(sets.count, 1)
        let rows = FileTools.duplicateCandidates(sets)
        XCTAssertEqual(rows.preselected.count, 1)
        // The Codex probe: the checked copy's path now holds a same-size file with other contents.
        let checked = try XCTUnwrap(rows.items.first { rows.preselected.contains($0.id) })
        try Data(repeating: 66, count: 100_001).write(to: checked.url, options: .atomic)
        let plan = FileTools.planDuplicateTrash(sets, selected: rows.preselected, hash: hash)
        XCTAssertTrue(plan.trash.isEmpty, "the new file must not reach the Trash")
        XCTAssertEqual(plan.held.count, 1)
        XCTAssertTrue(plan.held[0].contains("replaced"), plan.held[0])
    }

    func testD01UnchangedCopyGoesAndInPlaceEditIsHeld() throws {
        let sets = try duplicateSets(["A", "B"], bytes: Data(repeating: 65, count: 4_096))
        let rows = FileTools.duplicateCandidates(sets)
        XCTAssertEqual(FileTools.planDuplicateTrash(sets, selected: rows.preselected, hash: hash).trash.count, 1)
        // Same inode, same size, contents changed and the date put back.
        let checked = try XCTUnwrap(rows.items.first { rows.preselected.contains($0.id) })
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: checked.url.path)[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: checked.url)
        try handle.write(contentsOf: Data([66]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: checked.url.path)
        let plan = FileTools.planDuplicateTrash(sets, selected: rows.preselected, hash: hash)
        XCTAssertTrue(plan.trash.isEmpty)
        XCTAssertEqual(plan.held.count, 1)
    }

    func testD01KeeperChangedOrGoneHoldsTheSet() throws {
        let sets = try duplicateSets(["A", "B"], bytes: Data(repeating: 65, count: 4_096))
        let rows = FileTools.duplicateCandidates(sets)
        let keeper = try XCTUnwrap(rows.items.first { !rows.preselected.contains($0.id) })
        try FileManager.default.removeItem(at: keeper.url)
        let plan = FileTools.planDuplicateTrash(sets, selected: rows.preselected, hash: hash)
        XCTAssertTrue(plan.trash.isEmpty, "the last copy stays")
        XCTAssertTrue(plan.held.first?.contains("no copy that stays") ?? false)
    }

    func testD01EveryCopyCheckedKeepsOneAndOtherSetsStillGo() throws {
        try Data(repeating: 1, count: 2_000).write(to: scratch.appendingPathComponent("x1"))
        try Data(repeating: 1, count: 2_000).write(to: scratch.appendingPathComponent("x2"))
        try Data(repeating: 2, count: 3_000).write(to: scratch.appendingPathComponent("y1"))
        try Data(repeating: 2, count: 3_000).write(to: scratch.appendingPathComponent("y2"))
        let sets = FileTools.duplicateSets(FileTools.sizedFiles(in: scratch, minimumBytes: 1), hash: hash)
        XCTAssertEqual(sets.count, 2)
        let rows = FileTools.duplicateCandidates(sets)
        // Check every copy of both sets; then replace one copy of the second set.
        let all = Set(rows.items.map(\.id))
        let ySet = try XCTUnwrap(sets.first { $0.members.first?.fingerprint.size == 2_000 })
        let replaced = ySet.members[1].url
        try FileManager.default.removeItem(at: replaced)
        try Data(repeating: 9, count: 2_000).write(to: replaced)
        let plan = FileTools.planDuplicateTrash(sets, selected: all, hash: hash)
        XCTAssertEqual(plan.trash.count, 1, "the healthy set loses one copy and keeps one")
        XCTAssertEqual(plan.keptLast.count, 2)
        XCTAssertEqual(plan.held.count, 1)
    }

    // MARK: D02 Airplane Mode keeps what it still has to restore

    private final class FakeRadios {
        var wifi = true, bluetooth = false
        var wifiFails = false
        var saved: AOMRadios.Saved?
        var radios: AOMRadios.Radios {
            AOMRadios.Radios(wifiOn: { self.wifi }, bluetoothOn: { self.bluetooth },
                             setWiFi: { on in if self.wifiFails { return "Wi-Fi: offline" }; self.wifi = on; return nil },
                             setBluetooth: { on in self.bluetooth = on; return true },
                             load: { self.saved }, store: { self.saved = $0 }, pause: { _ in })
        }
    }

    func testD02FailedRestoreRetriesOnlyWhatWasOn() {
        let fake = FakeRadios()
        XCTAssertTrue(AOMRadios.setAirplaneMode(true, radios: fake.radios).succeeded)
        XCTAssertEqual(fake.saved, .init(wifi: true, bluetooth: false))
        fake.wifiFails = true
        let failed = AOMRadios.setAirplaneMode(false, radios: fake.radios)
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.pending, ["Wi-Fi"])
        XCTAssertEqual(failed.title, "Wi-Fi Still Off")
        XCTAssertEqual(fake.saved, .init(wifi: true, bluetooth: false), "the record stays until Wi-Fi is back")
        XCTAssertTrue(AOMRadios.isAirplaneOn(saved: fake.saved, wifiOn: fake.wifi, bluetoothOn: fake.bluetooth), "toggle retries Off")
        fake.wifiFails = false
        XCTAssertTrue(AOMRadios.setAirplaneMode(false, radios: fake.radios).succeeded)
        XCTAssertTrue(fake.wifi)
        XCTAssertFalse(fake.bluetooth, "Bluetooth was off before and stays off")
        XCTAssertNil(fake.saved)
    }

    func testD02BothOnAndOppositeAndNoRecord() {
        let fake = FakeRadios()
        fake.wifi = false; fake.bluetooth = true
        _ = AOMRadios.setAirplaneMode(true, radios: fake.radios)
        XCTAssertEqual(fake.saved, .init(wifi: false, bluetooth: true))
        _ = AOMRadios.setAirplaneMode(false, radios: fake.radios)
        XCTAssertEqual([fake.wifi, fake.bluetooth], [false, true])
        fake.wifi = true
        _ = AOMRadios.setAirplaneMode(true, radios: fake.radios)
        XCTAssertEqual(fake.saved, .init(wifi: true, bluetooth: true))
        // No record (turned off by hand, or a fresh install): both come back, as in 7.4.
        fake.saved = nil
        _ = AOMRadios.setAirplaneMode(false, radios: fake.radios)
        XCTAssertEqual([fake.wifi, fake.bluetooth], [true, true])
    }

    func testD02TurningOnAgainKeepsAPendingRadioAndSurvivesARelaunch() throws {
        let fake = FakeRadios()
        fake.bluetooth = true
        _ = AOMRadios.setAirplaneMode(true, radios: fake.radios)
        fake.wifiFails = true
        _ = AOMRadios.setAirplaneMode(false, radios: fake.radios)
        XCTAssertEqual(fake.saved, .init(wifi: true, bluetooth: false), "Bluetooth came back, Wi-Fi didn't")
        // On again before Wi-Fi came back: Wi-Fi still counts as on.
        fake.wifiFails = false
        _ = AOMRadios.setAirplaneMode(true, radios: fake.radios)
        XCTAssertEqual(fake.saved, .init(wifi: true, bluetooth: true))
        // The record is the 7.4 JSON, so a relaunch reads it back.
        let data = try JSONEncoder().encode(fake.saved)
        XCTAssertEqual(try JSONDecoder().decode(AOMRadios.Saved.self, from: data), fake.saved)
        XCTAssertNotNil(try? JSONDecoder().decode(AOMRadios.Saved.self, from: Data(#"{"wifi":true,"bluetooth":false}"#.utf8)))
    }

    // MARK: D03 / D04 browser tabs

    /// Runs a generated script against a fake browser in JavaScriptCore.
    private func runJXA(_ script: String, windows: String) -> (result: String, state: String) {
        let context = JSContext()!
        context.evaluateScript("""
        function makeTabs(spec) {
          const tabs = spec.tabs.map(t => ({ select() { state.selected = t.id; } }));
          tabs.title = () => { if (spec.failTitle) throw new Error('no'); return spec.tabs.map(t => t.title); };
          tabs.name = tabs.title;
          tabs.url = () => { if (spec.failURL) throw new Error('no'); return spec.tabs.map(t => t.url); };
          tabs.id = () => spec.tabs.map(t => t.id);
          return tabs;
        }
        var state = {};
        const fakeWindows = (\(windows)).map((spec, i) => {
          const w = { tabs: makeTabs(spec), id: () => spec.wid };
          Object.defineProperty(w, 'activeTabIndex', { set(v) { state.window = spec.wid; state.active = v; } });
          Object.defineProperty(w, 'currentTab', { set(v) { state.window = spec.wid; state.current = w.tabs.indexOf(v) + 1; } });
          Object.defineProperty(w, 'index', { set(v) { state.front = spec.wid; } });
          return w;
        });
        function Application(id) { return { windows: () => fakeWindows, activate() { state.activated = true; } }; }
        """)
        let result = context.evaluateScript(script)?.toString() ?? ""
        let state = context.evaluateScript("JSON.stringify(state)")?.toString() ?? ""
        return (result, state)
    }

    func testD03OneWindowFailingKeepsTheNextWindowsTabs() {
        let chrome = PaletteBrowserTabs.browsers[1]
        let json = runJXA(PaletteBrowserTabs.readScript(chrome), windows: """
        [{wid: 1, failURL: true, tabs: [{id: 1, title: 'A', url: 'https://a.example/'}]},
         {wid: 2, tabs: [{id: 2, title: 'B', url: 'https://b.example/'}, {id: 3, title: '', url: 'https://c.example/'}]},
         {wid: 3, tabs: []}]
        """).result
        let read = PaletteBrowserTabs.parse(json, browser: chrome)
        XCTAssertEqual(read.failedWindows, 1)
        XCTAssertEqual(read.tabs.map(\.title), ["B", "https://c.example/"])
        XCTAssertEqual(read.tabs.map(\.url), ["https://b.example/", "https://c.example/"])
        XCTAssertEqual(read.tabs.map(\.window), [2, 2], "B keeps its own window")
        XCTAssertEqual(read.tabs.first?.tabID, "2")
        XCTAssertEqual(read.tabs.first?.windowID, "2")
    }

    func testD04TabFoundByIDAfterReorder() {
        let chrome = PaletteBrowserTabs.browsers[1]
        let picked = PaletteBrowserTabs.Tab(browser: chrome, window: 1, index: 2, title: "B", url: "https://b/", windowID: "1", tabID: "b")
        // A new tab went in front and the order changed: [X, A, C, B].
        let now = runJXA(PaletteBrowserTabs.activateScript(picked), windows: """
        [{wid: 1, tabs: [{id: 'x', title: 'X', url: 'https://x/'}, {id: 'a', title: 'A', url: 'https://a/'},
                         {id: 'c', title: 'C', url: 'https://c/'}, {id: 'b', title: 'B', url: 'https://b/'}]}]
        """)
        XCTAssertEqual(now.result, "ok")
        XCTAssertTrue(now.state.contains(#""active":4"#), now.state)
        // The tab was closed.
        let closed = runJXA(PaletteBrowserTabs.activateScript(picked), windows: "[{wid: 1, tabs: [{id: 'a', title: 'A', url: 'https://a/'}]}]")
        XCTAssertEqual(closed.result, "closed")
        XCTAssertFalse(closed.state.contains("active"))
        // Arc selects the tab it finds by id.
        let arc = PaletteBrowserTabs.Tab(browser: PaletteBrowserTabs.browsers[2], window: 1, index: 1, title: "B", url: "https://b/", tabID: "b")
        let selected = runJXA(PaletteBrowserTabs.activateScript(arc), windows: "[{wid: 9, tabs: [{id: 'a', title: 'A', url: 'https://a/'}, {id: 'b', title: 'B', url: 'https://b/'}]}]")
        XCTAssertTrue(selected.state.contains(#""selected":"b""#), selected.state)
    }

    func testD04ResolveWithoutIDsNeedsOneMatch() {
        let safari = PaletteBrowserTabs.browsers[0]
        func tab(_ w: Int, _ i: Int, _ title: String, _ url: String) -> PaletteBrowserTabs.Tab {
            .init(browser: safari, window: w, index: i, title: title, url: url, windowID: "\(w)")
        }
        let picked = tab(1, 2, "B", "https://b/")
        // Moved: [A, C, B] → found at its new place.
        guard case .found(let moved, false) = PaletteBrowserTabs.resolve(picked, in: [tab(1, 1, "A", "https://a/"), tab(1, 2, "C", "https://c/"), tab(1, 3, "B", "https://b/")]) else {
            return XCTFail()
        }
        XCTAssertEqual(moved.index, 3)
        XCTAssertEqual(PaletteBrowserTabs.resolve(picked, in: [tab(1, 1, "A", "https://a/")]), .closed)
        // The same address twice with the same title, neither where it was.
        XCTAssertEqual(PaletteBrowserTabs.resolve(picked, in: [tab(2, 1, "B", "https://b/"), tab(2, 4, "B", "https://b/")]), .ambiguous(2))
        // An id-matched tab that went to another address is still that tab.
        let chrome = PaletteBrowserTabs.Tab(browser: PaletteBrowserTabs.browsers[1], window: 1, index: 1, title: "B", url: "https://b/", tabID: "7")
        let navigated = PaletteBrowserTabs.Tab(browser: PaletteBrowserTabs.browsers[1], window: 2, index: 5, title: "Z", url: "https://z/", tabID: "7")
        XCTAssertEqual(PaletteBrowserTabs.resolve(chrome, in: [navigated]), .found(navigated, moved: true))
        XCTAssertEqual(PaletteBrowserTabs.ActivateResult.shown(moved: "z").message, "That tab now shows z")
    }

    func testD04SafariScriptShowsThePositionJustRead() {
        let safari = PaletteBrowserTabs.Tab(browser: PaletteBrowserTabs.browsers[0], window: 2, index: 1, title: "B", url: "https://b/")
        let run = runJXA(PaletteBrowserTabs.activateScript(safari), windows: """
        [{wid: 5, tabs: [{title: 'A', url: 'https://a/'}]}, {wid: 6, tabs: [{title: 'B', url: 'https://b/'}]}]
        """)
        XCTAssertEqual(run.result, "ok")
        XCTAssertTrue(run.state.contains(#""window":6"#) && run.state.contains(#""current":1"#), run.state)
    }

    // MARK: D05 / D06 meeting alerts

    private func event(_ title: String, start: TimeInterval, length: TimeInterval = 1_800, allDay: Bool = false, now: Date) -> PaletteSchedule.Event {
        PaletteSchedule.Event(id: title, title: title, start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + length),
                              isAllDay: allDay, calendar: "Work", location: nil, meetingLink: nil)
    }

    func testD05AShownEventDoesNotBlockTheNextOne() {
        // The Codex case: A started 60 s ago and was dismissed; B starts in 40 s.
        let start = Date()
        let a = event("A", start: -60, length: 1_800, now: start)
        let b = event("B", start: 40, length: 100, now: start)
        let alerted: Set<String> = [MeetingAlerts.key(a)]
        var shownB = 0
        for step in stride(from: 0.0, through: 140, by: 15) {
            let now = start.addingTimeInterval(step)
            if let due = MeetingAlerts.dueAlert([a, b], now: now, lead: 60, alerted: alerted.union(shownB > 0 ? [MeetingAlerts.key(b)] : []), snoozed: [:]) {
                XCTAssertEqual(due.title, "B")
                shownB += 1
            }
        }
        XCTAssertEqual(shownB, 1, "B shows once inside its lead time")
        XCTAssertEqual(MeetingAlerts.next([a, b], now: start, window: 1_800)?.title, "A", "the menu bar still counts A")
    }

    func testD05SimultaneousSnoozeAllDayAndEnded() {
        let now = Date()
        let one = PaletteSchedule.Event(id: "2", title: "Two", start: now.addingTimeInterval(30), end: now.addingTimeInterval(600),
                                        isAllDay: false, calendar: "", location: nil, meetingLink: nil)
        let other = PaletteSchedule.Event(id: "1", title: "One", start: now.addingTimeInterval(30), end: now.addingTimeInterval(600),
                                          isAllDay: false, calendar: "", location: nil, meetingLink: nil)
        let first = MeetingAlerts.dueAlert([one, other], now: now, lead: 60, alerted: [], snoozed: [:])
        XCTAssertEqual(first?.id, "1", "same start: ordered by key")
        let second = MeetingAlerts.dueAlert([one, other], now: now, lead: 60, alerted: [MeetingAlerts.key(other)], snoozed: [:])
        XCTAssertEqual(second?.id, "2")
        XCTAssertNil(MeetingAlerts.dueAlert([one, other], now: now, lead: 60, alerted: [MeetingAlerts.key(one), MeetingAlerts.key(other)], snoozed: [:]))
        // A snooze brings it back after a minute, even past the five-minute cut.
        let late = now.addingTimeInterval(400)
        XCTAssertEqual(MeetingAlerts.dueAlert([one], now: late, lead: 60, alerted: [MeetingAlerts.key(one)],
                                              snoozed: [MeetingAlerts.key(one): late.addingTimeInterval(-1)])?.id, "2")
        XCTAssertNil(MeetingAlerts.dueAlert([event("Holiday", start: 10, allDay: true, now: now)], now: now, lead: 60, alerted: [], snoozed: [:]))
        XCTAssertNil(MeetingAlerts.dueAlert([event("Over", start: -900, length: 600, now: now)], now: now, lead: 60, alerted: [], snoozed: [:]))
        XCTAssertNil(MeetingAlerts.dueAlert([event("Long running", start: -3_600, length: 7_200, now: now)], now: now, lead: 60, alerted: [], snoozed: [:]),
                     "an event that started an hour ago doesn't alert at launch")
    }

    func testD06AlertRangeCrossesMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 23, minute: 50)))
        let meeting = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 0, minute: 2)))
        let range = MeetingAlerts.feedRange(now: late)
        XCTAssertTrue(range.start < late && meeting < range.end, "00:02 is read at 23:50")
        let e = PaletteSchedule.Event(id: "m", title: "Midnight", start: meeting, end: meeting.addingTimeInterval(1_800),
                                      isAllDay: false, calendar: "", location: nil, meetingLink: nil)
        XCTAssertEqual(MeetingAlerts.next([e], now: late, window: 1_800)?.id, "m")
        XCTAssertEqual(MeetingAlerts.dueAlert([e], now: meeting.addingTimeInterval(-50), lead: 60, alerted: [], snoozed: [:])?.id, "m")
    }

    // MARK: F02 snippet choices and optional sections

    private let reply = """
    안녕하세요 {arg:고객명}님,
    {choice:수령 방식|배송|방문}으로 준비하겠습니다.
    {optional:서명 넣기}
    --
    김용우 드림
    {/optional}
    감사합니다, {arg:고객명}님.
    """

    func testF02ChoiceAndSectionLeftOutLeaveNoEmptyLine() throws {
        let tokens = try SnippetTemplate.parse(reply).get()
        let fields = SnippetTemplate.fields(tokens)
        XCTAssertEqual(fields.map(\.name), ["고객명", "수령 방식", "서명 넣기"], "고객명 is asked once")
        let out = SnippetTemplate.render(tokens, context: .init(arguments: ["고객명": "이", "수령 방식": "방문", "서명 넣기": SnippetField.off]))
        XCTAssertEqual(out.text, "안녕하세요 이님,\n방문으로 준비하겠습니다.\n감사합니다, 이님.")
        let signed = SnippetTemplate.render(tokens, context: .init(arguments: ["고객명": "이"]))
        XCTAssertEqual(signed.text, "안녕하세요 이님,\n배송으로 준비하겠습니다.\n--\n김용우 드림\n감사합니다, 이님.", "defaults: first option, section in")
    }

    func testF02DefaultsInlineSectionsAndErrors() throws {
        let tokens = try SnippetTemplate.parse("Thanks{optional:sig|off}, Kim{/optional}. {choice:Way|Post|*Visit}").get()
        XCTAssertEqual(SnippetTemplate.render(tokens).text, "Thanks. Visit")
        XCTAssertEqual(SnippetTemplate.render(tokens, context: .init(arguments: ["sig": "1", "Way": "Post"])).text, "Thanks, Kim. Post")
        for broken in ["{optional:a}x{optional:b}y{/optional}{/optional}", "{optional:a} no end", "stray {/optional}",
                       "{choice:only|one}", "{choice:x|*a|*b}", "{arg:x} {choice:x|a|b}", "{optional:a|maybe}x{/optional}"] {
            guard case .failure = SnippetTemplate.parse(broken) else { return XCTFail("should fail: \(broken)") }
        }
        // Old snippets stay literal.
        XCTAssertEqual(try SnippetTemplate.render(text: "{choice:x|a|b}", syntax: nil).get().text, "{choice:x|a|b}")
        // A repeated choice is one question.
        XCTAssertEqual(SnippetTemplate.fields(try SnippetTemplate.parse("{choice:x|a|b} {choice:x|a|b}").get()).count, 1)
        XCTAssertEqual(PaletteSnippets.preview(text: "{choice:Way|Post|*Visit} {arg:who}", syntax: 2), "Visit ‹who›")
    }

    func testF02FieldsInsideASectionLeftOutAreSkipped() throws {
        let tokens = try SnippetTemplate.parse("Hi {arg:name}{optional:PS|on}\nP.S. {arg:note} {choice:tone|warm|plain}{/optional}").get()
        var request = PaletteSnippetForm.Request(snippetID: UUID(), fields: SnippetTemplate.fields(tokens))
        XCTAssertEqual(request.fields.map(\.section), [nil, nil, "PS", "PS"])
        XCTAssertEqual(request.step.1, 4)
        request.answer("Lee")
        request.answer(SnippetField.off)
        XCTAssertTrue(request.isComplete, "note and tone aren't asked once P.S. is left out")
        XCTAssertEqual(SnippetTemplate.render(tokens, context: .init(arguments: request.values)).text, "Hi Lee")
        var both = PaletteSnippetForm.Request(snippetID: UUID(), fields: SnippetTemplate.fields(tokens))
        both.answer("Lee"); both.answer(SnippetField.on)
        XCTAssertEqual(both.currentName, "note")
        XCTAssertFalse(both.isLast)
        both.answer("see you"); XCTAssertTrue(both.isLast)
        both.answer("plain")
        XCTAssertEqual(SnippetTemplate.render(tokens, context: .init(arguments: both.values)).text, "Hi Lee\nP.S. see you plain")
    }

    // MARK: F03 ZIP

    /// A ZIP with stored entries, written by hand (names as given, so unsafe ones too).
    private func storedZip(_ entries: [(String, Data, flags: UInt16)], at url: URL) throws {
        var archive = Data(), directory = Data()
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        for (name, data, flags) in entries {
            let offset = UInt32(archive.count)
            let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count))) }
            let nameData = Data(name.utf8)
            var common = le16(20) + le16(flags | 0x0800) + le16(0) + le16(0) + le16(0x5B76)
            common += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(UInt16(nameData.count)) + le16(0)
            archive += le32(0x0403_4b50) + common + nameData + data
            directory += le32(0x0201_4b50) + le16(0x0314) + common + le16(0) + le16(0) + le16(0) + le32(0o100644 << 16) + le32(offset) + nameData
        }
        let start = UInt32(archive.count)
        archive += directory
        archive += le32(0x0605_4b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        archive += le32(UInt32(directory.count)) + le32(start) + le16(0)
        try archive.write(to: url)
    }

    func testF03PickTwoOfAHundredWithSameNamesAndKorean() throws {
        let source = scratch.appendingPathComponent("src/Bundle", isDirectory: true)
        for folder in ["계약/2026", "Archive/Old", "misc"] {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("new contract".utf8).write(to: source.appendingPathComponent("계약/2026/report.pdf"))
        try Data("old contract".utf8).write(to: source.appendingPathComponent("Archive/Old/report.pdf"))
        for number in 1...98 { try Data(repeating: UInt8(number), count: 3_000 + number).write(to: source.appendingPathComponent("misc/file\(number).bin")) }
        let zip = scratch.appendingPathComponent("bundle.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let files = try ZipArchive.entries(of: zip).filter { !$0.isDirectory }
        XCTAssertEqual(files.count, 100)
        let reports = files.filter { $0.name == "report.pdf" }
        XCTAssertEqual(reports.count, 2, "same names in different folders are two entries")
        XCTAssertEqual(Set(reports.map(\.folder)), ["Bundle/계약/2026", "Bundle/Archive/Old"])
        XCTAssertEqual(ZipExtractModel.filter(files, query: "계약 report").count, 1)

        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let picked = reports + [files.first { $0.name == "file7.bin" }!]
        let outcome = ZipArchive.extract(Array(picked.prefix(2)), from: zip, into: out)
        XCTAssertEqual(outcome.written.count, 2)
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Bundle/계약/2026/report.pdf"), encoding: .utf8), "new contract")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Bundle/Archive/Old/report.pdf"), encoding: .utf8), "old contract")
        let made = FileManager.default.subpaths(atPath: out.path)?.sorted() ?? []
        XCTAssertEqual(made, ["Bundle", "Bundle/Archive", "Bundle/Archive/Old", "Bundle/Archive/Old/report.pdf",
                              "Bundle/계약", "Bundle/계약/2026", "Bundle/계약/2026/report.pdf"].sorted(), "only the two files and their folders")

        // Again into the same place: the files there stay, the new ones get numbers.
        let again = ZipArchive.extract(Array(picked.prefix(1)), from: zip, into: out)
        XCTAssertEqual(again.written.first?.lastPathComponent, "report 2.pdf")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Bundle/\(reports[0].folder.dropFirst("Bundle/".count))/report.pdf"), encoding: .utf8),
                       reports[0].folder.contains("계약") ? "new contract" : "old contract")
        // Flattened: both report.pdf in one folder, the second numbered.
        let flat = scratch.appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        let flattened = ZipArchive.extract(reports, from: zip, into: flat, keepFolders: false)
        XCTAssertEqual(flattened.written.map(\.lastPathComponent).sorted(), ["report 2.pdf", "report.pdf"])
        // Cancelled before the first entry: nothing written, no temporary file left.
        let stopped = scratch.appendingPathComponent("stopped", isDirectory: true)
        try FileManager.default.createDirectory(at: stopped, withIntermediateDirectories: true)
        XCTAssertTrue(ZipArchive.extract(reports, from: zip, into: stopped, isCancelled: { true }).cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stopped.path), [])
    }

    func testF03UnsafeEncryptedAndLinkedEntriesAreNotWritten() throws {
        let zip = scratch.appendingPathComponent("odd.zip")
        try storedZip([("../escape.txt", Data("x".utf8), 0), ("ok/fine.txt", Data("fine".utf8), 0),
                       ("secret.txt", Data("s".utf8), 0x0001), ("/abs/root.txt", Data("r".utf8), 0)], at: zip)
        let entries = try ZipArchive.entries(of: zip)
        XCTAssertEqual(entries.count, 4)
        XCTAssertNotNil(entries[0].unsupported, "climbs out")
        XCTAssertNil(entries[1].unsupported)
        XCTAssertTrue(entries[2].unsupported?.contains("Password") ?? false)
        XCTAssertEqual(entries[3].components, ["abs", "root.txt"], "a leading / stays inside")
        let out = scratch.appendingPathComponent("odd-out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let outcome = ZipArchive.extract(entries, from: zip, into: out)
        XCTAssertEqual(outcome.written.count, 2)
        XCTAssertEqual(outcome.failures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escape.txt").path))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("ok/fine.txt"), encoding: .utf8), "fine")
        // A folder already there that links outside the destination isn't written through.
        let elsewhere = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linked = scratch.appendingPathComponent("linked-out", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("ok"), withDestinationURL: elsewhere)
        let blocked = ZipArchive.extract([entries[1]], from: zip, into: linked)
        XCTAssertTrue(blocked.written.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        XCTAssertNil(ZipArchive.safeComponents("a/../../b"))
        XCTAssertEqual(ZipArchive.numberedName("README", 2), "README 2")
        XCTAssertThrowsError(try ZipArchive.entries(of: scratch.appendingPathComponent("odd-out/ok/fine.txt")))
    }

    // MARK: F06 storage map

    func testF06TreeSizesDrillDownAndHardLinks() throws {
        let root = scratch.appendingPathComponent("disk", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A/B"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: root.appendingPathComponent("A/B/big.bin"))
        try Data(repeating: 2, count: 300_000).write(to: root.appendingPathComponent("A/small.bin"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("A/B/big.bin"), to: root.appendingPathComponent("A/big-link.bin"))
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 50_000).write(to: locked.appendingPathComponent("hidden.bin"))
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }

        let scan = try XCTUnwrap(StorageMap.scan(root))
        XCTAssertEqual(scan.hardLinksSkipped, 1)
        let a = try XCTUnwrap(scan.root.children.first)
        XCTAssertEqual(a.name, "A", "largest first")
        let b = try XCTUnwrap(a.children.first { $0.name == "B" })
        let big = try XCTUnwrap(b.children.first)
        XCTAssertEqual(big.name, "big.bin")
        XCTAssertEqual(big.path.map(\.name), ["disk", "A", "B", "big.bin"], "top → folder → file")
        XCTAssertEqual(a.size, a.children.reduce(0) { $0 + $1.size }, "the list and the map add up the same")
        XCTAssertEqual(scan.root.size, scan.root.children.reduce(0) { $0 + $1.size })
        // "B" sorts before "big-link.bin", so the file in B counts and the link is 0.
        XCTAssertGreaterThan(big.size, 1_900_000)
        XCTAssertEqual(a.children.first { $0.name == "big-link.bin" }?.size, 0)
        XCTAssertLessThan(a.size, 2_000_000 + 400_000, "the hard link isn't counted twice")
        let lockedNode = try XCTUnwrap(scan.root.children.first { $0.name == "Locked" })
        XCTAssertTrue(lockedNode.unreadable)
        let empty = try XCTUnwrap(scan.root.children.first { $0.name == "Empty" })
        XCTAssertFalse(empty.unreadable)
        XCTAssertEqual(empty.size, 0)
        XCTAssertEqual(scan.root.unreadableBelow, 1)
        XCTAssertNil(StorageMap.scan(root, isCancelled: { true }))
    }

    func testF06TenThousandFilesReportProgressAndStop() throws {
        let root = scratch.appendingPathComponent("many", isDirectory: true)
        for folder in 0..<100 {
            let dir = root.appendingPathComponent("d\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<100 { FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(file)").path, contents: Data([1])) }
        }
        var reports = 0
        let started = Date()
        let scan = try XCTUnwrap(StorageMap.scan(root) { _ in reports += 1 })
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(scan.root.fileCount, 10_000)
        XCTAssertEqual(scan.root.children.count, 100)
        print("F06: 10,000 files measured in \(String(format: "%.2f", elapsed)) s with \(reports) progress reports")
        XCTAssertLessThan(elapsed, 20)
        // Stop partway: the scan returns nothing instead of a partial map.
        var seen = 0
        XCTAssertNil(StorageMap.scan(root, isCancelled: { seen += 1; return seen > 30 }))
    }

    func testF06SquarifiedRectsFillWithoutOverlap() {
        let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1, 0]
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = StorageMap.squarify(sizes, in: bounds)
        let total = sizes.reduce(0, +)
        for (size, rect) in zip(sizes, rects) where size > 0 {
            XCTAssertEqual(Double(rect.width * rect.height), size / total * 240_000, accuracy: 1)
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect))
        }
        XCTAssertEqual(rects[7], .zero)
        for i in rects.indices { for j in rects.indices where j > i {
            XCTAssertLessThan(rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height, 0.5)
        } }
    }

    // MARK: F07 Compare PDFs

    private func pdf(pages: Int, at url: URL) throws {
        let document = PDFDocument()
        for number in 0..<pages {
            let image = NSImage(size: NSSize(width: 200, height: 280), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                ("Page \(number + 1)" as NSString).draw(at: NSPoint(x: 20, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
                return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: number)
        }
        XCTAssertTrue(document.write(to: url))
    }

    func testF07LinkedPagesMissingPageAndSwap() throws {
        let draft = scratch.appendingPathComponent("draft.pdf"), revised = scratch.appendingPathComponent("revised.pdf")
        try pdf(pages: 8, at: draft)
        try pdf(pages: 5, at: revised)
        let before = try [draft, revised].map(hash)
        let model = PDFCompareModel()
        model.open(draft, side: .left)
        model.open(revised, side: .right)
        XCTAssertEqual(model.sync.counts[.left], 8)
        model.sync.move(.left, to: 3)
        XCTAssertEqual(model.sync.pages[.right], 3, "page 4 is linked")
        XCTAssertNil(model.sync.missingPage(on: .right))
        model.sync.move(.left, to: 6)
        XCTAssertEqual(model.sync.pages[.right], 3, "the short one stays where it was")
        XCTAssertEqual(model.sync.missingPage(on: .right), "No page 7 here · this PDF has 5 pages")
        model.swap()
        XCTAssertEqual(model.pane(.left).url, revised)
        XCTAssertEqual(model.sync.pages[.left], 3)
        XCTAssertEqual(model.sync.pages[.right], 6, "each document keeps its page")
        XCTAssertEqual(model.sync.missingPage(on: .left), "No page 7 here · this PDF has 5 pages")
        model.sync.linked = false
        model.sync.move(.left, to: 0)
        XCTAssertEqual(model.sync.pages[.right], 6, "unlinked sides scroll on their own")
        XCTAssertEqual(try [draft, revised].map(hash), before, "neither file changed")
    }

    // MARK: F08 Compare Folders

    func testF08DifferencesCopyMissingAndRerun() throws {
        let left = scratch.appendingPathComponent("Work", isDirectory: true), right = scratch.appendingPathComponent("SSD", isDirectory: true)
        for root in [left, right] { try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true) }
        func put(_ text: String, _ root: URL, _ path: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        try put("same", left, "a.txt"); try put("same", right, "a.txt")
        try put("inner", left, "sub/b.txt"); try put("inner", right, "sub/B.txt")
        try put("left only", left, "only-left.txt")
        try put("right only", right, "only-right.txt")
        try put("AAAA", left, "tricky.txt"); try put("BBBB", right, "tricky.txt")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for root in [left, right] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent("tricky.txt").path)
        }
        try FileManager.default.createDirectory(at: left.appendingPathComponent("New Folder/deep"), withIntermediateDirectories: true)
        try put("deep", left, "New Folder/deep/x.txt")

        let comparison = try XCTUnwrap(FolderCompare.compare(left, right))
        func status(_ id: String) -> FolderCompare.Status? { comparison.items.first { $0.id == id }?.status }
        XCTAssertEqual(status("a.txt"), .same)
        XCTAssertEqual(status("tricky.txt"), .differs, "same size and date, other contents")
        XCTAssertEqual(status("only-left.txt"), .leftOnly)
        XCTAssertEqual(status("only-right.txt"), .rightOnly)
        XCTAssertEqual(status("new folder"), .leftOnly, "a missing folder is one row")
        XCTAssertEqual(comparison.items.first { $0.id == "new folder" }?.left?.files, 1)
        if comparison.ignoresCase { XCTAssertEqual(status("sub/b.txt"), .same, "B.txt matches b.txt where case doesn't count") }

        let missing = comparison.items.filter { $0.canCopy && $0.status == .leftOnly }
        XCTAssertEqual(missing.count, 2)
        // Something appears at one destination after the comparison: it stays.
        try put("theirs", right, "only-left.txt")
        let result = FolderCompare.copyMissing(missing, direction: .leftToRight)
        XCTAssertEqual(result.copied, ["new folder"])
        XCTAssertNotNil(result.skipped["only-left.txt"])
        XCTAssertEqual(try String(contentsOf: right.appendingPathComponent("only-left.txt"), encoding: .utf8), "theirs")
        XCTAssertEqual(try String(contentsOf: right.appendingPathComponent("New Folder/deep/x.txt"), encoding: .utf8), "deep")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: right.path).contains { $0.hasPrefix(".aom-copy-") })

        // Compared again: what was copied is the same now and isn't offered again.
        let again = try XCTUnwrap(FolderCompare.compare(left, right))
        XCTAssertEqual(again.items.first { $0.id == "new folder/deep/x.txt" }?.status, .same, "the copied folder is on both sides now")
        XCTAssertNil(again.items.first { $0.id == "new folder" })
        XCTAssertTrue(again.items.filter { $0.canCopy && $0.status == .leftOnly }.isEmpty)
    }

    func testF08ChangedSourceNestedRootsAndKeys() throws {
        let left = scratch.appendingPathComponent("L", isDirectory: true), right = scratch.appendingPathComponent("R", isDirectory: true)
        for root in [left, right] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        try Data("v1".utf8).write(to: left.appendingPathComponent("doc.txt"))
        let comparison = try XCTUnwrap(FolderCompare.compare(left, right))
        try Data("version 2".utf8).write(to: left.appendingPathComponent("doc.txt"))
        let result = FolderCompare.copyMissing(comparison.items, direction: .leftToRight)
        XCTAssertEqual(result.skipped["doc.txt"], "Changed since the comparison; compare again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("doc.txt").path))
        let inner = left.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FolderCompare.compare(left, inner)) { XCTAssertEqual($0 as? FolderCompare.Failure, .nested) }
        XCTAssertThrowsError(try FolderCompare.compare(left, left)) { XCTAssertEqual($0 as? FolderCompare.Failure, .sameFolder) }
        XCTAssertEqual(FolderCompare.key("Re\u{0301}sume\u{0301}.TXT", ignoresCase: true), "résumé.txt")
        XCTAssertEqual(FolderCompare.key("한글", ignoresCase: false), "한글".precomposedStringWithCanonicalMapping)
        XCTAssertNotEqual(FolderCompare.key("A", ignoresCase: false), FolderCompare.key("a", ignoresCase: false))
    }
}
