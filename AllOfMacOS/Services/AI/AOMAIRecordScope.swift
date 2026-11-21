import AppKit
import Foundation

// AOM 7.3: what one Ask AI question may read (DeepSeek design v2 §3, Codex
// 7.2.3 report pp. 4–5).
//
// 7.2.1–7.2.3 gave every tool-capable model all four record tools whenever
// the global "Let Ask AI search and read your records" switch was on (the
// default), and the executor searched every source when the model named
// none — the SSH config included. A question now reads nothing unless it
// names what it may read: @wiki, @memories, @claude, @codex, @chats,
// @shell, @docs (@mac is wiki + memories + docs), @files (a folder the
// person chose), @ssh (~/.ssh/config and known_hosts only) and @clip (the
// current clipboard text, attached once). The scope is fixed when the
// question is sent and is the same for the system prompt, the tool schemas
// (one definition per tool name, its source list cut to what was allowed),
// and every tool round; the executor checks each call against it again.

/// Where a question goes, said before it is sent.
enum AOMAIEgress: Equatable {
    /// Answered on this Mac (Apple Intelligence; Ollama on a loopback address with a local model).
    case onDevice
    /// A router on this Mac that forwards to someone else (claude-code-proxy's
    /// haiku route goes to DeepSeek): treated as external.
    case loopbackProxy(host: String)
    case external(host: String)
    /// A CLI agent with its own read-only access.
    case agent

    var leavesMac: Bool {
        switch self {
        case .onDevice, .agent: return false
        case .loopbackProxy, .external: return true
        }
    }

    /// "On this Mac", "Local Proxy → DeepSeek (external)", "Sent to api.openai.com".
    func label(_ provider: AOMAIProvider) -> String {
        switch self {
        case .onDevice: return "On this Mac"
        case .loopbackProxy: return "Local Proxy · forwards outside this Mac"
        case .external(let host): return "Sent to \(host.isEmpty ? provider.title : host)"
        case .agent: return "\(provider.title) · its own read-only access"
        }
    }

    /// A short word for the transcript line.
    var short: String {
        switch self {
        case .onDevice: return "On device"
        case .loopbackProxy: return "Via local proxy (external)"
        case .external(let host): return host
        case .agent: return "Agent"
        }
    }
}

extension AOMAIProvider {
    /// Pure: where a question to this provider and model goes. An Ollama
    /// address that isn't loopback, or a cloud model ("…-cloud", ":cloud")
    /// that Ollama runs remotely, is external.
    func egress(model: String, baseURL: String) -> AOMAIEgress {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        switch self {
        case .apple: return .onDevice
        case .claudeCode, .codex, .deepSeekHarness: return .agent
        case .localProxy: return loopback ? .loopbackProxy(host: host) : .external(host: host)
        case .ollama:
            let cloud = model.lowercased().hasSuffix("-cloud") || model.lowercased().contains(":cloud")
            return loopback && !cloud ? .onDevice : .external(host: cloud ? "ollama.com" : host)
        case .anthropic, .openAI, .deepSeek: return .external(host: host)
        }
    }

    /// Calls AOM's record tools (Anthropic Messages or OpenAI chat).
    var takesRecordTools: Bool { isAnthropicCompatible || isOpenAICompatible }
}

/// One thing a question may read.
enum AOMAIRecordSource: String, CaseIterable, Codable, Identifiable, Comparable {
    case wiki, memories, claude, codex, chats, shell, docs, files, ssh, clip

    var id: String { rawValue }

    static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    var mention: String { "@" + rawValue }

    var title: String {
        switch self {
        case .wiki: return "LLM Wiki"
        case .memories: return "Claude memories"
        case .claude: return "Claude Code logs"
        case .codex: return "Codex logs"
        case .chats: return "AOM AI chats"
        case .shell: return "Shell history"
        case .docs: return "Agent instructions"
        case .files: return "A folder"
        case .ssh: return "SSH config"
        case .clip: return "Clipboard text"
        }
    }

    var detail: String {
        switch self {
        case .wiki: return "~/.agents/llm-wiki — runbooks, architecture, decisions"
        case .memories: return "~/.claude/projects/*/memory"
        case .claude: return "Claude Code conversation logs (other AI chats)"
        case .codex: return "Codex conversation logs (other AI chats)"
        case .chats: return "Earlier Ask AI conversations"
        case .shell: return "~/.zsh_history and ~/.bash_history"
        case .docs: return "AGENTS.md, CLAUDE.md, Codex config"
        case .files: return "Only the folder you choose, read-only"
        case .ssh: return "~/.ssh/config and known_hosts — never keys"
        case .clip: return "The text on the clipboard now, attached once"
        }
    }

    var symbol: String {
        switch self {
        case .wiki: return "books.vertical"
        case .memories: return "brain"
        case .claude: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .chats: return "bubble.left.and.text.bubble.right"
        case .shell: return "clock.arrow.circlepath"
        case .docs: return "doc.text"
        case .files: return "folder"
        case .ssh: return "network"
        case .clip: return "doc.on.clipboard"
        }
    }

    /// Needs a choice of its own beyond @mac: other AI chats, shell
    /// history, SSH and folders.
    var isSensitive: Bool { [.claude, .codex, .chats, .shell, .ssh, .files].contains(self) }

    /// What search_records reads for it.
    var searchSources: [AOMAILocalTools.Source] {
        switch self {
        case .wiki: return [.wiki]
        case .memories: return [.memories]
        case .claude: return [.claude_sessions]
        case .codex: return [.codex_sessions]
        case .chats: return [.aom_chats]
        case .shell: return [.shell_history]
        case .docs: return [.agent_docs]
        case .ssh: return [.ssh_config]
        case .files, .clip: return []
        }
    }

    /// @mac: the records that hold no other AI's conversations, no shell
    /// history and nothing about SSH.
    static let mac: [AOMAIRecordSource] = [.wiki, .memories, .docs]
}

/// What a question may read, fixed when it is sent.
struct AOMAIRecordScope: Equatable, Codable {
    var sources: Set<AOMAIRecordSource> = []
    /// Folders for @files (absolute, standardized).
    var folders: [String] = []

    static let none = AOMAIRecordScope()

    var isEmpty: Bool { sources.subtracting([.clip]).isEmpty && folders.isEmpty }
    var attachesClipboard: Bool { sources.contains(.clip) }

    /// Fixed order, so the schemas and the tests are stable.
    var ordered: [AOMAIRecordSource] { sources.sorted() }

    /// search_records' sources, in the tool's own order.
    var searchSources: [AOMAILocalTools.Source] {
        let wanted = Set(ordered.flatMap(\.searchSources))
        return AOMAILocalTools.Source.allCases.filter(wanted.contains)
    }

    var hasFolders: Bool { sources.contains(.files) && !folders.isEmpty }

    /// The tools this scope offers, each name once (DeepSeek v2 §3.3: two
    /// mentions never add a tool twice; Anthropic and OpenAI reject that).
    var toolNames: [String] {
        var names: [String] = []
        if !searchSources.isEmpty { names.append("search_records") }
        if !searchSources.isEmpty || hasFolders { names.append("read_file") }
        if hasFolders { names += ["list_directory", "find_files"] }
        return names
    }

    /// "LLM Wiki, Claude memories, ~/Projects".
    var summary: String {
        var parts = ordered.filter { $0 != .files }.map(\.title)
        if sources.contains(.files) { parts += folders.map { ($0 as NSString).abbreviatingWithTildeInPath } }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: ", ")
    }

    func union(_ other: AOMAIRecordScope) -> AOMAIRecordScope {
        var merged = self
        merged.sources.formUnion(other.sources)
        for folder in other.folders where !merged.folders.contains(folder) { merged.folders.append(folder) }
        return merged
    }

    // MARK: Reading paths

    /// Pure: why this scope doesn't let `path` be read (nil: it may, after
    /// the tools' own refusals for keys and credentials).
    func readRefusal(_ path: String, home: URL) -> String? {
        let real = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ root: String) -> Bool { real == root || real.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        func file(_ relative: String) -> String { homePath + "/" + relative }
        for source in ordered {
            switch source {
            case .wiki: if inside(file(".agents/llm-wiki")) { return nil }
            case .memories:
                if inside(file(".claude/projects")), real.contains("/memory/") { return nil }
            case .claude:
                if inside(file(".claude/projects")), real.hasSuffix(".jsonl") { return nil }
            case .codex: if inside(file(".codex/sessions")) { return nil }
            case .chats: if real == file("Library/Application Support/AllOfMacOS/AI/chats.json") { return nil }
            case .shell: if [file(".zsh_history"), file(".bash_history")].contains(real) { return nil }
            case .docs:
                if AOMAILocalTools.agentDocNames.map(file).contains(real) { return nil }
            case .ssh: if [file(".ssh/config"), file(".ssh/known_hosts")].contains(real) { return nil }
            case .files:
                for folder in folders {
                    let root = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
                    if inside(root) { return nil }
                }
            case .clip: break
            }
        }
        return "This question may read only: \(summary). \((real as NSString).abbreviatingWithTildeInPath) is outside that; ask again with an @ mention (for example @files) to allow it."
    }

    /// Pure: the folders list_directory and find_files may use.
    func folderRefusal(_ path: String) -> String? {
        guard hasFolders else { return "This question may not list or search folders. Mention @files and choose a folder to allow it." }
        let real = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        for folder in folders {
            let root = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
            if real == root || real.hasPrefix(root + "/") { return nil }
        }
        return "Only \(folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) may be listed in this question."
    }

    // MARK: Mentions

    /// What a question's @ mentions name, and the question without them.
    /// A mention is a word that starts with @ at the start or after a
    /// space; unknown ones (an e-mail address, "@someone") stay in the text.
    static func parse(_ text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      lastFolders: [String] = []) -> (question: String, scope: AOMAIRecordScope, unknown: [String]) {
        var scope = AOMAIRecordScope()
        var unknown: [String] = []
        // A mention starts the text or follows any whitespace (a new line
        // too). Only recognised mentions are cut out; everything else —
        // line breaks, indentation, code — stays exactly as written
        // (7.3 review, Codex probe: "explain:\n\n    return  a" lost both).
        guard let pattern = try? NSRegularExpression(pattern: #"(?:^|(?<=\s))@\S+"#) else { return (text, scope, unknown) }
        let ns = text as NSString
        var removals: [NSRange] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            let token = String(word.dropFirst())
            let lowered = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?)"))
            var recognised = true
            if let folder = folderArgument(token, home: home) {
                scope.sources.insert(.files)
                if !scope.folders.contains(folder) { scope.folders.append(folder) }
            } else {
                switch lowered {
                case "mac": scope.sources.formUnion(AOMAIRecordSource.mac)
                case "memory", "memories": scope.sources.insert(.memories)
                case "clipboard": scope.sources.insert(.clip)
                case "history": scope.sources.insert(.shell)
                case "files", "folder":
                    scope.sources.insert(.files)
                    for folder in lastFolders where !scope.folders.contains(folder) { scope.folders.append(folder) }
                default:
                    if let source = AOMAIRecordSource(rawValue: lowered), source != .files { scope.sources.insert(source) }
                    else { recognised = false; unknown.append(word) }
                }
            }
            guard recognised else { continue }
            // The mention without punctuation that ends a sentence ("why @mac?"
            // keeps its "?"), and one space after it (or before it).
            var range = match.range
            let trailing = word.reversed().prefix { ",.;:!?)".contains($0) }.count
            if trailing < word.count - 1 { range.length -= (word as NSString).length - (String(word.dropLast(trailing)) as NSString).length }
            let after = range.location + range.length
            if after < ns.length, [" ", "\t"].contains(ns.substring(with: NSRange(location: after, length: 1))) {
                range.length += 1
            } else if range.location > 0, ns.substring(with: NSRange(location: range.location - 1, length: 1)) == " " {
                range.location -= 1
                range.length += 1
            }
            removals.append(range)
        }
        let kept = NSMutableString(string: text)
        for range in removals.reversed() { kept.replaceCharacters(in: range, with: "") }
        // A comma left at the very start by "@wiki, how…" goes too.
        var question = (kept as String).trimmingCharacters(in: .whitespacesAndNewlines)
        if !removals.isEmpty { question = String(question.drop { ",;:".contains($0) || $0 == " " }) }
        return (question, scope, unknown)
    }

    /// "@files:~/Projects", "@~/Projects", "@/Users/me/x" → the folder (it must exist).
    static func folderArgument(_ token: String, home: URL) -> String? {
        var path: String
        if token.lowercased().hasPrefix("files:") { path = String(token.dropFirst(6)) }
        else if token.hasPrefix("~/") || token.hasPrefix("/") { path = token }
        else { return nil }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        guard !path.isEmpty else { return nil }
        let full = AOMAILocalTools.resolve(path, home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: full).standardizedFileURL.path
    }

    // MARK: Clipboard

    /// The clipboard's text for @clip, or why it isn't attached.
    static func clipboardText(_ pasteboard: NSPasteboard = .general, limit: Int = 20_000) -> Result<String, AOMAIError> {
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failure(AOMAIError(message: "The clipboard has no text to attach."))
        }
        if ClipboardSecretScanner.containsSecret(inText: text) {
            return .failure(AOMAIError(message: "The clipboard looks like it holds a password or key, so it wasn't attached."))
        }
        guard text.count <= limit else {
            return .failure(AOMAIError(message: "The clipboard text is over \(limit / 1000)k characters; copy less and ask again."))
        }
        return .success(text)
    }
}

/// How the records setting reads (Settings › AI).
enum AOMAIRecordsMode: String, CaseIterable, Identifiable {
    /// Only what a question names with @ (the default since 7.3).
    case mentions
    /// Never, even when mentioned.
    case never

    var id: String { rawValue }

    static let key = "AOMAIRecordsMode"
    static let onDeviceKey = "AOMAIRecordsOnDevice"

    /// 7.3 migration: the 7.2 switch turned off stays off.
    static var current: AOMAIRecordsMode {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: key), let mode = AOMAIRecordsMode(rawValue: raw) { return mode }
            if defaults.object(forKey: AOMAILocalTools.enabledKey) as? Bool == false { return .never }
            return .mentions
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            UserDefaults.standard.set(newValue != .never, forKey: AOMAILocalTools.enabledKey)
        }
    }

    /// On-device models (a local Ollama model) may read @mac without a
    /// mention. Off unless chosen.
    static var onDeviceReadsMac: Bool {
        get { UserDefaults.standard.bool(forKey: onDeviceKey) }
        set { UserDefaults.standard.set(newValue, forKey: onDeviceKey) }
    }

    /// Pure: the scope a question gets.
    static func effective(_ asked: AOMAIRecordScope, egress: AOMAIEgress, mode: AOMAIRecordsMode, onDeviceReadsMac: Bool) -> AOMAIRecordScope {
        guard mode != .never else { return AOMAIRecordScope(sources: asked.sources.intersection([.clip])) }
        if asked.isEmpty, egress == .onDevice, onDeviceReadsMac {
            var scope = asked
            scope.sources.formUnion(AOMAIRecordSource.mac)
            return scope
        }
        return asked
    }
}

/// What a question shared, shown under its answer ("AI 자료 영수증").
struct AOMAIReceipt: Equatable, Codable {
    var destination: String
    var leavesMac: Bool
    var allowed: String
    /// "LLM Wiki · 2 searches", "~/Projects/x.md".
    var used: [String] = []
    var earlierTurns: Int = 0
    var clipboardAttached = false
    var note: String?

    var line: String {
        var parts = [destination]
        parts.append(allowed == "Nothing" ? "No records" : "Allowed: \(allowed)")
        if !used.isEmpty { parts.append("Used: " + used.joined(separator: ", ")) }
        else if allowed != "Nothing" { parts.append("Nothing read") }
        if clipboardAttached { parts.append("Clipboard attached") }
        if earlierTurns > 0 { parts.append("\(earlierTurns) earlier turn\(earlierTurns == 1 ? "" : "s") sent") }
        if let note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}
