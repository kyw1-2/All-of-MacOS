import AppKit
import XCTest
@testable import AllOfMacOS

final class PaletteKnowledgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func item(_ id: String, _ title: String, section: QuickCommandPalette.Section = .commands) -> QuickCommandPalette.PaletteItem {
        QuickCommandPalette.PaletteItem(id: id, title: title, subtitle: "", icon: "circle", section: section,
                                        primary: .init(title: "Run") {})
    }

    func testThePickForAQueryComesFirstNextTime() {
        var knowledge = PaletteKnowledge()
        knowledge.record(itemID: "action.capture", query: "ca", now: now)
        let items = [item("action.calendar", "Calendar"), item("action.capture", "Capture Area")]
        // Both start with "ca"; without knowledge Calendar (first) wins.
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.results(for: items, query: "ca", now: now).first?.id, "action.calendar")
        XCTAssertEqual(QuickCommandPalette.PaletteSearch.results(for: items, query: "CA ", knowledge: knowledge, now: now).first?.id,
                       "action.capture")
    }

    func testUseOrdersRowsOfTheSameMatchQualityButNeverBeatsABetterMatch() {
        var knowledge = PaletteKnowledge()
        for _ in 0..<5 { knowledge.record(itemID: "b", query: "x", now: now) }
        let items = [item("a", "Window Left"), item("b", "Window Right"), item("c", "Move Window")]
        let ranked = QuickCommandPalette.PaletteSearch.results(for: items, query: "window", knowledge: knowledge, now: now).map(\.id)
        XCTAssertEqual(ranked, ["b", "a", "c"], "prefix matches first, the used one leading them; a contains-match stays after")
    }

    func testEmptyPaletteLeadsWithSuggestionsOnlyAfterRepeatedUse() {
        var knowledge = PaletteKnowledge()
        knowledge.record(itemID: "nav", query: "", now: now)
        let items = [item("cmd", "Capture"), item("nav", "Open Settings", section: .navigation)]
        var rows = QuickCommandPalette.PaletteSearch.results(for: items, query: "", knowledge: knowledge, now: now)
        XCTAssertFalse(rows.contains(where: \.isSuggestion), "one use is not a habit")
        knowledge.record(itemID: "nav", query: "", now: now)
        rows = QuickCommandPalette.PaletteSearch.results(for: items, query: "", knowledge: knowledge, now: now)
        XCTAssertEqual(rows.map(\.id), ["nav", "cmd"])
        XCTAssertTrue(rows[0].isSuggestion)
        XCTAssertEqual(rows[0].section, .navigation, "a suggestion keeps its own section's colour")
    }

    func testUseDecaysWithAOneWeekHalfLife() {
        var knowledge = PaletteKnowledge()
        knowledge.record(itemID: "a", query: "", now: now)
        XCTAssertEqual(knowledge.decayedScore("a", now: now.addingTimeInterval(7 * 86_400)), 0.5, accuracy: 0.001)
    }

    func testMomentaryRowsAreNeverLearnt() {
        var knowledge = PaletteKnowledge()
        for id in ["calculator", "fallback.google", "clipboard.123", "capture.9", "files.latestDownload", "menu.permission"] {
            knowledge.record(itemID: id, query: "x", now: now)
        }
        XCTAssertNil(knowledge.pick(for: "x"))
        XCTAssertEqual(knowledge.decayedScore("calculator", now: now), 0)
    }

    func testForgetRemovesUseAndPicks() {
        var knowledge = PaletteKnowledge()
        knowledge.record(itemID: "a", query: "q", now: now)
        knowledge.forget("a")
        XCTAssertNil(knowledge.pick(for: "q"))
        XCTAssertEqual(knowledge.decayedScore("a", now: now), 0)
    }

    func testStoreIsBounded() {
        var knowledge = PaletteKnowledge()
        for index in 0..<(PaletteKnowledge.maxItems + 50) { knowledge.record(itemID: "i\(index)", query: "q\(index)", now: now) }
        XCTAssertLessThanOrEqual(knowledge.uses.count, PaletteKnowledge.maxItems)
        XCTAssertLessThanOrEqual(knowledge.picks.count, PaletteKnowledge.maxQueries)
    }
}

final class OrphanedFilesTests: XCTestCase {
    func testBundleIDCandidatesStripExtensionsAndPrefixes() {
        XCTAssertEqual(CleanupTools.bundleIDCandidate(in: "com.foo.Bar.plist"), "com.foo.Bar")
        XCTAssertEqual(CleanupTools.bundleIDCandidate(in: "group.com.foo.shared"), "com.foo.shared")
        XCTAssertEqual(CleanupTools.bundleIDCandidate(in: "2BUA8C4S2C.com.agilebits"), nil, "two parts after the team prefix")
        XCTAssertEqual(CleanupTools.bundleIDCandidate(in: "2BUA8C4S2C.com.agilebits.onepassword"), "com.agilebits.onepassword")
        XCTAssertEqual(CleanupTools.bundleIDCandidate(in: "com.foo.app.savedState"), "com.foo.app")
        XCTAssertNil(CleanupTools.bundleIDCandidate(in: "Google"))
        XCTAssertNil(CleanupTools.bundleIDCandidate(in: "Notes.app"))
        XCTAssertNil(CleanupTools.bundleIDCandidate(in: "zz.foo.bar"), "not a known top-level domain")
        XCTAssertNil(CleanupTools.bundleIDCandidate(in: "com.foo..bar"))
    }

    func testHelpersOfAnInstalledAppAreKnown() {
        let installed: (String) -> Bool = { $0 == "com.tinyspeck.slackmacgap" }
        XCTAssertTrue(CleanupTools.isKnownBundleID("com.tinyspeck.slackmacgap.ShipIt", installed: installed))
        XCTAssertFalse(CleanupTools.isKnownBundleID("com.tinyspeck.other", installed: installed))
    }

    func testScanListsOnlyOldDataOfMissingApps() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("aom-orphans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let caches = library.appendingPathComponent("Caches"), prefs = library.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-40 * 86_400)
        func make(_ url: URL, modified: Date) throws {
            try Data(repeating: 1, count: 4096).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try make(caches.appendingPathComponent("com.gone.App"), modified: old)
        try make(prefs.appendingPathComponent("com.gone.App.plist"), modified: old)
        try make(prefs.appendingPathComponent("com.here.App.plist"), modified: old)
        try make(prefs.appendingPathComponent("com.apple.finder.plist"), modified: old)
        try make(prefs.appendingPathComponent("com.fresh.App.plist"), modified: Date())
        let found = CleanupTools.orphanedFiles(library: library, installed: { $0 == "com.here.App" })
        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), ["com.gone.App", "com.gone.App.plist"])
        XCTAssertTrue(found.allSatisfy { $0.note == "com.gone.App" }, "grouped by the app's ID")
        XCTAssertTrue(CleanupTools.orphanHint(for: found[0].url).contains("unchanged for 40 days"))
    }

    func testLaunchAgentsCountOnlyWhenTheirProgramIsGone() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("aom-agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let agents = library.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-90 * 86_400)
        func agent(_ name: String, program: String) throws {
            let url = agents.appendingPathComponent(name)
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": name, "ProgramArguments": [program, "--run"]],
                                                          format: .xml, options: 0)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        try agent("com.user.sync-job.plist", program: "/bin/sh")
        try agent("com.gone.updater.plist", program: "/Applications/Gone.app/Contents/MacOS/updater")
        let found = CleanupTools.orphanedFiles(library: library, installed: { _ in false })
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["com.gone.updater.plist"],
                       "a script agent whose program exists stays, even though no app has its label")
    }

    func testRemovedAppsIsAFreeUpSpaceScan() {
        XCTAssertTrue(SystemToolsModel.CleanupScan.allCases.contains(.orphans))
        XCTAssertTrue(SystemToolCatalog.info(.freeUpSpace).matches("orphaned"))
    }
}

final class KeepAwakeRulesTests: XCTestCase {
    func testExternalDisplayRule() {
        XCTAssertTrue(KeepAwakeRules.wantsDisplayAssertion(enabled: true, builtInFlags: [true, false]))
        XCTAssertFalse(KeepAwakeRules.wantsDisplayAssertion(enabled: true, builtInFlags: [true]))
        XCTAssertFalse(KeepAwakeRules.wantsDisplayAssertion(enabled: false, builtInFlags: [true, false]))
        XCTAssertTrue(KeepAwakeRules.wantsDisplayAssertion(enabled: true, builtInFlags: [false]), "lid closed, external only")
    }

    func testBatteryFloor() {
        XCTAssertTrue(KeepAwakeRules.shouldStopForBattery(floor: 20, percent: 20, onBattery: true))
        XCTAssertFalse(KeepAwakeRules.shouldStopForBattery(floor: 20, percent: 21, onBattery: true))
        XCTAssertFalse(KeepAwakeRules.shouldStopForBattery(floor: 20, percent: 5, onBattery: false), "charging keeps it")
        XCTAssertFalse(KeepAwakeRules.shouldStopForBattery(floor: 0, percent: 5, onBattery: true), "floor off")
        XCTAssertFalse(KeepAwakeRules.shouldStopForBattery(floor: 20, percent: nil, onBattery: true), "no battery")
    }

    @MainActor
    func testRuleOriginIsClearedWhenTheAssertionGoes() {
        let service = KeepAwakeService()
        service.createAssertion = { minutes, display in .init(id: 7, minutes: minutes, keepDisplay: display, endsAt: nil) }
        service.releaseAssertion = { _ in }
        service.start(minutes: nil, keepDisplay: false, origin: .externalDisplay)
        XCTAssertEqual(service.origin, .externalDisplay)
        service.stop()
        XCTAssertEqual(service.origin, .manual)
        service.start(minutes: 15, keepDisplay: false)
        XCTAssertEqual(service.origin, .manual)
    }
}

final class MixerHiddenAppsTests: XCTestCase {
    private func app(_ id: String, _ name: String) -> AppAudioState {
        AppAudioState(pid: 1, name: name, bundleID: id, icon: nil, gain: 1, muted: false, tapped: false)
    }

    func testHiddenAppsLeaveTheListButSearchStillFindsThem() {
        let apps = [app("ru.keepcoder.Telegram", "Telegram"), app("com.spotify.client", "Spotify")]
        let browse = AppAudioMixerService.partitionHidden(apps, hidden: ["ru.keepcoder.Telegram"], query: "")
        XCTAssertEqual(browse.shown.map(\.name), ["Spotify"])
        XCTAssertEqual(browse.hidden.map(\.name), ["Telegram"])
        let search = AppAudioMixerService.partitionHidden(apps, hidden: ["ru.keepcoder.Telegram"], query: "tele")
        XCTAssertEqual(search.shown.map(\.name), ["Telegram"])
        XCTAssertTrue(search.hidden.isEmpty)
    }
}

final class StatusItemNameTests: XCTestCase {
    func testEveryMenuBarItemHasItsOwnAutosaveName() {
        XCTAssertEqual(Set(AOMStatusItemName.all).count, AOMStatusItemName.all.count)
        XCTAssertTrue(AOMStatusItemName.all.allSatisfy { $0.hasPrefix("com.kyw.allofmacos.status.") })
    }
}

@MainActor
final class TriggerSelectorActionTests: XCTestCase {
    func testEnableAndDisableTriggerActionsChangeTheNamedTriggers() {
        let state = AppState()
        let shortcut = KeyboardShortcut(keyCode: 0, modifiers: NSEvent.ModifierFlags([.command, .option, .control]))
        var a = Trigger(name: "Focus Mode", input: .keyboardShortcut(shortcut)); a.isEnabled = true
        var b = Trigger(name: "focus mode", input: .keyboardShortcut(shortcut)); b.isEnabled = true
        var c = Trigger(name: "Other", input: .keyboardShortcut(shortcut)); c.isEnabled = true
        state.currentPreset.triggers = [a, b, c]
        XCTAssertEqual(state.applyTriggerSelector("Focus Mode", enabled: false), 2, "names match case-insensitively")
        XCTAssertEqual(state.currentPreset.triggers.map(\.isEnabled), [false, false, true])
        XCTAssertEqual(state.applyTriggerSelector(c.id.uuidString, enabled: false), 1)
        XCTAssertEqual(state.applyTriggerSelector("Focus Mode", enabled: false), 0, "already off: nothing to save")
        XCTAssertNil(state.selectedTrigger, "an action never moves the editor's selection")
        a = state.currentPreset.triggers[0]; b = state.currentPreset.triggers[1]
        XCTAssertFalse(a.isEnabled || b.isEnabled)
    }
}
