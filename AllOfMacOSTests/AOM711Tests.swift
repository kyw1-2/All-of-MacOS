import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.11: Kill Process, weather units and fields, the panel's icon click.
@MainActor
final class AOM711Tests: XCTestCase {
    // MARK: Kill Process (spec §1)

    func testInstanceCheckRefusesAReusedPID() {
        let alive = PaletteProcesses.BSD(ppid: 1, uid: getuid(), name: "sleep", started: 100, zombie: false)
        XCTAssertEqual(PaletteProcesses.outcome(current: alive, expectedStart: 100, signalErrno: nil), .sent)
        XCTAssertEqual(PaletteProcesses.outcome(current: alive, expectedStart: 99, signalErrno: nil), .changed,
                       "another process now has the PID: never signalled")
        XCTAssertEqual(PaletteProcesses.outcome(current: nil, expectedStart: 100, signalErrno: nil), .alreadyGone)
        let zombie = PaletteProcesses.BSD(ppid: 1, uid: getuid(), name: "sleep", started: 100, zombie: true)
        XCTAssertEqual(PaletteProcesses.outcome(current: zombie, expectedStart: 100, signalErrno: nil), .alreadyGone)
        XCTAssertEqual(PaletteProcesses.outcome(current: alive, expectedStart: 100, signalErrno: EPERM), .notPermitted)
        XCTAssertEqual(PaletteProcesses.outcome(current: alive, expectedStart: 100, signalErrno: ESRCH), .alreadyGone)
    }

    func testKindsAndOwners() {
        XCTAssertEqual(PaletteProcesses.outerApp(of: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
                       "Google Chrome", "a helper belongs to the outermost app")
        XCTAssertNil(PaletteProcesses.outerApp(of: "/opt/homebrew/bin/node"))
        XCTAssertEqual(PaletteProcesses.kind(app: nil, path: "/opt/homebrew/bin/node"), .process)
        XCTAssertEqual(PaletteProcesses.kind(app: nil, path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"), .helper)
        let agent = PaletteProcesses.AppInfo(name: "Stats", bundleID: "eu.exelban.Stats", bundlePath: "/Applications/Stats.app", policy: .accessory)
        XCTAssertEqual(PaletteProcesses.kind(app: agent, path: nil), .menuBarApp)
    }

    /// Two processes with the same name: each its own row; ending one leaves the other.
    func testTwoSameNamedProcessesEndOneAtATime() throws {
        let first = Process(), second = Process()
        for process in [first, second] {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            try process.run()
        }
        defer { for process in [first, second] where process.isRunning { process.terminate() } }
        let rows = PaletteProcesses.snapshot(apps: [:]).filter { [first.processIdentifier, second.processIdentifier].contains($0.pid) }
        XCTAssertEqual(rows.count, 2, "one row per instance")
        XCTAssertTrue(rows.allSatisfy { $0.name == "sleep" && $0.kind == .process })
        XCTAssertTrue(PaletteProcesses.keywords(rows[0]).contains(String(rows[0].pid)), "found by PID")
        let target = try XCTUnwrap(rows.first { $0.pid == first.processIdentifier })
        XCTAssertEqual(PaletteProcesses.forceQuit(target), .sent)
        first.waitUntilExit()
        XCTAssertFalse(PaletteProcesses.isAlive(target))
        XCTAssertTrue(second.isRunning, "the other PID with the same name lives")
        XCTAssertEqual(PaletteProcesses.forceQuit(target), .alreadyGone, "a second Return on a gone row does nothing")
    }

    func testProtectedRowsAreNeverSignalled() {
        let own = PaletteProcesses.snapshot(apps: [:]).first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        XCTAssertEqual(own?.isProtected, true)
        if let own { XCTAssertEqual(PaletteProcesses.forceQuit(own), .protected) }
    }

    // MARK: Weather (spec §2)

    private func reading(_ temperature: Double, unit: MenuBarWeather.Unit = .celsius) -> WeatherReading {
        WeatherReading(cityID: 1, temperature: temperature, feelsLike: temperature - 2, code: 0, isDay: true, low: temperature - 5,
                       high: temperature + 4, rainChance: 30, fetchedAt: Date(timeIntervalSince1970: 0), unit: unit,
                       humidity: 64, windSpeed: 10)
    }

    func testSameObservationReadsInEitherUnit() {
        XCTAssertEqual(MenuBarWeather.line(reading(20).converted(to: .fahrenheit), fields: [.temperature]).text, "68°F")
        XCTAssertEqual(MenuBarWeather.line(reading(0).converted(to: .fahrenheit), fields: [.temperature]).text, "32°F")
        XCTAssertEqual(MenuBarWeather.line(reading(68, unit: .fahrenheit).converted(to: .celsius), fields: [.temperature]).text, "20°C",
                       "never 20°F after switching back")
        XCTAssertEqual(MenuBarWeather.line(reading(20), fields: [.temperature]).text, "20°C")
        XCTAssertEqual(MenuBarWeather.line(reading(20).converted(to: .fahrenheit), fields: [.wind]).text, "바람 6mph", "wind carries its unit")
    }

    func testFieldsKeepTheirOrderAndSkipMissingValues() {
        XCTAssertEqual(MenuBarWeather.line(reading(12), fields: [.temperature, .humidity, .rainChance]).text, "12°C · 습도 64% · 강수 30%")
        XCTAssertEqual(MenuBarWeather.line(reading(12), fields: [.rainChance, .temperature]).text, "강수 30% · 12°C")
        var missing = reading(12)
        missing.humidity = nil
        XCTAssertEqual(MenuBarWeather.line(missing, fields: [.temperature, .humidity]).text, "12°C")
        XCTAssertEqual(MenuBarWeather.line(nil, fields: [.temperature]).text, "—", "no data yet")
        XCTAssertEqual(MenuBarWeather.line(reading(12), fields: []).text, "", "icon only")
        let long = MenuBarWeather.line(reading(12), fields: MenuBarWeather.Field.allCases, limit: 20)
        XCTAssertTrue(long.text.count <= 20 || !long.text.contains("·"))
        XCTAssertTrue(long.full.hasPrefix(long.text), "the last fields go first; the tooltip has all")
    }

    func testOldSettingsCarryOver() {
        XCTAssertEqual(MenuBarWeather.fields(migrating: .iconOnly), [], "icon-only stays icon only")
        XCTAssertEqual(MenuBarWeather.fields(migrating: .temperature), [.temperature])
        XCTAssertEqual(MenuBarWeather.fields(migrating: .feelsLike), [.feelsLike])
    }

    // MARK: The panel's icon (spec §4)

    func testOnlyAPressOnTheIconBlocksTheReopen() {
        let icon = CGRect(x: 1400, y: 1050, width: 30, height: 24)
        XCTAssertTrue(AOMStatusPanelController.isIconPress(pointer: CGPoint(x: 1410, y: 1060), anchor: icon, buttonsDown: 1))
        XCTAssertFalse(AOMStatusPanelController.isIconPress(pointer: CGPoint(x: 1410, y: 1060), anchor: icon, buttonsDown: 0),
                       "a click that already ended (its own toggle) blocks nothing")
        XCTAssertFalse(AOMStatusPanelController.isIconPress(pointer: CGPoint(x: 600, y: 400), anchor: icon, buttonsDown: 1),
                       "a click elsewhere closes and that's all")
        XCTAssertFalse(AOMStatusPanelController.isIconPress(pointer: CGPoint(x: 1410, y: 1060), anchor: .null, buttonsDown: 1))
    }
}

/// 7.11 review and swarm audit: bounded process names.
final class AOM711ReviewTests: XCTestCase {
    func testProcessNamesNeverReadPastTheirField() {
        var full = [UInt8](repeating: 0x61, count: 32) // 32 × "a", no NUL
        full.withUnsafeBytes { XCTAssertEqual(PaletteProcesses.cString($0), String(repeating: "a", count: 32)) }
        var short: [UInt8] = Array("node".utf8) + [0, 0x62, 0x62]
        short.withUnsafeBytes { XCTAssertEqual(PaletteProcesses.cString($0), "node") }
        _ = (full, short)
    }
}

/// 7.11: the launcher comes back as it was within 90 s of a plain close.
@MainActor
final class AOM711LauncherKeepTests: XCTestCase {
    func testKeptScreenComesBackOnlyForAPlainReopenInTime() {
        let reuse = { (now: Double, fresh: Bool, route: Bool, hotkey: Bool, content: Bool) in
            AOMLauncherController.reusesKept(now: now, keptUntil: 100, hasContent: content, startFresh: fresh,
                                              initialRoute: route, hotkey: hotkey)
        }
        XCTAssertTrue(reuse(50, false, false, false, true), "reopened within the time: as it was")
        XCTAssertFalse(reuse(100, false, false, false, true), "after 90 s: back to the root")
        XCTAssertFalse(reuse(50, true, false, false, true), "a row ran: fresh")
        XCTAssertFalse(reuse(50, false, true, false, true), "opened on a given screen: that screen")
        XCTAssertFalse(reuse(50, false, false, true, true), "a launcher hotkey: fresh")
        XCTAssertFalse(reuse(50, false, false, false, false), "nothing kept")
        XCTAssertEqual(AOMLauncherController.keepSeconds, 90)
    }
}

/// 7.11 (user report): a Back gesture's ⌘[ while a text field has the focus.
final class AOM711ShortcutMenuTests: XCTestCase {
    func testMenuShortcutMatching() {
        XCTAssertEqual(ShortcutMenuPress.menuModifiers([.command]), 0)
        XCTAssertEqual(ShortcutMenuPress.menuModifiers([.command, .shift]), 1)
        XCTAssertEqual(ShortcutMenuPress.menuModifiers([.command, .option, .control]), 6)
        XCTAssertNil(ShortcutMenuPress.menuModifiers([.control]), "only ⌘ shortcuts have menu commands")
        XCTAssertTrue(ShortcutMenuPress.matches(cmdChar: "[", cmdModifiers: 0, character: "[", modifiers: 0))
        XCTAssertTrue(ShortcutMenuPress.matches(cmdChar: "W", cmdModifiers: nil, character: "w", modifiers: 0))
        XCTAssertFalse(ShortcutMenuPress.matches(cmdChar: "[", cmdModifiers: 1, character: "[", modifiers: 0), "⇧⌘[ is another command")
        XCTAssertFalse(ShortcutMenuPress.matches(cmdChar: nil, cmdModifiers: 0, character: "[", modifiers: 0))
        XCTAssertEqual(ShortcutMenuPress.character(for: 33), "[", "on the ASCII layout whatever the input source")
    }
}
