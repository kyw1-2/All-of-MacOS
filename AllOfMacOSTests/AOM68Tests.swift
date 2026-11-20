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
