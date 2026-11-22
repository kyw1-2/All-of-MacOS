import AppKit
import PDFKit
import XCTest
import zlib
@testable import AllOfMacOS

/// 7.6: Codex's audit of 7.5 (DT, FC, Z, SM, F07a, MB, BT, SEC) and the
/// menu bar features W01 weather, M04 sections, M08 strip, M12/AUD-01.
@MainActor
final class AOM76Tests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AOM76-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func hash(_ url: URL) throws -> String { try FileTools.sha256Hex(fileAt: url) }

    // MARK: DT01 / DT02

    func testDT01KeeperChangingDuringTheBatchHoldsTheRest() throws {
        for name in ["a1", "a2", "a3"] { try Data(repeating: 7, count: 5_000).write(to: scratch.appendingPathComponent(name)) }
        let sets = FileTools.duplicateSets(FileTools.sizedFiles(in: scratch, minimumBytes: 1), hash: hash)
        let rows = FileTools.duplicateCandidates(sets)
        let keeper = try XCTUnwrap(rows.items.first { !rows.preselected.contains($0.id) }).url
        var moved: [URL] = []
        let result = FileTools.trashDuplicates(sets, selected: rows.preselected, hash: hash) { url in
            moved.append(url)
            // After the first move the copy that stays is replaced.
            try FileManager.default.removeItem(at: keeper)
            try Data(repeating: 9, count: 5_000).write(to: keeper)
        }
        XCTAssertEqual(moved.count, 1, "the second copy isn't moved once the keeper changed")
        XCTAssertEqual(result.held.count, 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
    }

    func testDT02KeptLastPlusAFailureIsNotASuccess() throws {
        for name in ["b1", "b2"] { try Data(repeating: 3, count: 4_000).write(to: scratch.appendingPathComponent(name)) }
        let sets = FileTools.duplicateSets(FileTools.sizedFiles(in: scratch, minimumBytes: 1), hash: hash)
        let all = Set(FileTools.duplicateCandidates(sets).items.map(\.id))
        let result = FileTools.trashDuplicates(sets, selected: all, hash: hash) { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertEqual(result.keptLast.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.held.isEmpty)
        XCTAssertFalse(result.succeeded, "a refused move is never reported as done")
        XCTAssertTrue(result.summary.contains("couldn't be moved"))
    }

    // MARK: FC01–FC04

    private func folders() throws -> (URL, URL) {
        let left = scratch.appendingPathComponent("L", isDirectory: true), right = scratch.appendingPathComponent("R", isDirectory: true)
        for root in [left, right] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        return (left, right)
    }

    func testFC01FolderChangedAfterComparisonIsHeld() throws {
        let (left, right) = try folders()
        try FileManager.default.createDirectory(at: left.appendingPathComponent("New/inner"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: left.appendingPathComponent("New/inner/a.txt"))
        let comparison = try XCTUnwrap(FolderCompare.compare(left, right))
        try Data("2".utf8).write(to: left.appendingPathComponent("New/inner/b.txt"))
        let result = FolderCompare.copyMissing(comparison.items, direction: .leftToRight)
        XCTAssertEqual(result.skipped["new"], "The folder changed since the comparison; compare again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("New").path))
    }

    func testFC02StopInsideAFolderCopyLeavesNothing() throws {
        let (left, right) = try folders()
        let big = left.appendingPathComponent("Big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for number in 0..<40 { try Data([UInt8(number)]).write(to: big.appendingPathComponent("f\(number)")) }
        let comparison = try XCTUnwrap(FolderCompare.compare(left, right))
        var checks = 0
        let result = FolderCompare.copyMissing(comparison.items, direction: .leftToRight, isCancelled: { checks += 1; return checks > 10 })
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.copied.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: right.path), [], "no partial folder, no temporary copy")
    }

    func testFC04RowsKeepTheFoldersSpelling() throws {
        let (left, right) = try folders()
        for root in [left, right] { try FileManager.default.createDirectory(at: root.appendingPathComponent("ProjectA/Reports"), withIntermediateDirectories: true) }
        try Data("q1".utf8).write(to: left.appendingPathComponent("ProjectA/Reports/Q1.pdf"))
        let comparison = try XCTUnwrap(FolderCompare.compare(left, right))
        let row = try XCTUnwrap(comparison.items.first { $0.status == .leftOnly })
        XCTAssertEqual(row.path, "ProjectA/Reports/Q1.pdf")
        if comparison.ignoresCase { XCTAssertEqual(row.id, "projecta/reports/q1.pdf") }
    }

    func testFC01FileWithoutFingerprintIsNeverCopied() throws {
        let (left, right) = try folders()
        try Data("x".utf8).write(to: left.appendingPathComponent("doc.txt"))
        var comparison = try XCTUnwrap(FolderCompare.compare(left, right))
        let index = try XCTUnwrap(comparison.items.firstIndex { $0.id == "doc.txt" })
        let side = try XCTUnwrap(comparison.items[index].left)
        comparison.items[index].left = FolderCompare.Side(url: side.url, size: side.size, modified: side.modified, isFolder: false, isLink: false, fingerprint: nil)
        let result = FolderCompare.copyMissing(comparison.items, direction: .leftToRight)
        XCTAssertNotNil(result.skipped["doc.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("doc.txt").path))
    }

    // MARK: Z01 / Z02

    private func entry(_ id: Int, size: Int64) -> ZipArchive.Entry {
        ZipArchive.Entry(id: id, path: "f\(id)", components: ["f\(id)"], size: size, compressedSize: size, method: 0, crc: 0,
                         localHeaderOffset: 0, isDirectory: false, modified: nil, unsupported: nil)
    }

    func testZ01TotalsNeverTrap() {
        XCTAssertEqual(ZipArchive.totalSize([entry(1, size: 10), entry(2, size: 20)]), 30)
        XCTAssertNil(ZipArchive.totalSize([entry(1, size: .max), entry(2, size: 1)]))
        let outcome = ZipArchive.extract([entry(1, size: .max), entry(2, size: .max)], from: scratch.appendingPathComponent("none.zip"), into: scratch)
        XCTAssertTrue(outcome.written.isEmpty)
        XCTAssertTrue(outcome.failures.first?.contains("add up") ?? false)
    }

    func testZ02BudgetAndFreeSpaceStopBeforeWriting() {
        let picked = [entry(1, size: 600), entry(2, size: 600)]
        let overBudget = ZipArchive.extract(picked, from: scratch.appendingPathComponent("none.zip"), into: scratch, budget: 1_000)
        XCTAssertTrue(overBudget.failures.first?.contains("over the") ?? false)
        let noSpace = ZipArchive.extract(picked, from: scratch.appendingPathComponent("none.zip"), into: scratch, freeSpace: { _ in 1_100 })
        XCTAssertTrue(noSpace.failures.first?.contains("is free") ?? false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    // MARK: SM01

    func testSM01TopItemsKeepTheLargestAndCountEverything() {
        var top = TopItems(keep: 3)
        for size in 1...1_000 { top.add(StorageNode(name: "f\(size)", url: scratch, kind: .file, size: Int64(size), fileCount: 1)) }
        XCTAssertEqual(top.sortedKept.map(\.size), [1_000, 999, 998])
        XCTAssertEqual(top.totalFiles, 1_000)
        XCTAssertEqual(top.totalSize, 500_500)
        XCTAssertLessThanOrEqual(top.kept.count, 6, "never holds more than twice what it keeps")
        let folder = StorageNode(name: "wide", url: scratch, kind: .folder)
        folder.finish(top, unreadable: false, unreadableHere: 0)
        XCTAssertEqual(folder.children.count, 4, "three largest and one 'smaller items'")
        XCTAssertEqual(folder.children.last?.kind, .smallerItems(997))
        XCTAssertEqual(folder.size, folder.children.reduce(0) { $0 + $1.size })
    }

    // MARK: F07a

    private func pdf(pages: Int, at url: URL) throws {
        let document = PDFDocument()
        for number in 0..<pages {
            let image = NSImage(size: NSSize(width: 100, height: 140), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: number)
        }
        XCTAssertTrue(document.write(to: url))
    }

    func testF07aBadgeSaysNoMatchingPageWhenLinkedPagesDontLineUp() throws {
        let three = scratch.appendingPathComponent("three.pdf"), one = scratch.appendingPathComponent("one.pdf")
        try pdf(pages: 3, at: three)
        try pdf(pages: 1, at: one)
        let model = PDFCompareModel()
        model.open(three, side: .left)
        model.open(one, side: .right)
        model.sync.move(.left, to: 2)
        XCTAssertEqual(model.textVerdict?.verdict, .noMatchingPage)
        model.sync.linked = false
        XCTAssertEqual(model.textVerdict?.verdict, .noText, "unlinked: the two pages on screen (image pages have no text)")
        XCTAssertEqual(model.textVerdict?.linked, false)
    }

    // MARK: MB01 / MB05

    private func item(_ title: String, id: String = "", ordinal: Int, siblings: Int = 2, unique: Bool = true) -> AOMMenuShelfItem {
        AOMMenuShelfItem(pid: 1, ownerBundleID: "com.example.weather", ownerName: "Weather", title: title, axIdentifier: id,
                         ordinal: ordinal, siblings: siblings, identifierIsUnique: unique)
    }

    func testMB01PinsSurviveTitleChangesAndDuplicatesStayApart() {
        let before = item("18°C", ordinal: 0), after = item("19°C", ordinal: 0)
        XCTAssertEqual(before.pinKey, after.pinKey, "a changing title keeps the pin")
        let twins = [item("A", id: "status", ordinal: 0, unique: false), item("B", id: "status", ordinal: 1, unique: false)]
        XCTAssertEqual(AOMMenuShelfPolicy.ordered(twins, pinned: [], query: "").count, 2, "two items sharing an identifier are two rows")
        XCTAssertNotEqual(twins[0].pinKey, twins[1].pinKey)
        // Pressing: one sure match only.
        let live = [AOMMenuShelfPolicy.Live(identifier: "status", title: "A"), .init(identifier: "status", title: "B")]
        XCTAssertEqual(AOMMenuShelfPolicy.resolve(twins[1], in: live), 1)
        XCTAssertNil(AOMMenuShelfPolicy.resolve(twins[1], in: live + [.init(identifier: "status", title: "C")]), "a third twin: no guess")
        XCTAssertEqual(AOMMenuShelfPolicy.resolve(after, in: [.init(identifier: "", title: "20°C"), .init(identifier: "", title: "x")]), 0)
        XCTAssertNil(AOMMenuShelfPolicy.resolve(after, in: [.init(identifier: "", title: "20°C")]), "the list changed length")
        // Old pins move over only when they name one item.
        let migrated = AOMMenuShelfPolicy.migratePins(["com.example.weather|0|18°C"], items: [before])
        XCTAssertEqual(migrated, [before.pinKey])
    }

    func testMB05SpacingRollsBackBothKeys() {
        var stored: [String: Int] = ["NSStatusItemSpacing": 6]
        var writes = 0
        let failing = SystemToolsModel.MenuBarSpacing.Store(read: { stored[$0] }, write: { key, value in
            writes += 1
            // The second key never takes.
            if key == "NSStatusItemSelectionPadding", value != nil { return }
            stored[key] = value
        }, synchronize: { true })
        XCTAssertFalse(SystemToolsModel.MenuBarSpacing.tight.apply(to: failing))
        XCTAssertEqual(stored["NSStatusItemSpacing"], 6, "the first key went back")
        XCTAssertNil(stored["NSStatusItemSelectionPadding"], "absent before, absent after")
        XCTAssertGreaterThan(writes, 2)
        var good: [String: Int] = [:]
        let working = SystemToolsModel.MenuBarSpacing.Store(read: { good[$0] }, write: { good[$0] = $1 }, synchronize: { true })
        XCTAssertTrue(SystemToolsModel.MenuBarSpacing.compact.apply(to: working))
        XCTAssertEqual(good, ["NSStatusItemSpacing": 8, "NSStatusItemSelectionPadding": 6])
        XCTAssertTrue(SystemToolsModel.MenuBarSpacing.standard.apply(to: working))
        XCTAssertTrue(good.isEmpty)
    }

    // MARK: BT01

    func testBT01IdenticalSafariTabsAreNeverGuessed() {
        let safari = PaletteBrowserTabs.browsers[0]
        let picked = PaletteBrowserTabs.Tab(browser: safari, window: 1, index: 1, title: "Inbox", url: "https://mail/", windowID: "5")
        let twins = [PaletteBrowserTabs.Tab(browser: safari, window: 1, index: 2, title: "Inbox", url: "https://mail/", windowID: "5"),
                     PaletteBrowserTabs.Tab(browser: safari, window: 1, index: 1, title: "Inbox", url: "https://mail/", windowID: "5")]
        XCTAssertEqual(PaletteBrowserTabs.resolve(picked, in: twins), .ambiguous(2), "the old position doesn't decide")
    }

    // MARK: SEC01 / SEC04

    func testSEC01PrivateCopyIsMarkedAndExpiresOnlyIfUntouched() {
        let board = NSPasteboard(name: NSPasteboard.Name("AOM76-\(UUID().uuidString)"))
        ClipboardMCPSettings.copyPrivately("AOM_MCP_TOKEN=dummy", seconds: 0.05, pasteboard: board)
        let types = board.pasteboardItems?.first?.types.map(\.rawValue) ?? []
        XCTAssertTrue(types.contains("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(types.contains("org.nspasteboard.TransientType"))
        let gone = expectation(description: "cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNil(board.string(forType: .string))
            gone.fulfill()
        }
        wait(for: [gone], timeout: 2)
        ClipboardMCPSettings.copyPrivately("AOM_MCP_TOKEN=dummy", seconds: 0.05, pasteboard: board)
        board.clearContents()
        board.setString("the user's own copy", forType: .string)
        let kept = expectation(description: "kept")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(board.string(forType: .string), "the user's own copy", "a later copy isn't wiped")
            kept.fulfill()
        }
        wait(for: [kept], timeout: 2)
        XCTAssertFalse(ClipboardMCPSettings.instructions(for: .claudeCode, token: ClipboardMCPSettings.hiddenToken).snippet.contains("dummy"))
    }

    func testSEC04LinksRunOnlyAllowedTriggerIDs() {
        let id = UUID()
        XCTAssertFalse(AOMLinkConsent.mayRun(id, allowed: []))
        XCTAssertTrue(AOMLinkConsent.mayRun(id, allowed: [id.uuidString]))
        XCTAssertFalse(AOMLinkConsent.mayRun(UUID(), allowed: [id.uuidString]), "a renamed or new trigger isn't covered")
    }

    // MARK: W01 weather

    func testW01ParsingTitlesAndFreshness() throws {
        let cities = try MenuBarWeather.parseCities(Data(#"{"results":[{"id":1835848,"name":"Seoul","latitude":37.566,"longitude":126.9784,"timezone":"Asia/Seoul","country":"South Korea","admin1":"Seoul"}]}"#.utf8))
        XCTAssertEqual(cities.first?.label, "Seoul, South Korea", "a region named like the city isn't repeated")
        let city = try XCTUnwrap(cities.first)
        let now = Date()
        let reading = try MenuBarWeather.parseForecast(Data(#"{"current":{"temperature_2m":2.7,"weather_code":3,"is_day":1},"daily":{"temperature_2m_max":[4.4],"temperature_2m_min":[-4.2],"precipitation_probability_max":[10]}}"#.utf8),
                                                       city: city, unit: .celsius, now: now)
        XCTAssertNil(reading.feelsLike)
        XCTAssertEqual(MenuBarWeather.title(reading, display: .temperature), "3°")
        XCTAssertEqual(MenuBarWeather.title(reading, display: .feelsLike), "3°", "feels-like missing: the actual value")
        XCTAssertEqual(MenuBarWeather.title(reading, display: .iconOnly), "")
        XCTAssertEqual(MenuBarWeather.title(nil, display: .temperature), "—")
        XCTAssertEqual(reading.low, -4.2)
        XCTAssertEqual(reading.rainChance, 10)
        XCTAssertEqual(MenuBarWeather.symbol(code: 3, isDay: true), "cloud")
        XCTAssertEqual(MenuBarWeather.symbol(code: 0, isDay: false), "moon.stars")
        XCTAssertTrue(MenuBarWeather.isFresh(reading, city: city, unit: .celsius, now: now.addingTimeInterval(29 * 60)))
        XCTAssertFalse(MenuBarWeather.isFresh(reading, city: city, unit: .celsius, now: now.addingTimeInterval(31 * 60)))
        XCTAssertFalse(MenuBarWeather.isFresh(reading, city: city, unit: .fahrenheit, now: now), "another unit reads again")
        XCTAssertEqual(MenuBarWeather.retryAfter("120", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(MenuBarWeather.retryAfter("5", now: now), now.addingTimeInterval(60), "at least a minute")
        XCTAssertEqual(MenuBarWeather.retryAfter(nil, now: now), now.addingTimeInterval(600))
        XCTAssertTrue(MenuBarWeather.spoken(city: city, reading: reading, problem: nil).hasPrefix("Weather in Seoul: Overcast, 3 degrees"))
        XCTAssertEqual(MenuBarWeather.spoken(city: city, reading: nil, problem: .offline), "Weather in Seoul: no reading yet, No connection")
    }

    func testW01AReplyForTheOldCityIsDropped() async throws {
        let defaults = UserDefaults.standard
        let saved = [MenuBarWeather.cityKey, MenuBarWeather.readingKey].map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip([MenuBarWeather.cityKey, MenuBarWeather.readingKey], saved) { defaults.set(value, forKey: key) } }
        let a = WeatherCity(id: 1, name: "A", timezone: "UTC", latitude: 0, longitude: 0)
        let b = WeatherCity(id: 2, name: "B", timezone: "UTC", latitude: 1, longitude: 1)
        let weather = MenuBarWeather()
        weather.provider = WeatherProvider(search: { _ in [] }, fetch: { city, unit in
            if city.id == 1 { try await Task.sleep(nanoseconds: 300_000_000) }
            return WeatherReading(cityID: city.id, temperature: Double(city.id * 10), feelsLike: nil, code: 0, isDay: true, fetchedAt: Date(), unit: unit)
        })
        weather.choose(a)
        weather.choose(b)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(weather.reading?.cityID, 2, "A's late reply doesn't replace B")
        XCTAssertEqual(weather.reading?.temperature, 20)
    }

    // MARK: M04 / M08

    func testM04LengthsAndOrder() {
        let long = MenuBarHider.collapsedLength, short = MenuBarHider.dividerLength
        XCTAssertTrue(MenuBarHider.lengths(collapsed: true, showsAll: false, hasAlways: true) == (long, short))
        XCTAssertTrue(MenuBarHider.lengths(collapsed: false, showsAll: false, hasAlways: true) == (short, long))
        XCTAssertTrue(MenuBarHider.lengths(collapsed: false, showsAll: true, hasAlways: true) == (short, short))
        XCTAssertTrue(MenuBarHider.lengths(collapsed: true, showsAll: false, hasAlways: false) == (long, nil))
        XCTAssertTrue(MenuBarHider.canUseAlways(alwaysMinX: 100, dividerMinX: 200, toggleMinX: 300))
        XCTAssertFalse(MenuBarHider.canUseAlways(alwaysMinX: 250, dividerMinX: 200, toggleMinX: 300), "the second divider right of the first")
        XCTAssertFalse(MenuBarHider.canUseAlways(alwaysMinX: nil, dividerMinX: 200, toggleMinX: 300))
    }

    func testM08HiddenItemsComeFirstRightToLeft() {
        let display = MenuBarStripPolicy.Display(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: CGRect(x: 660, y: 0, width: 190, height: 32))
        func at(_ x: CGFloat?, _ title: String) -> AOMMenuShelfItem {
            var item = AOMMenuShelfItem(pid: 1, ownerBundleID: title, ownerName: title, title: title, axIdentifier: "", ordinal: 0)
            item.frame = x.map { CGRect(x: $0, y: 2, width: 24, height: 22) }
            return item
        }
        let placed = MenuBarStripPolicy.arrange([at(1400, "clock"), at(700, "behind notch"), at(1000, "wifi"), at(-5000, "pushed off"), at(nil, "no frame")],
                                                displays: [display])
        XCTAssertEqual(placed.filter(\.hidden).map(\.item.title), ["behind notch", "pushed off", "no frame"])
        XCTAssertEqual(placed.filter { !$0.hidden }.map(\.item.title), ["clock", "wifi"])
        XCTAssertEqual(MenuBarStripPolicy.axRect(CGRect(x: 0, y: 950, width: 100, height: 32), primaryHeight: 982), CGRect(x: 0, y: 0, width: 100, height: 32))
    }

    // MARK: AUD-01 / M12

    func testAUD01GapCausesAndBins() {
        let period: UInt64 = 1_000
        XCTAssertEqual(AirPlayGapCause.classify(intervalTicks: 7_500, periodTicks: period, inputFrames: 128, frames: 128), .lateEntry)
        XCTAssertEqual(AirPlayGapCause.classify(intervalTicks: 1_000, periodTicks: period, inputFrames: 60, frames: 128), .inputShort)
        XCTAssertEqual(AirPlayGapCause.classify(intervalTicks: 1_000, periodTicks: period, inputFrames: 128, frames: 128), .clockJump)
        XCTAssertEqual(AirPlayGapCause.classify(intervalTicks: 0, periodTicks: period, inputFrames: 128, frames: 128), .clockJump, "no previous callback")
        XCTAssertEqual(AirPlayGapCause.bin(intervalTicks: 1_000, periodTicks: period), 0)
        XCTAssertEqual(AirPlayGapCause.bin(intervalTicks: 1_400, periodTicks: period), 2)
        XCTAssertEqual(AirPlayGapCause.bin(intervalTicks: 7_500, periodTicks: period), 6, "the 960-frame gap at 128 frames: 7.5 cycles")
        XCTAssertEqual(AirPlayGapCause.bin(intervalTicks: 50_000, periodTicks: period), 7)
    }

    func testM12SummaryGroupsTheWindowOnly() {
        let mark = Date()
        func event(_ kind: AudioEventKind, _ offset: TimeInterval, value: Int64 = 0) -> AudioEventLog.Event {
            AudioEventLog.Event(time: mark.addingTimeInterval(offset), kind: kind, source: "Chrome", value: value)
        }
        let summary = AudioGlitchMarker.summarize([event(.cycleGap, -3, value: 960), event(.gapCause, -3, value: 1), event(.overload, -3),
                                                   event(.cycleGap, 25, value: 128), event(.clockSkip, 4)], around: mark)
        XCTAssertEqual(summary.gaps, 1, "the gap 25 s later is outside ±10 s")
        XCTAssertEqual(summary.gapFrames, 960)
        XCTAssertEqual(summary.causes, ["late callback": 1])
        XCTAssertEqual(summary.overloads, 1)
        XCTAssertEqual(summary.other, 1)
        XCTAssertTrue(summary.headline.hasPrefix("1 output gap (1 late callback)"))
        XCTAssertTrue(AudioGlitchMarker.summarize([], around: mark).headline.hasPrefix("AOM recorded no output gap"))
    }

    // MARK: Gemini 7.6 review, checked against the code

    func testReviewFolderCopyFailsWholeOnAnUnreadableFolder() throws {
        let (left, right) = try folders()
        let locked = left.appendingPathComponent("New/locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: left.appendingPathComponent("New/a.txt"))
        try Data("b".utf8).write(to: locked.appendingPathComponent("b.txt"))
        let comparison = try XCTUnwrap(FolderCompare.compare(left, right))
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        // The signature saw the folder readable; copying it now must fail whole.
        let result = FolderCompare.copyMissing(comparison.items.map { item in
            var copy = item
            if var side = copy.left, side.isFolder { side.signature = FolderCompare.treeSignature(side.url); copy.left = side }
            return copy
        }, direction: .leftToRight)
        XCTAssertTrue(result.copied.isEmpty)
        XCTAssertNotNil(result.skipped["new"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: right.path), [], "no half-copied folder")
    }

    func testReviewTreeSignatureSeesRenamesAndEmptyFolders() throws {
        let folder = scratch.appendingPathComponent("Sig", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let first = FolderCompare.treeSignature(folder)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("a.txt"), to: folder.appendingPathComponent("b.txt"))
        let renamed = FolderCompare.treeSignature(folder)
        XCTAssertNotEqual(first.digest, renamed.digest, "same size and date, another name")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: false)
        XCTAssertNotEqual(renamed.digest, FolderCompare.treeSignature(folder).digest, "an empty folder counts")
    }

    func testReviewLoneTwinIsNotPressedForTheOther() {
        let twin = AOMMenuShelfItem(pid: 1, ownerBundleID: "x", ownerName: "X", title: "B", axIdentifier: "status", ordinal: 1,
                                    siblings: 2, identifierIsUnique: false)
        XCTAssertNil(AOMMenuShelfPolicy.resolve(twin, in: [.init(identifier: "status", title: "A")]), "its twin closed: no click on the other")
        let unique = AOMMenuShelfItem(pid: 1, ownerBundleID: "x", ownerName: "X", title: "C", axIdentifier: "only", ordinal: 3, siblings: 4)
        XCTAssertEqual(AOMMenuShelfPolicy.resolve(unique, in: [.init(identifier: "only", title: "C")]), 0, "a unique identifier finds its item anywhere")
        XCTAssertNotEqual(AOMMenuShelfItem(pid: 1, ownerBundleID: "x", ownerName: "X", title: "", axIdentifier: "", ordinal: 0).id,
                          AOMMenuShelfItem(pid: 2, ownerBundleID: "x", ownerName: "X", title: "", axIdentifier: "", ordinal: 0).id,
                          "two processes of one app are two rows")
        XCTAssertTrue(MenuBarStripPolicy.isOwnDivider(AOMMenuShelfItem(pid: 7, ownerBundleID: "a", ownerName: "AOM", title: "Menu Bar Hider divider",
                                                                       axIdentifier: "", ordinal: 0), ownPID: 7))
    }

    func testReviewWeatherTrendAndRecentCities() throws {
        let city = WeatherCity(id: 9, name: "Busan", timezone: "Asia/Seoul", latitude: 35, longitude: 129)
        let reading = try MenuBarWeather.parseForecast(Data(#"{"current":{"temperature_2m":10,"apparent_temperature":8,"weather_code":61,"is_day":1},"hourly":{"temperature_2m":[10,9,8,7,6,5],"precipitation_probability":[10,40,30,0,0,0]}}"#.utf8),
                                                       city: city, unit: .celsius, now: Date())
        XCTAssertEqual(MenuBarWeather.trend(reading), "Next 6 h: 10° → 5° · rain up to 40%")
        let a = WeatherCity(id: 1, name: "A", timezone: "UTC", latitude: 0, longitude: 0)
        let b = WeatherCity(id: 2, name: "B", timezone: "UTC", latitude: 0, longitude: 0)
        let c = WeatherCity(id: 3, name: "C", timezone: "UTC", latitude: 0, longitude: 0)
        XCTAssertEqual(MenuBarWeather.remember(a, in: [c, a, b]).map(\.id), [1, 3, 2])
        XCTAssertEqual(MenuBarWeather.remember(city, in: [a, b, c]).map(\.id), [9, 1, 2], "three at most")
    }
}
