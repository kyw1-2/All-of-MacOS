import AppKit
import CryptoKit
import Darwin
import Foundation

// AOM MCP — lets local AI tools (Claude Code, Codex, Cursor, Claude Desktop…)
// search and manage the clipboard history, like Paste 7's "Paste MCP".
//
// Transport: AI tools launch `AllOfMacOS --mcp` as a stdio MCP server. That
// bridge process connects to the running app over a Unix-domain socket in
// ~/Library/Application Support/AllOfMacOS (directory 0700, socket 0600) and
// authenticates with a per-tool token. Only SHA-256 hashes of tokens are
// stored. Nothing listens on the network. MCP is off until the user turns it
// on and connects a tool; secrets detected by Intelligent Clipboard are never
// returned.

struct ClipboardMCPTool: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var client: String
    var tokenHash: String
    var createdAt = Date()
    var lastUsed: Date?
}

@MainActor
final class ClipboardMCPSettings: ObservableObject {
    static let shared = ClipboardMCPSettings(defaults: PresetManager.isUIPreview || PresetManager.isRunningTests
        ? UserDefaults(suiteName: "AOMMCP.\(UUID().uuidString)")! : .standard)
    static let enabledKey = "AOMMCPEnabled"
    static let toolsKey = "AOMMCPTools"

    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey); ClipboardMCPServer.shared.refresh() } }
    @Published private(set) var tools: [ClipboardMCPTool] { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        tools = (defaults.data(forKey: Self.toolsKey)).flatMap { try? JSONDecoder().decode([ClipboardMCPTool].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tools) { defaults.set(data, forKey: Self.toolsKey) }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a tool and returns its token. The token is shown once.
    func connect(name: String, client: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = "aom_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tools.append(.init(name: trimmed.isEmpty ? client : String(trimmed.prefix(60)), client: client, tokenHash: Self.hash(token)))
        if !enabled { enabled = true }
        return token
    }

    func disconnect(_ id: UUID) {
        tools.removeAll { $0.id == id }
        ClipboardMCPServer.shared.dropConnections(of: id)
    }

    func tool(forToken token: String) -> ClipboardMCPTool? {
        let hash = Self.hash(token)
        return tools.first { $0.tokenHash == hash }
    }

    func markUsed(_ id: UUID) {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        if let last = tools[index].lastUsed, Date().timeIntervalSince(last) < 60 { return }
        tools[index].lastUsed = Date()
    }

    nonisolated static var socketURL: URL {
        let base = PresetManager.previewDirectory ?? (PresetManager.isRunningTests
            ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AllOfMacOS", isDirectory: true))
        return base.appendingPathComponent("mcp.sock")
    }

    static var executablePath: String { Bundle.main.executablePath ?? "/Applications/All of MacOS.app/Contents/MacOS/AllOfMacOS" }

    enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code", codex = "Codex", cursor = "Cursor", claudeDesktop = "Claude Desktop", custom = "Custom Tool"
        var id: String { rawValue }
    }

    /// Setup instructions for `client` with a freshly created `token`.
    static func instructions(for client: Client, token: String) -> (summary: String, snippet: String) {
        let exe = executablePath
        let json = """
        {
          "mcpServers": {
            "all-of-macos": {
              "command": "\(exe)",
              "args": ["--mcp"],
              "env": { "AOM_MCP_TOKEN": "\(token)" }
            }
          }
        }
        """
        switch client {
        case .claudeCode:
            return ("Run this command in Terminal, then start Claude Code and check /mcp.",
                    "claude mcp add --scope user all-of-macos --env AOM_MCP_TOKEN=\(token) -- \"\(exe)\" --mcp")
        case .codex:
            return ("Run this command in Terminal. Codex starts the server when it needs it.",
                    "codex mcp add all-of-macos --env AOM_MCP_TOKEN=\(token) -- \"\(exe)\" --mcp")
        case .cursor:
            return ("Add this to ~/.cursor/mcp.json (merge with existing servers).", json)
        case .claudeDesktop:
            return ("Add this to ~/Library/Application Support/Claude/claude_desktop_config.json, then restart Claude Desktop.", json)
        case .custom:
            return ("Add this stdio server to your AI tool's MCP configuration.", json)
        }
    }
}

// MARK: - In-app socket server

@MainActor
final class ClipboardMCPServer {
    static let shared = ClipboardMCPServer()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let queue = DispatchQueue(label: "com.kyw.allofmacos.mcp")

    /// Starts or stops listening to match the setting.
    func refresh() {
        let settings = ClipboardMCPSettings.shared
        if settings.enabled && !settings.tools.isEmpty && !PresetManager.isRunningTests { start() } else { stop() }
    }

    var isListening: Bool { listenFD >= 0 }

    func stopForTermination() { stop() }
    private func start() {
        guard listenFD < 0 else { return }
        let url = ClipboardMCPSettings.socketURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(url.path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            // Same-user peers only.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
            Task { @MainActor in self?.adopt(client) }
        }
        source.resume()
        acceptSource = source
    }

    private func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1; unlink(ClipboardMCPSettings.socketURL.path) }
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    func dropConnections(of toolID: UUID) {
        for (key, connection) in connections where connection.toolID == toolID {
            connection.close(); connections[key] = nil
        }
        refresh()
    }

    private func adopt(_ fd: Int32) {
        let connection = Connection(fd: fd, queue: queue)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onLine = { [weak self, weak connection] line in
            guard let self, let connection else { return }
            self.handle(line, on: connection)
        }
        connection.onClose = { [weak self] in self?.connections[key] = nil }
        connection.start()
    }

    private func handle(_ line: String, on connection: Connection) {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if connection.toolID == nil {
            // First line authenticates the bridge.
            guard let token = object["aom_mcp_auth"] as? String,
                  let tool = ClipboardMCPSettings.shared.tool(forToken: token), ClipboardMCPSettings.shared.enabled else {
                connection.send(["aom_mcp_auth": "denied"]); connection.close(); return
            }
            connection.toolID = tool.id
            connection.send(["aom_mcp_auth": "ok"])
            return
        }
        if let toolID = connection.toolID { ClipboardMCPSettings.shared.markUsed(toolID) }
        if let response = ClipboardMCPHandler.handle(object, store: .shared) { connection.send(response) }
    }

    final class Connection {
        let fd: Int32
        private let source: DispatchSourceRead
        private var buffer = Data()
        private var closed = false
        var toolID: UUID?
        var onLine: (@MainActor (String) -> Void)?
        var onClose: (@MainActor () -> Void)?

        init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        }

        func start() {
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            source.resume()
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { finish(); return }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count < 4 * 1_024 * 1_024 else { finish(); return }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onLine?(line) }
                }
            }
        }

        func send(_ object: [String: Any]) {
            guard !closed, var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }

        private func finish() {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.close() } }
        }

        func close() {
            guard !closed else { return }
            closed = true
            source.cancel()
            let callback = onClose
            onClose = nil
            MainActor.assumeIsolated { callback?() }
        }
    }
}

// MARK: - JSON-RPC / MCP tools

@MainActor
enum ClipboardMCPHandler {
    static let protocolVersion = "2025-06-18"

    static func handle(_ message: [String: Any], store: ClipboardStore) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else { return nil }
        func result(_ value: Any) -> [String: Any]? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": value]
        }
        switch method {
        case "initialize":
            let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
            return result([
                "protocolVersion": requested ?? protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "all-of-macos", "title": "All of MacOS Clipboard",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"],
                "instructions": "Search and manage the user's local All of MacOS clipboard history and pinboards. Items that look like secrets are never returned.",
            ])
        case "ping": return result([String: Any]())
        case "tools/list": return result(["tools": tools])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let value = try call(name, arguments, store: store)
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                return result(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                               "structuredContent": value, "isError": false])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            if method.hasPrefix("notifications/") { return nil }
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func schema(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let idProp: [String: Any] = ["type": "string", "description": "Identifier of the clipboard item (from search results)."]
    private static let boardProp: [String: Any] = ["type": "string", "description": "A pinboard id from list_pinboards."]
    private static let confirmProp: [String: Any] = ["type": "boolean", "description": "Call without it to preview; true to really delete."]

    static let tools: [[String: Any]] = [
        ["name": "search", "description": "Search clipboard history and pinboards (newest first). Free text matches titles, text, image text, apps and file paths; supports quotes, -exclude, from:App, type:link|text|image|file|color, board:Name. Returns summaries; call read_item for full content.",
         "inputSchema": schema(["query": ["type": "string"], "type": ["type": "string", "enum": ["text", "link", "image", "file", "color"]],
                                "app": ["type": "string", "description": "Source app name or bundle id."], "pinboard_id": boardProp,
                                "after": ["type": "string", "description": "ISO-8601 lower bound."], "before": ["type": "string", "description": "ISO-8601 upper bound."],
                                "limit": ["type": "integer", "minimum": 1, "maximum": 100]]),
         "annotations": ["readOnlyHint": true]],
        ["name": "read_item", "description": "Full content of one clipboard item: text, link, color, file paths, or image size and recognized text.",
         "inputSchema": schema(["id": idProp], required: ["id"]), "annotations": ["readOnlyHint": true]],
        ["name": "create_item", "description": "Create a text item in clipboard history (optionally pinned to a pinboard). Does not change the system clipboard.",
         "inputSchema": schema(["content": ["type": "string"], "pinboard_id": boardProp, "title": ["type": "string"]], required: ["content"])],
        ["name": "update_item", "description": "Change the text content and/or title of a text, link or color item.",
         "inputSchema": schema(["id": idProp, "content": ["type": "string"], "title": ["type": "string"]], required: ["id"])],
        ["name": "delete_item", "description": "Delete an item from history and every pinboard, for good. Two-step: call without confirm to preview, then with confirm: true.",
         "inputSchema": schema(["id": idProp, "confirm": confirmProp], required: ["id"]), "annotations": ["destructiveHint": true]],
        ["name": "copy_to_clipboard", "description": "Put an item on the system clipboard so the user can paste it.",
         "inputSchema": schema(["id": idProp, "plain_text": ["type": "boolean"]], required: ["id"])],
        ["name": "list_pinboards", "description": "List pinboards (id, name, color, itemCount).",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]],
        ["name": "create_pinboard", "description": "Create a pinboard.",
         "inputSchema": schema(["name": ["type": "string"], "color": ["type": "string", "enum": ClipboardStore.boardColors]], required: ["name"])],
        ["name": "rename_pinboard", "description": "Rename a pinboard.",
         "inputSchema": schema(["pinboard_id": boardProp, "name": ["type": "string"]], required: ["pinboard_id", "name"])],
        ["name": "delete_pinboard", "description": "Delete a pinboard (items stay in history). Two-step with confirm.",
         "inputSchema": schema(["pinboard_id": boardProp, "confirm": confirmProp], required: ["pinboard_id"]), "annotations": ["destructiveHint": true]],
        ["name": "add_item_to_pinboard", "description": "Pin an item to a pinboard; pinning twice keeps it pinned once.",
         "inputSchema": schema(["id": idProp, "pinboard_id": boardProp], required: ["id", "pinboard_id"])],
        ["name": "remove_item_from_pinboard", "description": "Unpin an item from a pinboard, keeping it in history.",
         "inputSchema": schema(["id": idProp, "pinboard_id": boardProp], required: ["id", "pinboard_id"])],
        ["name": "get_suggestions", "description": "Intelligent Clipboard: the items the user most likely wants to paste into the frontmost app right now.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]],
    ]

    private static let iso = ISO8601DateFormatter()

    static func isSecret(_ entry: ClipboardEntry) -> Bool {
        ClipboardIntelligence.shared.itemClass(entry) == .secret
    }

    static func summary(_ entry: ClipboardEntry, store: ClipboardStore) -> [String: Any] {
        let secret = isSecret(entry)
        var item: [String: Any] = [
            "id": entry.id.uuidString, "type": entry.kind.rawValue,
            "title": secret ? "Hidden secret" : entry.title,
            "preview": secret ? "[hidden: looks like a password, token or key]" : String(entry.previewText.prefix(240)),
            "timestamp": iso.string(from: entry.lastCopiedAt),
            "pinboards": store.boards.filter { entry.pinboardIDs.contains($0.id) }.map(\.name),
        ]
        if let app = entry.sourceName ?? entry.sourceBundleID { item["app"] = app }
        return item
    }

    private static func entry(_ arguments: [String: Any], store: ClipboardStore, key: String = "id") throws -> ClipboardEntry {
        guard let raw = arguments[key] as? String, let id = UUID(uuidString: raw),
              let entry = store.entries.first(where: { $0.id == id }) else {
            throw ToolError("No clipboard item found with id \(arguments[key] as? String ?? "(missing)"). Use search to find ids.")
        }
        return entry
    }

    private static func board(_ arguments: [String: Any], store: ClipboardStore) throws -> ClipboardPinboard {
        guard let raw = arguments["pinboard_id"] as? String, let id = UUID(uuidString: raw),
              let board = store.boards.first(where: { $0.id == id }) else {
            throw ToolError("Unknown pinboard. Use list_pinboards to see valid ids.")
        }
        return board
    }

    static func call(_ name: String, _ arguments: [String: Any], store: ClipboardStore) throws -> [String: Any] {
        switch name {
        case "search":
            var query = (arguments["query"] as? String) ?? ""
            if let app = arguments["app"] as? String, !app.isEmpty { query += " from:\"\(app)\"" }
            let kind = (arguments["type"] as? String).flatMap(ClipboardEntry.Kind.init(rawValue:))
            let boardID = (arguments["pinboard_id"] as? String).flatMap(UUID.init(uuidString:))
            let after = (arguments["after"] as? String).flatMap(iso.date(from:))
            let before = (arguments["before"] as? String).flatMap(iso.date(from:))
            let limit = min(100, max(1, arguments["limit"] as? Int ?? 20))
            let matches = store.filtered(query: query, kind: kind, source: nil, board: boardID, since: after)
                .filter { before == nil || $0.lastCopiedAt < before! }
            return ["items": matches.prefix(limit).map { summary($0, store: store) }, "total": matches.count]
        case "read_item":
            let item = try entry(arguments, store: store)
            guard !isSecret(item) else { throw ToolError("This item looks like a password, token or key and is not shared with AI tools.") }
            var value = summary(item, store: store)
            if let text = item.text { value["content"] = String(text.prefix(100_000)) }
            if !item.fileURLs.isEmpty { value["files"] = item.fileURLs.map(\.path) }
            if item.kind == .image {
                if let data = item.imageData, let rep = NSBitmapImageRep(data: data) {
                    value["image"] = ["width": rep.pixelsWide, "height": rep.pixelsHigh]
                }
                if let ocr = item.recognizedText { value["recognized_text"] = String(ocr.prefix(50_000)) }
            }
            return value
        case "create_item":
            guard let content = arguments["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("content must be non-empty text.")
            }
            let target = arguments["pinboard_id"] == nil ? nil : try board(arguments, store: store)
            guard let created = store.createTextItem(content) else { throw ToolError(store.lastError ?? "Could not create the item.") }
            if let title = arguments["title"] as? String, !title.isEmpty { store.rename(entryID: created.id, title: title) }
            if let target { store.pin(entryID: created.id, boardID: target.id) }
            return summary(store.entries.first { $0.id == created.id } ?? created, store: store)
        case "update_item":
            let item = try entry(arguments, store: store)
            if let content = arguments["content"] as? String {
                guard [.text, .link, .color].contains(item.kind) else { throw ToolError("Only text, link and color items can be edited.") }
                store.editText(entryID: item.id, text: content)
            }
            if let title = arguments["title"] as? String { store.rename(entryID: item.id, title: title) }
            return summary(store.entries.first { $0.id == item.id } ?? item, store: store)
        case "delete_item":
            let item = try entry(arguments, store: store)
            guard arguments["confirm"] as? Bool == true else {
                return ["preview": summary(item, store: store),
                        "message": "This would delete this item from history and its pinboards, for good. Call again with confirm: true to delete."]
            }
            store.delete(entryIDs: [item.id])
            return ["deleted": item.id.uuidString]
        case "copy_to_clipboard":
            let item = try entry(arguments, store: store)
            guard !isSecret(item) else { throw ToolError("Secrets are not copied on behalf of AI tools. Paste it yourself from the clipboard panel.") }
            guard try store.write(entryIDs: [item.id], plainText: arguments["plain_text"] as? Bool ?? false) else {
                throw ToolError("Could not write to the clipboard.")
            }
            return ["copied": item.id.uuidString]
        case "list_pinboards":
            return ["pinboards": store.boards.map { board in
                ["id": board.id.uuidString, "name": board.name, "color": board.color,
                 "itemCount": store.entries.filter { $0.pinboardIDs.contains(board.id) }.count] as [String: Any]
            }]
        case "create_pinboard":
            guard let name = arguments["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError("name is required.") }
            let color = (arguments["color"] as? String).flatMap { ClipboardStore.boardColors.contains($0) ? $0 : nil } ?? "blue"
            let board = store.createBoard(name: name, color: color)
            guard store.boards.contains(where: { $0.id == board.id }) else { throw ToolError("Could not create the pinboard.") }
            return ["id": board.id.uuidString, "name": board.name, "color": board.color, "itemCount": 0]
        case "rename_pinboard":
            let target = try board(arguments, store: store)
            store.renameBoard(id: target.id, name: arguments["name"] as? String ?? "")
            return ["id": target.id.uuidString, "name": store.boards.first { $0.id == target.id }?.name ?? target.name]
        case "delete_pinboard":
            let target = try board(arguments, store: store)
            guard arguments["confirm"] as? Bool == true else {
                return ["message": "This would delete pinboard \"\(target.name)\". Its items stay in history. Call again with confirm: true."]
            }
            store.deleteBoard(id: target.id)
            return ["deleted": target.id.uuidString]
        case "add_item_to_pinboard", "remove_item_from_pinboard":
            let item = try entry(arguments, store: store)
            let target = try board(arguments, store: store)
            if name == "add_item_to_pinboard" { store.pin(entryID: item.id, boardID: target.id) }
            else { store.unpin(entryID: item.id, boardID: target.id) }
            return ["id": target.id.uuidString, "name": target.name,
                    "itemCount": store.entries.filter { $0.pinboardIDs.contains(target.id) }.count]
        case "get_suggestions":
            let front = NSWorkspace.shared.frontmostApplication
            let ids = ClipboardIntelligence.shared.suggestions(for: front, store: store) { _ in }
            return ["app": front?.localizedName ?? "", "kind": ClipboardIntelligence.shared.lastContext.kind.rawValue,
                    "items": ids.compactMap { id in store.entries.first { $0.id == id } }.map { summary($0, store: store) }]
        default:
            throw ToolError("Unknown tool \(name).")
        }
    }
}

// MARK: - stdio bridge (`AllOfMacOS --mcp`)

enum ClipboardMCPBridge {
    /// Runs before NSApplication starts; never returns.
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var token = ProcessInfo.processInfo.environment["AOM_MCP_TOKEN"] ?? ""
        if let i = arguments.firstIndex(of: "--token"), arguments.indices.contains(i + 1) { token = arguments[i + 1] }
        let fd = connect(path: ClipboardMCPSettings.socketURL.path)
        var authed = false
        if fd >= 0, !token.isEmpty {
            writeLine(fd, "{\"aom_mcp_auth\":\(jsonString(token))}")
            if let reply = readLine(fd), reply.contains("\"ok\"") { authed = true }
        }
        guard authed else {
            let reason = fd < 0 ? "All of MacOS is not running, or MCP is turned off (Settings ▸ Clipboard ▸ MCP & AI Tools)."
                : token.isEmpty ? "AOM_MCP_TOKEN is missing. Connect this tool in All of MacOS Settings ▸ Clipboard ▸ MCP & AI Tools."
                : "The token was rejected. Reconnect this tool in All of MacOS settings."
            failAll(reason)
        }
        // socket → stdout
        let reader = Thread {
            while let line = readLine(fd) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
            exit(0)
        }
        reader.start()
        // stdin → socket
        while let line = Swift.readLine(strippingNewline: true) {
            if !line.isEmpty { writeLine(fd, line) }
        }
        exit(0)
    }

    private static func failAll(_ reason: String) -> Never {
        while let line = Swift.readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = object["id"] else { continue }
            let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": reason]]
            if let out = try? JSONSerialization.data(withJSONObject: response) {
                FileHandle.standardOutput.write(out + Data("\n".utf8))
            }
        }
        exit(1)
    }

    private static func jsonString(_ value: String) -> String {
        (try? String(decoding: JSONSerialization.data(withJSONObject: [value]), as: UTF8.self)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    private static func connect(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    private static func writeLine(_ fd: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { return }
            offset += written
        }
    }

    private static var pending = [UInt8]()
    private static func readLine(_ fd: Int32) -> String? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            pending.append(contentsOf: chunk[0..<count])
        }
    }
}
