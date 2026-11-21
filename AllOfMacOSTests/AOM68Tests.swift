import AppKit
import XCTest
@testable import AllOfMacOS

/// 6.8: windows that stay put, AOM capturable, the launcher's input source
/// and the defects Codex's independent 6.7 review found.
final class AOM68Tests: XCTestCase {
    // MARK: Windows

    func testTheWindowDirectlyAboveIsTheLastOtherAppNormalWindowListed() {
        let own: pid_t = 100
        let above: [[String: Any]] = [
            [kCGWindowLayer as String: 25, kCGWindowOwnerPID as String: pid_t(1), kCGWindowNumber as String: CGWindowID(1)], // menu bar
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: pid_t(2), kCGWindowNumber as String: CGWindowID(20)],  // Safari, front
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: own, kCGWindowNumber as String: CGWindowID(30)],      // AOM's own
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: pid_t(3), kCGWindowNumber as String: CGWindowID(40)],  // Notes, just above
        ]
        XCTAssertEqual(AOMOverlayActivation.windowDirectlyAbove(in: above, ownPID: own), 40)
        XCTAssertNil(AOMOverlayActivation.windowDirectlyAbove(in: [], ownPID: own), "a front window stays in front")
    }

    @MainActor
    func testTheMenuBarPanelOpensUnderItsIconInsideTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 382, height: 420)
        let middle = AOMStatusPanelController.frame(size: size, under: CGRect(x: 900, y: 875, width: 30, height: 24), visible: visible)
        XCTAssertEqual(middle.midX, 915, accuracy: 1)
        XCTAssertEqual(middle.maxY, 869, accuracy: 1, "6 pt under the icon")
        let edge = AOMStatusPanelController.frame(size: size, under: CGRect(x: 1420, y: 875, width: 20, height: 24), visible: visible)
        XCTAssertLessThanOrEqual(edge.maxX, visible.maxX - 8, "an icon at the right edge keeps the panel on screen")
    }

    // MARK: Launcher

    func testOnlyANonASCIIInputSourceIsSwitched() {
        XCTAssertTrue(PaletteInputSource.needsSwitch(currentID: "com.apple.inputmethod.Korean.2SetKorean", currentIsASCII: false))
        XCTAssertFalse(PaletteInputSource.needsSwitch(currentID: "com.apple.keylayout.ABC", currentIsASCII: true))
        XCTAssertFalse(PaletteInputSource.needsSwitch(currentID: nil, currentIsASCII: false))
    }

    func testScreenFilteringIgnoresTheSharedSectionName() {
        let item = QuickCommandPalette.PaletteItem(id: "x", title: "Orbit", subtitle: "/Applications", icon: "app",
                                                   section: .commands, primary: .init(title: "Run") {})
        XCTAssertTrue(QuickCommandPalette.PaletteSearch.filtered([item], query: "commands").isEmpty,
                      "Codex review: \"commands\" matched every row of a screen")
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.rank(of: item, matching: "commands"), 3, "the root still matches sections")
    }

    // MARK: Uninstall (Codex review U1–U3)

    func testTheResultNamesTheAppOnlyWhenTheAppMoved() {
        let app = URL(fileURLWithPath: "/Applications/Notes Plus.app")
        let prefs = URL(fileURLWithPath: "/Users/x/Library/Preferences/com.example.notes.plist")
        var leftovers = CleanupTools.TrashOutcome()
        leftovers.moved = [prefs]
        XCTAssertEqual(PaletteUninstallFlow.title(for: leftovers, app: app, name: "Notes Plus"),
                       "1 Leftover in the Trash · Notes Plus Stays Installed")
        var whole = CleanupTools.TrashOutcome()
        whole.moved = [app, prefs]
        XCTAssertEqual(PaletteUninstallFlow.title(for: whole, app: app, name: "Notes Plus"), "Notes Plus Is in the Trash")
        var partial = whole
        partial.failures = ["x.plist: denied"]
        XCTAssertEqual(PaletteUninstallFlow.title(for: partial, app: app, name: "Notes Plus"), "2 Moved, 1 Stayed")
        XCTAssertEqual(PaletteUninstallFlow.title(for: CleanupTools.TrashOutcome(), app: app, name: "Notes Plus"), "Nothing Was Moved")
    }

    @MainActor
    func testLeftoversOnlyKeepTheAppAndARetryListsOnlyWhatStayed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aom68-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Notes Plus.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let bundleID = "com.example.aom68.\(UUID().uuidString.prefix(8).lowercased())"
        try ([ "CFBundleIdentifier": bundleID, "CFBundleName": "Notes Plus", "CFBundlePackageType": "APPL"] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let prefs = root.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let plist = prefs.appendingPathComponent("\(bundleID).plist")
        let byHost = prefs.appendingPathComponent("\(bundleID).extra.plist")
        try Data("a".utf8).write(to: plist)
        try Data("b".utf8).write(to: byHost)
        let app = root.appendingPathComponent("Notes Plus.app")

        let flow = PaletteUninstallFlow(app: app, library: root.appendingPathComponent("Library"))
        flow.start()
        waitFor { flow.phase == .review }
        flow.toggle(app.path)   // keep the app, move only its preferences
        try FileManager.default.removeItem(at: byHost)   // one leftover vanishes before the move
        flow.trash()
        waitFor { if case .done = flow.phase { return true }; return false }
        guard case .done(let outcome) = flow.phase else { return XCTFail("\(flow.phase)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "the app stays")
        XCTAssertEqual(outcome.moved.map(\.lastPathComponent), [plist.lastPathComponent])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertFalse(flow.canRetry && FileManager.default.fileExists(atPath: byHost.path))
        flow.retryFailed()
        XCTAssertNotEqual(flow.phase, .review, "nothing left to retry: the failed item no longer exists")
        flow.cancel()
    }

    @MainActor
    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let done = expectation(description: "condition")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: timeout + 1)
    }

    func testUnreadableLeftoverFoldersAreReportedNotHidden() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("aom68-lib-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.appendingPathComponent("Containers").path)
            try? FileManager.default.removeItem(at: library)
        }
        let locked = library.appendingPathComponent("Containers", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let scan = CleanupTools.leftoverScan(bundleID: "com.example.locked.app", appName: "Locked", library: library)
        XCTAssertEqual(scan.unreadable, ["Container"])
        XCTAssertTrue(scan.matches.isEmpty)
    }
}

/// 6.9: Ask AI on the user's Claude Code and Codex CLIs.
final class AOM69AITests: XCTestCase {
    func testClaudeStreamLinesBecomeSessionDeltaAndResult() {
        // Lines as `claude -p … --output-format stream-json --include-partial-messages --verbose` printed them on this Mac.
        let initLine = #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"b2f9155f-7720-4fe9-9519-799b07260925"}"#
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"OK"}},"session_id":"b2f9155f"}"#
        let thinking = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}}"#
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"OK","session_id":"b2f9155f-7720-4fe9-9519-799b07260925"}"#
        XCTAssertEqual(PaletteAIEvent.parse(initLine, provider: .claude), [.session("b2f9155f-7720-4fe9-9519-799b07260925")])
        XCTAssertEqual(PaletteAIEvent.parse(delta, provider: .claude), [.delta("OK")])
        XCTAssertEqual(PaletteAIEvent.parse(thinking, provider: .claude), [], "thinking is not shown as the answer")
        XCTAssertEqual(PaletteAIEvent.parse(result, provider: .claude), [.session("b2f9155f-7720-4fe9-9519-799b07260925"), .done("OK")])
        XCTAssertEqual(PaletteAIEvent.parse("not json", provider: .claude), [])
    }

    func testCodexEventsIncludingTheUsageLimitError() {
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"thread.started","thread_id":"01a1f891"}"#, provider: .codex), [.session("01a1f891")])
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"OK"}}"#, provider: .codex),
                       [.message("OK")])
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"item.completed","item":{"type":"reasoning","text":"x"}}"#, provider: .codex), [])
        // Exactly what Codex printed here on 2026-11-20 (its usage limit).
        let limit = #"{"type":"error","message":"You’ve hit your usage limit. Try again at 9:10 PM."}"#
        XCTAssertEqual(PaletteAIEvent.parse(limit, provider: .codex), [.failure("You’ve hit your usage limit. Try again at 9:10 PM.")])
    }

    func testTurnsInTheLauncherAreReadOnly() {
        let claude = PaletteAIProvider.claude.arguments(prompt: "hi", session: "abc")
        XCTAssertEqual(Array(claude.prefix(2)), ["-p", "hi"])
        XCTAssertTrue(claude.contains("plan"), "Claude Code runs in plan mode in the launcher")
        XCTAssertEqual(claude.suffix(2), ["--resume", "abc"])
        XCTAssertFalse(claude.contains { $0.contains("dangerously") })
        let codex = PaletteAIProvider.codex.arguments(prompt: "hi", session: nil)
        XCTAssertEqual(codex.first, "exec")
        XCTAssertTrue(zip(codex, codex.dropFirst()).contains { $0 == ("--sandbox", "read-only") })
        XCTAssertEqual(codex.last, "hi")
    }

    func testTerminalCommandsQuoteThePrompt() {
        let command = PaletteAIProvider.claude.terminalCommand(session: nil, prompt: "it's \"fine\"")
        XCTAssertTrue(command.hasSuffix(#" 'it'\''s "fine"'"#), command)
        XCTAssertTrue(PaletteAIProvider.codex.terminalCommand(session: "t1", prompt: nil).hasSuffix(" resume 't1'"))
    }

    func testPlaceholdersNeedTheirText() {
        let template = PaletteAICommand.all.first { $0.id == "ai.korean" }!.template
        XCTAssertNil(PaletteAICommand.fill(template, selection: "  ", clipboard: nil), "no selection, no question")
        XCTAssertTrue(PaletteAICommand.fill(template, selection: "Hello", clipboard: nil)?.contains("Hello") == true)
        XCTAssertEqual(PaletteAICommand.fill("{clipboard}!", selection: nil, clipboard: "x"), "x!")
    }

    @MainActor
    func testCodexFollowUpsCarryTheEarlierTurns() {
        let earlier: [PaletteAIChat.Message] = [.init(role: .user, text: "What is AOM?"), .init(role: .assistant, text: "A Mac utility."),
                                                .init(role: .error, text: "limit")]
        let prompt = PaletteAIChat.withHistory("And its launcher?", earlier[...])
        XCTAssertTrue(prompt.contains("User: What is AOM?"))
        XCTAssertTrue(prompt.contains("Assistant: A Mac utility."))
        XCTAssertFalse(prompt.contains("limit"), "errors are not context")
        XCTAssertTrue(prompt.hasSuffix("User: And its launcher?"))
        XCTAssertEqual(PaletteAIChat.withHistory("Hi", [][...]), "Hi")
    }
}

/// 6.10: battery care on macOS 27 firmware (native limit, Hold Here, Top Up,
/// Discharge through CHIE).
final class AOM610BatteryTests: XCTestCase {
    private final class FakeSMC: SMCWriting {
        var values: [String: SMCValue]
        var writes: [(String, [UInt8])] = []
        init(_ values: [String: SMCValue]) { self.values = values }
        func read(_ key: String) throws -> SMCValue {
            guard let value = values[key] else { throw HardwareControlError.unavailable("SMC \(key) operation failed (0, 132)") }
            return value
        }
        func write(_ key: String, value: SMCValue) throws { values[key] = value; writes.append((key, value.bytes)) }
    }

    func testHoldUsesMacOSStepsAndNeverGoesBelow80() {
        XCTAssertEqual(BatteryTelemetry.holdLimit(for: 83), 85)
        XCTAssertEqual(BatteryTelemetry.holdLimit(for: 80), 80)
        XCTAssertEqual(BatteryTelemetry.holdLimit(for: 62), 80, "macOS 27 can't hold below 80%")
        XCTAssertEqual(BatteryTelemetry.holdLimit(for: 100), 100)
    }

    func testTelemetryFromThisMacsRegistryValues() {
        // Values ioreg showed on this Mac on 2026-11-20 (held at 80% on a 65 W adapter).
        let t = BatteryTelemetry.from([
            "CurrentCapacity": 80, "IsCharging": false, "ExternalConnected": true, "FullyCharged": false, "CycleCount": 537,
            "BatteryData": ["DesignCapacity": 4382, "AppleRawMaxCapacity": 3623],
            "AdapterDetails": ["Watts": 65], "ChargerData": ["NotChargingReason": 16777216],
            "PowerTelemetryData": ["SystemPowerIn": 11732, "SystemLoad": 11732, "BatteryPower": 0],
        ])
        XCTAssertEqual(t.percent, 80)
        XCTAssertEqual(t.health, 83)
        XCTAssertEqual(t.adapterRating, 65)
        XCTAssertEqual(t.batteryWatts, 0)
        XCTAssertEqual(BatteryCareSection.stateLine(power: t, limit: 80, discharging: nil, topUp: false),
                       "Not charging — held at 80%, running on the adapter")
        var charging = t
        charging.isCharging = true
        XCTAssertEqual(BatteryCareSection.stateLine(power: charging, limit: nil, discharging: nil, topUp: true), "Charging to 100% (top up)")
    }

    func testDischargeModeIsParsedWithItsTarget() {
        XCTAssertEqual(BatteryCareMode.parse("discharge-70")?.mode, .discharge)
        XCTAssertEqual(BatteryCareMode.parse("discharge-70")?.target, 70)
        XCTAssertNil(BatteryCareMode.parse("discharge-5"), "never below 10%")
        XCTAssertEqual(BatteryCareMode.parse("limit80")?.mode, .limit80)
        XCTAssertNil(BatteryCareMode.parse("nonsense"))
    }

    func testDischargeRunsFromACToTheTargetEvenWhileTheAdapterReadsGone() {
        var policy = DischargePolicy()
        XCTAssertFalse(policy.cutsAdapter(percent: 90, target: 70, onAC: false), "never starts on battery")
        XCTAssertTrue(policy.cutsAdapter(percent: 90, target: 70, onAC: true))
        XCTAssertTrue(policy.cutsAdapter(percent: 80, target: 70, onAC: false), "the cut adapter reads as unplugged")
        XCTAssertFalse(policy.cutsAdapter(percent: 70, target: 70, onAC: false))
        XCTAssertFalse(policy.cutsAdapter(percent: 75, target: 70, onAC: false), "does not restart by itself")
    }

    func testTheControllerCutsAndRestoresCHIEOnThisFirmware() throws {
        // macOS 27.3 here: CH0B/CH0C/CHTE are gone (132), CHIE answers [0].
        let smc = FakeSMC(["CHIE": SMCValue(type: "hex_", bytes: [0])])
        var sample = HardwareSample()
        sample.batteryPercent = 90
        sample.onAC = true
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("aom610-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: journal) }
        let controller = try HardwareController(smc: smc, journal: journal, readSample: { sample }, thermalPressure: { false })
        XCTAssertThrowsError(try controller.configure(battery: .limit80, fan: .auto), "the old charge keys don't exist here")
        try controller.configure(battery: .discharge, fan: .auto, dischargeTarget: 70)
        XCTAssertEqual(smc.values["CHIE"]?.bytes, [0x08], "adapter cut")
        sample.batteryPercent = 70
        sample.onAC = false
        try controller.tick()
        XCTAssertEqual(smc.values["CHIE"]?.bytes, [0x00], "adapter back at the target")
        sample.batteryPercent = 85
        try controller.configure(battery: .discharge, fan: .auto, dischargeTarget: 70)
        XCTAssertEqual(smc.values["CHIE"]?.bytes, [0x00], "on battery: does not start")
        try controller.stop()
        XCTAssertEqual(smc.values["CHIE"]?.bytes, [0x00])
    }

    func testAnotherUtilitysAdapterCutIsNeverTaken() throws {
        let smc = FakeSMC(["CHIE": SMCValue(type: "hex_", bytes: [0x08])])
        var sample = HardwareSample()
        sample.batteryPercent = 90
        sample.onAC = true
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("aom610b-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: journal) }
        let controller = try HardwareController(smc: smc, journal: journal, readSample: { sample }, thermalPressure: { false })
        XCTAssertThrowsError(try controller.configure(battery: .discharge, fan: .auto, dischargeTarget: 70))
        XCTAssertTrue(smc.writes.isEmpty)
    }
}

/// 6.11: System Tools without the tools the launcher, the Apple menu and the
/// Battery card now cover.
final class AOM611ToolsTests: XCTestCase {
    func testRetiredToolsLeaveThePageAndStoredListsMoveToKillApps() {
        let retired: Set<SystemToolID> = [.lockScreen, .sleep, .sleepDisplays, .batteryDetails]
        XCTAssertEqual(SystemToolCatalog.retiredIDs, retired)
        XCTAssertTrue(SystemToolCatalog.available.allSatisfy { !retired.contains($0.id) })
        XCTAssertEqual(SystemToolsModel.storedTools(["forceQuit", "lockScreen", "quitAll", "darkMode", "batteryDetails"]),
                       [.killApps, .darkMode], "Force Quit and Quit All become Kill Apps once; the rest drop")
        XCTAssertEqual(SystemToolCatalog.info(.lockScreen).title, "Lock Screen", "a retired id still resolves")
    }

    func testAwakeReasonsLiveWithPowerAndWindowStateWithFixIt() {
        XCTAssertEqual(SystemToolCatalog.info(.awakeReasons).group, .power)
        XCTAssertEqual(SystemToolCatalog.info(.resetSavedState).group, .fixIt)
        XCTAssertEqual(SystemToolGroup.power.name, "Battery & Power")
        XCTAssertEqual(SystemToolCatalog.info(.killApps).group, .apps)
    }
}

/// 6.11: Automation glyphs and folded step options, Ice's menu bar spacing.
final class AOM611UITests: XCTestCase {
    func testTrackpadRowsShowTheGestureItself() {
        XCTAssertEqual(AOMTriggerGlyph.symbol(name: "4 Finger Tap", category: .trackpad), "hand.tap")
        XCTAssertEqual(AOMTriggerGlyph.symbol(name: "3 Finger Double Tap", category: .trackpad), "hand.tap.fill")
        XCTAssertEqual(AOMTriggerGlyph.symbol(name: "4 Finger Swipe Down", category: .trackpad), "arrow.down")
        XCTAssertEqual(AOMTriggerGlyph.symbol(name: "Corner Click Top Left", category: .trackpad), "arrow.up.left.square")
        XCTAssertEqual(AOMTriggerGlyph.symbol(name: "TipTap Right", category: .trackpad), "hand.point.right")
        XCTAssertEqual(AOMTriggerGlyph.symbol(name: "⌘K", category: .keyboard), TriggerCategory.keyboard.iconName)
    }

    func testFoldedStepOptionsSummarizeWhatIsSet() {
        var p = ActionParameters()
        XCTAssertEqual(ActionConfigView.sequenceSummary(p), "Default")
        XCTAssertEqual(ActionConfigView.conditionSummary(p), "Always")
        p.repeatCount = 3
        p.delayAfterMs = 200
        XCTAssertEqual(ActionConfigView.sequenceSummary(p), "After 200 ms · repeat 3×")
        p.onlyAppBundleID = "com.apple.Safari"
        p.powerSource = "ac"
        XCTAssertEqual(ActionConfigView.conditionSummary(p), "2 conditions")
    }

    func testMenuBarSpacingWritesIcesKeysAndRestoresByDeleting() {
        XCTAssertEqual(SystemToolsModel.MenuBarSpacing.compact.commands.first,
                       ["-currentHost", "write", "-globalDomain", "NSStatusItemSpacing", "-int", "8"])
        XCTAssertEqual(SystemToolsModel.MenuBarSpacing.standard.commands.map { $0[1] }, ["delete", "delete"])
        XCTAssertEqual(SystemToolsModel.MenuBarSpacing.current(spacing: nil), .standard)
        XCTAssertEqual(SystemToolsModel.MenuBarSpacing.current(spacing: 4), .tight)
        XCTAssertEqual(SystemToolsModel.MenuBarSpacing.current(spacing: 8), .compact)
    }
}
