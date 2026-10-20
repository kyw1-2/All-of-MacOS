import AppKit
import XCTest
@testable import AllOfMacOS

/// Intelligent Clipboard, the AOM MCP server and shelf performance helpers
/// (Paste 7.0.2 parity: PastePicks, Paste MCP).
@MainActor
final class ClipboardIntelligenceMCPTests: XCTestCase {

    // MARK: - Classification

    func testItemClassifierRecognisesPasteCategories() {
        let cases: [(String, ClipboardItemClass)] = [
            ("https://example.com/path", .link),
            ("someone@example.com", .email),
            ("+82 10-1234-5678", .phone),
            ("sk-abcdefghijklmnopqrstuvwxyz123456", .secret),
            ("ghp_abcdefghijklmnopqrstuvwxyz0123456789", .secret),
            ("password: hunter2!", .secret),
            ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", .secret),
            ("1Z999AA10123456784", .trackingNumber),
            ("$1,299.00", .money),
            ("~/Projects/app/main.swift", .path),
            ("let x = foo(); return x == 1", .code),
            ("git status --short", .code),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ClipboardItemClassifier.classify(text: text), expected, text)
        }
        XCTAssertEqual(ClipboardItemClassifier.classify(text: "A calm place for everything you copy."), .unclassified)
    }

    // MARK: - Destination kinds

    func testDestinationKindFromAccessibilityAndAppCategory() {
        XCTAssertEqual(ClipboardDestinationReader.kind(role: "AXTextField", subrole: "AXSecureTextField", hint: "", bundleID: nil), .password)
        XCTAssertEqual(ClipboardDestinationReader.kind(role: "AXTextField", subrole: "AXSearchField", hint: "", bundleID: nil), .search)
        XCTAssertEqual(ClipboardDestinationReader.kind(role: "AXTextArea", subrole: "", hint: "", bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(ClipboardDestinationReader.kind(role: "AXTextArea", subrole: "", hint: "", bundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(ClipboardDestinationReader.kind(role: "AXTextField", subrole: "", hint: "", bundleID: "com.example"), .text)
        XCTAssertEqual(ClipboardDestinationReader.category("com.tinyspeck.slackmacgap"), .chat)
        XCTAssertNil(ClipboardDestinationReader.category("com.example.unknown"))
    }

    // MARK: - Ranking

    private func entry(_ text: String, age: TimeInterval = 60, app: String? = "com.apple.Safari") -> ClipboardEntry {
        ClipboardEntry.captured(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]],
                                sourceName: "Safari", sourceBundleID: app, at: Date().addingTimeInterval(-age))
    }

    func testRankerPrefersMatchingClassAndHistoryAndHidesSecrets() {
        let email = entry("someone@example.com", age: 7_200)
        let secret = entry("sk-abcdefghijklmnopqrstuvwxyz123456", age: 30)
        let prose = entry("A calm place for everything you copy.", age: 10)
        let command = entry("swift build -c release -j 2", age: 3_600)
        let entries = [prose, secret, command, email]
        let classes: (ClipboardEntry) -> ClipboardItemClass = { ClipboardItemClassifier.classify($0) }

        let emailField = ClipboardDestinationContext(bundleID: "com.apple.mail", kind: .text, fieldHint: "email address")
        XCTAssertEqual(ClipboardSuggestionRanker.rank(entries, context: emailField, events: [], classes: classes).first, email.id)

        let terminal = ClipboardDestinationContext(bundleID: "com.apple.Terminal", kind: .terminal)
        let terminalPicks = ClipboardSuggestionRanker.rank(entries, context: terminal, events: [], classes: classes)
        XCTAssertEqual(terminalPicks.first, command.id)
        XCTAssertFalse(terminalPicks.contains(secret.id), "secrets never suggested outside password fields")

        let password = ClipboardDestinationContext(bundleID: "com.apple.Safari", kind: .password, isSecureInput: true)
        XCTAssertEqual(ClipboardSuggestionRanker.rank(entries, context: password, events: [], classes: classes), [secret.id])

        // History: the prose item was pasted into Notes before → suggested there.
        let notes = ClipboardDestinationContext(bundleID: "com.apple.Notes", kind: .text)
        let events = (0..<3).map { _ in
            ClipboardPasteEvent(entryID: prose.id, itemClass: .unclassified, sourceBundleID: nil,
                                destinationBundleID: "com.apple.Notes", destinationKind: .text, date: Date())
        }
        XCTAssertEqual(ClipboardSuggestionRanker.rank(entries, context: notes, events: events, classes: classes).first, prose.id)
        XCTAssertTrue(ClipboardSuggestionRanker.rank(entries, context: .init(), events: [], classes: classes).isEmpty)
    }

    func testSuggestionsArePromotedOnlyInUnfilteredHistory() {
        let a = entry("one"), b = entry("two"), c = entry("three")
        XCTAssertEqual(ClipboardPanelState.promoting([c.id], in: [a, b, c]).map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(ClipboardPanelState.promoting([UUID()], in: [a, b]).map(\.id), [a.id, b.id])
    }

    func testPasteLogPersistsAndCaps() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aom-pastelog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ClipboardPasteLog(directory: dir)
        let event = ClipboardPasteEvent(entryID: UUID(), itemClass: .link, sourceBundleID: "a", destinationBundleID: "b",
                                        destinationKind: .search, date: Date())
        log.record(event)
        await log.flush()
        XCTAssertEqual(ClipboardPasteLog(directory: dir).events, [event])
        log.erase()
        await log.flush()
        XCTAssertTrue(ClipboardPasteLog(directory: dir).events.isEmpty)
    }

    // MARK: - Shelf geometry (scroll performance)

    func testVisibleRangeArithmetic() {
        // 232 pt cards, 24 pt gaps, 24 pt inset, 1000 pt viewport.
        XCTAssertEqual(ClipboardShelfGeometry.visibleRange(offset: 0, viewportWidth: 1000, pitch: 256, side: 232, inset: 24, count: 20), 0..<4)
        XCTAssertEqual(ClipboardShelfGeometry.visibleRange(offset: 300, viewportWidth: 1000, pitch: 256, side: 232, inset: 24, count: 20), 1..<5)
        XCTAssertEqual(ClipboardShelfGeometry.visibleRange(offset: 0, viewportWidth: 1000, pitch: 256, side: 232, inset: 24, count: 2), 0..<2)
        XCTAssertEqual(ClipboardShelfGeometry.visibleRange(offset: 0, viewportWidth: 1000, pitch: 256, side: 232, inset: 24, count: 0), 0..<0)
    }

    func testResultsAreMemoisedPerStoreRevision() async {
        let store = ClipboardStore()
        await store.ready()
        _ = store.createTextItem("alpha")
        let state = ClipboardPanelState()
        let first = state.results(in: store)
        XCTAssertEqual(first.count, 1)
        _ = store.createTextItem("beta")
        XCTAssertEqual(state.results(in: store).count, 2, "a store change invalidates the cache")
        state.query = "beta"
        XCTAssertEqual(state.results(in: store).map(\.text), ["beta"])
    }

    // MARK: - MCP

    private func call(_ name: String, _ arguments: [String: Any] = [:], store: ClipboardStore) -> [String: Any] {
        let response = ClipboardMCPHandler.handle(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                   "params": ["name": name, "arguments": arguments]], store: store)
        return (response?["result"] as? [String: Any]) ?? [:]
    }

    func testMCPProtocolAndTools() async throws {
        let store = ClipboardStore()
        await store.ready()
        let initialize = try XCTUnwrap(ClipboardMCPHandler.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                                   "params": ["protocolVersion": "2025-06-18"]], store: store))
        let initResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(initResult["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(ClipboardMCPHandler.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], store: store))
        let list = try XCTUnwrap(ClipboardMCPHandler.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], store: store))
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(Set(names), ["search", "read_item", "create_item", "update_item", "delete_item", "copy_to_clipboard",
                                    "list_pinboards", "create_pinboard", "rename_pinboard", "delete_pinboard",
                                    "add_item_to_pinboard", "remove_item_from_pinboard", "get_suggestions"])

        // create → search → read
        let created = try XCTUnwrap(call("create_item", ["content": "Meeting at 10:30"], store: store)["structuredContent"] as? [String: Any])
        let id = try XCTUnwrap(created["id"] as? String)
        let search = try XCTUnwrap(call("search", ["query": "meeting"], store: store)["structuredContent"] as? [String: Any])
        XCTAssertEqual((search["items"] as? [[String: Any]])?.first?["id"] as? String, id)
        let read = try XCTUnwrap(call("read_item", ["id": id], store: store)["structuredContent"] as? [String: Any])
        XCTAssertEqual(read["content"] as? String, "Meeting at 10:30")

        // pinboards
        let board = try XCTUnwrap(call("create_pinboard", ["name": "Work", "color": "pink"], store: store)["structuredContent"] as? [String: Any])
        let boardID = try XCTUnwrap(board["id"] as? String)
        _ = call("add_item_to_pinboard", ["id": id, "pinboard_id": boardID], store: store)
        XCTAssertEqual(store.boards.first?.color, "pink")
        XCTAssertTrue(store.entries.first { $0.id.uuidString == id }?.pinboardIDs.contains(UUID(uuidString: boardID)!) == true)

        // secrets are hidden
        _ = store.createTextItem("sk-abcdefghijklmnopqrstuvwxyz123456")
        let secretSearch = try XCTUnwrap(call("search", ["query": "sk-"], store: store)["structuredContent"] as? [String: Any])
        let secret = try XCTUnwrap((secretSearch["items"] as? [[String: Any]])?.first)
        XCTAssertFalse((secret["preview"] as? String ?? "").contains("abcdef"))
        XCTAssertEqual(call("read_item", ["id": secret["id"] as! String], store: store)["isError"] as? Bool, true)
        XCTAssertEqual(call("copy_to_clipboard", ["id": secret["id"] as! String], store: store)["isError"] as? Bool, true)

        // two-step delete
        let preview = try XCTUnwrap(call("delete_item", ["id": id], store: store)["structuredContent"] as? [String: Any])
        XCTAssertNotNil(preview["message"])
        XCTAssertTrue(store.entries.contains { $0.id.uuidString == id })
        _ = call("delete_item", ["id": id, "confirm": true], store: store)
        XCTAssertFalse(store.entries.contains { $0.id.uuidString == id })
        XCTAssertEqual(call("read_item", ["id": UUID().uuidString], store: store)["isError"] as? Bool, true)
    }

    func testMCPTokensAreHashedAndRevocable() throws {
        let settings = ClipboardMCPSettings(defaults: UserDefaults(suiteName: "AOMMCPTest.\(UUID())")!)
        let token = try settings.connect(name: "Codex", client: "Codex")
        XCTAssertTrue(token.hasPrefix("aom_"))
        XCTAssertEqual(settings.tools.count, 1)
        XCTAssertNotEqual(settings.tools[0].tokenHash, token, "only a hash is stored")
        XCTAssertEqual(settings.tool(forToken: token)?.name, "Codex")
        XCTAssertNil(settings.tool(forToken: token + "x"))
        let snippet = ClipboardMCPSettings.instructions(for: .claudeCode, token: token).snippet
        XCTAssertTrue(snippet.contains("--mcp") && snippet.contains("AOM_MCP_TOKEN=\(token)"))
        settings.disconnect(settings.tools[0].id)
        XCTAssertNil(settings.tool(forToken: token))
    }

    /// F-07: a CSPRNG failure must not mint the fixed all-zero token, and must
    /// not leave a connected tool behind.
    func testMCPConnectFailsClosedWhenRandomnessIsUnavailable() throws {
        let suite = "AOMMCPTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardMCPSettings(defaults: defaults)

        XCTAssertThrowsError(try settings.connect(name: "Bad", client: "Custom Tool", randomBytes: { _ in nil })) { error in
            XCTAssertEqual(error as? ClipboardMCPSettings.TokenError, .randomnessUnavailable)
        }
        XCTAssertTrue(settings.tools.isEmpty, "a failed RNG must not connect a tool")

        let token = try settings.connect(name: "Good", client: "Custom Tool", randomBytes: { count in
            [UInt8](repeating: 0xA5, count: count)
        })
        XCTAssertTrue(token.hasPrefix("aom_"))
        XCTAssertEqual(settings.tools.count, 1)
        XCTAssertEqual(settings.tool(forToken: token)?.name, "Good")
    }

    /// macOS 26 uses local OCR + text inference; image attachments stay 27+.
    func testDestinationWindowModelRequiresSupportedOnDeviceModel() {
        if #unavailable(macOS 26.0) {
            XCTAssertFalse(ClipboardIntelligence.destinationModelAvailable)
        }
        if ClipboardIntelligence.destinationModelAvailable {
            XCTAssertTrue(ClipboardIntelligence.modelAvailable,
                          "Destination refinement requires an available on-device model")
        }
    }
}
