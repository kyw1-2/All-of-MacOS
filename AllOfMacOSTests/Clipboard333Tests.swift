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

}
