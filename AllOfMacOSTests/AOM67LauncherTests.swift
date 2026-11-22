import AppKit
import XCTest
@testable import AllOfMacOS

/// 6.7: the launcher's screens (Kill Apps, Uninstall App, Sound Devices,
/// Clipboard History, Window Management, Keep Awake, System Commands), the
/// in-panel confirmation and the Codex report's defects L1–L5, A3–A5.
final class AOM67LauncherTests: XCTestCase {
    private typealias Item = QuickCommandPalette.PaletteItem
    private typealias Action = QuickCommandPalette.PaletteAction

    private func item(_ id: String, _ title: String, group: String? = nil, aliases: [String] = [],
                      effect: Action.Effect = .close) -> Item {
        var item = Item(id: id, title: title, subtitle: "", icon: "app", section: .commands,
                        primary: Action(title: "Run", effect: effect) {})
        item.group = group
        item.aliases = aliases
        return item
    }

    // MARK: Navigation (spec 02, test 10)

    func testPushKeepsTheScreenBelowAndPopGivesItBack() {
        var navigation = PaletteNavigation()
        XCTAssertTrue(navigation.isRoot)
        navigation.push(.uninstallApps, query: "unistall", selection: "system.screen.uninstall")
        navigation.push(.uninstallReview(URL(fileURLWithPath: "/Applications/Notes Plus.app")), query: "no", selection: "uninstall.x")
        XCTAssertEqual(navigation.depth, 2)
        XCTAssertEqual(navigation.breadcrumb, ["Uninstall App", "Uninstall Notes Plus"])
        let review = navigation.pop()
        XCTAssertEqual(review?.returnQuery, "no")
        XCTAssertEqual(review?.returnSelection, "uninstall.x")
        let list = navigation.pop()
        XCTAssertEqual(list?.returnQuery, "unistall", "the root search comes back as it was")
        XCTAssertEqual(list?.returnSelection, "system.screen.uninstall")
        XCTAssertTrue(navigation.isRoot)
        XCTAssertNil(navigation.pop())
    }

    func testAConfirmationNeverStacksOnAnotherAndStaysOutOfTheBreadcrumb() {
        var navigation = PaletteNavigation()
        navigation.push(.killApps, query: "", selection: nil)
        navigation.push(.confirm, query: "", selection: "kill.1")
        navigation.push(.confirm, query: "", selection: "kill.2")
        XCTAssertEqual(navigation.depth, 2)
        XCTAssertEqual(navigation.breadcrumb, ["Quit App"], "7.11: Kill Apps is Quit App (일반 종료)")
        XCTAssertFalse(PaletteRoute.confirm.isSearchable)
        XCTAssertTrue(PaletteRoute.killApps.isSearchable)
    }

    func testEscapePopsAScreenEvenWithAQuery() {
        typealias Search = QuickCommandPalette.PaletteSearch
        XCTAssertEqual(Search.escapeOutcome(query: "saf", depth: 1), .pop)
        XCTAssertEqual(Search.escapeOutcome(query: "", depth: 2), .pop)
        XCTAssertEqual(Search.escapeOutcome(query: "saf", depth: 0), .clearQuery)
        XCTAssertEqual(Search.escapeOutcome(query: "  ", depth: 0), .close)
        XCTAssertEqual(Search.escapeOutcome(query: "x"), .clearQuery, "the old entry point is the root's")
    }

    // MARK: Ranking (spec 02)

    func testVerbAliasesAndTheTypoReachTheirScreens() {
        let screens = QuickCommandPalette.screenCommands
        func top(_ query: String) -> String? {
            let items = screens.map { screen -> Item in
                var item = item(screen.id, screen.route.title, aliases: screen.aliases, effect: .push(screen.route))
                item.keywords = screen.keywords
                return item
            } + [item("app.safari", "Safari"), item("system.keepAwake", "Keep Awake")]
            return QuickCommandPalette.PaletteSearch.results(for: items, query: query).first?.id
        }
        // 7.11 (spec §1): force quitting has its own screen; "killapps" finds it.
        XCTAssertEqual(top("killapps"), "system.screen.killProcess")
        XCTAssertEqual(top("앱 종료"), "system.screen.killApps")
        XCTAssertEqual(top("강제 종료"), "system.screen.killProcess")
        XCTAssertEqual(top("강종"), "system.screen.killProcess")
        XCTAssertEqual(top("kill process"), "system.screen.killProcess")
        XCTAssertEqual(top("quit app"), "system.screen.killApps")
        XCTAssertEqual(top("unistall app"), "system.screen.uninstall")
        XCTAssertEqual(top("앱 삭제"), "system.screen.uninstall")
        XCTAssertEqual(top("uninstall"), "system.screen.uninstall")
        XCTAssertEqual(top("출력"), "audio.screen.devices")
        XCTAssertEqual(top("saf"), "app.safari", "a short prefix still finds the app first")
    }

    func testAShortAliasPrefixDoesNotOutrankATitlePrefix() {
        let items = [item("system.sleep", "Sleep", aliases: ["sleep", "잠자기"]), item("app.safari", "Safari")]
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.results(for: items, query: "s").map(\.id), ["system.sleep", "app.safari"],
                       "both are title prefixes; stable order")
        XCTAssertNil(QuickCommandPalette.PaletteSearch.rank(of: item("x", "Xcode", aliases: ["sleep"]), matching: "sl"),
                     "two letters of an alias are not a match")
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.rank(of: item("x", "Xcode", aliases: ["sleep"]), matching: "sle"), 2)
    }

    func testScreenFilteringKeepsGroupOrder() {
        let items = [item("o1", "Studio Display", group: "Output"), item("o2", "MacBook Speakers", group: "Output"),
                     item("i1", "MacBook Microphone", group: "Input"), item("v1", "Set Volume to 50%", group: "Volume")]
        let search = QuickCommandPalette.PaletteSearch.self
        XCTAssertEqual(search.filtered(items, query: "").map(\.id), ["o1", "o2", "i1", "v1"])
        XCTAssertEqual(search.filtered(items, query: "macbook").map(\.id), ["o2", "i1"], "Output before Input, as built")
        XCTAssertTrue(search.filtered(items, query: "zzz").isEmpty, "a screen has no web fallback")
    }

    // MARK: Kill Apps (spec 03)

    func testKillAppsListsHeavyAppsFirstAndProtectedLast() {
        typealias Entry = PaletteKillApps.Entry
        let entries = [
            Entry(pid: 1, name: "Finder", bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app",
                  memory: 900, isHidden: false, isProtected: true),
            Entry(pid: 2, name: "Notes", bundleID: "a.notes", path: "/Applications/Notes.app", memory: 100, isHidden: false, isProtected: false),
            Entry(pid: 3, name: "Chrome", bundleID: "a.chrome", path: "/Applications/Chrome.app", memory: 4000, isHidden: true, isProtected: false),
            Entry(pid: 4, name: "Bear", bundleID: "a.bear", path: "/Applications/Bear.app", memory: 100, isHidden: false, isProtected: false),
        ]
        XCTAssertEqual(PaletteKillApps.ordered(entries).map(\.pid), [3, 4, 2, 1])
    }

    func testAQuitThatTakesTooLongReadsStillRunning() {
        let asked = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(PaletteKillApps.quitState(askedAt: nil, now: asked))
        XCTAssertEqual(PaletteKillApps.quitState(askedAt: asked, now: asked.addingTimeInterval(3)), .quitting)
        XCTAssertEqual(PaletteKillApps.quitState(askedAt: asked, now: asked.addingTimeInterval(PaletteKillApps.quitPatience)), .stillRunning)
    }

    func testMemoryIsReadForThisProcessAndShownCompactly() {
        let own = PaletteKillApps.memoryFootprint(ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(own)
        XCTAssertGreaterThan(own ?? 0, 1 << 20)
        XCTAssertNil(PaletteKillApps.memoryDescription(nil))
        XCTAssertNotNil(PaletteKillApps.memoryDescription(3 << 30)?.range(of: "GB"))
        XCTAssertNotNil(PaletteKillApps.memoryDescription(300 << 20)?.range(of: "MB"))
    }

    func testTheListNeverIncludesAOMItself() {
        let pids = PaletteKillApps.entries().map(\.pid)
        XCTAssertFalse(pids.contains(ProcessInfo.processInfo.processIdentifier))
    }

    func testARowThatDisappearsHandsTheSelectionToItsNeighbour() {
        let previous = ["kill.1", "kill.2", "kill.3"]
        XCTAssertEqual(PaletteRouteModels.neighbor(of: "kill.2", previous: previous, current: ["kill.1", "kill.3"]), "kill.3")
        XCTAssertEqual(PaletteRouteModels.neighbor(of: "kill.3", previous: previous, current: ["kill.1", "kill.2"]), "kill.2",
                       "the last row hands it upward")
        XCTAssertNil(PaletteRouteModels.neighbor(of: "kill.9", previous: previous, current: ["kill.1"]))
    }

    // MARK: Uninstall App (spec 04)

    @MainActor
    func testTheReviewRefusesSystemAppsBeforeScanning() {
        let flow = PaletteUninstallFlow(app: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        flow.start()
        guard case .failed(let title, _) = flow.phase else { return XCTFail("\(flow.phase)") }
        XCTAssertTrue(title.contains("Calculator"))
        XCTAssertTrue(flow.candidates.isEmpty)
        flow.trash()
        XCTAssertNotEqual(flow.phase, .moving, "nothing moves without a review")
    }

    @MainActor
    func testTheReviewTicksBundleIDMatchesAndLeavesNameOnlyMatchesUnticked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aom67-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Notes Plus.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.notesplus.\(UUID().uuidString.prefix(6))",
                                   "CFBundleName": "Notes Plus", "CFBundlePackageType": "APPL"]
        try (info as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        let bundleID = info["CFBundleIdentifier"] as! String
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let prefs = library.appendingPathComponent("Preferences", isDirectory: true)
        let support = library.appendingPathComponent("Application Support/Notes Plus", isDirectory: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: prefs.appendingPathComponent("\(bundleID).plist"))

        let flow = PaletteUninstallFlow(app: root.appendingPathComponent("Notes Plus.app"), library: library)
        flow.start()
        let done = expectation(description: "review")
        Task { @MainActor in
            for _ in 0..<100 where flow.phase != .review { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(flow.phase, .review)
        let names = Set(flow.chosen.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains("Notes Plus.app"))
        XCTAssertTrue(names.contains("\(bundleID).plist"))
        XCTAssertFalse(names.contains("Notes Plus"), "a name-only folder starts unticked")
        flow.selectNone()
        XCTAssertTrue(flow.chosen.isEmpty)
        flow.trash()
        XCTAssertEqual(flow.phase, .review, "nothing ticked, nothing moves")
        flow.cancel()
    }

    // MARK: System commands

    func testDestructiveSystemCommandsAskInThePanel() {
        let byID = Dictionary(uniqueKeysWithValues: PaletteSystemCommand.all.map { ($0.id, $0) })
        XCTAssertEqual(byID.count, PaletteSystemCommand.all.count, "unique IDs")
        XCTAssertNotNil(byID["system.emptyTrash"]?.confirmation)
        XCTAssertNotNil(byID["system.logOut"]?.confirmation)
        XCTAssertNil(byID["system.lock"]?.confirmation)
        // Restart and Shut Down open macOS's own dialog: nothing quits unasked.
        XCTAssertEqual(byID["system.restart"]?.appleEventSource?.contains("aevtrrst"), true)
        XCTAssertEqual(byID["system.shutDown"]?.appleEventSource?.contains("aevtrsdn"), true)
        XCTAssertTrue(PaletteSystemCommand.all.allSatisfy { !$0.aliases.isEmpty })
    }

    // MARK: Report defects

    func testL2NestedRunningAppsAreListedButBundleHelpersAreNot() {
        let folders = [URL(fileURLWithPath: "/Applications")]
        let installed = [PaletteApplications.App(name: "Control", url: URL(fileURLWithPath: "/Applications/Control.app"))]
        let running = [URL(fileURLWithPath: "/Applications/Control.app"),
                       URL(fileURLWithPath: "/Applications/Vendor/Nested.app"),
                       URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Simulator.app")]
        XCTAssertEqual(PaletteApplications.merged(installed, running: running, folders: folders).map(\.name), ["Control", "Nested"])
        XCTAssertTrue(PaletteApplications.isInsideAnotherBundle("/Applications/Xcode.app/Contents/Applications/Simulator.app"))
        XCTAssertFalse(PaletteApplications.isInsideAnotherBundle("/Applications/Vendor/Nested.app"))
    }

    func testL2ScanFindsAppsInPlainSubfolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aom67-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Top.app", "Vendor/Nested.app", "Top.app/Contents/Helper.app", "Deep/Er/Lost.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        XCTAssertEqual(PaletteApplications.scan([root]).map(\.name).sorted(), ["Nested", "Top"],
                       "one level of plain folders, never inside a bundle")
    }

    @MainActor
    func testL4ThePanelFitsASmallScreen() {
        let small = CGRect(x: 0, y: 0, width: 640, height: 480)
        let frame = AOMLauncherController.frame(on: small)
        XCTAssertTrue(small.contains(frame), "\(frame) inside \(small)")
        XCTAssertLessThanOrEqual(frame.width, small.width - 32)
        let offset = CGRect(x: -1440, y: 100, width: 1440, height: 875)
        XCTAssertTrue(offset.contains(AOMLauncherController.frame(on: offset)), "a display left of the main one")
        XCTAssertEqual(AOMLauncherController.size(fitting: CGRect(x: 0, y: 0, width: 3000, height: 2000)),
                       AOMLauncherController.size)
    }

    @MainActor
    func testL5TheKeyIsShownOnlyWhileRegistered() {
        if GlobalHotKeyManager.shared.status != .active {
            XCTAssertFalse(AOMLauncherShortcut.isRegistered)
        }
    }

    func testL1AQuicklinkWaitingForItsSearchKeepsThePanel() {
        let wait = Action(title: "Use Quicklink", effect: .stay) {}
        XCTAssertEqual(wait.effect, .stay)
        let screen = item("system.screen.killApps", "Kill Apps", effect: .push(.killApps))
        XCTAssertTrue(screen.pushes)
        XCTAssertFalse(item("x", "X").pushes)
    }

    func testResultsCacheSeparatesScreens() {
        let cache = PaletteResultsCache()
        var builds = 0
        _ = cache.items(for: .init(query: "", refresh: 0, generation: 0)) { builds += 1; return [] }
        _ = cache.items(for: .init(query: "", refresh: 0, generation: 0, route: "killApps")) { builds += 1; return [] }
        XCTAssertEqual(builds, 2, "the root and a screen with the same query are different lists")
    }
}
