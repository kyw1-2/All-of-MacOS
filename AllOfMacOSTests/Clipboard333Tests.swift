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

    // MARK: - PA-04 · the classification cache key covers the whole content

    func testMiddleEditChangesTheCacheKeyAndTheClass() {
        // clipboard-privacy-probe.log: middle_edit_same_digest= true
        let before = probeEntry(String(repeating: "x", count: 600) + String(repeating: "a", count: fake.utf8.count) + String(repeating: "y", count: 600))
        var after = before
        after.text = String(repeating: "x", count: 600) + fake + String(repeating: "y", count: 600)
        XCTAssertEqual(before.text?.utf8.count, after.text?.utf8.count)
        XCTAssertNotEqual(ClipboardIntelligence.digest(before), ClipboardIntelligence.digest(after))
        XCTAssertEqual(ClipboardIntelligence.digest(before), ClipboardIntelligence.digest(before))

        let intelligence = ClipboardIntelligence()
        XCTAssertEqual(intelligence.itemClass(before), .unclassified)
        XCTAssertEqual(intelligence.itemClass(after), .secret, "same id, new middle: re-classified, not served from the cache")

        // Everything the scanner reads is part of the key.
        var ocr = before
        ocr.recognizedText = "Receipt"
        var renamed = before
        renamed.title = "Renamed"
        XCTAssertNotEqual(ClipboardIntelligence.digest(before), ClipboardIntelligence.digest(ocr))
        XCTAssertNotEqual(ClipboardIntelligence.digest(before), ClipboardIntelligence.digest(renamed))
        let rich = captured([[NSPasteboard.PasteboardType.string.rawValue: Data("same".utf8),
                              NSPasteboard.PasteboardType.html.rawValue: Data("<p>one</p>".utf8)]])
        var richEdited = rich
        richEdited.items = [[NSPasteboard.PasteboardType.string.rawValue: Data("same".utf8),
                             NSPasteboard.PasteboardType.html.rawValue: Data("<p>two</p>".utf8)]]
        XCTAssertNotEqual(ClipboardIntelligence.digest(rich), ClipboardIntelligence.digest(richEdited))
    }

    // MARK: - Pinboards (Paste parity)

    func testDeletingAPinboardWithItsItemsIsUndoable() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        let work = store.createBoard(name: "Work"), home = store.createBoard(name: "Home")
        let onlyWork = try XCTUnwrap(store.createTextItem("only work"))
        let both = try XCTUnwrap(store.createTextItem("both"))
        let loose = try XCTUnwrap(store.createTextItem("loose"))
        store.pin(entryID: onlyWork.id, boardID: work.id)
        store.pin(entryID: both.id, boardID: work.id)
        store.pin(entryID: both.id, boardID: home.id)
        XCTAssertEqual(store.itemsOnlyOnBoard(work.id), 1)

        XCTAssertEqual(store.deleteBoard(id: work.id, deletingItems: true), 1)
        XCTAssertEqual(store.boards.map(\.id), [home.id])
        XCTAssertFalse(store.entries.contains { $0.id == onlyWork.id }, "Paste deletes a pinboard's items with it")
        XCTAssertEqual(store.entries.first { $0.id == both.id }?.pinboardIDs, [home.id], "items on another pinboard stay")
        XCTAssertTrue(store.entries.contains { $0.id == loose.id })

        let undone = store.undoLastDeletion()
        XCTAssertEqual(undone.boardCount, 1)
        XCTAssertEqual(undone.entryIDs, [onlyWork.id])
        XCTAssertEqual(store.boards.map(\.id), [work.id, home.id], "the pinboard returns to its place")
        XCTAssertEqual(store.entries.first { $0.id == onlyWork.id }?.pinboardIDs, [work.id])
        XCTAssertEqual(store.entries.first { $0.id == both.id }?.pinboardIDs, [work.id, home.id])
    }

    func testDeletingAPinboardButKeepingItemsNeverLosesThemSilently() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = makeHarness(now: { clock })
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        store.settings.retentionDays = 1
        let board = store.createBoard(name: "Archive")
        let old = try XCTUnwrap(store.createTextItem("pinned long ago"))
        store.pin(entryID: old.id, boardID: board.id)
        clock.addTimeInterval(10 * 86_400)
        let fresh = try XCTUnwrap(store.createTextItem("pinned today"))
        store.pin(entryID: fresh.id, boardID: board.id)

        XCTAssertEqual(store.deleteBoard(id: board.id, deletingItems: false), 0)
        XCTAssertEqual(store.entries.first { $0.id == fresh.id }?.pinboardIDs, [], "a recent item stays in history")
        XCTAssertFalse(store.entries.contains { $0.id == old.id }, "an item past the history limit leaves with its pinboard")
        XCTAssertTrue(store.canUndoDeletion, "…but not silently: Undo Delete has it")

        let undone = store.undoLastDeletion()
        XCTAssertEqual(undone.boardCount, 1)
        XCTAssertEqual(undone.entryIDs, [old.id])
        XCTAssertEqual(store.entries.first { $0.id == old.id }?.pinboardIDs, [board.id])
        XCTAssertEqual(store.entries.first { $0.id == fresh.id }?.pinboardIDs, [board.id])
    }

    func testUnpinningAnItemPastTheHistoryLimitIsUndoable() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = makeHarness(now: { clock })
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        store.settings.retentionDays = 7
        let board = store.createBoard(name: "Snippets")
        let item = try XCTUnwrap(store.createTextItem("signature block"))
        store.pin(entryID: item.id, boardID: board.id)
        clock.addTimeInterval(30 * 86_400)
        XCTAssertTrue(store.unpin(entryID: item.id, boardID: board.id))
        XCTAssertFalse(store.entries.contains { $0.id == item.id })
        XCTAssertEqual(store.undoLastDeletion().entryIDs, [item.id])
        XCTAssertEqual(store.entries.first { $0.id == item.id }?.pinboardIDs, [board.id], "it comes back pinned")
        XCTAssertFalse(store.unpin(entryID: UUID(), boardID: board.id))
    }

    func testOnePinboardPerItemMovesLikePasteAndSurvivesReload() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        let a = store.createBoard(name: "A"), b = store.createBoard(name: "B")
        let item = try XCTUnwrap(store.createTextItem("snippet"))
        XCTAssertFalse(store.settings.onePinboardPerItem, "AOM's several-pinboard default is kept")
        store.pin(entryID: item.id, boardID: a.id)
        store.pin(entryID: item.id, boardID: b.id)
        XCTAssertEqual(store.entries.first { $0.id == item.id }?.pinboardIDs, [a.id, b.id])

        store.settings.onePinboardPerItem = true
        store.pin(entryID: item.id, boardID: a.id)
        XCTAssertEqual(store.entries.first { $0.id == item.id }?.pinboardIDs, [a.id], "pinning elsewhere moves the item")
        await store.flush()
        let reopenedBoard = NSPasteboard(name: .init(harness.token + "-2"))
        defer { reopenedBoard.releaseGlobally() }
        let reopened = ClipboardStore(directory: harness.directory, pasteboard: reopenedBoard, defaults: harness.defaults)
        await reopened.ready()
        XCTAssertTrue(reopened.settings.onePinboardPerItem)
        XCTAssertEqual(reopened.entries.first?.pinboardIDs, [a.id])
    }

    func testOptionCopyBetweenPinboardsMakesACopyWhenItemsKeepOnePinboard() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        let a = store.createBoard(name: "A"), b = store.createBoard(name: "B"), c = store.createBoard(name: "C")
        let item = try XCTUnwrap(store.createTextItem("snippet"))
        store.pin(entryID: item.id, boardID: a.id)
        XCTAssertEqual(store.copy(entryID: item.id, toBoard: b.id), item.id, "several pinboards allowed: the item itself")
        XCTAssertEqual(store.entries.first { $0.id == item.id }?.pinboardIDs, [a.id, b.id])

        store.settings.onePinboardPerItem = true
        store.pin(entryID: item.id, boardID: a.id)
        let copied = try XCTUnwrap(store.copy(entryID: item.id, toBoard: c.id))
        XCTAssertNotEqual(copied, item.id, "one pinboard per item: ⌥ copies instead of moving")
        XCTAssertEqual(store.entries.first { $0.id == item.id }?.pinboardIDs, [a.id], "the original stays where it was")
        let copy = try XCTUnwrap(store.entries.first { $0.id == copied })
        XCTAssertEqual(copy.pinboardIDs, [c.id])
        XCTAssertEqual(copy.title, store.entries.first { $0.id == item.id }?.title)
        XCTAssertEqual(copy.text, "snippet")
        XCTAssertEqual(store.copy(entryID: item.id, toBoard: a.id), item.id, "already there: nothing to copy")
        XCTAssertEqual(store.entries.count, 2)
    }

    func testSettingsSavedByOlderVersionsStillDecode() async throws {
        let token = "AOM333-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: token))
        defer { defaults.removePersistentDomain(forName: token) }
        let legacy = #"{"enabled":true,"pasteDirectly":false,"plainText":true,"retentionDays":7,"ignoredApps":["com.example.a"],"maxEntries":500,"maxBytes":1048576}"#
        defaults.set(Data(legacy.utf8), forKey: "AOMClipboardSettings.v1")
        let harness = Harness(token: token, directory: FileManager.default.temporaryDirectory.appendingPathComponent(token),
                              board: NSPasteboard(name: .init(token)), defaults: defaults,
                              store: ClipboardStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(token),
                                                    pasteboard: NSPasteboard(name: .init(token)), defaults: defaults))
        defer { cleanUp(harness) }
        await harness.store.ready()
        XCTAssertEqual(harness.store.settings.retentionDays, 7, "a missing 3.3.3 key must not reset the settings")
        XCTAssertEqual(harness.store.settings.ignoredApps, ["com.example.a"])
        XCTAssertFalse(harness.store.settings.pasteDirectly)
        XCTAssertTrue(harness.store.settings.searchesAllLists)
        XCTAssertFalse(harness.store.settings.onePinboardPerItem)
    }

    func testMCPDeletePinboardCanDeleteItsItems() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        let board = store.createBoard(name: "Temp")
        let item = try XCTUnwrap(store.createTextItem("temporary"))
        store.pin(entryID: item.id, boardID: board.id)
        let preview = try XCTUnwrap(call("delete_pinboard", ["pinboard_id": board.id.uuidString, "delete_items": true],
                                         store: store)["structuredContent"] as? [String: Any])
        XCTAssertTrue((preview["message"] as? String)?.contains("1 item(s)") == true)
        XCTAssertEqual(store.boards.count, 1, "the preview deletes nothing")
        let result = try XCTUnwrap(call("delete_pinboard", ["pinboard_id": board.id.uuidString, "delete_items": true, "confirm": true],
                                        store: store)["structuredContent"] as? [String: Any])
        XCTAssertEqual(result["deletedItems"] as? Int, 1)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.canUndoDeletion)
    }

    // MARK: - Search (Paste parity)

    func testSearchFromAPinboardLooksThroughEveryList() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        let work = store.createBoard(name: "Work"), home = store.createBoard(name: "Home")
        let inWork = try XCTUnwrap(store.createTextItem("needle in work"))
        let inHome = try XCTUnwrap(store.createTextItem("needle at home"))
        let inHistory = try XCTUnwrap(store.createTextItem("needle in history"))
        store.pin(entryID: inWork.id, boardID: work.id)
        store.pin(entryID: inHome.id, boardID: home.id)

        let state = ClipboardPanelState()
        state.selectBoard(work.id)
        XCTAssertEqual(state.results(in: store).map(\.id), [inWork.id], "without a search the pinboard is shown")
        state.query = "needle"
        XCTAssertTrue(state.searchesAllLists(in: store))
        XCTAssertEqual(Set(state.results(in: store).map(\.id)), [inWork.id, inHome.id, inHistory.id])
        // The off-main search path (a fresh state, so no cached results) agrees.
        let typed = ClipboardPanelState()
        typed.selectBoard(work.id)
        typed.query = "needle"
        XCTAssertTrue(typed.displayedResults(in: store).isEmpty, "the first call only starts the search")
        await typed.finishPendingSearch()
        XCTAssertEqual(Set(typed.displayedResults(in: store).map(\.id)), [inWork.id, inHome.id, inHistory.id])

        state.query = "needle board:\"Home\""
        XCTAssertEqual(state.results(in: store).map(\.id), [inHome.id], "a typed board: filter still narrows")

        store.settings.searchesAllLists = false
        state.query = "needle"
        XCTAssertFalse(state.searchesAllLists(in: store))
        XCTAssertEqual(state.results(in: store).map(\.id), [inWork.id], "the old scope is one switch away")
    }

    func testNewSearchOperators() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15)))
        func at(_ day: Int, _ hour: Int = 12) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let board = ClipboardPinboard(name: "Work")
        var pinned = ClipboardEntry(title: "Pinned", text: "alpha", lastCopiedAt: at(28), items: [])
        pinned.pinboardIDs = [board.id]
        let today = ClipboardEntry(title: "Today", text: "beta", lastCopiedAt: at(29, 9), items: [])
        let lastWeek = ClipboardEntry(title: "Old", text: "gamma", lastCopiedAt: at(20), items: [])
        let picture = ClipboardEntry(title: "Image", kind: .image, lastCopiedAt: at(29), items: [])
        let all = [pinned, today, lastWeek, picture]
        func matches(_ query: String) -> [String] {
            let search = ClipboardSearchQuery(query, boards: [board], now: now, calendar: calendar)
            return all.filter { search.matches($0, boards: [board]) }.map(\.title)
        }
        XCTAssertEqual(matches("is:pinned"), ["Pinned"])
        XCTAssertEqual(matches("is:unpinned"), ["Today", "Old", "Image"])
        XCTAssertEqual(matches("-is:pinned type:text"), ["Today", "Old"])
        XCTAssertEqual(matches("pinboard:work"), matches("board:work"))
        XCTAssertEqual(matches("on:yesterday"), ["Pinned"])
        XCTAssertEqual(matches("on:2026-10-29"), ["Today", "Image"])
        XCTAssertEqual(matches("on:today"), ["Today", "Image"])
        XCTAssertEqual(matches("after:7d"), ["Pinned", "Today", "Image"])
        XCTAssertEqual(matches("before:1w"), ["Old"])
        XCTAssertEqual(matches("type:images"), ["Image"])
        XCTAssertEqual(matches("type:snippets beta"), ["Today"])
        XCTAssertEqual(matches("on:someday"), [], "an unreadable date matches nothing")

        XCTAssertEqual(ClipboardSearchQuery.filterTokens(in: "is:pinned on:today type:images after:2w notes"),
                       ["is:pinned", "on:today", "type:images", "after:2w"])
        XCTAssertEqual(ClipboardSearchQuery.filterTokens(in: "is:pin on:to"), [], "half-typed tokens stay text")
        XCTAssertEqual(ClipboardSearchQuery.chipFilters(in: "pinboard:Work ").map(\.field), ["board"])
        XCTAssertTrue(ClipboardSearchQuery("type:image -draft").hasContentTerms)
        XCTAssertFalse(ClipboardSearchQuery("type:image from:Safari is:pinned").hasContentTerms)
    }

    func testShowInOffersEveryListAnItemLivesIn() {
        let work = ClipboardPinboard(name: "Work"), home = ClipboardPinboard(name: "Home")
        var item = ClipboardEntry(title: "Snippet", text: "x", items: [])
        item.pinboardIDs = [home.id]
        let boards = [work, home]
        XCTAssertEqual(ClipboardPanelState.showInTargets(for: item, viewing: nil, searching: true, boards: boards), [nil, home.id])
        XCTAssertEqual(ClipboardPanelState.showInTargets(for: item, viewing: nil, searching: false, boards: boards), [home.id])
        XCTAssertEqual(ClipboardPanelState.showInTargets(for: item, viewing: home.id, searching: false, boards: boards), [nil])
        XCTAssertEqual(ClipboardPanelState.home(of: item, viewing: nil, searching: false, boards: boards), home.id)
        XCTAssertNil(ClipboardPanelState.home(of: item, viewing: home.id, searching: false, boards: boards))
        XCTAssertNil(ClipboardPanelState.home(of: ClipboardEntry(title: "Loose", items: []), viewing: work.id, searching: true, boards: boards))
    }

    // MARK: - Retention (Paste parity)

    func testShorterRetentionAndStorageLimitsAskAndUndo() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = makeHarness(now: { clock })
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        store.settings.retentionDays = 0
        let board = store.createBoard(name: "Keep")
        let pinned = try XCTUnwrap(store.createTextItem("pinned and old"))
        store.pin(entryID: pinned.id, boardID: board.id)
        let old = try XCTUnwrap(store.createTextItem("old"))
        clock.addTimeInterval(40 * 86_400)
        let recent = try XCTUnwrap(store.createTextItem(String(repeating: "recent ", count: 1_000)))

        XCTAssertEqual(store.itemsRemoved(byRetentionDays: 365), 0)
        XCTAssertEqual(store.itemsRemoved(byRetentionDays: 30), 1, "only the unpinned item past the new limit")
        store.applyRetentionDays(30)
        XCTAssertEqual(store.settings.retentionDays, 30)
        XCTAssertEqual(Set(store.entries.map(\.id)), [pinned.id, recent.id])
        // A change made after the limit is not rolled back by its Undo.
        store.settings.ignoredApps.append("com.example.added-later")
        XCTAssertEqual(store.undoLastDeletion().entryIDs, [old.id], "unlike Paste, AOM can undo it")
        XCTAssertEqual(store.settings.retentionDays, 0, "Undo restores the previous limit too")
        XCTAssertTrue(store.settings.excludes("com.example.added-later"), "…and only that limit")

        // 7,000 bytes of history against the smallest storage limit (1 KB).
        XCTAssertGreaterThan(store.itemsRemoved(byMaxBytes: 1_024), 0)
        XCTAssertEqual(store.itemsRemoved(byMaxBytes: 1_024 * 1_024 * 1_024), 0)
        store.applyMaxBytes(1_024)
        XCTAssertEqual(store.settings.maxBytes, 1_024)
        XCTAssertFalse(store.entries.contains { $0.id == recent.id })
        XCTAssertTrue(store.entries.contains { $0.id == pinned.id }, "pinned items are exempt")
        XCTAssertTrue(store.undoLastDeletion().entryIDs.contains(recent.id))
        XCTAssertEqual(store.settings.maxBytes, 200 * 1_024 * 1_024)
        XCTAssertTrue(store.entries.contains { $0.id == recent.id }, "not trimmed again by the restored limit")
        let plan = ClipboardStore.removalPlan(store.entries, limits: ClipboardStore.Settings(retentionDays: 0, maxEntries: 1), now: clock)
        XCTAssertFalse(plan.contains(pinned.id), "pinned items are never removed by limits")
        XCTAssertEqual(plan.count, store.entries.filter { $0.pinboardIDs.isEmpty }.count - 1)
    }

    // MARK: - P03 · link cards

    func testLinkCardsFetchOnlySafeLinks() {
        XCTAssertNotNil(ClipboardLinkPolicy.fetchableURL("https://example.com/article"))
        XCTAssertNotNil(ClipboardLinkPolicy.fetchableURL("http://news.example.org/a?page=2"))
        for refused in ["https://example.invalid/?token=FAKEONLY0123456789", "https://alice:pw@example.com/",
                        "mailto:someone@example.com", "ftp://example.com/file", "https://localhost:8080/admin",
                        "http://192.168.1.1/", "http://10.0.0.8/x", "http://172.20.1.1/", "http://[::1]/", "http://router/",
                        "https://printer.local/", "https://a.example.com/x?X-Amz-Signature=abcdef0123456789",
                        "https://example.com/has space"] {
            XCTAssertNil(ClipboardLinkPolicy.fetchableURL(refused), refused)
        }
    }

    func testLinkCardParserReadsOpenGraphAndFallbacks() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/posts/1"))
        let html = """
        <html><head><title>Fallback title</title>
        <meta property="og:title" content="Paste &amp; AOM &#8212; parity">
        <meta property='og:site_name' content='Example News'>
        <meta content="/images/card.png" property="og:image">
        </head><body><meta property="og:title" content="ignored"></body></html>
        """
        let card = ClipboardLinkMetadataParser.parse(html: html, baseURL: base)
        XCTAssertEqual(card.title, "Paste & AOM — parity")
        XCTAssertEqual(card.siteName, "Example News")
        XCTAssertEqual(card.imageURL?.absoluteString, "https://example.com/images/card.png")

        let plain = ClipboardLinkMetadataParser.parse(html: "<head><title>\n  Just   a title </title><link rel=\"apple-touch-icon\" href=\"https://cdn.example.com/icon.png\"></head>", baseURL: base)
        XCTAssertEqual(plain.title, "Just a title")
        XCTAssertEqual(plain.imageURL?.absoluteString, "https://cdn.example.com/icon.png")
        XCTAssertTrue(ClipboardLinkMetadataParser.parse(html: "<p>no head</p>", baseURL: base).isEmpty)
        XCTAssertNil(ClipboardLinkMetadataParser.parse(html: "<meta property=\"og:image\" content=\"javascript:alert(1)\">", baseURL: base).imageURL)
    }

    func testLinkCardsNeverTouchTheNetworkWhileOffAndAskOncePerPage() async throws {
        let metadata = ClipboardLinkMetadataStore()
        let requests = Calls()
        let picture = png(twoWordImage("A", "B"))
        metadata.loader = { request, _ in
            let url = try XCTUnwrap(request.url)
            requests.record(url.absoluteString)
            if url.path.hasSuffix(".png") {
                return (picture, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
            }
            if url.path == "/missing" {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!)
            }
            let html = #"<head><meta property="og:title" content="Card title"><meta property="og:image" content="https://example.com/card.png"></head>"#
            return (Data(html.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                     headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
        }
        let page = try XCTUnwrap(URL(string: "https://example.com/article"))

        let off = await metadata.card(for: page, enabled: false)
        XCTAssertNil(off)
        XCTAssertTrue(requests.all.isEmpty, "with the switches off nothing is requested")
        let suite = "AOM333-prefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ClipboardPreferences(defaults: defaults).linkCards, "link cards are off by default")

        let loadedCard = await metadata.card(for: page, enabled: true)
        let card = try XCTUnwrap(loadedCard)
        XCTAssertEqual(card.title, "Card title")
        _ = await metadata.card(for: page, enabled: true)
        XCTAssertEqual(requests.all, ["https://example.com/article"], "one request per page and session")
        let picturePreview = await metadata.image(for: card, enabled: true)
        let image = try XCTUnwrap(picturePreview)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 480)
        let switchedOff = await metadata.image(for: card, enabled: false)
        XCTAssertNil(switchedOff, "the image follows the same switches")

        let missing = try XCTUnwrap(URL(string: "https://example.com/missing"))
        let first = await metadata.card(for: missing, enabled: true)
        let second = await metadata.card(for: missing, enabled: true)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(requests.all.filter { $0.hasSuffix("/missing") }.count, 1, "a failure is remembered")

        let tokenLink = try XCTUnwrap(URL(string: "https://example.com/login?token=FAKEONLY0123456789"))
        let refused = await metadata.card(for: tokenLink, enabled: true)
        XCTAssertNil(refused)
        XCTAssertFalse(requests.all.contains(tokenLink.absoluteString), "a one-time link is never fetched")
        metadata.removeAll()
        XCTAssertNil(metadata.cachedCard(for: page))
    }

    // MARK: - P04 · OCR boxes, highlights and regions

    func testImageTextGeometry() {
        let lines = ClipboardImageText.normalizedLines([("Total 42", CGRect(x: 100, y: 50, width: 400, height: 40)),
                                                        ("   ", CGRect(x: 0, y: 0, width: 10, height: 10))],
                                                       imageSize: CGSize(width: 1_000, height: 500))
        XCTAssertEqual(lines.map(\.text), ["Total 42"], "empty lines are dropped")
        let box = lines[0].box
        for (value, expected) in [(box.minX, 0.1), (box.minY, 0.1), (box.width, 0.4), (box.height, 0.08)] {
            XCTAssertEqual(value, expected, accuracy: 1e-9)
        }
        let match = ClipboardImageText.matchBoxes(in: lines, terms: ["42"])
        XCTAssertEqual(match.count, 1)
        XCTAssertEqual(match[0].minX, 0.1 + 0.4 * 6 / 8, accuracy: 0.0001, "the match covers its share of the line")
        XCTAssertEqual(match[0].width, 0.4 * 2 / 8, accuracy: 0.0001)
        XCTAssertTrue(ClipboardImageText.matchBoxes(in: lines, terms: ["missing"]).isEmpty)
        XCTAssertEqual(ClipboardImageText.text(in: CGRect(x: 0, y: 0, width: 0.6, height: 0.5), lines: lines), "Total 42")
        XCTAssertEqual(ClipboardImageText.text(in: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2), lines: lines), "")

        XCTAssertEqual(ClipboardImageText.pixelRect(for: CGRect(x: 0.5, y: -0.2, width: 0.9, height: 0.5), imageWidth: 200, imageHeight: 100),
                       CGRect(x: 100, y: 0, width: 100, height: 30), "clamped to the image")
        XCTAssertNil(ClipboardImageText.pixelRect(for: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001), imageWidth: 200, imageHeight: 100))
        let fitted = ClipboardImageText.fittedRect(imageSize: CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(fitted, CGRect(x: 0, y: 100, width: 400, height: 200))
        let unit = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let view = ClipboardImageText.viewRect(for: unit, in: fitted)
        XCTAssertEqual(ClipboardImageText.unitRect(for: view, in: fitted), unit)
    }

    func testIndexingKeepsLineBoxesAndRegionsReadOnlyTheirText() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let store = harness.store
        await store.ready()
        let data = png(twoWordImage("HARBOR", "PELICAN"))
        harness.board.clearContents()
        XCTAssertTrue(harness.board.setData(data, forType: .png))
        store.poll(sourceName: "Test", sourceBundleID: "test.aom333")
        await store.finishPendingCaptures()
        var entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.kind, .image)
        for _ in 0..<300 where store.entries.first?.recognizedLines == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        entry = try XCTUnwrap(store.entries.first)
        let lines = try XCTUnwrap(entry.recognizedLines, "indexing stores line boxes with the text")
        XCTAssertTrue(entry.recognizedText?.localizedCaseInsensitiveContains("pelican") == true)
        let pelican = ClipboardImageText.matchBoxes(in: lines, terms: ["pelican"])
        XCTAssertFalse(pelican.isEmpty)
        XCTAssertGreaterThan(pelican[0].midX, 0.5, "the match is boxed where the word is")

        let right = await ClipboardImageText.recognizeRegion(imageData: data, region: CGRect(x: 0.55, y: 0, width: 0.45, height: 1),
                                                             storedLines: lines)
        XCTAssertTrue(right.localizedCaseInsensitiveContains("pelican"), right)
        XCTAssertFalse(right.localizedCaseInsensitiveContains("harbor"), right)

        // Region copies go to the (private) pasteboard without a new item.
        let count = store.entries.count
        try store.copyDerivedText(right)
        XCTAssertEqual(harness.board.string(forType: .string), right.trimmingCharacters(in: .whitespacesAndNewlines))
        let crop = try XCTUnwrap(ClipboardImageText.croppedImage(imageData: data, region: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(crop.width, 700)
        try store.copyDerivedImage(crop)
        XCTAssertNotNil(harness.board.data(forType: .png))
        store.poll(sourceName: "Test", sourceBundleID: "test.aom333")
        await store.finishPendingCaptures()
        XCTAssertEqual(store.entries.count, count, "derived copies are not recorded as history")

        await store.flush()
        let reopenedBoard = NSPasteboard(name: .init(harness.token + "-2"))
        defer { reopenedBoard.releaseGlobally() }
        let reopened = ClipboardStore(directory: harness.directory, pasteboard: reopenedBoard, defaults: harness.defaults)
        await reopened.ready()
        XCTAssertEqual(reopened.entries.first?.recognizedLines, lines, "line boxes are saved with the history")
    }

    func testImagesIndexedBeforeBoxesGetThemWhenPreviewed() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        var old = ClipboardEntry(title: "Image", kind: .image, sourceName: "Test", sourceBundleID: "test.aom333",
                                 items: [[NSPasteboard.PasteboardType.png.rawValue: png(twoWordImage("HARBOR", "PELICAN"))]])
        old.recognizedText = "HARBOR PELICAN"
        old.recognizedImageDigest = "indexed by 3.3.2"
        try writeArchive([old], to: harness.directory)
        await harness.store.ready()
        XCTAssertNil(harness.store.entries.first?.recognizedLines, "a 3.3.2 archive has no boxes")
        let lines = await harness.store.recognizedLayout(for: old.id)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(harness.store.entries.first?.recognizedLines, lines, "kept once read")
        let again = await harness.store.recognizedLayout(for: old.id)
        XCTAssertEqual(again, lines)
    }
}
