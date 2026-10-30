import XCTest
@testable import AllOfMacOS

/// 3.3.6 System Tools: parsers and mappings behind the new tools, and the
/// removal of the Text & Developer group. Nothing here changes system state:
/// command output is fed in as text, files live in a temporary folder, and
/// favorites go to a throwaway defaults suite.
@MainActor
final class SystemTools336Tests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aom-tools336-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ relative: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    // MARK: - Catalog, removed tools and stored ids

    static let removedIDs = ["formatJSON", "base64", "urlCode", "changeCase", "cleanText", "textStats", "uuid", "timestamp", "pickColor", "hashText"]

    func testTextAndDeveloperIsGoneAndTheNewGroupsAreFilled() {
        XCTAssertFalse(SystemToolGroup.allCases.map(\.name).contains("Text & Developer"))
        for id in Self.removedIDs { XCTAssertNil(SystemToolID(rawValue: id), "\(id) was removed") }
        XCTAssertGreaterThanOrEqual(SystemToolCatalog.all.count, 59 + 25, "59 kept tools plus at least 25 new ones")
        XCTAssertEqual(SystemToolsInventory.count, SystemToolCatalog.all.count)
        for group in [SystemToolGroup.displaySound, .energy, .apps, .disk, .info] {
            XCTAssertGreaterThanOrEqual(SystemToolCatalog.tools(in: group).count, 4, group.name)
        }
        // The subtitle shares the Workspace tile's one line with the count.
        XCTAssertLessThanOrEqual(SystemToolsInventory.subtitle.count, 24, "About 26 characters fit beside the count at 1320 pt")
        XCTAssertFalse(SystemToolsInventory.subtitle.localizedCaseInsensitiveContains("dev"))
        // 3.3.5 ids that stayed keep their raw values (saved favorites).
        for kept in ["darkMode", "keepAwake", "ejectAll", "speedTest", "fileHash", "devJunk", "copyIP"] {
            XCTAssertNotNil(SystemToolID(rawValue: kept), kept)
        }
        XCTAssertEqual(SystemToolCatalog.info(.ejectAll).group, .disk, "Eject All moved to Disk & Storage")
    }

    func testStoredIDsOfRemovedToolsAreDroppedSilently() {
        XCTAssertEqual(SystemToolsModel.storedTools(["formatJSON", "dns", "uuid", "dns", "no-such-tool", "ping"]), [.dns, .ping])
        XCTAssertEqual(SystemToolsModel.storedTools(nil), [])
        XCTAssertEqual(SystemToolsModel.storedTools(Self.removedIDs), [])
    }

    func testModelRewritesListsThatHeldRemovedIDs() throws {
        let suite = "aom-tools336-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["uuid", "speedTest", "base64"], forKey: SystemToolsModel.favoritesKey)
        defaults.set(["hashText", "wifi", "timestamp", "dns"], forKey: SystemToolsModel.recentKey)
        let model = SystemToolsModel(defaults: defaults)
        XCTAssertEqual(model.favorites, [.speedTest])
        XCTAssertEqual(model.recent, [.wifi, .dns])
        XCTAssertEqual(defaults.stringArray(forKey: SystemToolsModel.favoritesKey), ["speedTest"])
        XCTAssertEqual(defaults.stringArray(forKey: SystemToolsModel.recentKey), ["wifi", "dns"])
    }

    func testSearchFindsTheNewTools() {
        func hits(_ query: String) -> Set<SystemToolID> { Set(SystemToolCatalog.all.filter { $0.matches(query) }.map(\.id)) }
        XCTAssertTrue(hits("amphetamine").isSuperset(of: [.keepAwake, .awakeWhileApp]))
        XCTAssertTrue(hits("time machine").isSuperset(of: [.backupNow, .backupStatus]))
        XCTAssertTrue(hits("rssi").contains(.wifiDetails))
        XCTAssertTrue(hits("coconutbattery").contains(.batteryDetails))
        XCTAssertTrue(hits("json").isEmpty, "No text tools left")
    }

    // MARK: - ps

    func testPSOutputParsesNamesWithSpacesAndSortsTop() {
        let text = """
        42722  53.9   8400     0 storagekitd
        41967  40.0 474992   501 Google Chrome Helper (Renderer)
          651  27,7  41808    88 WindowServer
        garbage line
            1   0.0  12000     0 launchd
        """
        let samples = ProcessTools.parsePS(text)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[1].name, "Google Chrome Helper (Renderer)")
        XCTAssertEqual(samples[1].memory, 474_992 * 1024)
        XCTAssertEqual(samples[2].cpu, 27.7, accuracy: 0.001, "Comma decimals from a non-English locale")
        XCTAssertEqual(ProcessTools.top(samples, by: .cpu, limit: 2).map(\.pid), [42722, 41967])
        XCTAssertEqual(ProcessTools.top(samples, by: .memory, limit: 1).first?.pid, 41967)
        XCTAssertTrue(ProcessTools.detail(samples[0], ownUID: 501).contains("root (can't quit)"))
        XCTAssertTrue(ProcessTools.detail(samples[1], ownUID: 501).hasSuffix("· you"))
        XCTAssertEqual(ProcessTools.psArguments, ["-Aceo", "pid=,pcpu=,rss=,uid=,comm="])
    }

    func testLaunchItemNamesComeFromPlistFiles() {
        XCTAssertEqual(ProcessTools.launchItemNames(["com.b.agent.plist", ".DS_Store", "readme.txt", "com.a.helper.plist"]),
                       ["com.a.helper", "com.b.agent"])
    }

    // MARK: - pmset

    func testPmsetSettingsAndLowPowerMode() {
        let text = """
        System-wide power settings:
         SleepDisabled		0
        Currently in use:
         standby              1
         Sleep On Power Button 1
         sleep                0 (sleep prevented by Google Chrome, powerd)
         lowpowermode         0
         hibernatefile        /var/vm/sleepimage
        """
        let settings = PowerTools.parsePmsetSettings(text)
        XCTAssertEqual(settings["lowpowermode"], "0")
        XCTAssertEqual(settings["sleep"], "0")
        XCTAssertEqual(settings["Sleep On Power Button"], "1")
        XCTAssertEqual(settings["hibernatefile"], "/var/vm/sleepimage")
        XCTAssertNil(settings["Currently in use"])
        XCTAssertTrue(PowerTools.supportsLowPowerMode(settings))
        XCTAssertFalse(PowerTools.supportsLowPowerMode(["sleep": "1"]))
        XCTAssertEqual(PowerTools.lowPowerArguments(on: true), ["-a", "lowpowermode", "1"])
        XCTAssertEqual(PowerTools.lowPowerArguments(on: false), ["-a", "lowpowermode", "0"])
    }

    func testAssertionsKeepOnlySleepPreventingOnes() {
        let text = """
        Listed by owning process:
           pid 651(WindowServer): [0x0001273b0009947a] 00:03:21 UserIsActive named: "com.apple.iohideventsystem.queue.tickle"
           pid 1343(Google Chrome): [0x0005178c00019c36] 00:08:06 NoIdleSleepAssertion named: "Playing audio"
           pid 1343(Google Chrome): [0x0005178c00059c35] 00:08:07 NoDisplaySleepAssertion named: "Video Wake Lock"
           pid 594(powerd): [0x0001703d00018c47] 66:38:39 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
        Kernel Assertions: 0x4=USB
        """
        let assertions = PowerTools.parseAssertions(text)
        XCTAssertEqual(assertions.map(\.pid), [1343, 1343, 594])
        XCTAssertEqual(assertions[0].process, "Google Chrome")
        XCTAssertEqual(assertions[1].name, "Video Wake Lock")
        XCTAssertEqual(PowerTools.assertionKind(assertions[1].type), "Keeps the display on")
        XCTAssertEqual(PowerTools.assertionKind(assertions[2].type), "Keeps the Mac awake")
    }

    func testBatteryDetailsReadNestedTemperatureAndCondition() throws {
        let dictionary: [String: Any] = [
            "CurrentCapacity": 80, "MaxCapacity": 100, "CycleCount": 535, "DesignCapacity": 4382, "DesignCycleCount9C": 1000,
            "IsCharging": false, "ExternalConnected": true, "FullyCharged": false, "Voltage": 12107,
            "BatteryData": ["AppleRawMaxCapacity": 3622, "AppleRawCurrentCapacity": 2778, "Temperature": 3879]
        ]
        let details = try XCTUnwrap(PowerTools.parseBatteryDetails(dictionary))
        XCTAssertEqual(details.percent, 80)
        XCTAssertEqual(details.fullChargeCapacity, 3622)
        XCTAssertEqual(details.currentCapacity, 2778)
        XCTAssertEqual(details.healthPercent, 83)
        XCTAssertEqual(details.temperatureCelsius ?? 0, 38.79, accuracy: 0.001)
        XCTAssertEqual(details.voltage ?? 0, 12.107, accuracy: 0.0001)
        XCTAssertTrue(details.lines.contains("Cycle count: 535 of 1000 rated"))
        XCTAssertTrue(details.lines.contains("Temperature: 38.8 °C"))
        XCTAssertTrue(details.lines[0].contains("On power, not charging"))
        var noisy = dictionary
        noisy["BatteryData"] = ["Temperature": 9_999_999]
        XCTAssertNil(PowerTools.parseBatteryDetails(noisy)?.temperatureCelsius, "Out-of-range sensor values are dropped")
        let json = #"{"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_cycle_count":535,"sppower_battery_health":"Good"}}]}"#
        XCTAssertEqual(PowerTools.parseBatteryCondition(json), "Normal")
        XCTAssertEqual(PowerTools.parseBatteryCondition(json.replacingOccurrences(of: "Good", with: "Service Recommended")), "Service Recommended")
        XCTAssertNil(PowerTools.parseBatteryCondition("{}"))
    }

    // MARK: - tmutil and diskutil

    func testTimeMachineStatusAndSnapshots() throws {
        let idle = """
        Backup session status:
        {
            ClientID = "com.apple.backupd";
            Percent = "-1";
            Running = 0;
        }
        """
        let idleStatus = try XCTUnwrap(DiskTools.parseBackupStatus(idle))
        XCTAssertFalse(idleStatus.running)
        XCTAssertNil(idleStatus.progress)
        XCTAssertEqual(DiskTools.backupStatusText(idleStatus), "Not backing up")
        let running = """
        Backup session status:
        {
            BackupPhase = Copying;
            ClientID = "com.apple.backupd";
            Percent = "0.42";
            Running = 1;
        }
        """
        let busy = try XCTUnwrap(DiskTools.parseBackupStatus(running))
        XCTAssertTrue(busy.running)
        XCTAssertEqual(busy.progress ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(DiskTools.backupStatusText(busy), "Backing up (Copying), 42%")
        XCTAssertNil(DiskTools.parseBackupStatus("tmutil: error"))

        let none = SystemToolsCommand.Output(status: 0, stdout: "tmutil: No destinations configured.\n", stderr: "")
        XCTAssertFalse(DiskTools.hasDestination(none))
        let one = SystemToolsCommand.Output(status: 0, stdout: "====\nName : Backup\nKind : Local\nID : 1234\n", stderr: "")
        XCTAssertTrue(DiskTools.hasDestination(one))

        let snapshots = """
        Snapshots for volume group containing disk /:
        com.apple.os.update-2157898813C7601DC92DCC1799E6AE1D
        com.apple.TimeMachine.2026-10-30-120000.local
        com.apple.os.update-MSUPrepareUpdate
        """
        let names = DiskTools.parseLocalSnapshots(snapshots)
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(names.filter(DiskTools.isTimeMachineSnapshot), ["com.apple.TimeMachine.2026-10-30-120000.local"])
        XCTAssertEqual(DiskTools.thinArguments, ["thinlocalsnapshots", "/", "20000000000", "4"])
    }

    func testVerifyVolumeOutput() {
        let ok = """
        Started file system verification on disk3s1s1 (Macintosh HD)
        Verifying file system
        The volume /dev/rdisk3s1s1 appears to be OK
        File system check exit code is 0
        Finished file system verification on disk3s1s1 (Macintosh HD)
        """
        let good = DiskTools.parseVerify(ok, status: 0)
        XCTAssertTrue(good.ok)
        XCTAssertEqual(good.summary, "The volume /dev/rdisk3s1s1 appears to be OK")
        let bad = DiskTools.parseVerify("Verifying file system\nerror: invalid node\nError: -69845: File system verify or repair failed\n", status: 1)
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.summary, "Error: -69845: File system verify or repair failed")
        XCTAssertFalse(DiskTools.parseVerify("", status: 1).ok)
        XCTAssertEqual(DiskTools.verifyArguments(), ["verifyVolume", "/"])
    }

    func testStorageBarFraction() {
        XCTAssertEqual(DiskTools.usedFraction(total: 200, available: 50), 0.75, accuracy: 0.0001)
        XCTAssertEqual(DiskTools.usedFraction(total: 0, available: 0), 0)
        XCTAssertEqual(DiskTools.usedFraction(total: 100, available: 150), 0, "Reported free space above total is clamped")
    }

    // MARK: - Network

    func testRSSIAndChannelFormattingWithoutCoreWLAN() {
        XCTAssertEqual(NetworkTools.signalQuality(rssi: -45), "Excellent")
        XCTAssertEqual(NetworkTools.signalQuality(rssi: -50), "Excellent")
        XCTAssertEqual(NetworkTools.signalQuality(rssi: -60), "Good")
        XCTAssertEqual(NetworkTools.signalQuality(rssi: -65), "Fair")
        XCTAssertEqual(NetworkTools.signalQuality(rssi: -82), "Weak")
        XCTAssertEqual(NetworkTools.rssiText(rssi: -52, noise: -93), "-52 dBm · Good · SNR 41 dB")
        XCTAssertEqual(NetworkTools.rssiText(rssi: -52, noise: 0), "-52 dBm · Good", "A zero noise floor means unknown")
        XCTAssertEqual(NetworkTools.channelText(number: 36, bandGHz: 5, widthMHz: 80), "36 (5 GHz, 80 MHz)")
        XCTAssertEqual(NetworkTools.channelText(number: 6, bandGHz: 2.4, widthMHz: nil), "6 (2.4 GHz)")
        XCTAssertEqual(NetworkTools.channelText(number: 1, bandGHz: nil, widthMHz: nil), "1")
        let hidden = NetworkTools.WiFiDetails(interface: "en0", powerOn: true, ssid: nil, rssi: -52, noise: -93, channel: "36", transmitRate: 573)
        XCTAssertTrue(hidden.lines.contains { $0.contains("Location") }, "A withheld SSID says why")
        XCTAssertTrue(hidden.lines.contains("Transmit rate: 573 Mbps"))
        XCTAssertEqual(NetworkTools.WiFiDetails(interface: "en0", powerOn: false, ssid: nil, rssi: nil, noise: nil, channel: nil, transmitRate: nil).lines.last,
                       "Wi-Fi is off")
    }

    func testPingSummaryAndHostValidation() throws {
        let text = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes

        --- 1.1.1.1 ping statistics ---
        5 packets transmitted, 4 packets received, 20.0% packet loss
        round-trip min/avg/max/stddev = 5.096/5.444/5.770/0.276 ms
        """
        let result = try XCTUnwrap(NetworkTools.parsePing(text))
        XCTAssertEqual(result.sent, 5)
        XCTAssertEqual(result.received, 4)
        XCTAssertEqual(result.lossPercent, 20)
        XCTAssertEqual(result.summary, "5.4 ms average (5.1–5.8) · 20% loss")
        let silent = try XCTUnwrap(NetworkTools.parsePing("3 packets transmitted, 0 packets received, 100.0% packet loss"))
        XCTAssertEqual(silent.summary, "No reply (100% loss)")
        XCTAssertNil(NetworkTools.parsePing("ping: cannot resolve nope: Unknown host"))
        XCTAssertTrue(NetworkTools.isValidHost("apple.com"))
        XCTAssertTrue(NetworkTools.isValidHost("2606:4700:4700::1111"))
        XCTAssertFalse(NetworkTools.isValidHost("-f apple.com"), "Can't smuggle a ping option")
        XCTAssertFalse(NetworkTools.isValidHost("a b"))
        XCTAssertFalse(NetworkTools.isValidHost(""))
        XCTAssertEqual(NetworkTools.pingArguments(host: "apple.com").last, "apple.com")
    }

    func testDNSServersListeningPortsAndIPLiterals() {
        let scutil = """
        resolver #1
          nameserver[0] : 168.126.63.1
          nameserver[1] : 168.126.63.2
        resolver #2
          domain   : local
          nameserver[0] : 168.126.63.1
          nameserver[1] : fe80::1%en0
        """
        XCTAssertEqual(NetworkTools.parseDNSServers(scutil), ["168.126.63.1", "168.126.63.2", "fe80::1%en0"])
        let lsof = """
        p1026
        crapportd
        f12
        PTCP
        n*:58592
        TST=LISTEN
        f13
        PTCP
        n[::1]:58592
        TST=LISTEN
        p1145
        cControlCenter
        f9
        PTCP
        n*:5000
        TST=LISTEN
        """
        let ports = NetworkTools.listeningPorts(NetworkTools.parsePortUsers(lsof))
        XCTAssertEqual(ports.map(\.pid), [1145, 1026], "Port order, IPv4 and IPv6 listeners collapsed")
        XCTAssertEqual(ports.first?.command, "ControlCenter")
        XCTAssertEqual(NetworkTools.listeningArguments, ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcPnT"])
        XCTAssertTrue(NetworkTools.isIPAddress("203.0.113.7\n"))
        XCTAssertTrue(NetworkTools.isIPAddress("2001:db8::1"))
        XCTAssertFalse(NetworkTools.isIPAddress("<html>captive portal</html>"))
        XCTAssertFalse(NetworkTools.isIPAddress("999.1.1.1"))
        XCTAssertEqual(NetworkTools.publicIPURL.scheme, "https")
    }

    // MARK: - System Settings panes and system info

    func testSettingsPaneURLTable() {
        // CFBundleIdentifiers of the Settings extensions found in
        // /System/Library/ExtensionKit/Extensions on macOS 27.2.
        let verified: Set<String> = [
            "com.apple.systempreferences.GeneralSettings", "com.apple.SystemProfiler.AboutExtension", "com.apple.Software-Update-Settings.extension",
            "com.apple.settings.Storage", "com.apple.wifi-settings-extension", "com.apple.BluetoothSettings", "com.apple.Network-Settings.extension",
            "com.apple.AirDrop-Handoff-Settings.extension", "com.apple.Battery-Settings.extension", "com.apple.Displays-Settings.extension",
            "com.apple.Sound-Settings.extension", "com.apple.Appearance-Settings.extension", "com.apple.Desktop-Settings.extension",
            "com.apple.ControlCenter-Settings.extension", "com.apple.Wallpaper-Settings.extension", "com.apple.Accessibility-Settings.extension",
            "com.apple.settings.PrivacySecurity.extension", "com.apple.LoginItems-Settings.extension", "com.apple.Time-Machine-Settings.extension",
            "com.apple.Keyboard-Settings.extension", "com.apple.Trackpad-Settings.extension", "com.apple.Notifications-Settings.extension",
            "com.apple.Focus-Settings.extension", "com.apple.Sharing-Settings.extension", "com.apple.Startup-Disk-Settings.extension"
        ]
        for pane in SystemInfo.Pane.allCases {
            XCTAssertTrue(verified.contains(pane.rawValue), pane.rawValue)
            XCTAssertEqual(pane.url.absoluteString, "x-apple.systempreferences:" + pane.rawValue)
            XCTAssertFalse(pane.title.isEmpty)
        }
        let listed = SystemInfo.Pane.menuSections.flatMap { $0 }
        XCTAssertEqual(listed.count, SystemInfo.Pane.allCases.count, "Each pane once in the menu")
        XCTAssertEqual(Set(listed), Set(SystemInfo.Pane.allCases))
    }

    func testSystemInfoParsing() {
        XCTAssertEqual(SystemInfo.parseMachineName(#"{"SPHardwareDataType":[{"machine_name":"MacBook Air","machine_model":"MacBookAir10,1"}]}"#), "MacBook Air")
        XCTAssertNil(SystemInfo.parseMachineName("not json"))
        XCTAssertEqual(SystemInfo.versionText(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)), "27.2")
        XCTAssertEqual(SystemInfo.versionText(OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 1)), "14.7.1")
        XCTAssertEqual(SystemInfo.explainReason("smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty"), "lid opened")
        XCTAssertEqual(SystemInfo.explainReason("rst_in,reset_in_rise wdog,reset_in_1 ap_restart"), "normal restart, watchdog reset (system hang)")
        XCTAssertNil(SystemInfo.explainReason("0x1234"))
        let overview = SystemInfo.Overview(modelName: "MacBook Air", modelIdentifier: "MacBookAir10,1", chip: "Apple M1",
                                           memory: 8 << 30, osVersion: "27.2", build: "26B118")
        XCTAssertEqual(overview.lines, ["Model: MacBook Air (MacBookAir10,1)", "Chip: Apple M1", "Memory: 8 GB", "macOS: 27.2 (26B118)"])
    }

    func testDisplayAndSoundStateMappings() {
        XCTAssertTrue(DisplaySoundState.startupChimeOn(nvramOutput: "", status: 1), "No StartupMute variable: the chime plays")
        XCTAssertFalse(DisplaySoundState.startupChimeOn(nvramOutput: "StartupMute\t%01\n", status: 0))
        XCTAssertTrue(DisplaySoundState.startupChimeOn(nvramOutput: "StartupMute\t%00\n", status: 0))
        XCTAssertEqual(DisplaySoundState.startupChimeArguments(on: false), ["StartupMute=%01"])
        XCTAssertEqual(DisplaySoundState.percentText(0.454), "45%")
        XCTAssertEqual(DisplaySoundState.percentText(1.7), "100%")
        XCTAssertNil(DisplaySoundState.percentText(nil))
        XCTAssertEqual(DisplaySoundState.shortName("MacBook Air Speakers"), "MacBook Air S…")
        XCTAssertEqual(DisplaySoundState.shortName("AirPods"), "AirPods")
    }

    // MARK: - Files

    func testDuplicateGroupingKeepsTheOldestAndIgnoresEmptyFiles() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let files = [
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/copy.jpg"), size: 10, created: new),
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/original.jpg"), size: 10, created: old),
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/other.jpg"), size: 10, created: old),
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/big-a.mov"), size: 500, created: nil),
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/deep/big-b.mov"), size: 500, created: nil),
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/empty1"), size: 0, created: nil),
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/empty2"), size: 0, created: nil),
            FileTools.SizedFile(url: URL(fileURLWithPath: "/x/unique"), size: 77, created: nil)
        ]
        var hashed: [String] = []
        let digests = ["copy.jpg": "A", "original.jpg": "A", "other.jpg": "B", "big-a.mov": "M", "big-b.mov": "M"]
        let groups = FileTools.duplicateGroups(files) { url in hashed.append(url.lastPathComponent); return digests[url.lastPathComponent]! }
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.url.lastPathComponent), ["big-a.mov", "big-b.mov"], "Most wasted space first; shorter path kept")
        XCTAssertEqual(groups[1].map(\.url.lastPathComponent), ["original.jpg", "copy.jpg"], "Oldest copy kept")
        XCTAssertFalse(hashed.contains("unique"), "Files with a unique size are never hashed")
        XCTAssertFalse(hashed.contains("empty1"))
        let rows = FileTools.duplicateCandidates(groups, home: "/x")
        XCTAssertEqual(rows.items.count, 4)
        XCTAssertEqual(rows.preselected, Set(["/x/deep/big-b.mov", "/x/copy.jpg"]), "Only copies are checked")
        XCTAssertTrue(rows.items[0].note.contains("keep"))
        XCTAssertEqual(FileTools.wasted(groups[0]), 500)
    }

    func testDuplicateScanOnRealFilesInATemporaryFolder() throws {
        try write("a/one.bin", Data(repeating: 1, count: 4096))
        try write("b/two.bin", Data(repeating: 1, count: 4096))
        try write("c/same-size-different.bin", Data(repeating: 2, count: 4096))
        try write("tiny.txt", Data("hi".utf8))
        let files = FileTools.sizedFiles(in: folder, minimumBytes: 1000)
        XCTAssertEqual(files.count, 3)
        let groups = FileTools.duplicateGroups(files) { try FileTools.sha256Hex(fileAt: $0) }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.url.lastPathComponent)), ["one.bin", "two.bin"])
    }

    func testFolderSizeAggregation() throws {
        let sizes = FileTools.aggregateSizes([("Movies/a.mov", 700), ("Movies/sub/b.mov", 300), ("notes.txt", 5), ("Code/x.swift", 40), ("/Code/y.swift", 60), ("", 9)])
        XCTAssertEqual(sizes, [.init(name: "Movies", size: 1000, files: 2), .init(name: "Code", size: 100, files: 2), .init(name: "notes.txt", size: 5, files: 1)])
        try write("Big/a.bin", Data(repeating: 0, count: 64 * 1024))
        try write("Small/b.bin", Data(repeating: 0, count: 10))
        let measured = FileTools.folderSizes(in: folder)
        XCTAssertEqual(measured.map(\.name), ["Big", "Small"])
        XCTAssertGreaterThanOrEqual(measured[0].size, 64 * 1024)
    }

    func testSHA256OfAStreamedFileAndClipboardHash() throws {
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(try FileTools.sha256Hex(fileAt: try write("abc.txt", Data("abc".utf8))), abc)
        let big = try write("big.bin", Data(repeating: 7, count: 3 << 20))
        XCTAssertEqual(try FileTools.sha256Hex(fileAt: big), FileTools.sha256Hex(try Data(contentsOf: big)), "Chunked equals whole")
        XCTAssertEqual(FileTools.expectedHash(in: " \(abc.uppercased())\n"), abc)
        XCTAssertNil(FileTools.expectedHash(in: "abc"))
        XCTAssertNil(FileTools.expectedHash(in: String(repeating: "g", count: 64)))
    }

    func testSavedStateFoldersAndFreeFileNames() throws {
        let library = folder.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: FileTools.savedStateFolder(bundleID: "com.b.app", library: library), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: FileTools.savedStateFolder(bundleID: "com.a.app", library: library), withIntermediateDirectories: true)
        try write("Library/Saved Application State/stray.plist", Data())
        XCTAssertEqual(FileTools.savedStateBundleIDs(library: library), ["com.a.app", "com.b.app"])
        XCTAssertEqual(FileTools.savedStateFolder(bundleID: "com.a.app", library: library).lastPathComponent, "com.a.app.savedState")
        let taken: Set<String> = ["untitled.txt", "untitled 2.txt"]
        XCTAssertEqual(FileTools.freeName("untitled", ext: "txt", in: folder) { taken.contains($0.lastPathComponent) }.lastPathComponent, "untitled 3.txt")
        XCTAssertEqual(FileTools.freeName("untitled", ext: "txt", in: folder) { _ in false }.lastPathComponent, "untitled.txt")
    }
}
