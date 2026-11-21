import PDFKit
import XCTest
@testable import AllOfMacOS

/// 7.2.2: DeepSeek Harness in Ask AI, the System Tools cleanup, and the
/// audit's N01 (rename preview), N02 (PDF compression compared) and N03
/// (folder rule on picked items).
final class AOM722Tests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AOM722-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func touch(_ name: String, _ text: String = "x") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: DeepSeek Harness

    func testDeepSeekHarnessRunsHeadlessAndReadOnly() {
        let script = URL(fileURLWithPath: "/cache/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js")
        XCTAssertEqual(AOMDeepSeekHarness.arguments(script: script, prompt: "--help me", session: nil),
                       [script.path, "--profile", "headless", "--json", "--", "--help me"], "the prompt can't become a flag")
        XCTAssertEqual(AOMDeepSeekHarness.arguments(script: script, prompt: "hi", session: "s1").suffix(4),
                       ["--session-id", "s1", "--", "hi"])
        let env = AOMDeepSeekHarness.environment(["PATH": "/bin"])
        XCTAssertEqual(env["ELECTRON_RUN_AS_NODE"], "1")
        XCTAssertEqual(env["DSH_PERMISSION_MODE"], "read-only")
        XCTAssertTrue(AOMDeepSeekHarness.binScript(in: URL(fileURLWithPath: "/c")).path.hasSuffix("@deepseek-ai/dsh/lib/bin.js"))
    }

    func testDeepSeekHarnessEvents() {
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"session","sessionId":"abc"}"#, provider: .dsh), [.session("abc")])
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"tool_call","tool":"read","input":{"file_path":"~/a.md"}}"#, provider: .dsh),
                       [.activity("read: ~/a.md")])
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"text","text":"Step one"}"#, provider: .dsh), [.message("Step one")])
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"final","text":"Done."}"#, provider: .dsh), [.done("Done.")])
        XCTAssertEqual(PaletteAIEvent.parse(#"{"type":"error","message":"no login"}"#, provider: .dsh), [.failure("no login")])
        XCTAssertEqual(PaletteAIEvent.parse("not json", provider: .dsh), [])
        XCTAssertTrue(AOMAIProvider.deepSeekHarness.isAgent)
    }

    /// A real asar layout: a pickled header, then the files' bytes.
    func testAsarSubtreeIsExtracted() throws {
        let body = Data("console.log(1)".utf8)
        let index: [String: Any] = ["files": ["dsh": ["files": ["bin.js": ["size": body.count, "offset": "0", "executable": true],
                                                                "link.js": ["link": "dsh/bin.js"]]]]]
        let json = try JSONSerialization.data(withJSONObject: index)
        func le(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        // Chromium pickle: [4][headerSize] then [payloadSize][jsonSize][json, padded to 4]
        let padded = json + Data(repeating: 0, count: (4 - json.count % 4) % 4)
        let header = le(padded.count + 4) + le(json.count) + padded
        let archive = le(4) + le(header.count) + header + body
        let asar = folder.appendingPathComponent("app.asar")
        try archive.write(to: asar)
        let out = folder.appendingPathComponent("out", isDirectory: true)
        try AOMDeepSeekHarness.extract(asar: asar, unpacked: folder.appendingPathComponent("app.asar.unpacked"), subtree: "dsh", into: out)
        let bin = out.appendingPathComponent("dsh/bin.js")
        XCTAssertEqual(try String(contentsOf: bin, encoding: .utf8), "console.log(1)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("dsh/link.js").path), "../dsh/bin.js",
                       "asar links are relative to the archive root")
    }

    // MARK: Ask AI search

    func testByteScanFindsEscapedKoreanAndRanksFullMatches() {
        let data = Data((#"{"text":"오라클 ssh oracle"}"# + "\nssh only\nORACLE and SSH here\n").utf8)
        let forms = ["오라클", "ssh"].map { AOMAILocalTools.forms(of: $0) }
        let hits = AOMAILocalTools.scan(data, forms: forms, limit: 3, deadline: .distantFuture)
        XCTAssertEqual(hits.full.first?.line, 1, "the \\u-escaped Korean line matches every term")
        XCTAssertTrue(hits.full.first?.snippet.contains("오라클") == true, "\(hits)")
        let both = AOMAILocalTools.scan(data, forms: ["oracle", "ssh"].map { AOMAILocalTools.forms(of: $0) }, limit: 3, deadline: .distantFuture)
        XCTAssertEqual(both.full.map(\.line), [1, 3], "ASCII matching ignores case")
    }

    func testWordAtATimeLoweringMatchesAByteLoop() {
        var bytes = (0...255).map(UInt8.init) + Array("Hello ORACLE 오라클 SSH-Zz@[`{".utf8)
        bytes += bytes.reversed()
        for length in [0, 1, 7, 8, 9, bytes.count] {
            let slice = Data(bytes.prefix(length))
            XCTAssertEqual(AOMAILocalTools.lowercasedASCII(slice), slice.map { $0 &- 65 < 26 ? $0 &+ 32 : $0 }, "length \(length)")
        }
    }

    // MARK: System Tools cleanup

    func testRemovedToolsAreGoneAndGroupedOnesStayFindable() {
        for raw in ["keyboardClean", "keystrokes", "metalHUD", "quitAll", "forceQuit", "timeMachine", "snapshots", "ping", "ports", "renewDHCP"] {
            XCTAssertNil(SystemToolID(rawValue: raw), raw)
        }
        XCTAssertEqual(SystemToolsModel.storedTools(["ping", "forceQuit", "darkMode"]), [.killApps, .darkMode])
        let finder = SystemToolCatalog.all.filter { $0.groupedInto == .finderDisplay }.map(\.id)
        XCTAssertEqual(Set(finder), [.extensions, .pathbar, .statusbar, .posixtitle, .showLibrary])
        XCTAssertEqual(Set(SystemToolCatalog.all.filter { $0.groupedInto == .dockSettings }.map(\.id)), [.dockactive, .dockdelay, .dockrecents])
        XCTAssertEqual(Set(SystemToolCatalog.all.filter { $0.groupedInto == .screenshotDefaults }.map(\.id)), [.shotshadow, .shotformat, .shotfolder])
        XCTAssertEqual(Set(SystemToolCatalog.all.filter { $0.groupedInto == .repair }.map(\.id)), [.launchServices, .spotlight])
        for group: SystemToolID in [.finderDisplay, .dockSettings, .screenshotDefaults, .repair] {
            XCTAssertNil(SystemToolCatalog.info(group).groupedInto, "a group tile is never itself hidden")
        }
        XCTAssertTrue(SystemToolCatalog.info(.pathbar).matches("path bar"), "searching still finds a grouped tool")
    }

    // MARK: N01 Batch Rename

    func testRenameTemplateWithNothingToFindNumbersTheFiles() throws {
        let a = try touch("a.txt"), b = try touch("b.txt")
        let rows = BatchRename.plan([a, b], find: "", template: "{n}")
        XCTAssertEqual(rows.map(\.newName), ["1.txt", "2.txt"], "7.2.1 ignored {n} without text to find (B07)")
        XCTAssertEqual(BatchRename.plan([a, b], find: "", template: "{name} {nn}", startingNumber: 9).map(\.newName), ["a 09.txt", "b 10.txt"])
        let day = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertTrue(BatchRename.plan([a], find: "", template: "{date} {name}", date: day)[0].newName.hasSuffix(" a.txt"))
        XCTAssertEqual(BatchRename.plan([a], find: "", template: "")[0].changes, false, "an empty template keeps the name")
        XCTAssertEqual(BatchRename.plan([a], find: "a", template: "x{n}")[0].newName, "x1.txt")
    }

    func testRenameProblemsBlockTheWholeSet() throws {
        let a = try touch("a.txt"), b = try touch("b.txt"), _ = try touch("taken.txt")
        let same = BatchRename.plan([a, b], find: "", template: "same")
        XCTAssertNil(same[0].problem)
        XCTAssertNotNil(same[1].problem, "two files can't get one name")
        XCTAssertNotNil(BatchRename.plan([a], find: "", template: "taken")[0].problem, "an existing file is never replaced")
        XCTAssertNotNil(BatchRename.plan([a], find: "a", template: "x/y")[0].problem)
        XCTAssertNotNil(BatchRename.plan([a], find: "a", template: "")[0].problem, "an empty name")
        XCTAssertThrowsError(try BatchRename.apply(same))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        let upper = BatchRename.plan([a], find: "a", template: "A")
        XCTAssertNil(upper[0].problem, "a change of case only is allowed")
        try BatchRename.apply(upper)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains("A.txt"))
    }

    func testRenameRollsBackAFailedMoveAndUndoes() throws {
        let a = try touch("a.txt"), b = try touch("b.txt"), c = try touch("c.txt")
        let rows = BatchRename.plan([a, b, c], find: "", template: "{name}-new")
        var calls = 0
        XCTAssertThrowsError(try BatchRename.apply(rows, move: { from, to in
            calls += 1
            if calls == 3 { throw CocoaError(.fileWriteNoPermission) }
            try BatchRename.defaultMove(from, to)
        })) { error in XCTAssertTrue(error.localizedDescription.contains("put back"), error.localizedDescription) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["a.txt", "b.txt", "c.txt"], "B02: nothing half-renamed")
        let done = try BatchRename.apply(rows)
        XCTAssertEqual(done.moves.count, 3)
        XCTAssertEqual(BatchRename.undo(done), 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(try MacMagicSystemToolService.shared.batchRename(urls: [a], pattern: "", replacement: "{n}").map(\.lastPathComponent), ["1.txt"])
    }

    // MARK: N02 PDF compression

    private func makePDF(pages: Int) throws -> URL {
        let url = folder.appendingPathComponent("Report.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            ("Quarterly report page \(page)" as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in
                for x in stride(from: 0, to: rect.width, by: 4) {
                    NSColor(hue: x / rect.width, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                    NSRect(x: x, y: 0, width: 4, height: rect.height).fill()
                }
                return true
            }
            image.draw(in: NSRect(x: 72, y: 300, width: 400, height: 300))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    func testCompressionKeepsTextOrMakesPagesImages() throws {
        let source = try makePDF(pages: 2)
        let keep = folder.appendingPathComponent("keep.pdf"), images = folder.appendingPathComponent("images.pdf")
        try MacMagicSystemToolService.shared.compressPDF(url: source, to: keep, mode: .keepText)
        try MacMagicSystemToolService.shared.compressPDF(url: source, to: images, mode: .pagesAsImages)
        let kept = try XCTUnwrap(PDFDocument(url: keep))
        XCTAssertEqual(kept.pageCount, 2)
        XCTAssertTrue(kept.string?.contains("Quarterly report page 2") == true, "Keep Text leaves the text selectable")
        let pictured = try XCTUnwrap(PDFDocument(url: images))
        XCTAssertEqual(pictured.pageCount, 2)
        XCTAssertEqual(pictured.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792), "pages keep their size")
        XCTAssertFalse(pictured.string?.contains("Quarterly") == true)
        XCTAssertEqual(PDFComparison.saving(original: 1_000, compressed: 380), "62% smaller")
        XCTAssertNil(PDFComparison.saving(original: 1_000, compressed: 1_200))
    }

    func testCompressedNameNeverReplacesAFile() {
        let source = URL(fileURLWithPath: "/docs/Report.pdf")
        var taken: Set<String> = ["/docs/Report (compressed).pdf", "/docs/Report (compressed 2).pdf"]
        XCTAssertEqual(MacMagicSystemToolService.freeName(nextTo: source, suffix: "compressed") { taken.contains($0.path) }.lastPathComponent,
                       "Report (compressed 3).pdf")
        taken = []
        XCTAssertEqual(MacMagicSystemToolService.freeName(nextTo: source, suffix: "compressed") { taken.contains($0.path) }.lastPathComponent,
                       "Report (compressed).pdf")
    }

    func testMergeNamesTheUnreadablePDFs() throws {
        let good = try makePDF(pages: 1)
        let bad = try touch("Broken.pdf", "not a pdf")
        let out = folder.appendingPathComponent("Merged.pdf")
        XCTAssertEqual(try MacMagicSystemToolService.shared.combinePDFs(urls: [good, bad], to: out), ["Broken.pdf"])
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
        XCTAssertThrowsError(try MacMagicSystemToolService.shared.combinePDFs(urls: [bad], to: folder.appendingPathComponent("none.pdf")))
    }

    // MARK: B24 Key mappings AOM replaced come back

    func testHyperKeyGivesBackTheCapsLockMappingItReplaced() {
        let capsToEscape = HIDKeyMapping.pair(0x39, 0x29), capsToF18 = HIDKeyMapping.pair(0x39, 0x6D)
        let other = HIDKeyMapping.pair(0x64, 0x35)
        let on = HIDKeyMapping.plan(current: [capsToEscape, other], previouslyOwned: [], displaced: [], desired: [capsToF18])
        XCTAssertEqual(on.pairs, [other, capsToF18])
        XCTAssertEqual(on.displaced, [capsToEscape], "what the Hyper key replaced is remembered")
        let again = HIDKeyMapping.plan(current: on.pairs, previouslyOwned: [capsToF18], displaced: on.displaced, desired: [capsToF18])
        XCTAssertEqual(again.pairs, [other, capsToF18])
        XCTAssertEqual(again.displaced, [capsToEscape], "a second apply keeps remembering it")
        let off = HIDKeyMapping.plan(current: on.pairs, previouslyOwned: [capsToF18], displaced: on.displaced, desired: [])
        XCTAssertEqual(off.pairs, [other, capsToEscape], "7.2.1 left Caps Lock with no mapping")
        XCTAssertEqual(off.displaced, [])
        let capsToControl = HIDKeyMapping.pair(0x39, 0xE0)
        let changed = HIDKeyMapping.plan(current: [other, capsToControl], previouslyOwned: [capsToF18], displaced: on.displaced, desired: [])
        XCTAssertEqual(changed.pairs, [other, capsToControl], "a mapping someone set since wins")
        XCTAssertEqual(HIDKeyMapping.merged(current: [capsToEscape], previouslyOwned: [], desired: [capsToF18]), [capsToF18])
    }

    func testGiveBackRestoresTheDisplacedPair() {
        let capsToEscape = HIDKeyMapping.pair(0x39, 0x29), capsToF18 = HIDKeyMapping.pair(0x39, 0x6D)
        var owned = [capsToF18], displaced = [capsToEscape]
        var written = ""
        let service = InputRemapService(hidutil: { arguments in
            if arguments[1] == "--get" { return #"( { HIDKeyboardModifierMappingDst = 30064771181; HIDKeyboardModifierMappingSrc = 30064771129; } )"# }
            written = arguments[2]; return "ok"
        }, loadOwned: { owned }, saveOwned: { owned = $0 }, loadDisplaced: { displaced }, saveDisplaced: { displaced = $0 })
        XCTAssertTrue(service.giveBackOwnedMappings(timeout: 2))
        XCTAssertEqual(written, HIDKeyMapping.json([capsToEscape]))
        XCTAssertEqual(owned, [])
        XCTAssertEqual(displaced, [])
    }

    // MARK: N03 Folder rule on picked items

    func testPickedItemsMustStillBeTheSameFile() throws {
        let file = try touch("Old.dmg")
        let shown = try XCTUnwrap(FolderRuleFileReader.read(file))
        XCTAssertTrue(FolderRulesRunner.isSameItem(shown, try XCTUnwrap(FolderRuleFileReader.read(file))))
        try FileManager.default.removeItem(at: file)
        _ = try touch("Old.dmg", "a different file under the same name")
        let now = try XCTUnwrap(FolderRuleFileReader.read(file))
        XCTAssertFalse(FolderRulesRunner.isSameItem(shown, now), "a replaced file is left alone")
        XCTAssertTrue(FolderRulesRunner.isSameItem(FolderRuleFileInfo(url: file), now), "an item read without an inode counts as the same")
    }

    @MainActor
    func testSelectedRunMessage() {
        XCTAssertEqual(FolderRulesEngine.selectedRunMessage(ran: 3, skipped: 0, failed: 0).text, "Ran on 3 items.")
        let mixed = FolderRulesEngine.selectedRunMessage(ran: 1, skipped: 2, failed: 1)
        XCTAssertEqual(mixed.text, "Ran on 1 item · 1 failed · 2 changed since the preview and were left alone.")
        XCTAssertEqual(mixed.tone, .warning)
    }
}
