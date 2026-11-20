import AppKit
import Combine

// AOM 6.9: Raycast's Quick AI on the user's own agents.
//
// Raycast AI answers in the launcher (Tab from the root search), keeps a
// conversation for follow-ups, pastes the answer into the app you were in
// with ↩, and moves a conversation into a full chat with ⌘J
// (manual.raycast.com/ai/quick-ai). AOM has no model of its own: it runs
// the CLIs already on this Mac — Claude Code (`claude -p … --output-format
// stream-json`) and Codex (`codex exec --json`) — so answers come from the
// accounts and settings the user already has. In the launcher they run
// read-only (Claude Code's plan mode, Codex's read-only sandbox); anything
// that should edit files or run commands continues in Terminal (⌘J), in an
// interactive session where the CLI asks for each permission itself.

enum PaletteAIProvider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Where the CLI is on this Mac: the user's own launcher first
    /// (~/.local/bin/claude routes like their terminal), then the installs.
    var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .claude:
            return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                    "\(home)/.npm-global/bin/claude", "\(home)/.claude/local/claude"]
        case .codex:
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                    "\(home)/.npm-global/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                    "/Applications/Codex.app/Contents/Resources/codex"]
        }
    }

    var executable: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Pure: the arguments of one read-only turn.
    func arguments(prompt: String, session: String?) -> [String] {
        switch self {
        case .claude:
            var args = ["-p", prompt, "--output-format", "stream-json", "--include-partial-messages", "--verbose",
                        "--permission-mode", "plan"]
            if let session { args += ["--resume", session] }
            return args
        case .codex:
            return ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", prompt]
        }
    }

    /// The interactive command that continues a conversation in Terminal.
    func terminalCommand(session: String?, prompt: String?) -> String {
        let quoted = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let exe = quoted(executable ?? (self == .claude ? "claude" : "codex"))
        switch self {
        case .claude:
            if let session { return "\(exe) --resume \(quoted(session))" }
            return prompt.map { "\(exe) \(quoted($0))" } ?? exe
        case .codex:
            if let session { return "\(exe) resume \(quoted(session))" }
            return prompt.map { "\(exe) \(quoted($0))" } ?? exe
        }
    }
}

/// One line of the CLI's JSON stream, reduced to what the panel shows. Pure.
enum PaletteAIEvent: Equatable {
    case session(String)
    case delta(String)
    case message(String)
    case done(String?)
    case failure(String)

    static func parse(_ line: String, provider: PaletteAIProvider) -> [PaletteAIEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch provider {
        case .claude:
            switch type {
            case "system":
                return (object["subtype"] as? String) == "init" ? (object["session_id"] as? String).map { [.session($0)] } ?? [] : []
            case "stream_event":
                guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                      let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return [] }
                return [.delta(text)]
            case "result":
                var events: [PaletteAIEvent] = []
                if let session = object["session_id"] as? String { events.append(.session(session)) }
                if (object["is_error"] as? Bool) == true {
                    events.append(.failure((object["result"] as? String) ?? "Claude Code reported an error."))
                } else {
                    events.append(.done(object["result"] as? String))
                }
                return events
            default:
                return []
            }
        case .codex:
            switch type {
            case "thread.started":
                return (object["thread_id"] as? String).map { [.session($0)] } ?? []
            case "item.completed":
                guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                      let text = item["text"] as? String else { return [] }
                return [.message(text)]
            case "turn.completed":
                return [.done(nil)]
            case "error":
                return [.failure((object["message"] as? String) ?? "Codex reported an error.")]
            case "turn.failed":
                let error = object["error"] as? [String: Any]
                return [.failure((error?["message"] as? String) ?? "Codex couldn't finish the turn.")]
            default:
                return []
            }
        }
    }
}

/// The launcher's conversation. Shared, so closing and reopening the
/// launcher keeps it; after ten quiet minutes a question starts a new one
/// (Raycast's auto-new chat).
@MainActor
final class PaletteAIChat: ObservableObject {
    static let shared = PaletteAIChat()

    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, error }
        let id = UUID()
        let role: Role
        var text: String
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isRunning = false
    @Published var provider: PaletteAIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "AOMLauncherAIProvider")
            if oldValue != provider { newChat() }
        }
    }

    private var sessions: [PaletteAIProvider: String] = [:]
    private var process: Process?
    private var lastActivity = Date.distantPast
    static let idleReset: TimeInterval = 600

    init() {
        provider = PaletteAIProvider(rawValue: UserDefaults.standard.string(forKey: "AOMLauncherAIProvider") ?? "") ?? .claude
    }

    var session: String? { sessions[provider] }
    var lastAnswer: String? { messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text }
    var lastQuestion: String? { messages.last { $0.role == .user }?.text }

    func newChat() {
        cancel()
        messages = []
        sessions = [:]
    }

    func cancel() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        isRunning = false
    }

    func ask(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        if Date().timeIntervalSince(lastActivity) > Self.idleReset { messages = []; sessions = [:] }
        lastActivity = Date()
        messages.append(Message(role: .user, text: text))
        guard let executable = provider.executable else {
            messages.append(Message(role: .error, text: "\(provider.title) isn't installed on this Mac (looked in \(provider.candidates.prefix(3).joined(separator: ", ")))."))
            return
        }
        // Codex has no streaming resume here: earlier turns go with the question.
        let sent = provider == .codex ? Self.withHistory(text, messages.dropLast()) : text
        messages.append(Message(role: .assistant, text: ""))
        run(executable, arguments: provider.arguments(prompt: sent, session: provider == .claude ? session : nil))
    }

    /// Pure: earlier turns as context for a CLI without a resumable session.
    nonisolated static func withHistory(_ prompt: String, _ earlier: ArraySlice<Message>) -> String {
        let turns = earlier.filter { $0.role != .error && !$0.text.isEmpty }.suffix(6)
        guard !turns.isEmpty else { return prompt }
        let history = turns.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        return "Conversation so far:\n\(history)\n\nUser: \(prompt)"
    }

    private func run(_ executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A GUI app gets launchd's PATH; the CLIs need the user's.
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        environment["TERM"] = "dumb"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let provider = self.provider
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            let events = lines.flatMap { PaletteAIEvent.parse($0, provider: provider) }
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { self?.apply(events, provider: provider) }
        }
        var errorText = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in errorText.append(handle.availableData) }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let stderr = String(decoding: errorText.suffix(2000), as: UTF8.self)
            DispatchQueue.main.async { self?.finish(status: status, stderr: stderr) }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
            // A turn that hangs is ended after five minutes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
        } catch {
            replaceLast(with: Message(role: .error, text: "Couldn't start \(provider.title): \(error.localizedDescription)"))
        }
    }

    private func apply(_ events: [PaletteAIEvent], provider: PaletteAIProvider) {
        guard provider == self.provider else { return }
        for event in events {
            switch event {
            case .session(let id): sessions[provider] = id
            case .delta(let text): appendToAnswer(text)
            case .message(let text): appendToAnswer(messages.last?.text.isEmpty == false ? "\n\n" + text : text)
            case .done(let text):
                if let text, !text.isEmpty, messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
                    appendToAnswer(text)
                }
            case .failure(let text): replaceLast(with: Message(role: .error, text: text))
            }
        }
    }

    private func appendToAnswer(_ text: String) {
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text += text
    }

    private func replaceLast(with message: Message) {
        if let index = messages.indices.last, messages[index].role == .assistant, messages[index].text.isEmpty {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func finish(status: Int32, stderr: String) {
        process = nil
        isRunning = false
        lastActivity = Date()
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            let reason = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            replaceLast(with: Message(role: .error, text: status == 15 ? "Stopped." : "\(provider.title) didn't answer (\(reason))."))
        }
    }

    /// ⌘J: the conversation in Terminal, interactive, where the CLI asks
    /// for each permission itself. A .command file needs no Automation access.
    func continueInTerminal() -> Bool {
        let command = provider.terminalCommand(session: session, prompt: session == nil ? lastQuestion : nil)
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AllOfMacOS/AI", isDirectory: true)
        let file = folder.appendingPathComponent("continue-\(provider.rawValue).command")
        let script = "#!/bin/zsh -l\ncd ~\n\(command)\n"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(file)
    }
}

/// Raycast's AI Commands on the selected text ({selection}).
struct PaletteAICommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let template: String
    var aliases: [String] = []

    static let all: [PaletteAICommand] = [
        .init(id: "ai.summarize", title: "Summarize Selection", symbol: "text.append",
              template: "Summarize this in three short bullet points, in the language it is written in:\n\n\"\"\"\n{selection}\n\"\"\"",
              aliases: ["summarize", "요약"]),
        .init(id: "ai.fix", title: "Fix Spelling and Grammar", symbol: "textformat.abc",
              template: "Fix spelling and grammar. Keep the meaning, tone and language. Reply with the corrected text only:\n\n\"\"\"\n{selection}\n\"\"\"",
              aliases: ["fix spelling", "grammar", "맞춤법"]),
        .init(id: "ai.english", title: "Translate Selection to English", symbol: "character.bubble",
              template: "Translate into natural English. Reply with the translation only:\n\n\"\"\"\n{selection}\n\"\"\"",
              aliases: ["translate english", "영어로", "영어 번역"]),
        .init(id: "ai.korean", title: "Translate Selection to Korean", symbol: "character.bubble.fill",
              template: "Translate into natural Korean. Reply with the translation only:\n\n\"\"\"\n{selection}\n\"\"\"",
              aliases: ["translate korean", "한국어로", "한글 번역", "번역"]),
        .init(id: "ai.explain", title: "Explain Selection", symbol: "questionmark.bubble",
              template: "Explain this clearly and briefly (code: what it does and any bug you see):\n\n\"\"\"\n{selection}\n\"\"\"",
              aliases: ["explain", "설명"]),
        .init(id: "ai.clipboard", title: "Ask AI About the Clipboard", symbol: "doc.on.clipboard",
              template: "Help me with this (summarize it if it's long):\n\n\"\"\"\n{clipboard}\n\"\"\"",
              aliases: ["clipboard ai", "클립보드 질문"]),
    ]

    var needsSelection: Bool { template.contains("{selection}") }

    /// Pure: the prompt with its placeholders filled, nil when one is empty.
    static func fill(_ template: String, selection: String?, clipboard: String?) -> String? {
        var prompt = template
        if prompt.contains("{selection}") {
            guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            prompt = prompt.replacingOccurrences(of: "{selection}", with: selection)
        }
        if prompt.contains("{clipboard}") {
            guard let clipboard, !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            prompt = prompt.replacingOccurrences(of: "{clipboard}", with: clipboard)
        }
        return prompt
    }

    /// The front app's selected text through Accessibility, never from a
    /// password field. Off the main thread (AX can stall).
    static func selectedText(in app: NSRunningApplication?) async -> String? {
        guard let pid = app?.processIdentifier, AXIsProcessTrusted() else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let read = TextSelectionReader.readAttributes(pid: pid) else { return nil }
            let attributes = read.attributes
            if TextActionsGate.isPasswordField(role: attributes.role, subrole: attributes.subrole) { return nil }
            return attributes.selectedText
        }.value
    }
}
