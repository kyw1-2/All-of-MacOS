import AppKit
import XCTest
@testable import AllOfMacOS

/// AOM 7.2: the launcher's new screens (Oracle report 05 and the Codex 7.2
/// review) — pure parts only; the screens themselves were checked with
/// --aom-preview-palette-route snapshots (docs/design-7.2-launcher.md).
final class AOM72LauncherTests: XCTestCase {
    // MARK: Emoji

    private let sample: [PaletteEmoji] = [
        PaletteEmoji(glyph: "♥️", name: "hearts suit", localizedName: "하트 카드", keywords: []),
        PaletteEmoji(glyph: "😍", name: "smiling face with heart-eyes", localizedName: "하트 눈의 웃는 얼굴", keywords: ["반함"]),
        PaletteEmoji(glyph: "❤️", name: "red heart", localizedName: "빨간색 하트", keywords: ["하트", "사랑"]),
        PaletteEmoji(glyph: "💙", name: "blue heart", localizedName: "파란색 하트", keywords: []),
        PaletteEmoji(glyph: "🔥", name: "fire", localizedName: nil, keywords: ["불", "불꽃"]),
        PaletteEmoji(glyph: "🚒", name: "fire engine", localizedName: "소방차", keywords: []),
        PaletteEmoji(glyph: "🧯", name: "fire extinguisher", localizedName: "소화기", keywords: []),
    ]

    func testEmojiColonTriggerPutsTheNamedEmojiFirst() {
        XCTAssertEqual(PaletteEmojiIndex.matches(":fire", in: sample, limit: 3).map(\.glyph), ["🔥", "🚒", "🧯"])
        XCTAssertEqual(PaletteEmojiIndex.matches(":fire:", in: sample, limit: 1).first?.glyph, "🔥")
        // A whole word beats a prefix ("hearts"); favourites first, then shorter names.
        XCTAssertEqual(PaletteEmojiIndex.matches("heart", in: sample, limit: 4).map(\.glyph), ["❤️", "😍", "💙", "♥️"])
    }

    func testEmojiKoreanWordsAndNames() {
        XCTAssertEqual(PaletteEmojiIndex.matches("불", in: sample, limit: 1).first?.glyph, "🔥")
        XCTAssertEqual(PaletteEmojiIndex.matches("하트", in: sample, limit: 1).first?.glyph, "❤️")
        XCTAssertEqual(PaletteEmojiIndex.matches("소방", in: sample, limit: 1).first?.glyph, "🚒")
        XCTAssertTrue(PaletteEmojiIndex.matches("zzz", in: sample, limit: 5).isEmpty)
        XCTAssertTrue(PaletteEmojiIndex.matches(":", in: sample, limit: 5).isEmpty)
    }

    func testEmojiBrowsingAndRecents() {
        XCTAssertEqual(PaletteEmojiIndex.browsing(recent: ["🔥", "🔥"], in: sample).prefix(3).map(\.glyph), ["🔥", "😍", "❤️"])
        XCTAssertEqual(PaletteRecentEmoji.recorded("🔥", in: ["❤️", "🔥", "😍"]), ["🔥", "❤️", "😍"])
        XCTAssertEqual(PaletteRecentEmoji.recorded("x", in: (0..<20).map(String.init)).count, PaletteRecentEmoji.limit)
        XCTAssertEqual(sample[2].codePoints, "U+2764")
    }

    func testSystemEmojiNamesLoadWhenPresent() throws {
        let english = PaletteEmojiIndex.resources.appendingPathComponent("en.lproj/AppleName.strings")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: english.path), "CoreEmoji names are not on this Mac")
        let all = PaletteEmojiIndex.load(languages: ["en-KR", "ko-KR"])
        XCTAssertGreaterThan(all.count, 1_000)
        let fire = try XCTUnwrap(all.first { $0.glyph == "🔥" })
        XCTAssertEqual(fire.name, "fire")
        XCTAssertTrue(fire.keywords.contains("불"), "the Korean words are attached even where macOS has no Korean name")
        XCTAssertNotNil(all.first { $0.glyph == "❤️" }?.localizedName, "the second language (ko) is read after English")
    }

    func testEmojiFallsBackToUnicodeNames() {
        let fallback = PaletteEmojiIndex.unicodeFallback()
        XCTAssertTrue(fallback.contains { $0.glyph == "🔥" && $0.name == "fire" })
        XCTAssertTrue(PaletteEmojiIndex.load(resources: URL(fileURLWithPath: "/nonexistent")).contains { $0.glyph == "🚀" })
    }

    // MARK: Recent searches

    func testRecentQueriesDeduplicateLimitAndAge() {
        var recents = PaletteRecentQueries()
        let now = Date()
        recents.record("HomePod", now: now.addingTimeInterval(-10))
        recents.record("brew outdated", now: now.addingTimeInterval(-5))
        recents.record("homepod", now: now)
        XCTAssertEqual(recents.recent(limit: 5, now: now).map(\.text), ["homepod", "brew outdated"])
        for index in 0..<40 { recents.record("query \(index)", now: now) }
        XCTAssertEqual(recents.entries.count, PaletteRecentQueries.limit)
        recents.record("old one", now: now.addingTimeInterval(-8 * 24 * 3600))
        XCTAssertFalse(recents.recent(limit: 50, now: now).contains { $0.text == "old one" }, "a week later it is gone")
        recents.remove("QUERY 39")
        XCTAssertFalse(recents.entries.contains { $0.text == "query 39" })
        recents.clear()
        XCTAssertTrue(recents.entries.isEmpty)
    }

    func testRecentQueriesSkipSecretsAndKeywords() {
        XCTAssertFalse(PaletteRecentQueries.isRecordable("g"))
        XCTAssertFalse(PaletteRecentQueries.isRecordable("sk-abcdefghijklmnopqrstuvwx"))
        XCTAssertFalse(PaletteRecentQueries.isRecordable("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        XCTAssertFalse(PaletteRecentQueries.isRecordable(String(repeating: "a", count: 121)))
        XCTAssertTrue(PaletteRecentQueries.isRecordable("환율 1 usd"))
    }

    // MARK: Hotkeys

    func testHotkeyRulesKeepTypingSafe() {
        XCTAssertNotNil(PaletteHotkeyRules.problem(with: KeyboardShortcut(keyCode: 0, modifiers: [])), "a bare letter types")
        XCTAssertNotNil(PaletteHotkeyRules.problem(with: KeyboardShortcut(keyCode: 0, modifiers: [.shift])), "⇧A is a capital A")
        XCTAssertNotNil(PaletteHotkeyRules.problem(with: KeyboardShortcut(keyCode: 12, modifiers: [.command])), "⌘Q quits")
        XCTAssertNotNil(PaletteHotkeyRules.problem(with: KeyboardShortcut(keyCode: 55, modifiers: [.command])), "a modifier alone")
        XCTAssertNil(PaletteHotkeyRules.problem(with: KeyboardShortcut(keyCode: 40, modifiers: [.option, .command])))
        XCTAssertNil(PaletteHotkeyRules.problem(with: KeyboardShortcut(keyCode: 96, modifiers: [])), "F5 alone")
        XCTAssertEqual(PaletteHotkeyRules.carbonModifiers([.command, .option]), UInt32(256 | 2048))
        XCTAssertTrue(PaletteHotkeyRules.same(KeyboardShortcut(keyCode: 49, modifiers: [.option]),
                                              KeyboardShortcut(keyCode: 49, modifiers: [.option, .function])))
    }

    @MainActor
    func testHotkeyStoreRefusesTakenKeysAndPersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AOM72HotkeyTests-\(UUID().uuidString)"))
        let store = PaletteHotkeyStore(defaults: defaults)
        let key = KeyboardShortcut(keyCode: 40, modifiers: [.option, .command, .control])
        try store.set(key, for: "capture.area", title: "Capture Area")
        XCTAssertEqual(store.binding(for: "capture.area")?.display, key.displayString)
        XCTAssertThrowsError(try store.set(key, for: "window.left", title: "Tile Window Left Half")) { error in
            XCTAssertEqual(error as? PaletteHotkeyStore.Failure, .taken("“Capture Area”"))
        }
        if let launcher = PaletteHotkeyRules.launcherShortcut() {
            XCTAssertThrowsError(try store.set(launcher, for: "window.left", title: "Left"))
        }
        let automation = Trigger(name: "Mine", input: .keyboardShortcut(KeyboardShortcut(keyCode: 3, modifiers: [.control, .option])))
        XCTAssertEqual(store.owner(of: KeyboardShortcut(keyCode: 3, modifiers: [.control, .option]), triggers: [automation]),
                       "the automation “\(automation.displayName)”")
        // Reloaded from the same defaults.
        XCTAssertEqual(PaletteHotkeyStore(defaults: defaults).bindings.map(\.itemID), ["capture.area"])
        store.remove("capture.area")
        XCTAssertNil(store.binding(for: "capture.area"))
    }

    // MARK: Script commands

    func testScriptMetadataRaycastAndAOM() throws {
        let raycast = """
        #!/bin/bash
        # @raycast.schemaVersion 1
        # @raycast.title Open Downloads
        # @raycast.mode fullOutput
        # @raycast.icon 📂
        # @raycast.packageName Files
        # @raycast.argument1 { "type": "text", "placeholder": "Subfolder", "optional": true }
        open ~/Downloads
        """
        let script = try XCTUnwrap(PaletteScript.parse(raycast, url: URL(fileURLWithPath: "/tmp/open.sh")))
        XCTAssertEqual(script.title, "Open Downloads")
        XCTAssertEqual(script.mode, .fullOutput)
        XCTAssertEqual(script.icon, "📂")
        XCTAssertEqual(script.packageName, "Files")
        XCTAssertEqual(script.argument, PaletteScript.Argument(placeholder: "Subfolder", optional: true, secure: false))
        let aom = "// @aom.title Say Hi\n// @aom.needsConfirmation true\nconsole.log('hi')"
        let mine = try XCTUnwrap(PaletteScript.parse(aom, url: URL(fileURLWithPath: "/tmp/hi.js")))
        XCTAssertEqual(mine.title, "Say Hi")
        XCTAssertEqual(mine.mode, .compact)
        XCTAssertTrue(mine.needsConfirmation)
        XCTAssertNil(PaletteScript.parse("#!/bin/sh\necho no title", url: URL(fileURLWithPath: "/tmp/x.sh")))
    }

    func testScriptInvocation() {
        let url = URL(fileURLWithPath: "/tmp/a.py")
        XCTAssertEqual(PaletteScripts.invocation(for: url, firstLine: "#!/usr/bin/env python3", isExecutable: true).executable, url)
        let env = PaletteScripts.invocation(for: url, firstLine: "#!/usr/bin/env python3", isExecutable: false)
        XCTAssertEqual(env.executable.path, "/usr/bin/env")
        XCTAssertEqual(env.arguments, ["python3", "/tmp/a.py"])
        XCTAssertEqual(PaletteScripts.invocation(for: url, firstLine: "echo hi", isExecutable: false).executable.path, "/bin/zsh")
        XCTAssertEqual(PaletteScripts.Outcome(status: 0, output: "a\nb\n\n", timedOut: false, cancelled: false).lastLine, "b")
    }

    func testScriptScanReadsOnlyTitledScripts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM72Scripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "#!/bin/sh\n# @aom.title Beta\necho b".write(to: folder.appendingPathComponent("b.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n# @raycast.title Alpha\necho a".write(to: folder.appendingPathComponent("a.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho untitled".write(to: folder.appendingPathComponent("c.sh"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PaletteScripts.scan(folder).map(\.title), ["Alpha", "Beta"])
        let script = try XCTUnwrap(PaletteScripts.scan(folder).first)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AOM72ScriptTrust-\(UUID().uuidString)"))
        XCTAssertFalse(PaletteScripts.isTrusted(script, defaults: defaults))
        PaletteScripts.trust(script, defaults: defaults)
        XCTAssertTrue(PaletteScripts.isTrusted(script, defaults: defaults))
        try "#!/bin/sh\n# @raycast.title Alpha\necho changed".write(to: script.url, atomically: true, encoding: .utf8)
        XCTAssertFalse(PaletteScripts.isTrusted(script, defaults: defaults), "an edited script asks again")
    }

    // MARK: Snippets

    func testSnippetsComeFromTypedStrings() {
        let snippet = PaletteSnippets.trigger(abbreviation: " ;sig ", text: "Best regards,\nYongwoo")
        let actionOnly = Trigger(name: "Run", input: .typedString(TypedStringSpec(abbreviation: ";run", replacement: "")))
        let other = Trigger(name: "Key", input: .keyboardShortcut(KeyboardShortcut(keyCode: 1, modifiers: [.command])))
        let list = PaletteSnippets.snippets(in: [other, actionOnly, snippet])
        XCTAssertEqual(list.map(\.abbreviation), [";sig"])
        XCTAssertEqual(list.first?.name, "Best regards,")
        XCTAssertEqual(PaletteSnippets.problem(with: ";sig", existing: [snippet]), "“;sig” is already a typed string")
        XCTAssertNotNil(PaletteSnippets.problem(with: "a", existing: []))
        XCTAssertNotNil(PaletteSnippets.problem(with: "two words", existing: []))
        XCTAssertNil(PaletteSnippets.problem(with: ";addr", existing: [snippet]))
    }

    // MARK: Calendar and contacts

    func testMeetingLinksAndTiming() {
        XCTAssertEqual(PaletteSchedule.meetingLink(in: [nil, "Join: https://us02web.zoom.us/j/123?pwd=x"])?.host, "us02web.zoom.us")
        XCTAssertEqual(PaletteSchedule.meetingLink(in: ["https://meet.google.com/abc-defg-hij"])?.host, "meet.google.com")
        XCTAssertNil(PaletteSchedule.meetingLink(in: ["https://example.com/zoom.us"]))
        let now = Date()
        func event(_ start: TimeInterval, _ end: TimeInterval, allDay: Bool = false) -> PaletteSchedule.Event {
            .init(id: "e", title: "T", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), isAllDay: allDay,
                  calendar: "Work", location: nil, meetingLink: nil)
        }
        XCTAssertTrue(PaletteSchedule.timing(of: event(-60, 600), now: now).hasPrefix("Now"))
        XCTAssertEqual(PaletteSchedule.timing(of: event(0, 3600, allDay: true), now: now), "All day")
        let soon = PaletteSchedule.timing(of: event(25 * 60, 50 * 60), now: now)
        XCTAssertTrue(soon == "in 25 min" || soon.contains("–"), soon)
        XCTAssertEqual(PaletteSchedule.dayTitle(now, now: now), "Today")
        XCTAssertEqual(PaletteSchedule.dayTitle(now.addingTimeInterval(86_400), now: now), "Tomorrow")
    }

    func testContactMatching() {
        let people = PaletteContacts.samples
        XCTAssertEqual(PaletteContacts.matching("min", in: people, limit: 3).first?.name, "Minji Park")
        XCTAssertEqual(PaletteContacts.matching("kim", in: people, limit: 3).first?.name, "Daniel Kim")
        XCTAssertEqual(PaletteContacts.matching("korea univ", in: people, limit: 3).first?.name, "Seoyeon Lee")
        XCTAssertEqual(PaletteContacts.matching("3290", in: people, limit: 3).first?.name, "Seoyeon Lee")
        XCTAssertEqual(PaletteContacts.matching("", in: people, limit: 2).count, 2)
    }

    // MARK: Launcher plumbing

    func testQuickRunDigitsAndRoutes() {
        XCTAssertEqual((0..<10).compactMap { QuickCommandPalette.quickRunDigit([18, 19, 20, 21, 23, 22, 26, 28, 25, 29][$0]) },
                       [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertTrue(PaletteRoute.emoji.allowsQuickRun)
        XCTAssertTrue(PaletteRoute.tool(.files("x")).allowsQuickRun)
        XCTAssertFalse(PaletteRoute.killApps.allowsQuickRun, "⌘1 never quits an app")
        XCTAssertFalse(PaletteRoute.tool(.brew(.installed, "")).allowsQuickRun, "⌘1 never uninstalls")
        XCTAssertFalse(PaletteRoute.confirm.allowsQuickRun)
        XCTAssertFalse(PaletteRoute.hotkey(itemID: "a", title: "A").isSearchable)
        XCTAssertTrue(LauncherTool.brew(.search, "").takesQuery)
        XCTAssertFalse(LauncherTool.network.takesQuery)
    }

    func testOnlyCommandLikeRowsGetHotkeys() {
        func item(_ id: String, _ section: QuickCommandPalette.Section) -> QuickCommandPalette.PaletteItem {
            .init(id: id, title: id, subtitle: "", icon: "x", section: section, primary: .init(title: "Run") {})
        }
        XCTAssertTrue(QuickCommandPalette.canHaveHotkey(item("capture.area", .commands)))
        XCTAssertTrue(QuickCommandPalette.canHaveHotkey(item("app./Applications/Safari.app", .applications)))
        XCTAssertFalse(QuickCommandPalette.canHaveHotkey(item("clipboard.x", .clipboard)))
        XCTAssertFalse(QuickCommandPalette.canHaveHotkey(item("files.recent.x", .recentFiles)))
        var fallback = item("fallback.ai", .fallback)
        fallback.placement = .fallback
        XCTAssertFalse(QuickCommandPalette.canHaveHotkey(fallback))
    }

    func testFolderBrowsingListsFoldersFirst() {
        let items = [PaletteFileHit(url: URL(fileURLWithPath: "/a/zeta.txt"), date: nil, isFolder: false),
                     PaletteFileHit(url: URL(fileURLWithPath: "/a/Beta"), date: nil, isFolder: true),
                     PaletteFileHit(url: URL(fileURLWithPath: "/a/alpha.txt"), date: nil, isFolder: false),
                     PaletteFileHit(url: URL(fileURLWithPath: "/a/file10"), date: nil, isFolder: false),
                     PaletteFileHit(url: URL(fileURLWithPath: "/a/file9"), date: nil, isFolder: false)]
        XCTAssertEqual(PaletteLauncherData.sortedForBrowsing(items).map(\.name), ["Beta", "alpha.txt", "file9", "file10", "zeta.txt"])
        XCTAssertNotNil(PaletteLauncherData.listing(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).error)
    }

    func testDensitySteps() {
        let saved = AOMLauncherDensity.current
        defer { AOMLauncherDensity.current = saved }
        AOMLauncherDensity.current = .regular
        AOMLauncherDensity.step(-1)
        XCTAssertEqual(AOMLauncherDensity.current, .compact)
        AOMLauncherDensity.step(-1)
        XCTAssertEqual(AOMLauncherDensity.current, .compact, "stops at the end")
        AOMLauncherDensity.step(1); AOMLauncherDensity.step(1); AOMLauncherDensity.step(1)
        XCTAssertEqual(AOMLauncherDensity.current, .spacious)
        XCTAssertEqual(AOMLauncherDensity.spacious.rowHeight, 52)
    }
}
