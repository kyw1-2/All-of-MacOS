import XCTest
@testable import AllOfMacOS

/// 7.2.1: Ask AI's read-only local tools and the local router started on
/// demand. The whole loop was checked live (Haiku → DeepSeek through
/// claude-code-proxy found the Oracle SSH alias in the wiki and ~/.ssh/config).
final class AOM721AIToolTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AOM721Home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents/llm-wiki/01-Architecture"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions/2026/11/21"), withIntermediateDirectories: true)
        try "# Standby\nAlways use the `ssh oracle` host alias, which tunnels over WSS/443.\nUnrelated line\n"
            .write(to: home.appendingPathComponent(".agents/llm-wiki/01-Architecture/MacBook-Standby.md"), atomically: true, encoding: .utf8)
        try "Host oracle\n  HostName 127.0.0.1\n  ProxyCommand websocat ...\n"
            .write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try "-----BEGIN OPENSSH PRIVATE KEY-----\n".write(to: home.appendingPathComponent(".ssh/id_ed25519"), atomically: true, encoding: .utf8)
        try #"{"type":"message","text":"오라클 서버는 ssh oracle 로 접속"}"#
            .write(to: home.appendingPathComponent(".codex/sessions/2026/11/21/rollout.jsonl"), atomically: true, encoding: .utf8)
        try "API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456\nPORT=8082\n".write(to: home.appendingPathComponent("proxy.env"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: search_records

    func testSearchFindsTheWikiAndCodexLinesNewestFirst() {
        let result = AOMAILocalTools.search("ssh oracle", sources: [.wiki, .codex_sessions], home: home)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("~/.agents/llm-wiki/01-Architecture/MacBook-Standby.md:2"), result.text)
        XCTAssertTrue(result.text.contains("오라클 서버는 ssh oracle"), "Codex's \\u escapes come back as Korean: \(result.text)")
        XCTAssertTrue(result.summary.hasPrefix("Searched records for “ssh oracle”"))
    }

    func testSearchFallsBackToTheClosestLines() {
        let result = AOMAILocalTools.search("oracle tailscale", sources: [.wiki], home: home)
        XCTAssertTrue(result.text.contains("No line has every word"), result.text)
        XCTAssertTrue(result.text.contains("MacBook-Standby.md"))
        XCTAssertTrue(AOMAILocalTools.search("x", sources: [.wiki], home: home).isError)
    }

    func testMatchesAndSnippets() {
        let text = "one\nThe Oracle box: ssh oracle\nssh elsewhere\n"
        let found = AOMAILocalTools.matches(in: text, terms: ["ssh", "oracle"], limit: 3)
        XCTAssertEqual(found.full.map(\.line), [2])
        let closest = AOMAILocalTools.matches(in: "one\nssh elsewhere\nmore oracle\n", terms: ["ssh", "oracle"], limit: 3)
        XCTAssertTrue(closest.full.isEmpty)
        XCTAssertEqual(closest.partial.map(\.line).sorted(), [2, 3], "with no full line, each word's lines are the closest")
        XCTAssertTrue(AOMAILocalTools.matches(in: "nothing here", terms: ["oracle"], limit: 3).full.isEmpty)
        XCTAssertEqual(AOMAILocalTools.unescapeUnicode(#"오라클"#), "오라클")
        let long = String(repeating: "a", count: 500) + " oracle " + String(repeating: "b", count: 500)
        let cut = AOMAILocalTools.snippet(long, around: 501)
        XCTAssertTrue(cut.hasPrefix("…") && cut.hasSuffix("…") && cut.contains("oracle"))
    }

    func testSecretsAreHiddenInResults() {
        XCTAssertFalse(AOMAILocalTools.redact("key sk-abcdefghijklmnopqrstuvwxyz123456 here").contains("sk-abc"))
        XCTAssertEqual(AOMAILocalTools.redact("ssh oracle"), "ssh oracle")
        let env = AOMAILocalTools.readFile("~/proxy.env", start: 1, count: 10, home: home)
        XCTAssertTrue(env.text.contains("API_KEY=[hidden]"), env.text)
        XCTAssertTrue(env.text.contains("PORT=[hidden]"), ".env values are all hidden")
    }

    // MARK: Files

    func testKeysAndCredentialFilesAreNeverRead() {
        let key = AOMAILocalTools.readFile("~/.ssh/id_ed25519", start: 1, count: 10, home: home)
        XCTAssertTrue(key.isError)
        XCTAssertFalse(key.text.contains("BEGIN"))
        let config = AOMAILocalTools.readFile("~/.ssh/config", start: 1, count: 10, home: home)
        XCTAssertFalse(config.isError)
        XCTAssertTrue(config.text.contains("2\t  HostName 127.0.0.1"), config.text)
        XCTAssertNotNil(AOMAILocalTools.refusal(for: home.appendingPathComponent(".aws/credentials").path, home: home))
        XCTAssertNotNil(AOMAILocalTools.refusal(for: home.appendingPathComponent("Documents/server.pem").path, home: home))
        XCTAssertNotNil(AOMAILocalTools.refusal(for: "/private/var/db/secret", home: home))
        XCTAssertNil(AOMAILocalTools.refusal(for: home.appendingPathComponent(".ssh/id_ed25519.pub").path, home: home))
        XCTAssertNil(AOMAILocalTools.refusal(for: "/etc/hosts", home: home))
    }

    func testReadWindowAndListing() {
        let lines = (1...500).map { "line \($0)" }.joined(separator: "\n")
        try? lines.write(to: home.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let window = AOMAILocalTools.readFile("~/big.txt", start: 450, count: 1_000, home: home)
        XCTAssertTrue(window.text.contains("450\tline 450"))
        XCTAssertTrue(window.text.contains("500\tline 500"))
        let first = AOMAILocalTools.readFile("~/big.txt", start: 1, count: 2, home: home)
        XCTAssertTrue(first.text.contains("read on with start_line 3"), first.text)
        let listing = AOMAILocalTools.listDirectory("~/.ssh", home: home)
        XCTAssertTrue(listing.text.contains("config"), "names are listed; contents stay closed")
        XCTAssertTrue(AOMAILocalTools.listDirectory("/private/var", home: home).isError)
    }

    func testToolSchemasHaveTheSameNamesForBothWireFormats() {
        let anthropic = AOMAILocalTools.anthropicSchemas.compactMap { $0["name"] as? String }
        let openAI = AOMAILocalTools.openAISchemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(anthropic, ["search_records", "read_file", "list_directory", "find_files"])
        XCTAssertEqual(anthropic, openAI)
        XCTAssertTrue(AOMAIClient.refusesTools(AOMAIError(message: "This model does not support tools")))
        XCTAssertFalse(AOMAIClient.refusesTools(AOMAIError(message: "Rate limited (429)")))
    }

    // MARK: Local router

    func testLocalProxyLaunchAndHints() {
        let folder = URL(fileURLWithPath: "/tmp/proxy")
        XCTAssertEqual(AOMLocalProxy.launch(folder: folder) { _ in true }.executable.path, "/tmp/proxy/.venv/bin/python")
        XCTAssertEqual(AOMLocalProxy.launch(folder: folder) { _ in false }.executable.path, "/usr/bin/python3")
        let env = AOMLocalProxy.environment(["HTTPS_PROXY": "socks5://x", "all_proxy": "x", "PATH": "/bin"])
        XCTAssertEqual(env, ["PATH": "/bin"])
        XCTAssertTrue(AOMLocalProxy.isLocal("http://127.0.0.1:8082"))
        XCTAssertFalse(AOMLocalProxy.isLocal("https://api.anthropic.com"))
        XCTAssertTrue(AOMLocalProxy.unreachableHint(host: "127.0.0.1", port: 8082).contains("Claude Code proxy"))
        XCTAssertEqual(AOMLocalProxy.unreachableHint(host: "127.0.0.1", port: 11434), " Is Ollama running?")
        XCTAssertEqual(AOMLocalProxy.unreachableHint(host: "api.deepseek.com", port: nil), "")
    }

    /// A stand-in router: a Python health server on a free port, started the
    /// way AOM starts claude-code-proxy.
    @MainActor
    func testEnsureRunningStartsTheRouterOnce() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "no python3")
        let folder = home.appendingPathComponent("router", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let port = 18_000 + Int.random(in: 0..<2_000)
        try """
        import http.server
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if self.path == "/health" else 404); self.end_headers(); self.wfile.write(b"ok")
            def log_message(self, *a): pass
        http.server.HTTPServer(("127.0.0.1", \(port)), H).serve_forever()
        """.write(to: folder.appendingPathComponent(AOMLocalProxy.script), atomically: true, encoding: .utf8)
        defer { AOMLocalProxy.stopStarted() }
        let base = "http://127.0.0.1:\(port)"
        let healthyBefore = await AOMLocalProxy.isHealthy(base: base)
        XCTAssertFalse(healthyBefore)
        let started = await AOMLocalProxy.ensureRunning(base: base, folder: folder, wait: 10)
        XCTAssertTrue(started)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("proxy.log").path))
        let again = await AOMLocalProxy.ensureRunning(base: base, folder: folder, wait: 1)
        XCTAssertTrue(again, "already up: answers without starting another")
        let remote = await AOMLocalProxy.ensureRunning(base: "http://example.invalid:9", folder: folder, wait: 1)
        XCTAssertFalse(remote, "never starts anything for a remote address")
    }
}
