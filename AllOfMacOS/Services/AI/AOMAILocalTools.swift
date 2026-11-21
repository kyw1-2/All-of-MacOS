import Foundation

// AOM 7.2.1: read-only tools for Ask AI's native models. Asked "다른 AI들 기록에
// 오라클 서버 접속하는 방법 있을 텐데 찾아 줘", Haiku → DeepSeek could only say it
// had no access. Models that can call tools (Anthropic Messages — the local
// router and the Claude API — and OpenAI-compatible chat: DeepSeek, OpenAI,
// Ollama) now get four tools that read this Mac: the user's records (LLM Wiki,
// Claude memories, Claude Code and Codex session logs, AOM chats, shell
// history), a text file, a folder, a Spotlight name search. Nothing writes or
// runs anything. Private keys, keychains and certificates are refused; every
// result goes through the clipboard secret scanner, and .env values are
// hidden, before it is sent to the model.

struct AOMAIToolResult: Equatable {
    var text: String
    /// One line for the transcript ("Searched records for “oracle ssh” · 9 matches").
    var summary: String
    var isError = false
}

enum AOMAILocalTools {
    static let enabledKey = "AOMAILocalTools"

    /// On unless turned off in Settings › AI.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    enum Source: String, CaseIterable {
        case wiki, memories, claude_sessions, codex_sessions, aom_chats, shell_history, agent_docs
    }

    struct Tool {
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
    }

    static let tools: [Tool] = [
        Tool(name: "search_records",
             description: "Search the user's own records on this Mac by keywords: their LLM Wiki (runbooks, architecture, decisions), Claude's saved memories, Claude Code and Codex conversation logs, AOM's AI chats, shell command history and agent instruction files. Use it whenever the user asks about their setup, servers, accounts, past work or what another AI did. Returns matching lines with file paths, newest first.",
             properties: [
                "query": ["type": "string", "description": "Keywords, e.g. \"oracle ssh\". Every word must appear on the line; fewer words find more."],
                "sources": ["type": "array", "items": ["type": "string", "enum": Source.allCases.map(\.rawValue)],
                            "description": "Where to look; all sources when omitted."],
             ],
             required: ["query"]),
        Tool(name: "read_file",
             description: "Read a text file in the user's home folder (or /etc), with line numbers. Use a path from search_records or list_directory. Secrets are hidden.",
             properties: [
                "path": ["type": "string", "description": "Absolute path or one starting with ~/"],
                "start_line": ["type": "integer", "description": "First line to read (1-based); default 1"],
                "max_lines": ["type": "integer", "description": "How many lines; default 200, at most 400"],
             ],
             required: ["path"]),
        Tool(name: "list_directory",
             description: "List a folder in the user's home folder: names, kinds, sizes and dates.",
             properties: ["path": ["type": "string", "description": "Absolute path or one starting with ~/"]],
             required: ["path"]),
        Tool(name: "find_files",
             description: "Find files and folders in the home folder whose name contains a text (Spotlight). Newest first.",
             properties: ["name": ["type": "string", "description": "Part of the file name"]],
             required: ["name"]),
    ]

    static var anthropicSchemas: [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description,
                     "input_schema": ["type": "object", "properties": $0.properties, "required": $0.required]] }
    }

    static var openAISchemas: [[String: Any]] {
        tools.map { ["type": "function",
                     "function": ["name": $0.name, "description": $0.description,
                                  "parameters": ["type": "object", "properties": $0.properties, "required": $0.required]]] }
    }

    static let promptLines = [
        "You can read this Mac with tools: search_records (the user's LLM Wiki, Claude memories, Claude Code and Codex conversation logs, AOM chats, shell history, agent instruction files), read_file, list_directory and find_files.",
        "When the user asks about their own setup, servers, accounts, files or what another AI did, search with the tools before answering; never say you can't access their records. Try a second search with fewer or other words before giving up.",
        "Cite the file paths and the exact commands you found. AOM hides secrets in tool results; never ask the user for passwords or keys.",
    ]

    // MARK: Running a call

    /// Runs one call off the main thread (each tool has its own time limit).
    static func run(_ name: String, arguments: [String: Any], home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> AOMAIToolResult {
        await Task.detached(priority: .userInitiated) {
            switch name {
            case "search_records":
                let query = (arguments["query"] as? String) ?? ""
                let sources = (arguments["sources"] as? [String])?.compactMap(Source.init(rawValue:))
                return search(query, sources: sources?.isEmpty == false ? sources! : Source.allCases, home: home)
            case "read_file":
                return readFile(arguments["path"] as? String ?? "", start: arguments["start_line"] as? Int ?? 1,
                                count: arguments["max_lines"] as? Int ?? 200, home: home)
            case "list_directory":
                return listDirectory(arguments["path"] as? String ?? "", home: home)
            case "find_files":
                return findFiles(arguments["name"] as? String ?? "", home: home)
            default:
                return AOMAIToolResult(text: "Unknown tool \(name).", summary: "Unknown tool \(name)", isError: true)
            }
        }.value
    }

    // MARK: search_records

    struct Hit: Equatable {
        var source: Source
        var path: String
        var line: Int
        var snippet: String
        var date: Date
    }

    /// The files of a source, newest first.
    static func files(of source: Source, home: URL) -> [URL] {
        let fm = FileManager.default
        func newest(_ urls: [URL], limit: Int) -> [URL] {
            urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
        func walk(_ root: URL, suffix: String, skipping: [String] = []) -> [URL] {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            var found: [URL] = []
            for case let url as URL in walker {
                if skipping.contains(where: { url.path.contains($0) }) { walker.skipDescendants(); continue }
                if url.pathExtension == suffix { found.append(url) }
                if found.count > 5_000 { break }
            }
            return found
        }
        switch source {
        case .wiki:
            return newest(walk(home.appendingPathComponent(".agents/llm-wiki"), suffix: "md", skipping: ["/.git/"]), limit: 2_000)
        case .memories:
            let projects = home.appendingPathComponent(".claude/projects")
            let folders = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            return newest(folders.flatMap { folder in
                ((try? fm.contentsOfDirectory(at: folder.appendingPathComponent("memory"), includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "md" }
            }, limit: 1_000)
        case .claude_sessions:
            let projects = home.appendingPathComponent(".claude/projects")
            let folders = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            return newest(folders.flatMap { folder in
                ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
            }, limit: 400)
        case .codex_sessions:
            return newest(walk(home.appendingPathComponent(".codex/sessions"), suffix: "jsonl"), limit: 300)
        case .aom_chats:
            return [home.appendingPathComponent("Library/Application Support/AllOfMacOS/AI/chats.json")].filter { fm.fileExists(atPath: $0.path) }
        case .shell_history:
            return [".zsh_history", ".bash_history"].map { home.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        case .agent_docs:
            return ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".codex/AGENTS.md", ".codex/config.toml", ".ssh/config"]
                .map { home.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        }
    }

    /// Lines that contain every word of `query`, newest files first, at most
    /// three per file and 30 in all, within about four seconds. With no such
    /// line, lines with the most words.
    static func search(_ query: String, sources: [Source], home: URL, budget: TimeInterval = 4) -> AOMAIToolResult {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else {
            return AOMAIToolResult(text: "Give search_records a word of at least two letters.", summary: "Empty search", isError: true)
        }
        let deadline = Date().addingTimeInterval(budget)
        var hits: [Hit] = []
        var partial: [(hit: Hit, matched: Int)] = []
        var scanned = 0
        outer: for source in sources {
            for url in files(of: source, home: home) {
                if Date() > deadline || hits.count >= 30 { break outer }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 60_000_000 else { continue }
                scanned += 1
                let text = String(decoding: data, as: UTF8.self)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let found = matches(in: text, terms: terms, limit: 3)
                for match in found.full {
                    hits.append(Hit(source: source, path: tilde(url.path, home: home), line: match.line, snippet: match.snippet, date: date))
                }
                if hits.isEmpty, partial.count < 60 {
                    for match in found.partial {
                        partial.append((Hit(source: source, path: tilde(url.path, home: home), line: match.line, snippet: match.snippet, date: date), match.matched))
                    }
                }
            }
        }
        let shown: [Hit]
        var header: String
        if !hits.isEmpty {
            shown = hits
            header = "\(hits.count) line(s) containing every word of “\(query)” (\(scanned) files read):"
        } else {
            shown = partial.sorted { $0.matched > $1.matched }.prefix(15).map(\.hit)
            header = shown.isEmpty ? "Nothing in \(scanned) files contains “\(query)”. Try other or fewer words."
                : "No line has every word of “\(query)”; closest \(shown.count) of \(scanned) files:"
        }
        let body = shown.map { hit in
            "[\(hit.source.rawValue)] \(hit.path):\(hit.line) (\(hit.date.formatted(date: .abbreviated, time: .omitted)))\n    \(hit.snippet)"
        }.joined(separator: "\n")
        if Date() > deadline { header += " (stopped at the time limit; narrow the sources for more)" }
        return AOMAIToolResult(text: header + (body.isEmpty ? "" : "\n" + body),
                               summary: "Searched records for “\(query)” · \(hits.isEmpty ? shown.count : hits.count) match\(shown.count == 1 ? "" : "es")")
    }

    struct Match: Equatable {
        var line: Int
        var snippet: String
        var matched: Int
    }

    /// Pure: lines of `text` with every term (case-insensitive), and lines
    /// with some of them; snippets are cut around the first term, JSON
    /// escapes undone and secrets hidden. A file without any term is
    /// skipped after one search.
    static func matches(in text: String, terms: [String], limit: Int) -> (full: [Match], partial: [Match]) {
        guard terms.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) else { return ([], []) }
        var full: [Match] = [], partial: [Match] = []
        var number = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            guard full.count < limit else { break }
            var matched = 0
            var first: String.Index?
            for term in terms {
                guard let range = line.range(of: term, options: .caseInsensitive) else { continue }
                matched += 1
                if first == nil || range.lowerBound < first! { first = range.lowerBound }
            }
            guard matched > 0, let first else { continue }
            let match = Match(line: number, snippet: snippet(String(line), around: line.distance(from: line.startIndex, to: first)),
                              matched: matched)
            if matched == terms.count { full.append(match) } else if partial.count < limit { partial.append(match) }
        }
        return (full, partial)
    }

    /// Pure: ~240 characters around `offset`, JSON escapes undone, one line, secrets hidden.
    static func snippet(_ line: String, around offset: Int, radius: Int = 120) -> String {
        let characters = Array(line)
        let start = max(0, offset - radius), end = min(characters.count, offset + radius)
        var text = String(characters[start..<end])
        text = text.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/")
        text = unescapeUnicode(text)
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return (start > 0 ? "…" : "") + redact(text.trimmingCharacters(in: .whitespaces)) + (end < characters.count ? "…" : "")
    }

    /// "오라" → "오라" (Codex logs escape Korean).
    static func unescapeUnicode(_ text: String) -> String {
        guard text.contains("\\u") else { return text }
        let pattern = try? NSRegularExpression(pattern: #"\\u([0-9a-fA-F]{4})"#)
        var result = text
        for match in (pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).reversed() {
            guard let range = Range(match.range, in: result), let hexRange = Range(match.range(at: 1), in: text),
                  let value = UInt32(text[hexRange], radix: 16), let scalar = Unicode.Scalar(value) else { continue }
            result.replaceSubrange(range, with: String(Character(scalar)))
        }
        return result
    }

    /// Pure: every credential the clipboard scanner knows replaced by [hidden];
    /// a password-shaped word too.
    static func redact(_ text: String) -> String {
        var result = text
        for pattern in ClipboardSecretScanner.patterns {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[hidden]")
        }
        let words = result.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            ClipboardSecretScanner.looksLikePassword(String(word)) ? "[hidden]" : String(word)
        }
        result = words.joined(separator: " ")
        if ClipboardSecretScanner.containsSecret(inText: result) { return "[hidden: looks like a credential]" }
        return result
    }

    // MARK: Files

    /// Pure: why a path may not be read, nil when it may.
    static func refusal(for path: String, home: URL) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let full = url.path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        let allowedRoots = [homePath, "/etc", "/private/etc", "/opt/homebrew/etc", "/usr/local/etc"]
        guard allowedRoots.contains(where: { full == $0 || full.hasPrefix($0 + "/") }) else {
            return "Only files in the home folder and /etc can be read."
        }
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "kdbx", "gpg", "asc", "der", "cer", "crt", "mobileprovision"].contains(ext) {
            return "\(url.lastPathComponent) holds keys or certificates; it is never read."
        }
        if name.hasPrefix("id_") && ext != "pub" { return "\(url.lastPathComponent) is a private key; it is never read." }
        let blockedFolders = ["/.ssh/", "/.gnupg/", "/Library/Keychains/", "/.aws/", "/.docker/", "/.kube/", "/.config/gh/", "/Library/Cookies/"]
        if blockedFolders.contains(where: { full.contains($0) }) {
            let open = ["config", "known_hosts"].contains(name) || ext == "pub"
            if !(full.contains("/.ssh/") && open) { return "\(tilde(full, home: home)) is in a credentials folder; only ~/.ssh/config, known_hosts and .pub files there can be read." }
        }
        if ["credentials", ".netrc", ".pgpass", ".npmrc", ".pypirc", "auth.json", "token", "tokens.json", "hosts.yml"].contains(name) {
            return "\(url.lastPathComponent) holds credentials; it is never read."
        }
        return nil
    }

    static func resolve(_ path: String, home: URL) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home.path }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2))).path }
        return trimmed.hasPrefix("/") ? trimmed : home.appendingPathComponent(trimmed).path
    }

    static func tilde(_ path: String, home: URL) -> String {
        // The home folder as given or behind /private (walking /var gives /private/var).
        for root in [home.path, "/private" + home.path] where path.hasPrefix(root + "/") {
            return "~" + path.dropFirst(root.count)
        }
        return path
    }

    static func readFile(_ path: String, start: Int, count: Int, home: URL) -> AOMAIToolResult {
        let full = resolve(path, home: home)
        if let refusal = refusal(for: full, home: home) {
            return AOMAIToolResult(text: refusal, summary: "Refused \(tilde(full, home: home))", isError: true)
        }
        guard let data = FileManager.default.contents(atPath: full) else {
            return AOMAIToolResult(text: "\(tilde(full, home: home)) doesn't exist or can't be read.", summary: "Couldn't read \(tilde(full, home: home))", isError: true)
        }
        guard data.count < 8_000_000, !data.prefix(4_096).contains(0) else {
            return AOMAIToolResult(text: "\(tilde(full, home: home)) isn't a text file (or is over 8 MB).", summary: "Not text: \(tilde(full, home: home))", isError: true)
        }
        let isEnv = URL(fileURLWithPath: full).lastPathComponent.hasPrefix(".env") || full.hasSuffix(".env")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let first = max(1, start), take = min(400, max(1, count))
        let slice = lines.dropFirst(first - 1).prefix(take)
        let body = slice.enumerated().map { index, line -> String in
            let text = String(line)
            // A .env line keeps its name only; names are not secrets.
            if isEnv, let equals = text.firstIndex(of: "="), !text.hasPrefix("#") {
                return "\(first + index)\t\(text[..<equals])=[hidden]"
            }
            return "\(first + index)\t\(redact(text))"
        }.joined(separator: "\n")
        let more = first - 1 + slice.count < lines.count ? "\n… \(lines.count) lines in all; read on with start_line \(first + slice.count)." : ""
        return AOMAIToolResult(text: "\(tilde(full, home: home)) (lines \(first)–\(first + slice.count - 1))\n" + body + more,
                               summary: "Read \(tilde(full, home: home))")
    }

    static func listDirectory(_ path: String, home: URL) -> AOMAIToolResult {
        let full = resolve(path.isEmpty ? "~" : path, home: home)
        let real = URL(fileURLWithPath: full).standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard [homePath, "/etc", "/private/etc"].contains(where: { real == $0 || real.hasPrefix($0 + "/") }) else {
            return AOMAIToolResult(text: "Only folders in the home folder and /etc can be listed.", summary: "Refused \(full)", isError: true)
        }
        let url = URL(fileURLWithPath: full)
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            return AOMAIToolResult(text: "\(tilde(full, home: home)) isn't a readable folder.", summary: "Couldn't list \(tilde(full, home: home))", isError: true)
        }
        let rows = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(300).map { item -> String in
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let kind = values?.isDirectory == true ? "folder" : SystemStatus.size(Int64(values?.fileSize ?? 0))
                let date = values?.contentModificationDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
                return "\(item.lastPathComponent)\t\(kind)\t\(date)"
            }
        return AOMAIToolResult(text: "\(tilde(full, home: home)) — \(items.count) item(s)\n" + rows.joined(separator: "\n"),
                               summary: "Listed \(tilde(full, home: home))")
    }

    static func findFiles(_ name: String, home: URL) -> AOMAIToolResult {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return AOMAIToolResult(text: "Give a name of at least two letters.", summary: "Empty file search", isError: true) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", home.path, "-name", needle]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return AOMAIToolResult(text: "Spotlight didn't run.", summary: "Spotlight didn't run", isError: true)
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        let paths = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let dated = paths.prefix(400).map { ($0, (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(40)
        let body = dated.map { "\(tilde($0.0, home: home))\t\($0.1.formatted(date: .abbreviated, time: .omitted))" }.joined(separator: "\n")
        return AOMAIToolResult(text: paths.isEmpty ? "Spotlight found nothing named like “\(needle)”." : "\(paths.count) match(es), newest first:\n" + body,
                               summary: "Found files named “\(needle)” · \(paths.count)")
    }
}
