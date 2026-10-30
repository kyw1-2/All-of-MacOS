import XCTest
@testable import AllOfMacOS

/// 3.3.5 System Tools: the pure engines behind the new tools (the Text &
/// Developer cases left with that group in 3.3.6; File SHA-256 is covered
/// in SystemTools336Tests). Nothing here
/// changes system state: preferences go to an in-memory store, files live in
/// a temporary folder, and "Trash" moves go to a fake trash inside it.
@MainActor
final class SystemTools335Tests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aom-tools335-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ relative: String, bytes: Int = 4) throws -> URL {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    // MARK: - Catalog and inventory

    func testCatalogCoversEveryToolOnceAndTheInventoryMatches() {
        let ids = SystemToolCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "No tool is listed twice")
        XCTAssertEqual(Set(ids), Set(SystemToolID.allCases), "Every id has a tile")
        XCTAssertGreaterThanOrEqual(ids.count, 42, "12 tools from 3.3.4 plus at least 30 new ones")
        XCTAssertEqual(SystemToolsInventory.count, ids.count)
        XCTAssertEqual(SystemToolsInventory.groups.flatMap(\.toolIDs).count, ids.count)
        for group in SystemToolGroup.allCases {
            XCTAssertFalse(SystemToolCatalog.tools(in: group).isEmpty, "\(group.name) has tools")
        }
        // The 3.3.4 ids survive, so saved favorites and recents keep working.
        for legacy in ["hidden", "desktop", "finder", "dns", "pdfmerge", "pdfcompress", "imageconvert", "videoconvert", "qr", "cache", "dsstore", "trash"] {
            XCTAssertNotNil(SystemToolID(rawValue: legacy), legacy)
        }
        XCTAssertTrue(SystemToolCatalog.all.allSatisfy { !$0.help.isEmpty && !$0.title.isEmpty })
    }

    func testSearchMatchesTitlesGroupsKeywordsAndDescriptions() {
        func hits(_ query: String) -> Set<SystemToolID> { Set(SystemToolCatalog.all.filter { $0.matches(query) }.map(\.id)) }
        XCTAssertTrue(hits("lsof").isSuperset(of: [.portLookup, .whoLocks]))
        XCTAssertTrue(hits("amphetamine").contains(.keepAwake))
        XCTAssertTrue(hits("network").contains(.speedTest), "Group names match")
        XCTAssertTrue(hits("battery").contains(.batteryDetails))
        XCTAssertEqual(hits("").count, SystemToolCatalog.all.count)
        XCTAssertTrue(hits("zzzz-no-such-tool").isEmpty)
    }

    func testRecentListIsNewestFirstWithoutDuplicates() {
        var list: [SystemToolID] = []
        for id in [SystemToolID.dns, .ping, .dns, .wifi, .sleep, .qr, .trash, .cache] {
            list = SystemToolsModel.updatedRecent(list, adding: id)
        }
        XCTAssertEqual(list, [.cache, .trash, .qr, .sleep, .wifi, .dns])
    }

    func testFavoritesPersistUnderAnAOMKey() throws {
        let suite = "aom-tools335-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SystemToolsModel.favoritesKey.hasPrefix("AOM"))
        let model = SystemToolsModel(defaults: defaults)
        model.toggleFavorite(.speedTest)
        model.toggleFavorite(.ping)
        model.toggleFavorite(.speedTest)
        XCTAssertEqual(defaults.stringArray(forKey: SystemToolsModel.favoritesKey), ["ping"])
        XCTAssertEqual(SystemToolsModel(defaults: defaults).favorites, [.ping])
    }

    func testPreviewLineIsShortAndSingleLine() {
        XCTAssertEqual(SystemToolsModel.preview("a\nb"), "a ⏎ b")
        let long = SystemToolsModel.preview(String(repeating: "x", count: 100))
        XCTAssertEqual(long.count, 48)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    // MARK: - Tweaks (in-memory store only)

    func testTweakKeysMapToTheDocumentedDefaults() {
        let table = Dictionary(uniqueKeysWithValues: SystemTweak.all.map { ($0.id, "\($0.domain) \($0.key)") })
        XCTAssertEqual(table["extensions"], "NSGlobalDomain AppleShowAllExtensions")
        XCTAssertEqual(table["pathbar"], "com.apple.finder ShowPathbar")
        XCTAssertEqual(table["statusbar"], "com.apple.finder ShowStatusBar")
        XCTAssertEqual(table["posixtitle"], "com.apple.finder _FXShowPosixPathInTitle")
        XCTAssertEqual(table["dockactive"], "com.apple.dock static-only")
        XCTAssertEqual(table["dockdelay"], "com.apple.dock autohide-delay")
        XCTAssertEqual(table["dockrecents"], "com.apple.dock show-recents")
        XCTAssertEqual(table["shotshadow"], "com.apple.screencapture disable-shadow")
        XCTAssertEqual(table["shotformat"], "com.apple.screencapture type")
        XCTAssertEqual(table["shotfolder"], "com.apple.screencapture location")
        // Every tweak has a tile with the same id.
        for tweak in SystemTweak.all { XCTAssertNotNil(SystemToolID(rawValue: tweak.id), tweak.id) }
    }

    func testFlagTweaksUseAppleDefaultsAndToggle() throws {
        let store = MemoryPreferenceStore()
        XCTAssertEqual(SystemTweak.pathBar.isOn(in: store), false)
        XCTAssertEqual(SystemTweak.dockRecentApps.isOn(in: store), true, "Recents are on by default")
        XCTAssertEqual(try SystemTweak.pathBar.toggle(in: store), true)
        XCTAssertEqual(store.value("ShowPathbar", domain: "com.apple.finder") as? Bool, true)
        XCTAssertEqual(try SystemTweak.dockRecentApps.toggle(in: store), false)
        XCTAssertEqual(store.value("show-recents", domain: "com.apple.dock") as? Bool, false)
        // String and number forms written by `defaults write` read the same.
        let typed = MemoryPreferenceStore(["com.apple.finder/ShowStatusBar": "YES", "com.apple.dock/static-only": NSNumber(value: 1)])
        XCTAssertEqual(SystemTweak.statusBar.isOn(in: typed), true)
        XCTAssertEqual(SystemTweak.dockActiveAppsOnly.isOn(in: typed), true)
    }

    func testInvertedAndNumberTweaks() throws {
        let store = MemoryPreferenceStore()
        XCTAssertEqual(SystemTweak.screenshotShadows.isOn(in: store), true, "Shadows are on while disable-shadow is unset")
        XCTAssertEqual(try SystemTweak.screenshotShadows.toggle(in: store), false)
        XCTAssertEqual(store.value("disable-shadow", domain: "com.apple.screencapture") as? Bool, true)

        XCTAssertEqual(SystemTweak.dockInstantAutoHide.isOn(in: store), false)
        XCTAssertEqual(try SystemTweak.dockInstantAutoHide.toggle(in: store), true)
        XCTAssertEqual(store.value("autohide-delay", domain: "com.apple.dock") as? Double, 0)
        XCTAssertEqual(try SystemTweak.dockInstantAutoHide.toggle(in: store), false)
        XCTAssertNil(store.value("autohide-delay", domain: "com.apple.dock"), "Off removes the key (Apple's default)")
        let slow = MemoryPreferenceStore(["com.apple.dock/autohide-delay": NSNumber(value: 0.5)])
        XCTAssertEqual(SystemTweak.dockInstantAutoHide.isOn(in: slow), false)
    }

    func testChoiceAndPathTweaks() throws {
        let store = MemoryPreferenceStore(["com.apple.screencapture/type": "JPEG"])
        XCTAssertEqual(SystemTweak.screenshotFormat.currentString(in: store), "jpg")
        try SystemTweak.screenshotFormat.setChoice("heic", in: store)
        XCTAssertEqual(SystemTweak.screenshotFormat.currentString(in: store), "heic")
        XCTAssertThrowsError(try SystemTweak.screenshotFormat.setChoice("bmp", in: store))
        XCTAssertEqual(SystemTweak.screenshotFormat.currentString(in: MemoryPreferenceStore(["com.apple.screencapture/type": "gif"])), "png")

        XCTAssertEqual(SystemTweak.screenshotFolder.currentString(in: MemoryPreferenceStore()),
                       ("~/Desktop" as NSString).expandingTildeInPath)
        try SystemTweak.screenshotFolder.setFolder(folder, in: store)
        XCTAssertEqual(SystemTweak.screenshotFolder.currentString(in: store), folder.path)
        XCTAssertThrowsError(try SystemTweak.screenshotFolder.setFolder(folder.appendingPathComponent("missing"), in: store))
    }

    // MARK: - Uninstaller and cleanup scans

    func testLeftoverMatcherNeedsDotBoundaries() {
        let matcher = CleanupTools.LeftoverMatcher(bundleID: "com.example.Notes", appName: "Notes Pro")
        XCTAssertTrue(matcher.matches("com.example.Notes.plist", allowNameMatch: false))
        XCTAssertTrue(matcher.matches("com.example.notes", allowNameMatch: false), "Case-insensitive")
        XCTAssertTrue(matcher.matches("ABCDE12345.com.example.Notes", allowNameMatch: false))
        XCTAssertTrue(matcher.matches("group.com.example.Notes.shared", allowNameMatch: false))
        XCTAssertTrue(matcher.matches("com.example.Notes.savedState", allowNameMatch: false))
        XCTAssertFalse(matcher.matches("com.example.NotesHelper.plist", allowNameMatch: false))
        XCTAssertFalse(matcher.matches("xcom.example.Notes", allowNameMatch: false))
        XCTAssertFalse(matcher.matches("com.example.plist", allowNameMatch: false))
        XCTAssertTrue(matcher.matches("Notes Pro", allowNameMatch: true))
        XCTAssertFalse(matcher.matches("Notes Pro", allowNameMatch: false), "Names only count where folders are named by app")
        XCTAssertFalse(CleanupTools.LeftoverMatcher(bundleID: "com.example.x1", appName: "X1").matches("x1", allowNameMatch: true),
                       "Short names never match")
        let vendor = CleanupTools.LeftoverMatcher(bundleID: "com.vendor", appName: "Vendor App")
        XCTAssertTrue(vendor.matches("com.vendor.plist", allowNameMatch: false))
        XCTAssertFalse(vendor.matches("com.vendor.otherapp.plist", allowNameMatch: false), "A two-part ID isn't a prefix")
    }

    func testUninstallPlanListsTheAppAndOnlyItsLeftovers() throws {
        let app = folder.appendingPathComponent("Apps/Notes Pro.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.Notes", "CFBundleName": "Notes Pro", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let library = folder.appendingPathComponent("Library")
        let expected = [
            try write("Library/Preferences/com.example.Notes.plist"),
            try write("Library/Caches/com.example.Notes/cache.db"),
            try write("Library/Application Support/Notes Pro/data"),
            try write("Library/Containers/com.example.Notes/Data/x"),
            try write("Library/Saved Application State/com.example.Notes.savedState/window.data")
        ]
        _ = try write("Library/Preferences/com.example.Other.plist")
        _ = try write("Library/Preferences/Notes Pro.plist")
        let plan = try CleanupTools.uninstallPlan(for: app, library: library, isRunning: { _ in false })
        XCTAssertEqual(plan.first?.url, app)
        XCTAssertEqual(plan.first?.note, "App")
        let leftovers = Set(plan.dropFirst().map { $0.url.standardizedFileURL.path })
        let wanted = Set([expected[0], expected[1].deletingLastPathComponent(), expected[2].deletingLastPathComponent(),
                          folder.appendingPathComponent("Library/Containers/com.example.Notes"),
                          folder.appendingPathComponent("Library/Saved Application State/com.example.Notes.savedState")]
            .map { $0.standardizedFileURL.path })
        XCTAssertEqual(leftovers, wanted)
        XCTAssertTrue(plan.allSatisfy { $0.size > 0 })

        XCTAssertThrowsError(try CleanupTools.uninstallPlan(for: app, library: library, isRunning: { _ in true })) { error in
            XCTAssertEqual(error as? CleanupTools.UninstallRefusal, .running("Notes Pro"))
        }
        XCTAssertThrowsError(try CleanupTools.uninstallPlan(for: folder, library: library, isRunning: { _ in false }))
    }

    func testUninstallRefusesAppleAppsAndAOM() throws {
        func makeApp(_ id: String) throws -> URL {
            let app = folder.appendingPathComponent("\(id).app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        XCTAssertThrowsError(try CleanupTools.uninstallPlan(for: try makeApp("com.apple.Safari"), library: folder, isRunning: { _ in false })) {
            XCTAssertEqual($0 as? CleanupTools.UninstallRefusal, .systemApp)
        }
        XCTAssertThrowsError(try CleanupTools.uninstallPlan(for: try makeApp("com.kyw.allofmacos"), library: folder, isRunning: { _ in false })) {
            XCTAssertEqual($0 as? CleanupTools.UninstallRefusal, .isAOM)
        }
    }

    func testLargeFilesAreSortedAndThresholded() throws {
        _ = try write("scan/small.bin", bytes: 10_000)
        let mid = try write("scan/a/mid.bin", bytes: 2_000_000)
        let big = try write("scan/b/big.bin", bytes: 4_000_000)
        _ = try write("scan/.hidden/huge.bin", bytes: 5_000_000)
        let found = CleanupTools.largeFiles(in: folder.appendingPathComponent("scan"), minimumBytes: 1_000_000)
        XCTAssertEqual(found.map { $0.url.standardizedFileURL.path }, [big, mid].map { $0.standardizedFileURL.path })
        XCTAssertEqual(CleanupTools.largeFiles(in: folder.appendingPathComponent("scan"), minimumBytes: 1_000_000, limit: 1).count, 1)
    }

    func testOldMeansNotAddedChangedOrOpenedRecently() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let old = Date(timeIntervalSince1970: 10 * 86_400)
        let recent = Date(timeIntervalSince1970: 95 * 86_400)
        XCTAssertTrue(CleanupTools.isOld(added: old, modified: old, opened: old, now: now, days: 30))
        XCTAssertFalse(CleanupTools.isOld(added: old, modified: old, opened: recent, now: now, days: 30), "Opened last week")
        XCTAssertFalse(CleanupTools.isOld(added: recent, modified: old, opened: nil, now: now, days: 30), "Downloaded last week")
        XCTAssertFalse(CleanupTools.isOld(added: nil, modified: nil, opened: nil, now: now, days: 30), "No dates: keep")
    }

    func testDeveloperJunkNeverListsArchives() throws {
        let library = folder.appendingPathComponent("Library")
        let derived = try write("Library/Developer/Xcode/DerivedData/App-abc/Build/x", bytes: 5_000)
        _ = try write("Library/Developer/Xcode/Archives/2026-10-30/App.xcarchive/Info.plist", bytes: 5_000)
        let found = CleanupTools.developerJunk(library: library)
        XCTAssertEqual(found.map { $0.url.lastPathComponent }, ["App-abc"])
        XCTAssertTrue(derived.path.hasPrefix(found[0].url.path))
    }

    /// Records trash moves into a folder inside the test directory instead
    /// of the user's real Trash.
    private final class FakeTrashFileManager: FileManager {
        var trash: URL!
        var refuse: Set<String> = []
        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            if refuse.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
            try moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
    }

    func testMoveToTrashReportsWhatMovedAndWhatStayed() throws {
        let manager = FakeTrashFileManager()
        manager.trash = folder.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: manager.trash, withIntermediateDirectories: true)
        manager.refuse = ["locked.bin"]
        let a = try write("a.bin", bytes: 1_000), locked = try write("locked.bin", bytes: 1_000)
        let outcome = CleanupTools.moveToTrash([CleanupCandidate(url: a, size: 1_000, note: ""),
                                                CleanupCandidate(url: locked, size: 1_000, note: "")], fileManager: manager)
        XCTAssertEqual(outcome.moved, [a])
        XCTAssertEqual(outcome.freed, 1_000)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.summary.contains("1 could not be moved"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.trash.appendingPathComponent("a.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path), "A refused item stays where it was")
    }

    // MARK: - Status strip

    func testBatteryDictionaryOnAppleSiliconAndIntel() throws {
        // Values read from this Mac's AppleSmartBattery entry (M1, macOS 27.2).
        let silicon: [String: Any] = ["CurrentCapacity": 80, "MaxCapacity": 100, "AppleRawMaxCapacity": 3622, "DesignCapacity": 4382,
                                      "NominalChargeCapacity": 3752, "CycleCount": 535, "IsCharging": false,
                                      "ExternalConnected": true, "TimeRemaining": 65535]
        let battery = try XCTUnwrap(SystemStatus.parseBattery(silicon))
        XCTAssertEqual(battery.percent, 80)
        XCTAssertEqual(battery.healthPercent, 83)
        XCTAssertEqual(battery.cycleCount, 535)
        XCTAssertNil(battery.minutesRemaining, "65535 means still calculating")
        XCTAssertEqual(battery.state, "On power")

        // The real macOS 27.2 shape: the mAh figures only inside BatteryData,
        // whose own Current/MaxCapacity are mAh and must not win.
        let nested: [String: Any] = ["CurrentCapacity": 80, "MaxCapacity": 100, "CycleCount": 535, "ExternalConnected": true,
                                     "BatteryData": ["AppleRawMaxCapacity": 3622, "DesignCapacity": 4382,
                                                     "CurrentCapacity": 2778, "MaxCapacity": 3622]]
        let current = try XCTUnwrap(SystemStatus.parseBattery(nested))
        XCTAssertEqual(current.percent, 80)
        XCTAssertEqual(current.healthPercent, 83)

        let intel: [String: Any] = ["CurrentCapacity": 3000, "MaxCapacity": 6000, "DesignCapacity": 6500,
                                    "IsCharging": true, "ExternalConnected": true, "TimeRemaining": 95]
        let old = try XCTUnwrap(SystemStatus.parseBattery(intel))
        XCTAssertEqual(old.percent, 50)
        XCTAssertEqual(old.healthPercent, 92)
        XCTAssertEqual(old.minutesRemaining, 95)
        XCTAssertEqual(old.state, "Charging")
        XCTAssertNil(SystemStatus.parseBattery([:]), "A Mac without a battery")
    }

    func testCPUMemoryAndUptimeMath() {
        let a = SystemStatus.CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = SystemStatus.CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        XCTAssertEqual(SystemStatus.cpuUsage(from: a, to: b) ?? -1, 50, accuracy: 0.001)
        XCTAssertNil(SystemStatus.cpuUsage(from: b, to: a), "Counters going backwards give no reading")
        XCTAssertNil(SystemStatus.cpuUsage(from: a, to: a))
        XCTAssertEqual(SystemStatus.memoryUsed(internalPages: 100, purgeablePages: 20, wiredPages: 30, compressedPages: 10, pageSize: 16_384),
                       120 * 16_384)
        XCTAssertEqual(SystemStatus.memoryUsed(internalPages: 5, purgeablePages: 20, wiredPages: 0, compressedPages: 0, pageSize: 4096), 0)
        XCTAssertEqual(SystemStatus.uptimeText(90_061), "1d 1h")
        XCTAssertEqual(SystemStatus.uptimeText(3_700), "1h 1m")
        XCTAssertEqual(SystemStatus.uptimeText(59), "0m")
        XCTAssertEqual(SystemStatus.Memory(used: 1, total: 2, pressureLevel: 4).pressure, "Critical")
        XCTAssertNotNil(SystemStatus.secondsSinceBoot(), "kern.boottime is readable")
    }

    func testPreferredAddressSkipsLinkLocalAndPrefersEthernetOrWiFi() {
        let addresses = [SystemStatus.InterfaceAddress(interface: "utun3", address: "10.8.0.2"),
                         .init(interface: "en5", address: "169.254.10.1"),
                         .init(interface: "en0", address: "192.168.1.20"),
                         .init(interface: "bridge0", address: "192.168.2.1")]
        XCTAssertEqual(SystemStatus.preferredAddress(addresses)?.interface, "en0")
        XCTAssertEqual(SystemStatus.preferredAddress([.init(interface: "utun3", address: "10.8.0.2")])?.address, "10.8.0.2")
        XCTAssertNil(SystemStatus.preferredAddress([.init(interface: "en5", address: "169.254.10.1")]))
    }

    // MARK: - Network

    func testPortParsingAndLsofFieldOutput() {
        XCTAssertEqual(NetworkTools.port(from: " 8080 "), 8080)
        XCTAssertNil(NetworkTools.port(from: "0"))
        XCTAssertNil(NetworkTools.port(from: "65536"))
        XCTAssertNil(NetworkTools.port(from: "80; rm"))
        XCTAssertNil(NetworkTools.port(from: "-1"))
        XCTAssertEqual(NetworkTools.lsofArguments(port: 5000), ["-nP", "-i", ":5000", "-F", "pcPnT"])
        // Shape copied from `lsof -nP -i :58592 -F pcPnT` on this Mac, plus a client.
        let output = """
        p1026
        crapportd
        f12
        PTCP
        n*:58592
        TST=LISTEN
        TQR=0
        TQS=0
        f13
        PTCP
        n*:58592
        TST=LISTEN
        p2001
        cnode
        f30
        PTCP
        n127.0.0.1:61000->127.0.0.1:58592
        TST=ESTABLISHED
        p2002
        cmDNSResponder
        f5
        PUDP
        n*:58592
        """
        let users = NetworkTools.parsePortUsers(output)
        XCTAssertEqual(users.count, 3, "Two descriptors on the same socket are one row")
        XCTAssertEqual(users.first?.command, "rapportd")
        XCTAssertEqual(users.first?.state, "LISTEN")
        XCTAssertEqual(users[1].name, "127.0.0.1:61000->127.0.0.1:58592")
        XCTAssertEqual(users[2].proto, "UDP")
        XCTAssertEqual(users[2].state, "")
        XCTAssertTrue(NetworkTools.parsePortUsers("").isEmpty)
    }

    func testSpeedTestJSON() throws {
        let full = #"{"dl_throughput":146897728,"ul_throughput":31000000,"responsiveness":1023.06,"base_rtt":32.37,"interface_name":"en0"}"#
        let result = try XCTUnwrap(NetworkTools.parseSpeedTest(full))
        XCTAssertEqual(result.summary, "↓ 147 Mbps · ↑ 31.0 Mbps · 1023 RPM · 32 ms idle")
        XCTAssertEqual(result.interface, "en0")
        // `networkQuality -u` (no upload phase) on this Mac.
        let downloadOnly = #"{"base_rtt":23.99,"dl_responsiveness":857.23,"dl_throughput":144069920,"interface_name":"en0"}"#
        let partial = try XCTUnwrap(NetworkTools.parseSpeedTest(downloadOnly))
        XCTAssertNil(partial.upload)
        XCTAssertEqual(partial.responsiveness ?? 0, 857.23, accuracy: 0.01)
        XCTAssertNil(NetworkTools.parseSpeedTest("{}"))
        XCTAssertNil(NetworkTools.parseSpeedTest("not json"))
    }

    // MARK: - Commands and the keyboard lock

    func testAdministratorScriptQuotesEveryArgument() {
        let script = SystemToolsCommand.administratorScript([.init(path: "/usr/bin/mdutil", arguments: ["-E", "/"])])
        XCTAssertEqual(script, #"do shell script "'/usr/bin/mdutil' '-E' '/'" with administrator privileges"#)
        let tricky = SystemToolsCommand.administratorScript([.init(path: "/bin/echo", arguments: [#"a"b'c\"#])])
        XCTAssertEqual(tricky, #"do shell script "'/bin/echo' 'a\"b'\\''c\\'" with administrator privileges"#)
        XCTAssertEqual(SystemToolsCommand.sessionScript(.shutDown), #"tell application "System Events" to shut down"#)
    }

    func testCommandRunnerCapturesBothStreams() throws {
        let output = try SystemToolsCommand.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(output.stdout, "out\n")
        XCTAssertEqual(output.stderr, "err")
        XCTAssertEqual(output.status, 3)
        XCTAssertThrowsError(try SystemToolsCommand.runChecked("/usr/bin/false", []))
    }

    func testKeyboardLockBlocksKeysForABoundedTime() {
        XCTAssertEqual(KeyboardCleaningLock.clampedSeconds(1), 10)
        XCTAssertEqual(KeyboardCleaningLock.clampedSeconds(60), 60)
        XCTAssertEqual(KeyboardCleaningLock.clampedSeconds(3600), 120)
        let mask = KeyboardCleaningLock.eventMask
        for type: UInt32 in [10, 11, 12, 14] { XCTAssertNotEqual(mask & (1 << CGEventMask(type)), 0, "type \(type)") }
        XCTAssertEqual(mask & (1 << CGEventMask(CGEventType.leftMouseDown.rawValue)), 0, "The pointer keeps working")
    }
}
