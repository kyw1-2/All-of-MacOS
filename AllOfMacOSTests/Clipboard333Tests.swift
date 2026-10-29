import AppKit
import XCTest
@testable import AllOfMacOS

/// Release 3.3.3 clipboard regressions.
///
/// The privacy tests reproduce the cases of the 2026-10-29 audit probe
/// (PA-01…PA-04: `clipboard-privacy-probe.swift`) against the production
/// code paths instead of copies. The parity tests cover Paste's pinboard,
/// search and retention semantics, link cards (P03) and OCR regions (P04).
///
/// Every store uses a private named pasteboard, its own defaults suite and a
/// temporary directory. Nothing reads Accessibility, the screen, the user's
/// clipboard or the network: destination readers and URL loaders are stubs.
@MainActor
final class Clipboard333Tests: XCTestCase {

    /// The audit probe's synthetic fixture. Not a real credential.
    private let fake = "api_key=sk-SYNTHETIC0000000000000000"

    // MARK: - Harness

    private struct Harness {
        let token: String
        let directory: URL
        let board: NSPasteboard
        let defaults: UserDefaults
        let store: ClipboardStore
    }

    private func makeHarness(token: String = "AOM333-\(UUID().uuidString)", now: (() -> Date)? = nil) -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        let board = NSPasteboard(name: .init(token))
        let defaults = UserDefaults(suiteName: token)!
        let store = now.map { ClipboardStore(directory: directory, pasteboard: board, defaults: defaults, now: $0) }
            ?? ClipboardStore(directory: directory, pasteboard: board, defaults: defaults)
        return Harness(token: token, directory: directory, board: board, defaults: defaults, store: store)
    }

    private func cleanUp(_ harness: Harness) {
        harness.board.releaseGlobally()
        harness.defaults.removePersistentDomain(forName: harness.token)
        try? FileManager.default.removeItem(at: harness.directory)
    }

    private func copy(_ text: String, into harness: Harness, app: String = "test.aom333") {
        harness.board.clearContents()
        XCTAssertTrue(harness.board.setString(text, forType: .string))
        harness.store.poll(sourceName: "Test", sourceBundleID: app)
    }

    /// The probe builds entries directly, with no pasteboard representation.
    private func probeEntry(_ text: String, kind: ClipboardEntry.Kind = .text) -> ClipboardEntry {
        ClipboardEntry(title: "Synthetic fixture", text: text, kind: kind, createdAt: Date(), items: [])
    }

    private func captured(_ items: [[String: Data]], app: String = "test.aom333", at date: Date = Date()) -> ClipboardEntry {
        ClipboardEntry.captured(items: items, sourceName: "Test", sourceBundleID: app, at: date)
    }

    private func text(_ value: String, app: String = "test.aom333", age: TimeInterval = 60) -> ClipboardEntry {
        captured([[NSPasteboard.PasteboardType.string.rawValue: Data(value.utf8)]], app: app, at: Date().addingTimeInterval(-age))
    }

    /// A pre-3.3.3 style archive, written before the store opens it.
    private struct Archive: Codable {
        var version = 1
        var entries: [ClipboardEntry]
        var boards: [ClipboardPinboard]
    }

    private func writeArchive(_ entries: [ClipboardEntry], boards: [ClipboardPinboard] = [], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(entries: entries, boards: boards))
            .write(to: directory.appendingPathComponent("history-v1.json"))
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:], store: ClipboardStore) -> [String: Any] {
        let response = ClipboardMCPHandler.handle(["jsonrpc": "2.0", "id": 33, "method": "tools/call",
                                                   "params": ["name": name, "arguments": arguments]], store: store)
        return (response?["result"] as? [String: Any]) ?? [:]
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func record(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }

    /// Two words far apart on white, large enough for Vision to read.
    private func twoWordImage(_ left: String, _ right: String) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1_400, pixelsHigh: 320, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1_400, height: 320).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 92), .foregroundColor: NSColor.black]
        (left as NSString).draw(at: NSPoint(x: 40, y: 110), withAttributes: attributes)
        (right as NSString).draw(at: NSPoint(x: 840, y: 110), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    // MARK: - PA-01 · excluded apps are excluded everywhere

    func testExcludedDestinationIsNeverReadForSuggestionsOrMCP() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        harness.store.settings.ignoredApps = ["com.Example.Vault"]
        _ = harness.store.createTextItem("someone@example.com")
        let intelligence = ClipboardIntelligence()
        try XCTSkipUnless(intelligence.isEnabled, "Intelligent Clipboard is turned off in this test runner's defaults")
        let reads = Calls()
        intelligence.destinationReader = { _, bundleID, _, _ in
            reads.record(bundleID ?? "nil")
            return ClipboardDestinationContext(bundleID: bundleID, windowTitle: "Read", kind: .text, source: .accessibility)
        }
        intelligence.secureInputProbe = { false }
        let excluded = ClipboardSuggestionTarget(pid: 4_242, bundleID: " COM.EXAMPLE.VAULT ", appName: "Vault")

        var received: [UUID]?
        intelligence.suggestionsAsync(for: excluded, store: harness.store) { received = $0 }
        XCTAssertEqual(received, [], "an excluded destination is answered at once, before any read")
        XCTAssertEqual(intelligence.suggestions(for: excluded, store: harness.store), [])
        XCTAssertTrue(reads.all.isEmpty, "no Accessibility read of an excluded app (PA-01)")
        XCTAssertTrue(intelligence.lastContext.isExcluded)
        XCTAssertNil(intelligence.lastContext.windowTitle)
        XCTAssertEqual(intelligence.lastContext.fieldHint, "")

        // Control: an allowed destination is read once, off the main thread.
        let done = expectation(description: "allowed destination ranked")
        intelligence.suggestionsAsync(for: ClipboardSuggestionTarget(pid: 4_243, bundleID: "com.example.mail", appName: "Mail"),
                                      store: harness.store) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(reads.all, ["com.example.mail"])
    }

    func testRankerNeverOffersExcludedAppsOrWhatWasCopiedFromThem() {
        let vaultClip = text("someone@example.com", app: "com.example.vault")
        let mailClip = text("other@example.com", app: "com.example.notes", age: 7_200)
        let classes: (ClipboardEntry) -> ClipboardItemClass = ClipboardItemClassifier.classify
        let field = ClipboardDestinationContext(bundleID: "com.example.mail", kind: .text, fieldHint: "email")
        XCTAssertEqual(ClipboardSuggestionRanker.rank([vaultClip, mailClip], context: field, events: [], classes: classes).first,
                       vaultClip.id, "control: the newer email wins without an exclusion")
        let ranked = ClipboardSuggestionRanker.rank([vaultClip, mailClip], context: field, events: [], classes: classes,
                                                    excludedBundleIDs: ["com.example.vault"])
        XCTAssertFalse(ranked.contains(vaultClip.id), "items copied before their app was excluded are never offered")
        XCTAssertEqual(ranked.first, mailClip.id)

        let toVault = ClipboardDestinationContext(bundleID: "com.example.vault", kind: .text, fieldHint: "email")
        XCTAssertEqual(ClipboardSuggestionRanker.rank([mailClip], context: toVault, events: [], classes: classes,
                                                      excludedBundleIDs: ["com.example.vault"]), [])

        // Paste history that came from an excluded app teaches nothing.
        let prose = text("A calm place for everything you copy.", app: "com.example.notes")
        let notes = ClipboardDestinationContext(bundleID: "com.example.editor", kind: .text)
        let events = (0..<3).map { _ in
            ClipboardPasteEvent(entryID: prose.id, itemClass: .unclassified, sourceBundleID: "com.example.vault",
                                destinationBundleID: "com.example.editor", destinationKind: .text, date: Date())
        }
        XCTAssertEqual(ClipboardSuggestionRanker.rank([prose], context: notes, events: events, classes: classes).first, prose.id)
        XCTAssertEqual(ClipboardSuggestionRanker.rank([prose], context: notes, events: events, classes: classes,
                                                      excludedBundleIDs: ["com.example.vault"]), [])
    }

    func testCaptureUsesTheSameCaseInsensitiveExclusion() async {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        harness.store.settings.ignoredApps = ["com.Example.Vault"]
        XCTAssertTrue(harness.store.settings.excludes("  COM.example.vault "))
        XCTAssertFalse(harness.store.settings.excludes(nil))
        copy("from the vault", into: harness, app: "com.example.VAULT")
        await harness.store.finishPendingCaptures()
        XCTAssertTrue(harness.store.entries.isEmpty)
        copy("from notes", into: harness, app: "com.example.notes")
        await harness.store.finishPendingCaptures()
        XCTAssertEqual(harness.store.entries.map(\.text), ["from notes"])
    }

    func testPasteLogLearnsNothingAboutExcludedAppsOrTheirItems() async {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        harness.store.settings.ignoredApps = ["com.example.vault"]
        let intelligence = ClipboardIntelligence()
        intelligence.secureInputProbe = { false }
        guard intelligence.isEnabled, let item = harness.store.createTextItem("someone@example.com") else { return }

        func record(_ target: ClipboardSuggestionTarget) async {
            await withCheckedContinuation { continuation in
                intelligence.recordPaste(entryIDs: [item.id], target: target, store: harness.store) { continuation.resume() }
            }
        }
        await record(ClipboardSuggestionTarget(pid: 1, bundleID: "com.example.vault", appName: "Vault"))
        XCTAssertTrue(intelligence.log(for: harness.store).events.isEmpty, "a paste into an excluded app is not learned")
        await record(ClipboardSuggestionTarget(pid: 2, bundleID: "com.example.mail", appName: "Mail"))
        XCTAssertEqual(intelligence.log(for: harness.store).events.map(\.destinationBundleID), ["com.example.mail"])
        intelligence.log(for: harness.store).erase()
    }

    func testScreenModelNeverLooksAtBlockedDestinations() {
        var context = ClipboardDestinationContext(bundleID: "com.example.app", kind: .unknown)
        XCTAssertTrue(ClipboardIntelligence.allowsScreenRefinement(context), "control")
        context.isExcluded = true
        XCTAssertFalse(ClipboardIntelligence.allowsScreenRefinement(context))
        XCTAssertFalse(ClipboardIntelligence.allowsScreenRefinement(ClipboardDestinationContext(kind: .unknown, isSecureInput: true)))
        XCTAssertFalse(ClipboardIntelligence.allowsScreenRefinement(ClipboardDestinationContext(kind: .password, source: .appCategory)))
        XCTAssertEqual(ClipboardPrivacyGate.suggestions(destinationBundleID: "com.example.vault",
                                                        settings: .init(ignoredApps: ["com.example.vault"]), secureInput: false), .excludedApp)
    }

    // MARK: - PA-02 · password fields and secure input are hard blocks

    func testProbeSecretIsNotSuggestedIntoASecurePasswordField() {
        // clipboard-privacy-probe.log: secure_password_field_suggestion_count= 1
        let short = probeEntry(fake)
        let classes: (ClipboardEntry) -> ClipboardItemClass = ClipboardItemClassifier.classify
        let secure = ClipboardDestinationContext(bundleID: "invalid.synthetic", kind: .password, isSecureInput: true)
        XCTAssertEqual(ClipboardSuggestionRanker.rank([short], context: secure, events: [], classes: classes), [])

        // Fail closed for every blocked shape, even with paste history.
        let prose = text("Plain words to paste")
        let history = ClipboardPasteEvent(entryID: prose.id, itemClass: .unclassified, sourceBundleID: nil,
                                          destinationBundleID: "invalid.synthetic", destinationKind: .password, date: Date())
        for context in [ClipboardDestinationContext(bundleID: "invalid.synthetic", kind: .password),
                        ClipboardDestinationContext(bundleID: "invalid.synthetic", kind: .text, isSecureInput: true)] {
            XCTAssertEqual(ClipboardSuggestionRanker.rank([short, prose], context: context, events: [history, history],
                                                          classes: classes), [])
        }
        // A secret fits no other destination either.
        for kind in ClipboardDestinationKind.allCases where kind != .password {
            let context = ClipboardDestinationContext(bundleID: "invalid.synthetic", kind: kind, fieldHint: "token")
            XCTAssertFalse(ClipboardSuggestionRanker.rank([short], context: context, events: [], classes: classes).contains(short.id), kind.rawValue)
        }
        XCTAssertEqual(ClipboardSuggestionRanker.fit(.secret, .password, hint: ""), 0)
    }

    func testSecureKeyboardEntryStopsSuggestionsBeforeAnyRead() async {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        _ = harness.store.createTextItem(fake)
        let intelligence = ClipboardIntelligence()
        guard intelligence.isEnabled else { return }
        let reads = Calls()
        intelligence.destinationReader = { _, bundleID, _, _ in reads.record(bundleID ?? ""); return .init(bundleID: bundleID) }
        intelligence.secureInputProbe = { true }
        let target = ClipboardSuggestionTarget(pid: 7, bundleID: "com.example.browser", appName: "Browser")
        var received: [UUID]?
        intelligence.suggestionsAsync(for: target, store: harness.store) { received = $0 }
        XCTAssertEqual(received, [])
        XCTAssertEqual(intelligence.suggestions(for: target, store: harness.store), [])
        XCTAssertTrue(reads.all.isEmpty, "secure keyboard entry ends the request before Accessibility (PA-02)")
        XCTAssertTrue(intelligence.lastContext.isSecureInput)
        XCTAssertEqual(intelligence.lastContext.kind, .password)

        // Nothing is learned from a paste made under secure input.
        let item = harness.store.entries[0]
        await withCheckedContinuation { continuation in
            intelligence.recordPaste(entryIDs: [item.id], target: target, store: harness.store) { continuation.resume() }
        }
        XCTAssertTrue(intelligence.log(for: harness.store).events.isEmpty)
    }

    func testAccessibilitySecureFieldBlocksEvenWithHistory() async {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        XCTAssertEqual(ClipboardDestinationReader.kind(role: "AXTextField", subrole: "AXSecureTextField", hint: "", bundleID: nil), .password)
        guard let item = harness.store.createTextItem("hunter2 is not a good password") else { return XCTFail() }
        let intelligence = ClipboardIntelligence()
        guard intelligence.isEnabled else { return }
        intelligence.secureInputProbe = { false }
        intelligence.destinationReader = { _, bundleID, _, _ in
            ClipboardDestinationContext(bundleID: bundleID, kind: .password, isSecureInput: true, source: .accessibility)
        }
        let done = expectation(description: "ranked")
        var received: [UUID] = [item.id]
        intelligence.suggestionsAsync(for: ClipboardSuggestionTarget(pid: 9, bundleID: "com.example.bank", appName: "Bank"),
                                      store: harness.store) { received = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(received, [])
        XCTAssertTrue(intelligence.lastContext.blocksSuggestions)
    }

    // MARK: - PA-03 · the outbound secret check has no type or length gaps

    func testProbeBypassesAreAllSecretsNow() {
        // clipboard-privacy-probe.log: long_secret, image_ocr_secret and
        // link_token were unclassified/other/link, so MCP_isSecret was false.
        let long = probeEntry(String(repeating: "x", count: 64_001) + "\n" + fake)
        var picture = probeEntry("", kind: .image)
        picture.recognizedText = fake
        let link = probeEntry("https://example.invalid/?token=FAKEONLY0123456789", kind: .link)
        for (name, item) in [("short_secret", probeEntry(fake)), ("long_secret", long), ("image_ocr_secret", picture), ("link_token", link)] {
            XCTAssertEqual(ClipboardItemClassifier.classify(item), .secret, name)
            XCTAssertTrue(ClipboardMCPHandler.isSecret(item), name)
        }
        XCTAssertFalse(ClipboardMCPHandler.isSecret(probeEntry("https://example.com/docs?page=2", kind: .link)), "control")
        XCTAssertFalse(ClipboardMCPHandler.isSecret(probeEntry("A calm place for everything you copy.")), "control")
    }

    func testScannerReadsEveryRepresentationAndEncoding() throws {
        let string = NSPasteboard.PasteboardType.string.rawValue
        let rtf = try NSAttributedString(string: fake).data(from: NSRange(location: 0, length: fake.utf16.count),
                                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let cases: [(String, [[String: Data]])] = [
            ("rich text only", [[string: Data("Quarterly notes".utf8), NSPasteboard.PasteboardType.rtf.rawValue: rtf]]),
            ("UTF-16 only", [[string: Data("hello".utf8), "public.utf16-external-plain-text": fake.data(using: .utf16)!]]),
            ("HTML character references", [[string: Data("Invoice".utf8), NSPasteboard.PasteboardType.html.rawValue:
                Data("<p>api&#95;key&#61;sk&#x2D;SYNTHETIC0000000000000000</p>".utf8)]]),
            ("HTML split by tags", [[NSPasteboard.PasteboardType.html.rawValue: Data("<b>sk-SYNTH</b><i>ETIC0000000000000000</i>".utf8)]]),
            ("percent-encoded file URL", [[NSPasteboard.PasteboardType.fileURL.rawValue:
                Data("file:///tmp/sk%2DSYNTHETIC0000000000000000.txt".utf8)]]),
            // Types the current capture allowlist drops, as older archives hold them.
            ("legacy type, UTF-16 without a byte-order mark", [["com.example.legacy-text": fake.data(using: .utf16LittleEndian)!]]),
            ("legacy type past 4 MB", [["com.example.legacy-text": Data((String(repeating: "log line\n", count: 600_000) + fake).utf8)]]),
        ]
        for (name, items) in cases {
            let entry = captured(items)
            XCTAssertFalse(entry.text?.contains("sk-SYNTHETIC0000000000000000") == true, "\(name): the visible text does not show it")
            XCTAssertTrue(ClipboardSecretScanner.containsSecret(entry), name)
            XCTAssertEqual(ClipboardItemClassifier.classify(entry), .secret, name)
        }
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: "sk-SYNTH\u{200B}ETIC0000000000000000"), "zero-width split")
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: "ｓｋ－ＳＹＮＴＨＥＴＩＣ００００００００００００００００"), "full-width")
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: "https://alice:hunter2pw@example.com/"), "URL password")
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: "https://bucket.example.com/a.png?X-Amz-Signature=abcdef0123456789"))

        var renamed = text("Meeting notes")
        renamed.title = "token: abcdef123456"
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(renamed), "a title is handed out too")
        XCTAssertFalse(ClipboardSecretScanner.containsSecret(text("Meeting at 10:30")), "control")
        XCTAssertFalse(ClipboardSecretScanner.containsSecret(captured([[NSPasteboard.PasteboardType.fileURL.rawValue:
            Data("file:///Users/test/Documents/Report%202026.pdf".utf8)]])), "control")
    }

    func testLongClipsAreScannedWhole() {
        // Past the 1 MB slice length, and a key right across a slice border.
        let filler = String(repeating: "log line without credentials\n", count: 80_000)
        XCTAssertGreaterThan(filler.utf16.count, 2 * 1_048_576)
        XCTAssertFalse(ClipboardSecretScanner.containsSecret(inText: filler), "control")
        let border = 1 << 20
        let prefix = String(repeating: "a ", count: (border - 10) / 2)
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: prefix + " sk-SYNTHETIC0000000000000000 " + filler))
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: filler + fake))
    }

    func testMCPWithholdsEveryProbeBypass() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        var picture = ClipboardEntry(title: "Image", kind: .image, sourceName: "Test", sourceBundleID: "test.aom333",
                                     items: [[NSPasteboard.PasteboardType.png.rawValue: png(twoWordImage("A", "B"))]])
        picture.recognizedText = "Screenshot\n" + fake
        picture.recognizedImageDigest = "indexed"
        let link = captured([[NSPasteboard.PasteboardType.string.rawValue: Data("https://example.invalid/?token=FAKEONLY0123456789".utf8)]])
        let rich = captured([[NSPasteboard.PasteboardType.string.rawValue: Data("Quarterly notes".utf8),
                              NSPasteboard.PasteboardType.rtf.rawValue: try NSAttributedString(string: fake).data(
                                from: NSRange(location: 0, length: fake.utf16.count),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])]])
        let long = captured([[NSPasteboard.PasteboardType.string.rawValue: Data((String(repeating: "x", count: 64_001) + "\n" + fake).utf8)]])
        let plain = captured([[NSPasteboard.PasteboardType.string.rawValue: Data("Nothing secret about SYNTHETIC weather".utf8)]])
        try writeArchive([picture, link, rich, long, plain], to: harness.directory)
        await harness.store.ready()
        XCTAssertEqual(harness.store.entries.count, 5)

        for item in [picture, link, rich, long] {
            XCTAssertEqual(call("read_item", ["id": item.id.uuidString], store: harness.store)["isError"] as? Bool, true, item.title)
            XCTAssertEqual(call("copy_to_clipboard", ["id": item.id.uuidString], store: harness.store)["isError"] as? Bool, true, item.title)
        }
        XCTAssertEqual(call("read_item", ["id": plain.id.uuidString], store: harness.store)["isError"] as? Bool, false, "control")

        // A content search never matches a hidden item, so its text cannot be
        // probed one guess at a time; metadata searches still list it, hidden.
        let found = try XCTUnwrap(call("search", ["query": "SYNTHETIC"], store: harness.store)["structuredContent"] as? [String: Any])
        XCTAssertEqual((found["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [plain.id.uuidString])
        XCTAssertEqual(found["total"] as? Int, 1)
        let images = try XCTUnwrap(call("search", ["query": "type:image"], store: harness.store)["structuredContent"] as? [String: Any])
        let hidden = try XCTUnwrap((images["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(hidden["title"] as? String, "Hidden secret")
        XCTAssertEqual(hidden["preview"] as? String, ClipboardSecretScanner.placeholder)
    }

    func testAutomationRepliesHideCredentialsAndRefuseThemBack() {
        let definition: [String: Any] = [
            "name": "Sign in",
            "actions": [["type": "typeText", "text": fake], ["type": "openURL", "url": "https://example.com/start"],
                        ["type": "custom", "parameters": ["password": "hunter2", "count": 3]]],
        ]
        let redacted = ClipboardSecretScanner.redactingSecrets(in: definition)
        XCTAssertEqual(redacted.hidden, 2)
        let actions = (redacted.value as? [String: Any])?["actions"] as? [[String: Any]]
        XCTAssertEqual(actions?[0]["text"] as? String, ClipboardSecretScanner.placeholder)
        XCTAssertEqual(actions?[1]["url"] as? String, "https://example.com/start")
        XCTAssertEqual((actions?[2]["parameters"] as? [String: Any])?["password"] as? String, ClipboardSecretScanner.placeholder)
        XCTAssertEqual((actions?[2]["parameters"] as? [String: Any])?["count"] as? Int, 3)
        XCTAssertEqual(AutomationMCP.redactingSecrets(definition) as? NSDictionary, redacted.value as? NSDictionary)
        XCTAssertThrowsError(try AutomationMCP.rejectRedactedValues(redacted.value), "a placeholder never overwrites the secret")
        XCTAssertNoThrow(try AutomationMCP.rejectRedactedValues(["name": "Plain", "actions": [["type": "beep"]]]))
    }

}
