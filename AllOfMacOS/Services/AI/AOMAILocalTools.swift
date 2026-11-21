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
    /// 7.3: what the call read, for the answer's receipt ("LLM Wiki", "~/x/notes.md").
    var used: [String] = []
}

enum AOMAILocalTools {
    static let enabledKey = "AOMAILocalTools"

    /// 7.2's switch; since 7.3 `AOMAIRecordsMode` (off here means "never").
    static var isEnabled: Bool {
        get { AOMAIRecordsMode.current != .never }
        set { AOMAIRecordsMode.current = newValue ? .mentions : .never }
    }

    enum Source: String, CaseIterable {
        case wiki, memories, claude_sessions, codex_sessions, aom_chats, shell_history, agent_docs
        /// 7.3: ~/.ssh/config and known_hosts, only with @ssh (7.2 searched
        /// the SSH config as an "agent doc" whenever the model named no source).
        case ssh_config

        var title: String {
            switch self {
            case .wiki: return AOMAIRecordSource.wiki.title
            case .memories: return AOMAIRecordSource.memories.title
            case .claude_sessions: return AOMAIRecordSource.claude.title
            case .codex_sessions: return AOMAIRecordSource.codex.title
            case .aom_chats: return AOMAIRecordSource.chats.title
            case .shell_history: return AOMAIRecordSource.shell.title
            case .agent_docs: return AOMAIRecordSource.docs.title
            case .ssh_config: return AOMAIRecordSource.ssh.title
            }
        }
    }

    /// The agent instruction files @docs reads (no SSH file among them since 7.3).
    static let agentDocNames = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".codex/AGENTS.md", ".codex/config.toml"]

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

    /// 7.3: the tools of one scope — each name once, search_records' source
    /// list cut to the allowed sources, the file tools described with the
    /// folders they may use. An empty scope has no tools.
    static func tools(for scope: AOMAIRecordScope) -> [Tool] {
        let names = scope.toolNames
        let allowed = scope.searchSources
        let folders = scope.folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        return tools.filter { names.contains($0.name) }.map { tool in
            switch tool.name {
            case "search_records":
                var properties = tool.properties
                properties["sources"] = ["type": "array", "items": ["type": "string", "enum": allowed.map(\.rawValue)],
                                         "description": "Where to look, among: \(allowed.map(\.rawValue).joined(separator: ", ")); all of these when omitted."]
                return Tool(name: tool.name,
                            description: "Search the records the user allowed for this question (\(allowed.map(\.title).joined(separator: ", "))) by keywords. Returns matching lines with file paths, newest first.",
                            properties: properties, required: tool.required)
            case "read_file":
                let reach = [allowed.isEmpty ? nil : "files search_records found", folders.isEmpty ? nil : "files in \(folders)"]
                    .compactMap { $0 }.joined(separator: " and ")
                return Tool(name: tool.name, description: "Read a text file with line numbers: \(reach). Secrets are hidden.",
                            properties: tool.properties, required: tool.required)
            case "list_directory":
                return Tool(name: tool.name, description: "List a folder inside \(folders): names, kinds, sizes and dates.",
                            properties: tool.properties, required: tool.required)
            case "find_files":
                return Tool(name: tool.name, description: "Find files whose name contains a text inside \(folders) (Spotlight). Newest first.",
                            properties: tool.properties, required: tool.required)
            default:
                return tool
            }
        }
    }

    static func anthropicSchemas(_ tools: [Tool]) -> [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description,
                     "input_schema": ["type": "object", "properties": $0.properties, "required": $0.required]] }
    }

    static func openAISchemas(_ tools: [Tool]) -> [[String: Any]] {
        tools.map { ["type": "function",
                     "function": ["name": $0.name, "description": $0.description,
                                  "parameters": ["type": "object", "properties": $0.properties, "required": $0.required]]] }
    }

    static var anthropicSchemas: [[String: Any]] { anthropicSchemas(tools) }
    static var openAISchemas: [[String: Any]] { openAISchemas(tools) }

    /// The system prompt's lines for a scope; none for an empty one.
    static func promptLines(for scope: AOMAIRecordScope) -> [String] {
        let names = scope.toolNames
        guard !names.isEmpty else { return [] }
        return [
            "For this question the user allowed you to read: \(scope.summary). Your tools: \(names.joined(separator: ", ")). Nothing else on this Mac may be read.",
            "Search with the tools before answering questions about those records; try a second search with fewer or other words before giving up.",
            "Cite the file paths and the exact commands you found. AOM hides secrets in tool results; never ask the user for passwords or keys.",
        ]
    }

    // MARK: Running a call

    /// "Searching records for “uclass”…" while a call runs.
    static func describe(_ name: String, arguments: [String: Any]) -> String {
        switch name {
        case "search_records": return "Searching records for “\(arguments["query"] as? String ?? "")”…"
        case "read_file": return "Reading \(arguments["path"] as? String ?? "a file")…"
        case "list_directory": return "Listing \(arguments["path"] as? String ?? "a folder")…"
        case "find_files": return "Finding files named “\(arguments["name"] as? String ?? "")”…"
        default: return "Running \(name)…"
        }
    }

    /// Runs one call off the main thread (each tool has its own time limit),
    /// within `scope`: 7.3 checks every call again — a tool the scope
    /// doesn't offer, sources outside it (asked for or not: an empty or
    /// disjoint list is refused, never widened to every source) and paths
    /// outside its records and folders.
    static func run(_ name: String, arguments: [String: Any], scope: AOMAIRecordScope,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> AOMAIToolResult {
        await Task.detached(priority: .userInitiated) {
            runNow(name, arguments: arguments, scope: scope, home: home)
        }.value
    }

    /// Pure apart from the files it reads (tests).
    static func runNow(_ name: String, arguments: [String: Any], scope: AOMAIRecordScope, home: URL,
                       budget: TimeInterval = 3) -> AOMAIToolResult {
        guard scope.toolNames.contains(name) else {
            return AOMAIToolResult(text: "\(name) isn't allowed for this question. It may read only: \(scope.summary).",
                                   summary: "Refused \(name) (not allowed)", isError: true)
        }
        switch name {
        case "search_records":
            let query = (arguments["query"] as? String) ?? ""
            let allowed = scope.searchSources
            let asked = (arguments["sources"] as? [String] ?? []).compactMap(Source.init(rawValue:))
            let sources = asked.isEmpty ? allowed : allowed.filter(asked.contains)
            guard !sources.isEmpty else {
                return AOMAIToolResult(text: "None of those sources is allowed for this question; use: \(allowed.map(\.rawValue).joined(separator: ", ")).",
                                       summary: "Refused sources outside the question's scope", isError: true)
            }
            var result = search(query, sources: sources, home: home, budget: budget)
            result.used = sources.map(\.title)
            return result
        case "read_file":
            let full = resolve(arguments["path"] as? String ?? "", home: home)
            if let refusal = scope.readRefusal(full, home: home) {
                return AOMAIToolResult(text: refusal, summary: "Refused \(tilde(full, home: home)) (outside the scope)", isError: true)
            }
            var result = readFile(full, start: arguments["start_line"] as? Int ?? 1, count: arguments["max_lines"] as? Int ?? 200, home: home)
            if !result.isError { result.used = [tilde(full, home: home)] }
            return result
        case "list_directory":
            let full = resolve((arguments["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? scope.folders.first ?? "~", home: home)
            if let refusal = scope.folderRefusal(full) {
                return AOMAIToolResult(text: refusal, summary: "Refused \(tilde(full, home: home)) (outside the scope)", isError: true)
            }
            var result = listDirectory(full, home: home)
            if !result.isError { result.used = [tilde(full, home: home)] }
            return result
        case "find_files":
            var result = findFiles(arguments["name"] as? String ?? "", in: scope.folders.map { URL(fileURLWithPath: $0) }, home: home)
            if !result.isError { result.used = scope.folders.map { tilde($0, home: home) } }
            return result
        default:
            return AOMAIToolResult(text: "Unknown tool \(name).", summary: "Unknown tool \(name)", isError: true)
        }
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
            return agentDocNames.map { home.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        case .ssh_config:
            return [".ssh/config", ".ssh/known_hosts"].map { home.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        }
    }

    /// Lines that contain every word of `query`, from the newest files of all
    /// sources first (Codex audit B13), at most three per file and 30 in
    /// all, within `budget` seconds. With no such line, lines with the most
    /// words. 7.2.2: files are scanned as bytes (memmem on an ASCII-lowered
    /// copy) — 7.2.1 split 50 MB Claude logs into Swift strings and compared
    /// case-insensitively line by line, so one search could run for minutes
    /// and Ask AI sat on "Thinking…".
    static func search(_ query: String, sources: [Source], home: URL, budget: TimeInterval = 3) -> AOMAIToolResult {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else {
            return AOMAIToolResult(text: "Give search_records a word of at least two letters.", summary: "Empty search", isError: true)
        }
        let deadline = Date().addingTimeInterval(budget)
        var candidates: [(source: Source, url: URL, date: Date, size: Int)] = []
        // 7.3 (Codex 7.2.3 report): listing and dating the files counts
        // against the time limit too, and stops at it.
        listing: for source in sources {
            for url in files(of: source, home: home) {
                if Date() > deadline { break listing }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                candidates.append((source, url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
            }
        }
        candidates.sort { $0.date > $1.date }
        let forms = terms.map(Self.forms(of:))
        var hits: [Hit] = []
        var partial: [(hit: Hit, matched: Int)] = []
        var scanned = 0
        for candidate in candidates {
            if Date() > deadline || hits.count >= 30 { break }
            guard !Task.isCancelled else { break }
            guard candidate.size < 150_000_000,
                  let data = try? Data(contentsOf: candidate.url, options: .alwaysMapped) else { continue }
            scanned += 1
            let found = scan(data, forms: forms, limit: 3, deadline: deadline)
            let path = tilde(candidate.url.path, home: home)
            for match in found.full {
                hits.append(Hit(source: candidate.source, path: path, line: match.line, snippet: match.snippet, date: candidate.date))
            }
            if hits.isEmpty, partial.count < 60 {
                for match in found.partial {
                    partial.append((Hit(source: candidate.source, path: path, line: match.line, snippet: match.snippet, date: candidate.date),
                                    match.matched))
                }
            }
        }
        let shown: [Hit]
        var header: String
        if !hits.isEmpty {
            shown = Array(hits.prefix(30))
            header = "\(shown.count) line(s) containing every word of “\(query)” (\(scanned) of \(candidates.count) files read, newest first):"
        } else {
            shown = partial.sorted { $0.matched > $1.matched }.prefix(15).map(\.hit)
            header = shown.isEmpty ? "Nothing in \(scanned) of \(candidates.count) files contains “\(query)”. Try other or fewer words."
                : "No line has every word of “\(query)”; closest \(shown.count) in \(scanned) files:"
        }
        let body = shown.map { hit in
            "[\(hit.source.rawValue)] \(hit.path):\(hit.line) (\(hit.date.formatted(date: .abbreviated, time: .omitted)))\n    \(hit.snippet)"
        }.joined(separator: "\n")
        if scanned < candidates.count, hits.count < 30 {
            header += " Stopped at the \(Int(budget)) s limit; pass fewer sources to read more."
        }
        return AOMAIToolResult(text: header + (body.isEmpty ? "" : "\n" + body),
                               summary: "Searched records for “\(query)” · \(shown.count) match\(shown.count == 1 ? "" : "es")")
    }

    struct Match: Equatable {
        var line: Int
        var snippet: String
        var matched: Int
    }

    /// The bytes a term is looked for as: its UTF-8 with ASCII lowered and,
    /// for non-ASCII text, the JSON `\uXXXX` form Codex logs store Korean in
    /// (Codex audit B12: "검색" escaped was never found).
    static func forms(of term: String) -> [[UInt8]] {
        let lowered = term.lowercased()
        var result = [Array(lowered.utf8)]
        if lowered.unicodeScalars.contains(where: { !$0.isASCII }) {
            var escaped = ""
            for unit in lowered.utf16 {
                if unit < 0x80, let scalar = Unicode.Scalar(unit) { escaped.unicodeScalars.append(scalar) } else { escaped += String(format: "\\u%04x", unit) }
            }
            result.append(Array(escaped.utf8))
        }
        return result
    }

    /// Pure (tests): `matches` over a string.
    static func matches(in text: String, terms: [String], limit: Int) -> (full: [Match], partial: [Match]) {
        scan(Data(text.utf8), forms: terms.map { forms(of: $0.lowercased()) }, limit: limit, deadline: .distantFuture)
    }

    /// Lines of `data` with every term (any of its forms), and lines with
    /// some; the longest term leads and the rest are checked on its lines.
    static func scan(_ data: Data, forms: [[[UInt8]]], limit: Int, deadline: Date) -> (full: [Match], partial: [Match]) {
        guard !forms.isEmpty, !data.isEmpty else { return ([], []) }
        let lowered = lowercasedASCII(data)
        let lead = forms.indices.max { (forms[$0].first?.count ?? 0) < (forms[$1].first?.count ?? 0) } ?? 0
        var full: [Match] = [], partial: [Match] = []
        lowered.withUnsafeBufferPointer { hay in
            data.withUnsafeBytes { (original: UnsafeRawBufferPointer) in
                guard let base = hay.baseAddress else { return }
                let count = hay.count
                func find(_ needle: [UInt8], from: Int, to: Int) -> Int? {
                    guard !needle.isEmpty, to - from >= needle.count else { return nil }
                    return needle.withUnsafeBufferPointer { pointer -> Int? in
                        guard let found = memmem(base + from, to - from, pointer.baseAddress!, pointer.count) else { return nil }
                        return UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    }
                }
                // A file with none of the lead term's forms costs one pass.
                // With no line holding every term, the other terms get a
                // pass each for the closest lines (each line counted once).
                var seen = Set<Int>()
                func pass(_ leading: Int) {
                    var position = 0
                    var lineNumber = 1
                    var counted = 0
                    var checks = 0
                    while full.count < limit, position < count {
                        checks += 1
                        if checks % 64 == 0, Date() > deadline { break }
                        var hit: Int?
                        for form in forms[leading] {
                            if let index = find(form, from: position, to: count), index < (hit ?? .max) { hit = index }
                        }
                        guard let hit else { break }
                        var start = hit
                        while start > 0, base[start - 1] != 10 { start -= 1 }
                        let end = memchr(base + hit, 10, count - hit).map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? count
                        var cursor = counted
                        while cursor < start, let newline = memchr(base + cursor, 10, start - cursor) {
                            lineNumber += 1
                            cursor = (UnsafeRawPointer(newline) - UnsafeRawPointer(base)) + 1
                        }
                        counted = start
                        if seen.insert(start).inserted {
                            let matched = forms.filter { term in term.contains { find($0, from: start, to: end) != nil } }.count
                            let match = Match(line: lineNumber, snippet: snippet(original, from: start, to: end, hit: hit), matched: matched)
                            if matched == forms.count { full.append(match) } else if partial.count < limit { partial.append(match) }
                        }
                        if leading != lead, partial.count >= limit { break }
                        position = end + 1
                    }
                }
                pass(lead)
                if full.isEmpty {
                    for index in forms.indices where index != lead && partial.count < limit && Date() <= deadline { pass(index) }
                }
            }
        }
        return (full, partial)
    }

    /// Pure: `data` with A–Z lowered, eight bytes at a time (bytes of
    /// UTF-8 sequences are left alone). Three times faster than a byte loop:
    /// 271 MB of Claude logs in 0.3 s at -O.
    static func lowercasedASCII(_ data: Data) -> [UInt8] {
        var lowered = [UInt8](repeating: 0, count: data.count)
        data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            lowered.withUnsafeMutableBytes { target in
                guard let from = source.baseAddress, let to = target.baseAddress else { return }
                let words = source.count / 8
                for index in 0..<words {
                    let word = from.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)
                    let low = word & 0x7F7F_7F7F_7F7F_7F7F
                    let atLeastA = low &+ 0x3F3F_3F3F_3F3F_3F3F // bit 7 set when ≥ "A"
                    let pastZ = low &+ 0x2525_2525_2525_2525    // bit 7 set when > "Z"
                    let upper = atLeastA & ~pastZ & ~word & 0x8080_8080_8080_8080
                    to.storeBytes(of: word | (upper >> 2), toByteOffset: index * 8, as: UInt64.self)
                }
                for index in (words * 8)..<source.count {
                    let byte = source[index]
                    target[index] = byte &- 65 < 26 ? byte &+ 32 : byte
                }
            }
        }
        return lowered
    }

    /// ~600 bytes around `hit` within its line, cut on character
    /// boundaries, then made readable.
    private static func snippet(_ bytes: UnsafeRawBufferPointer, from lineStart: Int, to lineEnd: Int, hit: Int) -> String {
        var start = max(lineStart, hit - 300), end = min(lineEnd, hit + 300)
        while start > lineStart, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        while end < lineEnd, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        let cleaned = readable(text)
        let short = cleaned.count > 260 ? String(cleaned.prefix(260)) + "…" : cleaned
        return (start > lineStart ? "…" : "") + short + (end < lineEnd && cleaned.count <= 260 ? "…" : "")
    }

    /// JSON escapes undone, whitespace collapsed, secrets hidden.
    static func readable(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/")
        text = unescapeUnicode(text)
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return redact(text.trimmingCharacters(in: .whitespaces))
    }

    /// Pure: ~240 characters around `offset`, JSON escapes undone, one line, secrets hidden.
    static func snippet(_ line: String, around offset: Int, radius: Int = 120) -> String {
        let characters = Array(line)
        let start = max(0, offset - radius), end = min(characters.count, offset + radius)
        return (start > 0 ? "…" : "") + readable(String(characters[start..<end])) + (end < characters.count ? "…" : "")
    }

    /// Compiled once (7.3.2, agy NEW-04).
    private static let unicodeEscapes = try? NSRegularExpression(pattern: #"(?:\\u[0-9a-fA-F]{4})+"#)

    /// Codex logs escape Korean as \uXXXX; this turns it back into text.
    static func unescapeUnicode(_ text: String) -> String {
        guard text.contains("\\u") else { return text }
        guard let pattern = unicodeEscapes else { return text }
        var result = text
        // Runs of escapes decode together, so surrogate pairs (emoji) come back whole.
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let units = result[range].split(separator: "u").compactMap { UInt16($0.trimmingCharacters(in: CharacterSet(charactersIn: "\\")), radix: 16) }
            result.replaceSubrange(range, with: String(decoding: units, as: UTF16.self))
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
        let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
        guard size < 8_000_000 else {
            return AOMAIToolResult(text: "\(tilde(full, home: home)) is over 8 MB; read a smaller file or search it with search_records.",
                                   summary: "Too large: \(tilde(full, home: home))", isError: true)
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

    static func findFiles(_ name: String, home: URL) -> AOMAIToolResult { findFiles(name, in: [home], home: home) }

    /// 7.3 (Codex 7.2.3 report, B20): mdfind's output is read line by line
    /// while it runs and every path is dated as it arrives, keeping the 40
    /// newest — 7.2.3 collected all of it and dated only the first 5,000, so
    /// a recent file after those was never shown. A time-out says so
    /// instead of passing for "nothing found". Only inside `folders`.
    static func findFiles(_ name: String, in folders: [URL], home: URL, timeout: TimeInterval = 5) -> AOMAIToolResult {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return AOMAIToolResult(text: "Give a name of at least two letters.", summary: "Empty file search", isError: true) }
        guard !folders.isEmpty else { return AOMAIToolResult(text: "No folder to search.", summary: "No folder", isError: true) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = folders.flatMap { ["-onlyin", $0.path] } + ["-name", needle]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let newest = NewestPaths(limit: 40)
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { newest.add(line) }
                }
            }
            if !pending.isEmpty { newest.add(String(decoding: pending, as: UTF8.self)) }
            reading.leave()
        }
        do { try process.run() } catch {
            try? pipe.fileHandleForWriting.close()
            return AOMAIToolResult(text: "Spotlight didn't run.", summary: "Spotlight didn't run", isError: true)
        }
        let timedOut = reading.wait(timeout: .now() + timeout) == .timedOut
        if timedOut { process.terminate(); _ = reading.wait(timeout: .now() + 1) }
        let (count, dated) = newest.snapshot()
        let body = dated.map { "\(tilde($0.path, home: home))\t\($0.date.formatted(date: .abbreviated, time: .omitted))" }.joined(separator: "\n")
        let stopped = timedOut ? " Spotlight was stopped after \(Int(timeout)) s, so there may be more." : ""
        let text = count == 0 ? (timedOut ? "Spotlight didn't answer within \(Int(timeout)) s." : "Spotlight found nothing named like “\(needle)”.")
            : "\(count) match(es), newest first:\(stopped)\n" + body
        return AOMAIToolResult(text: text, summary: "Found files named “\(needle)” · \(count)\(timedOut ? " (stopped)" : "")", isError: count == 0 && timedOut)
    }
}

/// The `limit` most recently modified of the paths seen, and how many were seen.
final class NewestPaths: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    private var kept: [(path: String, date: Date)] = []

    init(limit: Int) { self.limit = limit }

    func add(_ path: String) {
        let date = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        lock.lock(); defer { lock.unlock() }
        count += 1
        if kept.count < limit {
            kept.append((path, date))
        } else if let oldest = kept.indices.min(by: { kept[$0].date < kept[$1].date }), kept[oldest].date < date {
            kept[oldest] = (path, date)
        }
    }

    func snapshot() -> (count: Int, newest: [(path: String, date: Date)]) {
        lock.lock(); defer { lock.unlock() }
        return (count, kept.sorted { $0.date > $1.date })
    }
}
