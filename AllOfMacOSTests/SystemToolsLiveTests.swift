import AppKit
import XCTest
@testable import AllOfMacOS

/// Runs every System Tools reader against this Mac: the commands, parsers
/// and system APIs each tool uses, read-only, plus the reversible switches
/// (Keep Awake, the sleep timer, Awake While App Runs, the Metal HUD).
/// Nothing here restarts, sleeps, quits or deletes. Off by default (CI and
/// `swift test`); run with `AOM_LIVE_SYSTEM_TESTS=1 swift test --filter SystemToolsLiveTests`.
final class SystemToolsLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AOM_LIVE_SYSTEM_TESTS"] == "1",
                          "Live System Tools checks run only with AOM_LIVE_SYSTEM_TESTS=1")
    }

    // MARK: Status strip

    func testStatusStripReadsThisMac() {
        let first = SystemStatus.cpuTicks()
        XCTAssertNotNil(first)
        usleep(200_000)
        if let first, let second = SystemStatus.cpuTicks(), let usage = SystemStatus.cpuUsage(from: first, to: second) {
            XCTAssert((0...100).contains(usage), "CPU \(usage)")
        }
        let memory = SystemStatus.memory()
        XCTAssertNotNil(memory)
        XCTAssertGreaterThan(memory?.used ?? 0, 0)
        XCTAssertNotEqual(memory?.pressure, "Unknown")
        XCTAssertNotNil(SystemStatus.startupDisk())
        XCTAssertNotNil(SystemStatus.secondsSinceBoot())
        XCTAssertFalse(SystemStatus.ipv4Addresses().isEmpty, "no IPv4 address on any interface")
    }

    // MARK: Quick Toggles and Tweaks (read only)

    func testToggleAndTweakStatesRead() {
        let store = CFPreferenceStore()
        for tweak in [SystemTweak.showAllExtensions, .pathBar, .statusBar, .fullPathInTitle, .dockActiveAppsOnly,
                      .dockInstantAutoHide, .dockRecentApps, .screenshotShadows] {
            _ = tweak.isOn(in: store) // nil is "macOS default"; it must not crash
        }
        XCTAssertFalse((SystemTweak.screenshotFormat.currentString(in: store) ?? "png").isEmpty)
        let finder = UserDefaults(suiteName: SystemTweak.finder)
        _ = MacMagicSystemToolService.finderFlag("AppleShowAllFiles", in: finder, default: false)
        _ = SystemToolsModel.isLibraryHidden()
        XCTAssertNotNil(DisplayControlService.currentMode(CGMainDisplayID()))
    }

    func testPmsetSettingsAndLowPowerSupport() throws {
        let output = try SystemToolsCommand.runChecked("/usr/bin/pmset", ["-g"])
        let settings = PowerTools.parsePmsetSettings(output.stdout)
        XCTAssertFalse(settings.isEmpty)
        // Apple silicon laptops offer Low Power Mode.
        if SystemStatus.battery() != nil { XCTAssertTrue(PowerTools.supportsLowPowerMode(settings)) }
    }

    // MARK: Power & Session

    func testAwakeReasonsAndBatteryDetails() throws {
        let assertions = try PowerTools.activeAssertions()
        // powerd always holds at least one while the display is on.
        XCTAssertFalse(assertions.isEmpty)
        if SystemStatus.battery() != nil {
            let details = PowerTools.batteryDetails()
            XCTAssertNotNil(details)
            let profile = try SystemToolsCommand.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"])
            XCTAssertNotNil(PowerTools.parseBatteryCondition(profile.stdout))
        }
    }

    @MainActor
    func testKeepAwakeStartsAndStops() throws {
        let awake = KeepAwakeService.shared
        // Codex F18: `try?` swallowed the skip and the test replaced a live session.
        try XCTSkipIf(awake.hasAssertion, "Keep Awake is in use")
        awake.start(minutes: 1, keepDisplay: false)
        XCTAssertTrue(awake.isActive)
        XCTAssertNotNil(awake.endsAt)
        awake.stop()
        XCTAssertFalse(awake.isActive)
    }

    @MainActor
    func testSleepTimerAndAppAwakeAreReversible() {
        let timer = SleepTimerService.shared
        guard !timer.isActive else { return }
        timer.start(minutes: 180)
        XCTAssertTrue(timer.isActive)
        timer.cancel()
        XCTAssertFalse(timer.isActive)
        let appAwake = AppAwakeService.shared
        guard !appAwake.isActive, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        XCTAssertTrue(appAwake.start(for: finder))
        XCTAssertTrue(appAwake.isActive)
        appAwake.stop()
        XCTAssertFalse(appAwake.isActive)
    }

    // MARK: Apps

    func testActivityLoginItemsAndOpenApps() throws {
        let samples = try ProcessTools.samples()
        XCTAssertGreaterThan(samples.count, 20)
        XCTAssertFalse(ProcessTools.top(samples, by: .cpu).isEmpty)
        XCTAssertFalse(ProcessTools.top(samples, by: .memory).isEmpty)
        _ = ProcessTools.loginItems()
        XCTAssertFalse(ProcessTools.regularApps().contains { $0.bundleIdentifier == "com.apple.finder" })
    }

    func testUninstallReviewListsLeftoversWithoutMovingAnything() throws {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        // A system app is refused; a user-installed one is reviewed.
        let candidates = ["/Applications/Ulanzi Studio.app", "/Applications/Telegram.app", "/Applications/KakaoTalk.app"]
        guard let app = candidates.map(URL.init(fileURLWithPath:)).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        let review = try CleanupTools.uninstallReview(for: app, library: library, isRunning: { _ in false })
        XCTAssertFalse(review.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "review moved the app")
        XCTAssertThrowsError(try CleanupTools.uninstallReview(for: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
                                                              library: library, isRunning: { _ in false }))
    }

    func testSavedWindowStateFolderLists() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        _ = FileTools.savedStateBundleIDs(library: library)
    }

    // MARK: Storage

    func testVolumesTimeMachineAndSnapshots() throws {
        let volumes = DiskTools.volumes()
        XCTAssertTrue(volumes.contains { $0.url.path == "/" || $0.isInternal })
        let status = try SystemToolsCommand.run("/usr/bin/tmutil", ["status"])
        XCTAssertNotNil(DiskTools.parseBackupStatus(status.stdout))
        let snapshots = try SystemToolsCommand.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        XCTAssertEqual(snapshots.status, 0)
        _ = DiskTools.parseLocalSnapshots(snapshots.stdout)
    }

    func testFreeUpSpaceScansATemporaryFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aom-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blob = Data(repeating: 7, count: 3_000_000)
        try blob.write(to: root.appendingPathComponent("a.bin"))
        try blob.write(to: root.appendingPathComponent("sub/b.bin"))
        try Data("x".utf8).write(to: root.appendingPathComponent("small.txt"))
        let sizes = FileTools.folderSizes(in: root)
        XCTAssertFalse(sizes.isEmpty)
        let large = CleanupTools.largeFiles(in: root, minimumBytes: 1_000_000)
        XCTAssertEqual(large.count, 2)
        let files = FileTools.sizedFiles(in: root, minimumBytes: 1_000_000)
        let groups = FileTools.duplicateGroups(files) { try FileTools.sha256Hex(fileAt: $0) }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
        _ = CleanupTools.oldDownloads(in: root, days: 30)
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        _ = CleanupTools.developerJunk(library: library)
    }

    func testRemovedAppsScanReadsTheRealLibrary() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let found = CleanupTools.orphanedFiles(library: library, installed: CleanupTools.isInstalledOrRunning)
        let byApp = Dictionary(grouping: found, by: \.note).mapValues { $0.reduce(0) { $0 + $1.size } }
        for (id, size) in byApp.sorted(by: { $0.value > $1.value }).prefix(25) {
            print("ORPHAN \(id) \(SystemStatus.size(size))")
        }
        XCTAssertFalse(found.contains { $0.note.hasPrefix("com.apple.") || $0.note.hasPrefix("com.kyw.allofmacos") })
        // The Mac's own tunnel and sync agents run scripts that exist.
        XCTAssertFalse(found.contains { $0.url.lastPathComponent == "com.kyw.mac-control-tunnel.plist" })
    }

    // MARK: Network

    func testNetworkInfoPingAndPorts() async throws {
        XCTAssertFalse(NetworkTools.dnsServers().isEmpty, "no DNS servers")
        let ping = try NetworkTools.ping(host: "127.0.0.1")
        XCTAssertEqual(ping.lossPercent, 0)
        _ = NetworkTools.wifiDetails()
        let listening = try NetworkTools.listeningUsers()
        XCTAssertFalse(listening.isEmpty, "nothing listening (AOM's own MCP socket is a Unix socket; rapportd and others listen on TCP)")
        if let port = listening.lazy.compactMap({ NetworkTools.port(from: String($0.name.split(separator: ":").last ?? "")) }).first {
            XCTAssertFalse(try NetworkTools.users(ofPort: port).isEmpty, "port \(port)")
        }
        let address = try await NetworkTools.publicIP()
        XCTAssertTrue(NetworkTools.isIPAddress(address), address)
    }

    func testSpeedTestFinishes() throws {
        let result = try NetworkTools.runSpeedTest(maxSeconds: 20)
        XCTAssertFalse(result.summary.isEmpty)
    }

    func testVPNServicesAndTailscaleRead() throws {
        let output = try SystemToolsCommand.run("/usr/sbin/scutil", VPNTools.listArguments())
        XCTAssertEqual(output.status, 0)
        _ = VPNTools.parseServiceList(output.stdout)
        if let cli = VPNTools.tailscaleExecutable() {
            let status = try SystemToolsCommand.run(cli.path, ["status", "--json"])
            if status.status == 0 { XCTAssertNoThrow(try VPNTools.parseTailscaleStatus(Data(status.stdout.utf8))) }
        }
    }

    // MARK: Homebrew

    func testHomebrewListsParse() throws {
        guard let brew = Homebrew.locate() else { throw XCTSkip("Homebrew is not installed") }
        let env = Homebrew.environment(base: ProcessInfo.processInfo.environment, brew: brew)
        func run(_ arguments: [String]) throws -> Data {
            let process = Process()
            process.executableURL = brew
            process.arguments = arguments
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }
        XCTAssertNoThrow(try Homebrew.parseOutdated(run(Homebrew.Command.outdated.arguments)))
        XCTAssertFalse(try Homebrew.parseInstalled(run(Homebrew.Command.installed.arguments)).isEmpty)
        XCTAssertNoThrow(try Homebrew.parseServices(run(Homebrew.Command.services.arguments)))
    }

    // MARK: Display

    func testMetalHUDRoundTrip() throws {
        let read = try SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.readArguments)
        try XCTSkipIf(MetalHUD.isOn(getenvOutput: read.stdout), "Metal HUD is in use")
        _ = try SystemToolsCommand.runChecked(MetalHUD.launchctl.path, MetalHUD.writeArguments(on: true))
        defer { _ = try? SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.writeArguments(on: false)) }
        let on = try SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.readArguments)
        XCTAssertTrue(MetalHUD.isOn(getenvOutput: on.stdout))
        _ = try SystemToolsCommand.runChecked(MetalHUD.launchctl.path, MetalHUD.writeArguments(on: false))
        let off = try SystemToolsCommand.run(MetalHUD.launchctl.path, MetalHUD.readArguments)
        XCTAssertFalse(MetalHUD.isOn(getenvOutput: off.stdout))
    }

    // MARK: Every tool has a working command path

    func testEveryCommandEachToolRunsExists() {
        let paths = ["/usr/bin/pmset", "/usr/bin/tmutil", "/usr/sbin/diskutil", "/usr/sbin/scutil", "/usr/sbin/lsof",
                     "/sbin/ping", "/usr/bin/networkQuality", "/usr/sbin/ipconfig", "/usr/bin/killall", "/usr/bin/mdutil",
                     "/usr/bin/osascript", "/usr/bin/chflags", "/bin/ps", "/bin/launchctl", "/usr/sbin/system_profiler",
                     "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"]
        for path in paths { XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path) }
    }
}
