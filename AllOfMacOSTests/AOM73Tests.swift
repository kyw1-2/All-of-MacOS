import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.3: the Codex 7.2.3 report (file safety, Ask AI's record scope, the
/// launcher folder, efficiency) and the DeepSeek v2 design (snippet
/// placeholders, module switches, the input source badge, the shelf,
/// scenes). Each case below is one the reports reproduced or asked for.
final class AOM73Tests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AOM73-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    private func touch(_ name: String, in directory: URL? = nil, _ text: String = "x") throws -> URL {
        let url = (directory ?? folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) }

    // MARK: P0 — Batch Rename Undo checks the file

    func testRenameUndoLeavesAFileThatTookTheNewName() throws {
        let a = try touch("a.txt", "original")
        let done = try BatchRename.apply(BatchRename.plan([a], find: "", template: "{name}-new"))
        let renamed = folder.appendingPathComponent("a-new.txt")
        XCTAssertNotNil(done.moves.first?.identity)
        // The Codex steps: the renamed file is put away and a new one takes its name.
        try FileManager.default.moveItem(at: renamed, to: folder.appendingPathComponent("kept.txt"))
        try "someone else's".write(to: renamed, atomically: false, encoding: .utf8)
        let back = BatchRename.undoResult(done)
        XCTAssertTrue(back.done.isEmpty, "7.2.3 renamed the new file back to a.txt")
        XCTAssertTrue(back.failures.first?.reason.contains("different file") == true, "\(back.failures)")
        XCTAssertEqual(text(renamed), "someone else's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(BatchRename.undo(done), 1)
    }

    func testRenameUndoStillWorksAfterAnEditInPlaceAndRefusesATakenName() throws {
        let a = try touch("a.txt", "original"), b = try touch("b.txt", "b")
        let done = try BatchRename.apply(BatchRename.plan([a, b], find: "", template: "{name}-x"))
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("a-x.txt"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" + edit".utf8)); try handle.close()
        try touch("b.txt", "a new b")   // b's old name is taken again
        let back = BatchRename.undoResult(done)
        XCTAssertEqual(back.done.count, 1)
        XCTAssertEqual(text(a), "original + edit", "the same file (an edit in place) goes back")
        XCTAssertEqual(back.failures.count, 1)
        XCTAssertTrue(back.failures[0].reason.contains("b.txt"), back.failures[0].reason)
        XCTAssertEqual(text(folder.appendingPathComponent("b.txt")), "a new b")
    }

    func testExclusiveMoveNeverReplacesAFile() throws {
        let a = try touch("a.txt", "a"), b = try touch("b.txt", "b")
        XCTAssertThrowsError(try BatchRename.exclusiveMove(a, b))
        XCTAssertEqual(text(b), "b")
        XCTAssertEqual(text(a), "a")
    }

    func testRenamePreviewMakesNoDateUnlessAsked() {
        var asked = 0
        let plain = BatchRename.expand("{name}-{n}", name: "x", number: 3, dateText: { asked += 1; return "d" })
        XCTAssertEqual(plain, "x-3")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(BatchRename.expand("{date} {nn}", name: "x", number: 3, dateText: { asked += 1; return "2026-11-21" }), "2026-11-21 03")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(BatchRename.dateString(Date(timeIntervalSince1970: 1_795_000_000), calendar: calendar), "2026-11-18")
        let urls = (0..<50).map { folder.appendingPathComponent("f\($0).txt") }
        let rows = BatchRename.plan(urls, find: "", template: "{date}-{n}", exists: { _ in false })
        XCTAssertEqual(Set(rows.map { String($0.newName.prefix(10)) }).count, 1, "one date for the whole set")
    }

    // MARK: P0 — conversions never overwrite

    func testPNGConversionKeepsAnExistingFileAndBothResults() throws {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill(); image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let source = folder.appendingPathComponent("Photo.tiff")
        try tiff.write(to: source)
        let existing = folder.appendingPathComponent("Photo-png.png")
        try Data("keep me".utf8).write(to: existing)
        let first = try MacMagicSystemToolService.shared.convertImage(url: source, to: .png)
        let second = try MacMagicSystemToolService.shared.convertImage(url: source, to: .png)
        XCTAssertEqual(text(existing), "keep me", "7.2.3 replaced it with the PNG")
        XCTAssertEqual(first.lastPathComponent, "Photo-png 2.png")
        XCTAssertEqual(second.lastPathComponent, "Photo-png 3.png")
        XCTAssertFalse(try names().contains { $0.hasPrefix(".aom-convert-") }, "no temporary file is left")
    }

    // MARK: P0 — unreadable shelf and chats are kept

    @MainActor
    func testUnreadableShelfAndChatsAreSetAside() throws {
        let shelfURL = try touch("shelf.json", "{ not json")
        let store = FilesShelfStore(fileURL: shelfURL)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.problem?.blocksSaving, false)
        XCTAssertTrue(try names().contains { $0.hasPrefix("shelf.unreadable-") }, "the damaged copy is kept")
        let chatsURL = try touch("chats.json", "[{\"broken\"")
        let history = AOMAIChatHistory(url: chatsURL)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertNotNil(history.problem)
        XCTAssertTrue(try names().contains { $0.hasPrefix("chats.unreadable-") })
    }

    // MARK: P0 — Ask AI reads only what a question names

    func testMentionsMakeTheScopeAndLeaveOtherWordsAlone() throws {
        let projects = folder.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let parsed = AOMAIRecordScope.parse("@wiki how do I reach oracle? mail me@example.com @files:\(projects.path)", home: folder)
        XCTAssertEqual(parsed.scope.sources, [.wiki, .files])
        XCTAssertEqual(parsed.scope.folders, [projects.standardizedFileURL.path])
        XCTAssertEqual(parsed.question, "how do I reach oracle? mail me@example.com")
        XCTAssertEqual(AOMAIRecordScope.parse("@mac setup", home: folder).scope.sources, Set(AOMAIRecordSource.mac))
        XCTAssertTrue(AOMAIRecordScope.parse("no mentions", home: folder).scope.isEmpty)
        XCTAssertEqual(AOMAIRecordScope.parse("@someone hi", home: folder).unknown, ["@someone"])
    }

    func testNoScopeMeansNoToolsAndMergedToolsAreUnique() {
        XCTAssertTrue(AOMAILocalTools.tools(for: .none).isEmpty)
        XCTAssertTrue(AOMAILocalTools.promptLines(for: .none).isEmpty)
        let scope = AOMAIRecordScope(sources: [.wiki, .memories, .docs, .clip])
        let tools = AOMAILocalTools.tools(for: scope)
        XCTAssertEqual(tools.map(\.name), ["search_records", "read_file"], "@mac + @wiki: one search_records")
        let schema = AOMAILocalTools.anthropicSchemas(tools)
        let sources = ((schema[0]["input_schema"] as? [String: Any])?["properties"] as? [String: Any])?["sources"] as? [String: Any]
        XCTAssertEqual((sources?["items"] as? [String: Any])?["enum"] as? [String], ["wiki", "memories", "agent_docs"])
        let withFolder = AOMAIRecordScope(sources: [.files], folders: [folder.path])
        XCTAssertEqual(AOMAILocalTools.tools(for: withFolder).map(\.name), ["read_file", "list_directory", "find_files"])
    }

    func testTheExecutorChecksEveryCallAgainstTheScope() throws {
        try touch(".agents/llm-wiki/Oracle.md", "ssh oracle over wss")
        try touch(".ssh/config", "Host oracle")
        try touch(".ssh/id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----")
        try touch("Documents/private.txt", "secret plans")
        let wiki = AOMAIRecordScope(sources: [.wiki])
        let notAllowed = AOMAILocalTools.runNow("list_directory", arguments: ["path": "~"], scope: wiki, home: folder)
        XCTAssertTrue(notAllowed.isError && notAllowed.text.contains("isn't allowed"))
        let disjoint = AOMAILocalTools.runNow("search_records", arguments: ["query": "oracle", "sources": ["shell_history"]], scope: wiki, home: folder)
        XCTAssertTrue(disjoint.isError, "a source outside the scope is refused, never widened to all")
        let found = AOMAILocalTools.runNow("search_records", arguments: ["query": "oracle"], scope: wiki, home: folder)
        XCTAssertFalse(found.isError)
        XCTAssertTrue(found.text.contains("Oracle.md"), found.text)
        XCTAssertFalse(found.text.contains(".ssh/config"), "7.2.3 searched the SSH config with every search")
        XCTAssertEqual(found.used, ["LLM Wiki"])
        let outside = AOMAILocalTools.runNow("read_file", arguments: ["path": "~/Documents/private.txt"], scope: wiki, home: folder)
        XCTAssertTrue(outside.isError && outside.summary.contains("outside the scope"))
        let ssh = AOMAIRecordScope(sources: [.ssh])
        XCTAssertFalse(AOMAILocalTools.runNow("read_file", arguments: ["path": "~/.ssh/config"], scope: ssh, home: folder).isError)
        let key = AOMAILocalTools.runNow("read_file", arguments: ["path": "~/.ssh/id_ed25519"], scope: ssh, home: folder)
        XCTAssertTrue(key.isError)
        XCTAssertFalse(key.text.contains("PRIVATE KEY"))
        XCTAssertFalse(AOMAILocalTools.files(of: .agent_docs, home: folder).contains { $0.path.contains(".ssh") })
    }

    func testWhereAQuestionGoes() {
        XCTAssertEqual(AOMAIProvider.localProxy.egress(model: "claude-haiku-5-5", baseURL: "http://127.0.0.1:8082"), .loopbackProxy(host: "127.0.0.1"))
        XCTAssertTrue(AOMAIEgress.loopbackProxy(host: "127.0.0.1").leavesMac, "the proxy's Haiku route goes to DeepSeek")
        XCTAssertEqual(AOMAIProvider.ollama.egress(model: "llama3.2", baseURL: "http://127.0.0.1:11434/v1"), .onDevice)
        XCTAssertTrue(AOMAIProvider.ollama.egress(model: "gpt-oss:120b-cloud", baseURL: "http://127.0.0.1:11434/v1").leavesMac)
        XCTAssertTrue(AOMAIProvider.ollama.egress(model: "llama3.2", baseURL: "http://192.168.0.5:11434/v1").leavesMac)
        XCTAssertEqual(AOMAIProvider.apple.egress(model: "", baseURL: ""), .onDevice)
        let mac = AOMAIRecordsMode.effective(.none, egress: .onDevice, mode: .mentions, onDeviceReadsMac: true)
        XCTAssertEqual(mac.sources, Set(AOMAIRecordSource.mac))
        XCTAssertTrue(AOMAIRecordsMode.effective(.none, egress: .loopbackProxy(host: "127.0.0.1"), mode: .mentions, onDeviceReadsMac: true).isEmpty)
        XCTAssertEqual(AOMAIRecordsMode.effective(AOMAIRecordScope(sources: [.wiki, .clip]), egress: .external(host: "x"), mode: .never, onDeviceReadsMac: false).sources, [.clip])
    }

    func testReceiptLine() {
        var receipt = AOMAIReceipt(destination: "Sent to api.deepseek.com", leavesMac: true, allowed: "LLM Wiki")
        XCTAssertEqual(receipt.line, "Sent to api.deepseek.com · Allowed: LLM Wiki · Nothing read")
        receipt.used = ["LLM Wiki ×2"]
        receipt.earlierTurns = 3
        XCTAssertEqual(receipt.line, "Sent to api.deepseek.com · Allowed: LLM Wiki · Used: LLM Wiki ×2 · 3 earlier turns sent")
    }

    func testRecordsSwitchTurnedOffIn72StaysOff() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: AOMAIRecordsMode.key), defaults.object(forKey: AOMAILocalTools.enabledKey))
        defer {
            defaults.set(saved.0, forKey: AOMAIRecordsMode.key)
            defaults.set(saved.1, forKey: AOMAILocalTools.enabledKey)
        }
        defaults.removeObject(forKey: AOMAIRecordsMode.key)
        defaults.set(false, forKey: AOMAILocalTools.enabledKey)
        XCTAssertEqual(AOMAIRecordsMode.current, .never)
        defaults.removeObject(forKey: AOMAILocalTools.enabledKey)
        XCTAssertEqual(AOMAIRecordsMode.current, .mentions)
    }

    func testSpotlightResultsKeepTheNewest() {
        let newest = NewestPaths(limit: 2)
        let old = try! touch("old.txt"), mid = try! touch("mid.txt"), new = try! touch("new.txt")
        for (url, age) in [(old, 300.0), (mid, 200.0), (new, 10.0)] {
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        [old.path, new.path, mid.path].forEach(newest.add)
        let snapshot = newest.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot.newest.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["new.txt", "mid.txt"])
    }

    func testProxyAnswerMustBeTheRouters() {
        XCTAssertTrue(AOMLocalProxy.isRouterAnswer(path: "/health", data: Data(#"{"status":"healthy","hybrid_mode":true}"#.utf8)))
        XCTAssertFalse(AOMLocalProxy.isRouterAnswer(path: "/health", data: Data("OK".utf8)))
        XCTAssertTrue(AOMLocalProxy.isRouterAnswer(path: "/", data: Data(#"{"message":"Claude-to-DeepSeek Hybrid API Proxy v2.0.0","status":"running","endpoints":{"messages":"/v1/messages"}}"#.utf8)))
        XCTAssertFalse(AOMLocalProxy.isRouterAnswer(path: "/", data: Data(#"{"name":"some other server"}"#.utf8)), "Codex B23: any 200 counted")
    }

    // MARK: P1 — the launcher reads a whole folder

    func testFolderListingKeepsEveryFileSorted() throws {
        let big = folder.appendingPathComponent("Big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for index in 0..<2_401 { FileManager.default.createFile(atPath: big.appendingPathComponent(String(format: "file-%04d.txt", index)).path, contents: nil) }
        try FileManager.default.createDirectory(at: big.appendingPathComponent("zzz folder"), withIntermediateDirectories: true)
        let listed = PaletteLauncherData.listing(of: big)
        XCTAssertNil(listed.error)
        XCTAssertEqual(listed.items.count, 2_402, "7.2.3 kept 2,000")
        XCTAssertEqual(listed.items.first?.name, "zzz folder", "folders first")
        XCTAssertEqual(PaletteLauncherData.folderMatches(listed.items, query: "file-2400").map(\.name), ["file-2400.txt"])
        XCTAssertNotNil(PaletteLauncherData.listing(of: folder.appendingPathComponent("gone")).error)
    }

    // MARK: P1 — input source badge

    func testBadgeGlyphsDuplicatesAndPlacement() {
        XCTAssertEqual(InputSourceBadgeLogic.glyph(id: "com.apple.inputmethod.Korean.2SetKorean", name: "2-Set Korean"), "한")
        XCTAssertEqual(InputSourceBadgeLogic.glyph(id: "com.apple.keylayout.ABC", name: "ABC"), "A")
        XCTAssertEqual(InputSourceBadgeLogic.glyph(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", name: "Hiragana"), "あ")
        let now = Date()
        XCTAssertTrue(InputSourceBadgeLogic.isDuplicate("ko", last: ("ko", now.addingTimeInterval(-0.1)), now: now))
        XCTAssertFalse(InputSourceBadgeLogic.isDuplicate("ko", last: ("en", now.addingTimeInterval(-0.05)), now: now), "한 → A → 한 shows each")
        XCTAssertFalse(InputSourceBadgeLogic.isDuplicate("ko", last: ("ko", now.addingTimeInterval(-0.5)), now: now))
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let caret = InputSourceBadgeLogic.frame(size: CGSize(width: 34, height: 30), anchor: CGRect(x: 990, y: 400, width: 1, height: 16),
                                                isCaret: true, screens: [screen])
        XCTAssertLessThanOrEqual(caret.maxX, screen.maxX, "flipped to the caret's left at the edge")
        XCTAssertLessThan(caret.minX, 990)
        let pointer = InputSourceBadgeLogic.frame(size: CGSize(width: 34, height: 30), anchor: CGRect(x: 500, y: 5, width: 0, height: 0),
                                                  isCaret: false, screens: [screen])
        XCTAssertGreaterThanOrEqual(pointer.minY, screen.minY)
    }

    @MainActor
    func testOneObserverServesEveryListener() {
        let hub = InputSourceChangeHub()
        var a = 0, b = 0
        let first = hub.subscribe { a += 1 }
        let second = hub.subscribe { b += 1 }
        XCTAssertTrue(hub.isObserving)
        hub.post()
        XCTAssertEqual([a, b], [1, 1])
        hub.unsubscribe(first)
        XCTAssertTrue(hub.isObserving)
        hub.unsubscribe(second)
        XCTAssertFalse(hub.isObserving, "nothing observes when nobody listens")
    }

    // MARK: P1 — snippet placeholders

    func testTemplateTokensAndMistakes() {
        guard case .success(let tokens) = SnippetTemplate.parse("Hi {arg:name}, {{x}} on {date:yyyy.MM.dd}{cursor}!") else { return XCTFail() }
        XCTAssertEqual(tokens, [.text("Hi "), .arg("name"), .text(", {x} on "), .date("yyyy.MM.dd"), .cursor, .text("!")])
        XCTAssertEqual(SnippetTemplate.argumentNames(tokens), ["name"])
        guard case .failure(let unknown) = SnippetTemplate.parse("ab {nope}") else { return XCTFail() }
        XCTAssertEqual(unknown.offset, 3)
        guard case .failure(let open) = SnippetTemplate.parse("x {date") else { return XCTFail() }
        XCTAssertEqual(open.offset, 2)
        guard case .failure(let twice) = SnippetTemplate.parse("{cursor}{cursor}") else { return XCTFail() }
        XCTAssertEqual(twice.offset, 8)
        XCTAssertFalse(SnippetTemplate.hasPlaceholders("if (a) { b }") , "braces in code aren't placeholders")
    }

    func testRenderingAndTheWayItIsInserted() {
        var context = SnippetTemplate.Context()
        context.now = Date(timeIntervalSince1970: 1_795_000_000)
        context.timeZone = TimeZone(identifier: "Asia/Seoul")!
        context.clipboard = { "copied" }
        context.arguments = ["who": "Kim"]
        guard case .success(let tokens) = SnippetTemplate.parse("{date} {arg:who}: {clipboard}{cursor} end") else { return XCTFail() }
        let render = SnippetTemplate.render(tokens, context: context)
        XCTAssertEqual(render.text, "2026-11-18 Kim: copied end")
        XCTAssertEqual(render.charactersAfterCursor, 4)
        XCTAssertEqual(render.cursorUTF16, 22)
        XCTAssertEqual(SnippetTemplate.route(for: render), .typeWithCaret(4))
        XCTAssertEqual(SnippetTemplate.route(for: SnippetRender(text: "short")), .type)
        XCTAssertEqual(SnippetTemplate.route(for: SnippetRender(text: String(repeating: "x", count: 80))), .paste)
        XCTAssertEqual(SnippetTemplate.route(for: SnippetRender(text: "a\nb", charactersAfterCursor: 1, cursorUTF16: 2)), .paste)
        XCTAssertEqual(SnippetTemplate.route(for: SnippetRender(text: String(repeating: "x", count: 80)), canRestoreClipboard: false), .type,
                       "a clipboard that can't be put back is never pasted over")
        context.clipboard = { "sk-abcdefghijklmnopqrstuvwxyz123456" }
        let secret = SnippetTemplate.render([.clipboard], context: context)
        XCTAssertEqual(secret.text, "")
        XCTAssertFalse(secret.notes.isEmpty)
        guard case .success(let literal) = SnippetTemplate.render(text: "{date} stays", syntax: nil) else { return XCTFail() }
        XCTAssertEqual(literal.text, "{date} stays", "snippets saved before 7.3 type literally")
    }

    func testSpecWithoutSyntaxDecodesAsLiteral() throws {
        let old = try JSONDecoder().decode(TypedStringSpec.self, from: Data(#"{"abbreviation":";d","replacement":"{date}"}"#.utf8))
        XCTAssertFalse(old.usesPlaceholders)
        let new = TypedStringSpec(abbreviation: ";d", replacement: "{date}", syntax: SnippetTemplate.currentSyntax)
        XCTAssertTrue(try JSONDecoder().decode(TypedStringSpec.self, from: JSONEncoder().encode(new)).usesPlaceholders)
        XCTAssertEqual(PaletteSnippets.preview(text: "Dear {arg:name}{cursor},", syntax: 2), "Dear ‹name›▏,")
    }

    @MainActor
    func testTypedStringsStillMatchWithThePreparedList() {
        let engine = TypedStringEngine()
        let trigger = Trigger(name: "sig", input: .typedString(TypedStringSpec(abbreviation: ";SIG", replacement: "Kim")))
        let generation = UUID()
        var match: TypedStringEngine.Match?
        for character in ";sig" {
            match = engine.observe(text: String(character), bundleID: "x", registered: [trigger], activationGroups: [], generation: generation)
        }
        XCTAssertEqual(match?.trigger.id, trigger.id)
        XCTAssertEqual(match?.backspaces, 3)
    }

    // MARK: Module switches

    @MainActor
    func testModuleSwitchesPersistAndCount() {
        let defaults = UserDefaults(suiteName: "AOM73-\(UUID().uuidString)")!
        let switches = AOMModuleSwitches(defaults: defaults)
        XCTAssertTrue(AOMModuleSwitch.allCases.filter { !$0.isOptIn }.allSatisfy(switches.isOn), "everything is on by default")
        XCTAssertTrue(AOMModuleSwitch.optIn.allSatisfy { !switches.isOn($0) }, "7.4 modules wait to be turned on")
        switches.startAll()
        XCTAssertNil(switches.set(.files, on: false))
        XCTAssertFalse(switches.isOn(.files))
        XCTAssertFalse(switches.isRunningForTests.contains(.files))
        XCTAssertEqual(AOMModuleSwitches(defaults: defaults).off, [.files], "remembered")
        for _ in 0..<20 { switches.set(.files, on: true); switches.set(.files, on: false) }
        XCTAssertEqual(switches.counters[.files]?.starts, 21)
        XCTAssertEqual(switches.counters[.files]?.stops, 21, "each start has its stop")
    }

    // MARK: Scenes

    func testScenePlanOrderProblemsAndPreview() {
        var scene = SceneProfile(name: "Coding")
        scene.launchApps = [SceneApp(bundleID: "com.apple.Terminal", name: "Terminal")]
        scene.layoutName = "Two up"
        scene.audio = SceneAudioTarget(uid: "AirPods-1", name: "AirPods", transport: 1)
        scene.appearance = .dark
        scene.keepAwakeMinutes = 60
        scene.startsFocus = true
        scene.quitApps = [SceneApp(bundleID: "com.apple.Music", name: "Music")]
        XCTAssertTrue(scene.problems.isEmpty)
        XCTAssertEqual(ScenePlanner.steps(scene).map(\.stage), ["Apps", "Windows", "System", "System", "System", "Focus", "Quit"])
        let state = SceneState(runningBundleIDs: ["com.apple.Terminal"], layoutNames: [], outputs: [("AirPods-2", "AirPods", 1)],
                               currentOutputUID: "Speakers", isDark: true, keepAwakeActive: false, focusActive: false)
        let preview = ScenePlanner.preview(scene, state: state)
        XCTAssertEqual(preview[0].outcome, .already, "Terminal is open")
        if case .skipped = preview[1].outcome {} else { XCTFail("no such layout: \(preview[1])") }
        XCTAssertEqual(preview[2].outcome, .done(nil), "found again by kind and name after the UID changed")
        XCTAssertEqual(preview[3].outcome, .already)
        XCTAssertEqual(preview[6].outcome, .already, "Music isn't open")
        scene.quitApps.append(SceneApp(bundleID: "com.apple.Terminal", name: "Terminal"))
        XCTAssertTrue(scene.problems.contains { $0.contains("open and to quit") })
        XCTAssertTrue(SceneAudio.resolve(SceneAudioTarget(uid: "x", name: "Speakers"), in: [("a", "Speakers", 0), ("b", "Speakers", 0)])?.ambiguous == true)
        XCTAssertNil(SceneAudio.resolve(SceneAudioTarget(uid: "x", name: "Gone"), in: [("a", "Speakers", 0)]))
    }

    // MARK: Efficiency and leftovers

    func testCommandCancelledBeforeItStartsNeverRunsAndRunsInItsFolder() async throws {
        let marker = folder.appendingPathComponent("ran")
        let command = StreamingCommand(URL(fileURLWithPath: "/usr/bin/touch"), [marker.path], timeout: 5)
        command.cancel()
        let result = try await command.run()
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "7.2.1 B19: the cancel was lost")
        let pwd = StreamingCommand(URL(fileURLWithPath: "/bin/pwd"), [], timeout: 5, currentDirectory: folder)
        let out = try await pwd.run()
        // Compared with the symbolic links resolved (/var is /private/var).
        XCTAssertEqual(realpath(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines), nil).map { String(cString: $0) },
                       realpath(folder.path, nil).map { String(cString: $0) })
    }

    func testLargeFilesKeepTheTopOnly() throws {
        for (name, size) in [("a", 3000), ("b", 9000), ("c", 6000), ("d", 9000), ("e", 100)] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(count: size))
        }
        let top = CleanupTools.largeFiles(in: folder, minimumBytes: 1, limit: 2)
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top.map(\.url.lastPathComponent).sorted(), ["b", "d"])
    }

    func testExpiredRecentSearchesArePruned() {
        var recent = PaletteRecentQueries()
        recent.record("fresh", now: Date().addingTimeInterval(-60))
        recent.record("old search", now: Date().addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(recent.entries.count, 2, "stored until something prunes it")
        XCTAssertTrue(recent.pruneExpired())
        XCTAssertEqual(recent.entries.map(\.text), ["fresh"])
        XCTAssertFalse(recent.pruneExpired())
    }

    @MainActor
    func testShortcutUsagesShowTheAppScope() {
        let store = PaletteHotkeyStore(defaults: UserDefaults(suiteName: "AOM73-\(UUID().uuidString)")!)
        let key = KeyboardShortcut(keyCode: 46, modifiers: [.command, .control, .option])
        var scoped = Trigger(name: "Mail macro", input: .keyboardShortcut(key))
        scoped.appBundleID = "com.apple.mail"
        let usages = store.usages(of: key, triggers: [scoped])
        XCTAssertEqual(usages.count, 1)
        XCTAssertTrue(usages[0].scope.hasPrefix("Only in"), usages[0].scope)
    }

    @MainActor
    func testActivityLogKeepsResultsAndRunsUndoOnce() {
        let log = FilesActivityLog()
        var undone = 0
        log.record("Moved 2 items", tool: "Drop Shelf", files: [folder], failures: [.init(url: folder, reason: "it no longer exists")],
                   undo: { undone += 1 })
        XCTAssertEqual(log.entries.first?.summary, "1 done · 1 failed")
        let id = log.entries[0].id
        log.run(id, retry: false)
        log.run(id, retry: false)
        XCTAssertEqual(undone, 1)
        XCTAssertNil(log.entries[0].undo)
    }

    @MainActor
    func testShelfRelocateSavesOnceAndAddUsesAMap() throws {
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let files = try (0..<5).map { try touch("s\($0).txt") }
        let items = store.add(files)
        XCTAssertEqual(store.add(files).map(\.id), items.map(\.id), "a file already on the shelf stays one item")
        let moved = folder.appendingPathComponent("moved", isDirectory: true)
        store.relocate(items.map { ($0.id, moved.appendingPathComponent($0.url.lastPathComponent)) })
        XCTAssertTrue(store.items.allSatisfy { $0.path.contains("/moved/") })
    }

    // MARK: 7.3 review (pasted review + the Codex probes)

    @MainActor
    func testOpeningASavedChatOfAnotherProviderSendsItsTurns() {
        let chat = PaletteAIChat()
        chat.model = AOMAIModelRef(provider: .apple, model: "default")
        let record = AOMAIChatHistory.Record(id: UUID(), title: "Earlier", date: Date(), model: "deepSeek:deepseek-chat",
                                             messages: [.init(role: "user", text: "q"), .init(role: "assistant", text: "a")])
        chat.load(record)
        XCTAssertEqual(chat.model.provider, .deepSeek)
        XCTAssertEqual(chat.historyStart, 0, "model's didSet held back the chat that was opened to continue it")
        XCTAssertEqual(chat.heldTurns, 0)
        chat.pendingScope = AOMAIRecordScope(sources: [.wiki])
        chat.newChat()
        XCTAssertTrue(chat.pendingScope.isEmpty, "records chosen for one chat don't carry into a new one")
    }

    @MainActor
    func testADeletedChatIsNotSavedBack() {
        let history = AOMAIChatHistory(url: nil)
        let record = AOMAIChatHistory.Record(id: UUID(), title: "x", date: Date(), model: nil,
                                             messages: [.init(role: "user", text: "q"), .init(role: "assistant", text: "a")])
        history.save(record)
        history.delete(record.id)
        history.save(record)   // the open chat saved again on New Chat
        XCTAssertFalse(history.records.contains { $0.id == record.id })
    }

    func testMentionsOnNewLinesAndTheQuestionKeepsItsFormatting() {
        let parsed = AOMAIRecordScope.parse("details\n@wiki please", home: folder)
        XCTAssertEqual(parsed.scope.sources, [.wiki], "a mention at the start of a line counts")
        XCTAssertEqual(parsed.question, "details\nplease")
        let code = "explain:\n\n    return  a"
        XCTAssertEqual(AOMAIRecordScope.parse(code, home: folder).question, code, "line breaks and indentation stay")
        XCTAssertEqual(AOMAIRecordScope.parse("why @mac?\n  x  y", home: folder).question, "why?\n  x  y")
        XCTAssertEqual(AOMAIRecordScope.parse("@wiki, how?", home: folder).question, "how?")
    }

    @MainActor
    func testShortcutFinderKeepsTheBindingsOwnTitle() throws {
        let store = PaletteHotkeyStore(defaults: UserDefaults(suiteName: "AOM73-\(UUID().uuidString)")!)
        let key = KeyboardShortcut(keyCode: 2, modifiers: [.command, .option, .control])
        try store.set(key, for: "capture.area", title: "Capture Area")
        let usage = try XCTUnwrap(store.usages(of: key, triggers: []).first)
        XCTAssertEqual(usage.title, "Launcher: Capture Area")
        XCTAssertEqual(usage.kind, .launcherRow(itemID: "capture.area", title: "Capture Area"), "no \"Launcher: \" prefix piles up")
    }

    func testSnippetChecksBeforeAnythingIsErased() {
        XCTAssertNotNil(SnippetInserterRefusal.check(SnippetRender(text: String(repeating: "x", count: SnippetTemplate.sizeLimit + 1))))
        XCTAssertNotNil(SnippetInserterRefusal.check(SnippetRender(text: "", notes: ["The clipboard had no text"])))
        let long = SnippetRender(text: "a" + String(repeating: "b", count: 601), charactersAfterCursor: 601, cursorUTF16: 1)
        XCTAssertEqual(SnippetTemplate.route(for: long, canRestoreClipboard: false), .type, "600+ ← presses stopped at 400")
        XCTAssertEqual(SnippetTemplate.route(for: SnippetRender(text: "ab", charactersAfterCursor: 1, cursorUTF16: 1), canRestoreClipboard: false),
                       .typeWithCaret(1))
        let existing = [PaletteSnippets.trigger(abbreviation: ";Ab", text: "first")]
        XCTAssertNotNil(PaletteSnippets.problem(with: ";ab", existing: existing), "the matcher ignores case, so these were one keyword")
    }

    @MainActor
    func testLauncherHidesAModuleThatIsOff() {
        let switches = AOMModuleSwitches(defaults: UserDefaults(suiteName: "AOM73-\(UUID().uuidString)")!)
        let rows = [("rules.preview", "Rule Preview"), ("go.\(AOMMainTab.folderRules.rawValue)", "Folder Rules page"), ("capture.area", "Capture")]
        XCTAssertEqual(AOMModuleSwitches.gated(rows.map { ($0.0, $0.1) }, isSearching: true, switches: switches, turnOnRow: { "on \($0.rawValue)" }),
                       ["Rule Preview", "Folder Rules page", "Capture", "on menuBarHider", "on memoryWatch", "on meetingAlerts"],
                       "7.4: the opt-in modules start off, so a search offers them")
        switches.set(.folderRules, on: false)
        let gated = AOMModuleSwitches.gated(rows.map { ($0.0, $0.1) }, isSearching: true, switches: switches,
                                            mark: { $0 += " (Off)" }, turnOnRow: { "on \($0.rawValue)" })
        XCTAssertEqual(gated, ["Folder Rules page (Off)", "Capture", "on folderRules", "on menuBarHider", "on memoryWatch", "on meetingAlerts"],
                       "the tool goes, the page stays marked, Turn On is found")
        XCTAssertEqual(AOMModuleSwitches.gated(rows.map { ($0.0, $0.1) }, isSearching: false, switches: AOMModuleSwitches(defaults: UserDefaults(suiteName: "AOM73-\(UUID().uuidString)")!),
                                               turnOnRow: { "on \($0.rawValue)" }), ["Rule Preview", "Folder Rules page", "Capture"], "no Turn On rows without a search")
    }

    @MainActor
    func testAReceivedFileMovedOutIsNeverTrashed() throws {
        let received = folder.appendingPathComponent("Received", isDirectory: true)
        let mine = folder.appendingPathComponent("Mine", isDirectory: true)
        let file = try touch("picture.txt", in: received, "received")
        let store = FilesShelfStore(fileURL: folder.appendingPathComponent("shelf.json"))
        let item = store.add([file], received: true)[0]
        XCTAssertEqual(FilesShelfPanelController.receivedToTrash([item], receivedFolder: received), [file.standardizedFileURL].map { URL(fileURLWithPath: FilesPath.key($0.path)) })
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let moved = mine.appendingPathComponent("picture.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        store.relocate([(item.id, moved)])
        let now = try XCTUnwrap(store.items.first)
        XCTAssertTrue(FilesShelfPanelController.receivedToTrash([now], receivedFolder: received).isEmpty, "Remove would have trashed your file")
    }

    func testRenameRefusesAFileReplacedAfterThePreviewAndLeavesBracesInNames() throws {
        let a = try touch("a.txt", "original")
        let rows = BatchRename.plan([a], find: "", template: "{name}-new")
        try FileManager.default.moveItem(at: a, to: folder.appendingPathComponent("kept-a.txt"))
        try "replacement".write(to: a, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try BatchRename.apply(rows)) { XCTAssertTrue($0.localizedDescription.contains("after the preview"), $0.localizedDescription) }
        XCTAssertEqual(text(a), "replacement", "nothing was renamed")
        let literal = folder.appendingPathComponent("report-{n}.txt")
        XCTAssertEqual(BatchRename.plan([literal], find: "unmatched", template: "other", exists: { _ in false })[0].newName, "report-{n}.txt")
        XCTAssertEqual(BatchRename.plan([literal], find: "report", template: "r{nn}", exists: { _ in false })[0].newName, "r01-{n}.txt",
                       "tokens are filled in the replacement only")
    }

    @MainActor
    func testExactNamesComeFirstAndFavoritesSayWhatMadeRoom() {
        let hits = (1...2_000).map { PaletteFileHit(url: folder.appendingPathComponent("A-report-\($0).txt"), date: nil, isFolder: false) }
            + [PaletteFileHit(url: folder.appendingPathComponent("report"), date: nil, isFolder: false)]
        XCTAssertEqual(PaletteLauncherData.folderMatches(hits, query: "report").first?.name, "report")
        let favorites = PaletteFolderFavorites(defaults: UserDefaults(suiteName: "AOM73-\(UUID().uuidString)")!)
        for index in 1...30 { XCTAssertNil(favorites.add(folder.appendingPathComponent("Fav\(index)"), query: "")) }
        XCTAssertEqual(favorites.add(folder.appendingPathComponent("Fav31"), query: "")?.name, "Fav1")
    }
}
