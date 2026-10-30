import AppKit
import XCTest
@testable import AllOfMacOS

/// N333-01 (re-audit 2026-10-30): credentials written with quoted keys —
/// `{"password": "…"}`, `'token': '…'` — reached MCP clients through
/// read_item and content search, and the final reply check let them pass,
/// because the inline pattern wanted `:` or `=` right after the name.
///
/// Every value is synthetic and none has a provider prefix, so only the key
/// name gives it away. Each store has its own temporary directory, named
/// pasteboard and defaults suite; nothing reads the user's clipboard,
/// Accessibility or the network. Replies are checked as the bytes the
/// socket server would send.
@MainActor
final class N333SecretExposureTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let token: String
        let directory: URL
        let board: NSPasteboard
        let defaults: UserDefaults
        let store: ClipboardStore
    }

    private func makeHarness() -> Harness {
        let token = "AOMN333-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        let board = NSPasteboard(name: .init(token))
        let defaults = UserDefaults(suiteName: token)!
        return Harness(token: token, directory: directory, board: board, defaults: defaults,
                       store: ClipboardStore(directory: directory, pasteboard: board, defaults: defaults))
    }

    private func cleanUp(_ harness: Harness) {
        harness.board.releaseGlobally()
        harness.defaults.removePersistentDomain(forName: harness.token)
        try? FileManager.default.removeItem(at: harness.directory)
    }

    /// The store's archive format, written before the store opens it, for
    /// representations the store API cannot create (UTF-16, HTML).
    private struct Archive: Codable {
        var version = 1
        var entries: [ClipboardEntry]
        var boards: [ClipboardPinboard]
    }

    private func writeArchive(_ entries: [ClipboardEntry], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(entries: entries, boards: []))
            .write(to: directory.appendingPathComponent("history-v1.json"))
    }

    /// One tools/call through the production JSON-RPC handler, and the reply
    /// serialised as `ClipboardMCPServer.Connection.send` writes it.
    private func call(_ name: String, _ arguments: [String: Any],
                      store: ClipboardStore) throws -> (result: [String: Any], wire: String) {
        let response = try XCTUnwrap(ClipboardMCPHandler.handle(["jsonrpc": "2.0", "id": 333, "method": "tools/call",
                                                                 "params": ["name": name, "arguments": arguments]],
                                                                store: store))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
        return (result, String(decoding: data, as: UTF8.self))
    }

    /// read_item refuses the item, a content search does not find it, a
    /// listing and a delete preview show it hidden, copy_to_clipboard writes
    /// nothing, and no reply carries any of `values`.
    private func assertWithheld(_ entry: ClipboardEntry, values: [String], query: String, in harness: Harness,
                                _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = harness.store
        let id = entry.id.uuidString
        XCTAssertTrue(ClipboardMCPHandler.isSecret(entry), "\(name): classified as a secret", file: file, line: line)
        XCTAssertThrowsError(try ClipboardMCPHandler.call("read_item", ["id": id], store: store),
                             "\(name): read_item", file: file, line: line)
        let read = try call("read_item", ["id": id], store: store)
        XCTAssertEqual(read.result["isError"] as? Bool, true, "\(name): read_item", file: file, line: line)

        let search = try call("search", ["query": query], store: store)
        let found = try XCTUnwrap(search.result["structuredContent"] as? [String: Any], name, file: file, line: line)
        XCTAssertEqual(found["total"] as? Int, 0, "\(name): a content search does not find it", file: file, line: line)
        XCTAssertEqual((found["items"] as? [[String: Any]])?.count, 0, name, file: file, line: line)

        let listing = try call("search", ["query": "", "limit": 100], store: store)
        let items = try XCTUnwrap((listing.result["structuredContent"] as? [String: Any])?["items"] as? [[String: Any]],
                                  name, file: file, line: line)
        let listed = try XCTUnwrap(items.first { $0["id"] as? String == id }, "\(name): listed by metadata",
                                   file: file, line: line)
        XCTAssertEqual(listed["title"] as? String, "Hidden secret", name, file: file, line: line)
        XCTAssertEqual(listed["preview"] as? String, ClipboardSecretScanner.placeholder, name, file: file, line: line)

        let preview = try call("delete_item", ["id": id], store: store)
        XCTAssertTrue(store.entries.contains { $0.id == entry.id }, "\(name): a preview deletes nothing", file: file, line: line)

        let changeCount = harness.board.changeCount
        let copy = try call("copy_to_clipboard", ["id": id], store: store)
        XCTAssertEqual(copy.result["isError"] as? Bool, true, "\(name): copy_to_clipboard", file: file, line: line)
        XCTAssertEqual(harness.board.changeCount, changeCount, "\(name): nothing reached the pasteboard", file: file, line: line)

        for reply in [read.wire, search.wire, listing.wire, preview.wire, copy.wire] {
            for value in values {
                XCTAssertFalse(reply.contains(value), "\(name): \(value) left in a reply", file: file, line: line)
            }
        }
    }

    // MARK: - Text

    func testQuotedKeyCredentialsAreWithheldFromReadSearchAndCopy() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        let nested = """
            {
              "service": "billing",
              "environments": [
                {"name": "staging", "database": {"user": "app", "password": "n333-nested-delta"}},
                {"name": "production", "auth": {"accessToken": "n333-nested-echo", "expiresIn": 3600}}
              ]
            }
            """
        let fixtures: [(name: String, text: String, values: [String])] = [
            ("JSON with spaces", #"{"password": "n333-read-alpha"}"#, ["n333-read-alpha"]),
            ("compact JSON", #"{"password":"n333-read-bravo"}"#, ["n333-read-bravo"]),
            ("client secret", #"{"client_secret": "n333-search-charlie", "client_id": "fixture-app"}"#, ["n333-search-charlie"]),
            ("nested objects and arrays", nested, ["n333-nested-delta", "n333-nested-echo"]),
            ("quoted YAML", "'database':\n  'user': 'app'\n  'password': 'n333-yaml-foxtrot'\n", ["n333-yaml-foxtrot"]),
            ("double-quoted YAML", "\"region\": \"eu-west-1\"\n\"api_key\": \"n333-yaml-golf\"\n", ["n333-yaml-golf"]),
            ("TOML", "[server]\n\"secret\" = \"n333-toml-hotel\"\n", ["n333-toml-hotel"]),
            ("JSON inside a JSON string", #"{"body": "{\"refresh_token\": \"n333-escaped-india\"}"}"#, ["n333-escaped-india"]),
            // Only the key-by-key reading sees these three.
            ("escaped key name", #"{"pass\u0077ord": "n333-escape-juliet"}"#, ["n333-escape-juliet"]),
            ("escaped line break", #"{"notes": "Staging login\npassword: n333-newline-kilo"}"#, ["n333-newline-kilo"]),
            ("escaped slashes", #"{"callback": "https:\/\/svc:n333-url-lima@example.com\/hook"}"#, ["n333-url-lima"]),
            ("camelCase key", #"{"user": {"sessionToken": "n333-camel-mike"}}"#, ["n333-camel-mike"]),
            ("Python dictionary", #"{'user': 'svc', 'passphrase': 'n333-python-november'}"#, ["n333-python-november"]),
            ("typographic quotes", "“password”: “n333-smart-oscar”", ["n333-smart-oscar"]),
        ]
        for fixture in fixtures {
            let entry = try XCTUnwrap(harness.store.createTextItem(fixture.text), fixture.name)
            XCTAssertTrue(ClipboardMCPHandler.replyContainsSecret(["content": fixture.text]),
                          "\(fixture.name): the final reply check agrees")
            try assertWithheld(entry, values: fixture.values, query: fixture.values[0], in: harness, fixture.name)
        }
    }

    // MARK: - Other representations

    func testJSONInRichTextHTMLAndUTF16IsWithheld() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        let string = NSPasteboard.PasteboardType.string.rawValue
        let utf16 = "public.utf16-external-plain-text"
        let mailJSON = try XCTUnwrap(#"{"service": "mail", "smtp_password": "n333-utf16-papa"}"#.data(using: .utf16))
        let keyJSON = try XCTUnwrap(#"{"api_key": "n333-utf16-quebec"}"#.data(using: .utf16))
        let behindPlainText = ClipboardEntry.captured(
            items: [[string: Data("Mail settings 333U".utf8), utf16: mailJSON]],
            sourceName: "Fixture", sourceBundleID: "test.n333", at: Date())
        let utf16Only = ClipboardEntry.captured(items: [[utf16: keyJSON]], sourceName: "Fixture",
                                                sourceBundleID: "test.n333", at: Date())
        let html = ClipboardEntry.captured(
            items: [[string: Data("Invoice 333H".utf8), NSPasteboard.PasteboardType.html.rawValue:
                        Data(#"<pre>{&quot;client_secret&quot;: &quot;n333-html-romeo&quot;}</pre>"#.utf8)]],
            sourceName: "Fixture", sourceBundleID: "test.n333", at: Date())
        XCTAssertEqual(behindPlainText.text, "Mail settings 333U", "the plain text does not show the JSON")
        XCTAssertEqual(utf16Only.text, #"{"api_key": "n333-utf16-quebec"}"#, "UTF-16 is the only text")
        XCTAssertEqual(html.text, "Invoice 333H")
        try writeArchive([behindPlainText, utf16Only, html], to: harness.directory)
        await harness.store.ready()
        XCTAssertEqual(harness.store.entries.count, 3)

        // Rich text through the store API: plain words, the JSON only in RTF.
        let json = #"{"database": {"user": "app", "password": "n333-rtf-sierra"}}"#
        let styled = NSAttributedString(string: json, attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                                                                    .underlineStyle: NSUnderlineStyle.single.rawValue])
        let rtf = try styled.data(from: NSRange(location: 0, length: styled.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rich = try XCTUnwrap(harness.store.createTextItem("Quarterly notes 333R", rtfData: rtf))
        XCTAssertNotNil(rich.items.first?[NSPasteboard.PasteboardType.rtf.rawValue], "the store kept the rich text")
        XCTAssertEqual(rich.text, "Quarterly notes 333R")

        try assertWithheld(rich, values: ["n333-rtf-sierra"], query: "333R", in: harness, "RTF")
        try assertWithheld(behindPlainText, values: ["n333-utf16-papa"], query: "333U", in: harness, "UTF-16 behind plain text")
        try assertWithheld(utf16Only, values: ["n333-utf16-quebec"], query: "n333-utf16-quebec", in: harness, "UTF-16 only")
        try assertWithheld(html, values: ["n333-html-romeo"], query: "333H", in: harness, "HTML")
    }

    // MARK: - Long JSON

    /// Records first and the credential last, so it lies past the 64 KB
    /// mark and past read_item's 100,000-character excerpt.
    private func longJSON(records: Int, value: String) -> String {
        let rows = (0..<records).map { #"    {"id": \#($0), "name": "record \#($0)", "notes": "plain words with nothing to hide"}"# }
        return "{\n  \"records\": [\n" + rows.joined(separator: ",\n")
            + ",\n    {\"id\": \(records), \"credentials\": {\"username\": \"svc\", \"password\": \"\(value)\"}}\n  ]\n}\n"
    }

    func testLongJSONIsWithheldAtAnyLength() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        let parsed = longJSON(records: 2_000, value: "n333-long-tango")
        let patternsOnly = longJSON(records: 32_000, value: "n333-long-uniform")
        XCTAssertGreaterThan(parsed.utf16.count, 100_000)
        XCTAssertLessThan(parsed.utf8.count, ClipboardSecretScanner.structuredScanLimit, "read key by key as well")
        XCTAssertGreaterThan(patternsOnly.utf8.count, ClipboardSecretScanner.structuredScanLimit,
                             "too long to parse: the patterns alone find it")
        for (name, text, value) in [("JSON past 100 KB", parsed, "n333-long-tango"),
                                    ("JSON past the parse limit", patternsOnly, "n333-long-uniform")] {
            let entry = try XCTUnwrap(harness.store.createTextItem(text), name)
            XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: text), name)
            try assertWithheld(entry, values: [value], query: value, in: harness, name)
        }
    }

    // MARK: - Scanner rules

    func testJSONIsReadKeyByKey() {
        // Escapes hide these from the patterns; the parsed JSON does not.
        for text in [#"{"pass\u0077ord": "n333-rule-victor"}"#, #"{"notes": "line one\npassword=n333-rule-whiskey"}"#] {
            XCTAssertFalse(ClipboardSecretScanner.matchesPattern(text), text)
            XCTAssertTrue(ClipboardSecretScanner.containsStructuredSecret(text), text)
        }
        XCTAssertFalse(ClipboardSecretScanner.containsStructuredSecret("password: plain text, not JSON"))
        // Too deep to parse: left to the patterns, which still see the key.
        let deep = String(repeating: "[", count: 600) + #"{"password": "n333-rule-xray"}"# + String(repeating: "]", count: 600)
        XCTAssertFalse(ClipboardSecretScanner.containsStructuredSecret(deep))
        XCTAssertTrue(ClipboardSecretScanner.containsSecret(inText: deep))

        for key in ["password", "db_password", "DB_PASSWORD", "dbPassword", "dbpassword", "accessToken", "ACCESS_TOKEN",
                    "X-API-Key", "APIKey", "client_secret", "clientSecret", "basicAuth", "Authorization", "credentials",
                    "passphrase", "aws_secret_access_key", "pin", "otp"] {
            XCTAssertTrue(ClipboardSecretScanner.isCredentialKey(key), key)
        }
        for key in ["token_type", "tokenizer", "prompt_tokens", "secretName", "password_updated_at", "passwordPolicy",
                    "author", "oauth", "keyboard", "spinner", "bypass", "monkey", "name"] {
            XCTAssertFalse(ClipboardSecretScanner.isCredentialKey(key), key)
        }
        XCTAssertEqual(ClipboardSecretScanner.keyWords("accessToken"), ["access", "token"])
        XCTAssertEqual(ClipboardSecretScanner.keyWords("ACCESS_TOKEN"), ["access", "token"])
        XCTAssertEqual(ClipboardSecretScanner.keyWords("APIKey"), ["apikey"])
        XCTAssertEqual(ClipboardSecretScanner.keyWords("X-API-Key"), ["x", "api", "key"])

        for value in ["", "   ", "***", "••••", "<redacted>", "<your-token>", "[REDACTED]", "redacted", "null", "None", "n/a",
                      ClipboardSecretScanner.placeholder] {
            XCTAssertTrue(ClipboardSecretScanner.isPlaceholderValue(value), value)
        }
        for value in ["hunter2", "*** and more", "n333-rule-yankee", "nullable"] {
            XCTAssertFalse(ClipboardSecretScanner.isPlaceholderValue(value), value)
        }
    }

    // MARK: - Ordinary JSON (false-positive controls)

    func testOrdinaryJSONStaysReadableSearchableAndCopyable() async throws {
        let harness = makeHarness()
        defer { cleanUp(harness) }
        await harness.store.ready()
        let report = #"{"name": "Weekly report n333", "count": 3, "tags": ["alpha", "beta"], "nested": {"enabled": true, "note": "nothing to hide"}}"#
        // A model reply's usage counts, names that only look like credential
        // names, a schema, and values that only stand in for credentials.
        let lookalike = """
            {
              "id": "chatcmpl-n333-control",
              "object": "chat.completion",
              "usage": {"prompt_tokens": 9, "completion_tokens": 12, "total_tokens": 21},
              "tokenizer": "cl100k_base",
              "token_type": "Bearer",
              "secretName": "db-credentials-ref",
              "properties": {"password": {"type": "string", "format": "password", "minLength": 8}},
              "password": "",
              "api_key": null,
              "client_secret": "<redacted>",
              "secret": "***",
              "hasPassword": false
            }
            """
        var created: [ClipboardEntry] = []
        for (name, text) in [("plain JSON", report), ("look-alike JSON", lookalike)] {
            let entry = try XCTUnwrap(harness.store.createTextItem(text), name)
            created.append(entry)
            XCTAssertFalse(ClipboardMCPHandler.isSecret(entry), name)
            XCTAssertFalse(ClipboardMCPHandler.replyContainsSecret(["content": text]), name)
            let read = try call("read_item", ["id": entry.id.uuidString], store: harness.store)
            XCTAssertEqual(read.result["isError"] as? Bool, false, name)
            XCTAssertEqual((read.result["structuredContent"] as? [String: Any])?["content"] as? String, text, name)
        }

        let search = try call("search", ["query": "n333"], store: harness.store)
        let found = try XCTUnwrap(search.result["structuredContent"] as? [String: Any])
        XCTAssertEqual(found["total"] as? Int, 2, "both are found by content")

        let copy = try call("copy_to_clipboard", ["id": created[0].id.uuidString], store: harness.store)
        XCTAssertEqual(copy.result["isError"] as? Bool, false)
        XCTAssertEqual(harness.board.string(forType: .string), report, "copied to the test's own pasteboard")
    }
}
