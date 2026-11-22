import JavaScriptCore
import XCTest
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
}
