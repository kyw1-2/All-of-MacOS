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
    // 7.0: kept as the agents beside the native models (AOMAIProvider).
    case claude, codex
    /// 7.2.2: DeepSeek Harness's headless profile (AOMDeepSeekHarness).
    case dsh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .dsh: return "DeepSeek Harness"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .dsh: return "water.waves"
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
                    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                    "/Applications/Codex.app/Contents/Resources/codex"]
        case .dsh:
            return [AOMDeepSeekHarness.executable?.path ?? "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"]
        }
    }

    var executable: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Pure: the arguments of one read-only turn.
    func arguments(prompt: String, session: String?, model: String = "default") -> [String] {
        switch self {
        case .claude:
            var args = ["-p", prompt, "--output-format", "stream-json", "--include-partial-messages", "--verbose",
                        "--permission-mode", "plan"]
            if let session { args += ["--resume", session] }
            return args
        case .codex:
            var args = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"]
            if model != "default" { args += ["--model", model] }
            return args + ["--", prompt]
        case .dsh:
            return AOMDeepSeekHarness.arguments(script: AOMDeepSeekHarness.binScript(in: AOMDeepSeekHarness.runtimeFolder()),
                                                prompt: prompt, session: session)
        }
    }

    /// The interactive command that continues a conversation in Terminal.
    func terminalCommand(session: String?, prompt: String?, model: String = "default") -> String {
        let quoted = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let exe = quoted(executable ?? (self == .claude ? "claude" : "codex"))
        switch self {
        case .dsh:
            // There is no interactive dsh command; ⌘J opens the app instead.
            return "open -b \(AOMDeepSeekHarness.bundleID)"
        case .claude:
            if let session { return "\(exe) --resume \(quoted(session))" }
            return prompt.map { "\(exe) \(quoted($0))" } ?? exe
        case .codex:
            let command = model == "default" ? exe : "\(exe) --model \(quoted(model))"
            if let session { return "\(command) resume \(quoted(session))" }
            return prompt.map { "\(command) -- \(quoted($0))" } ?? command
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
    /// 7.2.2: what the agent is doing now (a command, a file), shown under the answer.
    case activity(String)

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
        case .dsh:
            switch type {
            case "session":
                return (object["sessionId"] as? String).map { [.session($0)] } ?? []
            case "text":
                // One whole step's text at a time; steps are joined by a blank line.
                return (object["text"] as? String).map { $0.isEmpty ? [] : [.message($0)] } ?? []
            case "tool_call":
                let tool = object["tool"] as? String ?? "tool"
                let input = object["input"] as? [String: Any] ?? [:]
                let detail = (input["command"] ?? input["file_path"] ?? input["path"] ?? input["pattern"] ?? input["query"]) as? String
                return [.activity(detail.map { "\(tool): \(String($0.prefix(80)))" } ?? tool)]
            case "final":
                return [.done(object["text"] as? String)]
            case "error":
                return [.failure((object["message"] as? String) ?? "DeepSeek Harness reported an error.")]
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

/// The launcher's conversation (7.0). Shared, so closing and reopening the
/// launcher keeps it; after ten quiet minutes a question starts a new one
/// (Raycast's auto-new chat). Answers come from the chosen model: a native
/// provider streams over HTTP (or on-device), an agent through its CLI —
/// Claude Code in one warm session that stays up between questions, so
/// only the first question pays for its start-up.
@MainActor
final class PaletteAIChat: ObservableObject {
    static let shared = PaletteAIChat()

    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, error }
        let id = UUID()
        let role: Role
        var text: String
        /// The model that answered ("Claude Opus 5.5").
        var model: String? = nil
        /// Why an answer stopped early.
        var notice: String? = nil
        /// Reasoning before the first word.
        var thinking = false
        /// 7.3: a question's records ("LLM Wiki, ~/Projects") and the
        /// clipboard text it carries; an answer's receipt.
        var scopeSummary: String? = nil
        /// The records this question was allowed (Ask Again uses the same).
        var scope: AOMAIRecordScope? = nil
        /// 7.4: @clip, @window, @screen text, read when it was sent.
        var attachments: [AOMAIAttachment] = []
        var receipt: AOMAIReceipt? = nil

        /// What goes to the model: the question and its attachments.
        var sentText: String { text + attachments.map(\.sent).joined() }
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var isRunning = false
    /// 7.0: provider and model, persisted. Switching keeps the conversation.
    @Published var model: AOMAIModelRef {
        didSet {
            guard oldValue != model else { return }
            AOMAIConfig.selectedModel = model
            if oldValue.provider != model.provider || oldValue.provider.isAgent { agentSession.stop() }
            // 7.3 (Codex 7.2.3 report): a conversation doesn't follow the
            // person to another provider unasked. Turns before the switch
            // stay on this Mac until "Include Earlier Turns".
            if oldValue.provider != model.provider, messages.contains(where: { $0.role == .user }) {
                historyStart = messages.count
            }
        }
    }
    @Published private(set) var chatID = UUID()
    /// 7.3: turns before this index aren't sent (a switch to another provider).
    @Published private(set) var historyStart = 0
    /// 7.3: records chosen for the next question (the Records screen); they
    /// go with that question only.
    @Published var pendingScope = AOMAIRecordScope.none
    /// The last question's records (⌘⇧M uses them again).
    @Published private(set) var lastScope = AOMAIRecordScope.none
    /// Folders chosen for @files before, offered again.
    @Published var recentFolders: [String] = UserDefaults.standard.stringArray(forKey: "AOMAIRecentFolders") ?? [] {
        didSet { UserDefaults.standard.set(Array(recentFolders.prefix(8)), forKey: "AOMAIRecentFolders") }
    }

    /// Earlier turns held back since the switch to this provider.
    var heldTurns: Int { messages.prefix(historyStart).filter { $0.role != .error && !$0.text.isEmpty }.count }

    func includeEarlierTurns() { historyStart = 0 }

    func reuseLastScope() { pendingScope = pendingScope.union(lastScope) }

    func clearPendingScope() { pendingScope = .none }

    func toggle(_ source: AOMAIRecordSource) {
        if pendingScope.sources.contains(source) {
            pendingScope.sources.remove(source)
            if source == .files { pendingScope.folders = [] }
        } else {
            pendingScope.sources.insert(source)
        }
    }

    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        pendingScope.sources.insert(.files)
        if !pendingScope.folders.contains(path) { pendingScope.folders.append(path) }
        recentFolders.removeAll { $0 == path }
        recentFolders.insert(path, at: 0)
    }

    /// Where the current model sends a question.
    var egress: AOMAIEgress { model.provider.egress(model: model.model, baseURL: AOMAIConfig.baseURL(for: model.provider)) }

    /// 6.9 API kept for the agent paths and the tests.
    var provider: PaletteAIProvider { model.provider == .codex ? .codex : model.provider == .deepSeekHarness ? .dsh : .claude }
    var agent: PaletteAIProvider? {
        switch model.provider {
        case .claudeCode: return .claude
        case .codex: return .codex
        case .deepSeekHarness: return .dsh
        default: return nil
        }
    }

    private var sessions: [PaletteAIProvider: String] = [:]
    private var process: Process?
    private var task: Task<Void, Never>?
    private let agentSession = PaletteAgentSession()
    private var lastActivity = Date.distantPast
    /// Tokens collected between two screen updates (one update per frame).
    private var pending = ""
    private var flushScheduled = false
    static let idleReset: TimeInterval = 600

    init() {
        model = AOMAIConfig.selectedModel
        agentSession.onEvents = { [weak self] events in self?.applyAgent(events) }
        agentSession.onExit = { [weak self] status, stderr in self?.finishAgent(status: status, stderr: stderr) }
    }

    var session: String? { sessions[provider] }
    var lastAnswer: String? { messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text }
    var lastQuestion: String? { messages.last { $0.role == .user }?.text }
    var title: String { messages.first { $0.role == .user }.map { String($0.text.prefix(60)) } ?? "New Chat" }

    /// Starts the agent's CLI before the first question (the Ask AI screen opened).
    func prewarm() {
        if model.provider == .apple { AOMAppleIntelligence.prewarm(system: systemPrompt); return }
        // 7.2.1: the local router starts while the question is typed.
        if model.provider == .localProxy { Task { _ = await AOMLocalProxy.ensureRunning() }; return }
        guard agent == .claude, let executable = PaletteAIProvider.claude.executable else { return }
        agentSession.start(executable: executable, model: model.model, system: systemPrompt, resume: session)
    }

    func newChat() {
        cancel()
        AOMAIChatHistory.shared.save(self)
        messages = []
        sessions = [:]
        chatID = UUID()
        historyStart = 0
        // Records chosen for a question go with that chat's next question only.
        pendingScope = .none
        agentSession.stop()
    }

    /// Opens a saved conversation (AI Chat's sidebar).
    func load(_ record: AOMAIChatHistory.Record) {
        cancel()
        AOMAIChatHistory.shared.save(self)
        agentSession.stop()
        chatID = record.id
        messages = record.messages.map {
            Message(role: $0.role == "user" ? .user : .assistant, text: $0.text, model: $0.model, receipt: $0.receipt)
        }
        sessions = [:]
        lastActivity = Date()
        if let ref = record.model.flatMap(AOMAIModelRef.init(key:)) { model = ref }
        // After the model: its didSet holds earlier turns back on a change of
        // provider, but a chat opened to continue it sends its own turns.
        historyStart = 0
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if agentSession.isBusy { agentSession.stop() }
        flush()
        if isRunning, let last = messages.last, last.role == .assistant, last.text.isEmpty {
            messages.removeLast()
            messages.append(Message(role: .error, text: "Stopped."))
        }
        // Stopped while @window or @screen was being read: the question goes back unsent.
        if isRunning, let last = messages.last, last.role == .user, last.scopeSummary?.hasPrefix("Reading ") == true {
            messages.removeLast()
        }
        isRunning = false
    }

    func ask(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        if Date().timeIntervalSince(lastActivity) > Self.idleReset, !messages.isEmpty {
            AOMAIChatHistory.shared.save(self)
            messages = []
            sessions = [:]
            chatID = UUID()
            historyStart = 0
            agentSession.stop()
        }
        lastActivity = Date()
        // 7.3: the question's @ mentions and the Records screen's choices
        // make its scope, fixed now; the choices go with this question only.
        let parsed = AOMAIRecordScope.parse(text, lastFolders: recentFolders.prefix(1).map { $0 })
        var scope = parsed.scope.union(pendingScope)
        pendingScope = .none
        if !scope.isEmpty || scope.attachesAnything { lastScope = scope }
        let message = Message(role: .user, text: parsed.question.isEmpty ? text : parsed.question)
        let wanted = scope.attachments
        scope.sources.subtract(AOMAIRecordSource.attachments)
        var notes: [String] = []
        if scope.sources.contains(.files), scope.folders.isEmpty {
            scope.sources.remove(.files)
            notes.append("@files needs a folder: choose one in Records or write @~/path")
        }
        var clip: AOMAIAttachment?
        if wanted.contains(.clip) {
            switch AOMAIRecordScope.clipboardText() {
            case .success(let text): clip = .clipboard(text)
            case .failure(let error): notes.append(error.message)
            }
        }
        let screen = wanted.filter { $0 != .clip }
        guard !screen.isEmpty else {
            send(message, attachments: clip.map { [$0] } ?? [], scope: scope, notes: notes)
            return
        }
        // @window and @screen are read now, before the question goes, and
        // from the app the launcher opened over.
        isRunning = true
        var reading = message
        reading.scopeSummary = "Reading " + screen.map(\.title).joined(separator: ", ") + "…"
        messages.append(reading)
        let frontApp = AOMLauncherController.shared.frontApp ?? PaletteSession.previousApp()
        task = Task { [weak self] in
            var attached = clip.map { [$0] } ?? []
            var notes = notes
            for source in screen {
                switch await AOMAIAttachment.capture(source, frontApp: frontApp) {
                case .success(let attachment): attached.append(attachment)
                case .failure(let error): notes.append(error.message)
                }
            }
            guard let self, !Task.isCancelled, self.messages.last?.id == message.id else { return }
            self.messages.removeLast()
            self.isRunning = false
            self.send(message, attachments: attached, scope: scope, notes: notes)
        }
    }

    private func send(_ question: Message, attachments: [AOMAIAttachment], scope: AOMAIRecordScope, notes: [String]) {
        var message = question
        message.attachments = attachments
        message.scope = scope
        let parts = (scope.summary == "Nothing" ? [] : [scope.summary]) + attachments.map(\.label)
        message.scopeSummary = parts.isEmpty ? nil : parts.joined(separator: ", ")
        messages.append(message)
        answer(scope: scope, note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    /// ⌘R: the last question again (the old answer is replaced).
    func regenerate() {
        guard !isRunning, messages.contains(where: { $0.role == .user }) else { return }
        while let last = messages.last, last.role != .user { messages.removeLast() }
        // An agent remembers the turn it answered; it gets the question as new.
        if agent != nil { agentSession.stop(); sessions = [:] }
        answer(scope: messages.last(where: { $0.role == .user })?.scope ?? .none, note: nil)
    }

    /// The turns that may go with the question: from `historyStart` on.
    private var sendableEarlier: ArraySlice<Message> {
        let start = min(historyStart, max(0, messages.count - 2))
        return messages[start..<max(start, messages.count - 2)]
    }

    private func answer(scope asked: AOMAIRecordScope, note: String?) {
        guard let questionMessage = messages.last(where: { $0.role == .user }) else { return }
        let question = questionMessage.sentText
        let ref = model
        let egress = self.egress
        let scope = AOMAIRecordsMode.effective(asked, egress: egress, mode: .current, onDeviceReadsMac: AOMAIRecordsMode.onDeviceReadsMac)
        var receipt = AOMAIReceipt(destination: egress.label(ref.provider), leavesMac: egress.leavesMac, allowed: scope.summary,
                                   clipboardAttached: questionMessage.attachments.contains { $0.label == "Clipboard" },
                                   attached: questionMessage.attachments.isEmpty ? nil : questionMessage.attachments.map(\.label), note: note)
        if !scope.isEmpty, !ref.provider.takesRecordTools {
            receipt.note = [note, ref.provider.isAgent ? "\(ref.provider.title) reads with its own read-only access, not AOM's records" :
                                "\(ref.provider.title) can't read records; only attached text goes with it"].compactMap { $0 }.joined(separator: " · ")
            receipt.allowed = "Nothing"
        }
        if AOMAIRecordsMode.current == .never, !asked.isEmpty {
            receipt.note = [receipt.note, "Records are off in Settings › AI"].compactMap { $0 }.joined(separator: " · ")
        }
        messages.append(Message(role: .assistant, text: "", model: ref.title, receipt: receipt))
        // Counted with the answer in place: everything before the question.
        messages[messages.count - 1].receipt?.earlierTurns = sendableEarlier.filter { $0.role != .error && !$0.text.isEmpty }.count
        isRunning = true
        if let agent {
            guard let executable = agent.executable else {
                replaceLast(with: Message(role: .error, text: "\(agent.title) isn't installed on this Mac (looked in \(agent.candidates.prefix(3).joined(separator: ", ")))."))
                isRunning = false
                return
            }
            if agent == .claude {
                // Without a session to resume (Ask Again, a chat opened from
                // history) the earlier turns go with the question.
                let sent = session == nil ? Self.withHistory(question, sendableEarlier) : question
                agentSession.start(executable: executable, model: ref.model, system: systemPrompt, resume: session)
                agentSession.send(sent)
            } else if agent == .dsh {
                // dsh keeps its own session; a new one gets the earlier turns.
                let session = sessions[.dsh]
                let sent = session == nil ? Self.withHistory(question, sendableEarlier) : question
                setNotice("Starting DeepSeek Harness…")
                Task { [weak self] in
                    do {
                        _ = try await Task.detached(priority: .userInitiated) { try AOMDeepSeekHarness.prepareRuntime() }.value
                        guard let self, self.isRunning else { return }
                        self.run(executable, arguments: agent.arguments(prompt: sent, session: session, model: ref.model), agent: .dsh)
                    } catch {
                        guard let self else { return }
                        self.replaceLast(with: Message(role: .error, text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                        self.isRunning = false
                    }
                }
            } else {
                // Codex has no warm session here: earlier turns go with the question.
                let sent = Self.withHistory(question, sendableEarlier)
                run(executable, arguments: agent.arguments(prompt: sent, session: nil, model: ref.model), agent: .codex)
            }
            return
        }
        let turns = (Array(sendableEarlier) + [questionMessage]).compactMap { message -> AOMAITurn? in
            switch message.role {
            case .user: return AOMAITurn(role: .user, text: message.sentText)
            case .assistant: return message.text.isEmpty ? nil : AOMAITurn(role: .assistant, text: message.text)
            case .error: return nil
            }
        }
        let stream = AOMAIClient.stream(ref, system: systemPrompt, turns: Self.alternating(turns),
                                        scope: ref.provider.takesRecordTools ? scope : .none)
        task = Task { [weak self] in
            do {
                for try await piece in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch piece {
                    case .text(let delta): self.buffer(delta)
                    case .snapshot(let full): self.flush(); self.setAnswer(full)
                    case .thinking: self.setThinking(true)
                    case .notice(let notice): self.flush(); self.setNotice(notice)
                    case .used(let items): self.addUsed(items)
                    }
                }
                self?.finishNative(error: nil)
            } catch {
                self?.finishNative(error: error)
            }
        }
    }

    /// Pure: consecutive turns of one role merged (an error between two
    /// questions leaves them adjacent), starting with the user.
    nonisolated static func alternating(_ turns: [AOMAITurn]) -> [AOMAITurn] {
        var result: [AOMAITurn] = []
        for turn in turns {
            if let last = result.last, last.role == turn.role {
                result[result.count - 1] = AOMAITurn(role: turn.role, text: last.text + "\n\n" + turn.text)
            } else if result.isEmpty, turn.role == .assistant {
                continue
            } else {
                result.append(turn)
            }
        }
        return result
    }

    private var systemPrompt: String {
        AOMAIConfig.systemPrompt(frontApp: AOMLauncherController.shared.frontApp?.localizedName)
    }

    /// Pure: earlier turns as context for a CLI without a resumable session.
    nonisolated static func withHistory(_ prompt: String, _ earlier: ArraySlice<Message>) -> String {
        let turns = earlier.filter { $0.role != .error && !$0.text.isEmpty }.suffix(6)
        guard !turns.isEmpty else { return prompt }
        let history = turns.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        return "Conversation so far:\n\(history)\n\nUser: \(prompt)"
    }

    // MARK: Streaming into the transcript

    private func buffer(_ text: String) {
        pending += text
        guard !flushScheduled else { return }
        flushScheduled = true
        // About one screen update per frame however fast tokens arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let text = pending
        pending = ""
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text += text
        messages[index].thinking = false
    }

    private func setAnswer(_ text: String) {
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text = text
        messages[index].thinking = false
    }

    private func setThinking(_ on: Bool) {
        guard let index = messages.indices.last, messages[index].role == .assistant, messages[index].text.isEmpty else { return }
        if messages[index].thinking != on { messages[index].thinking = on }
    }

    /// "LLM Wiki" read twice reads "LLM Wiki ×2" in the receipt.
    private func addUsed(_ items: [String]) {
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        var used = messages[index].receipt?.used ?? []
        for item in items {
            if let at = used.firstIndex(where: { $0 == item || $0.hasPrefix(item + " ×") }) {
                let count = used[at] == item ? 1 : (used[at].components(separatedBy: " ×").last.flatMap(Int.init) ?? 1)
                used[at] = "\(item) ×\(count + 1)"
            } else {
                used.append(item)
            }
        }
        messages[index].receipt?.used = Array(used.prefix(12))
    }

    private func setNotice(_ notice: String) {
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].notice = notice
    }

    private func finishNative(error: Error?) {
        flush()
        task = nil
        isRunning = false
        lastActivity = Date()
        if let error {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            replaceLast(with: Message(role: .error, text: text))
        } else if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            replaceLast(with: Message(role: .error, text: last.notice ?? "\(model.title) sent an empty answer."))
        }
        AOMAIChatHistory.shared.save(self)
    }

    private func appendToAnswer(_ text: String) {
        guard let index = messages.indices.last, messages[index].role == .assistant else { return }
        messages[index].text += text
        messages[index].thinking = false
    }

    private func replaceLast(with message: Message) {
        if let index = messages.indices.last, messages[index].role == .assistant, messages[index].text.isEmpty {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    // MARK: Agents (Claude Code warm session, Codex per turn)

    private func applyAgent(_ events: [PaletteAIEvent]) {
        for event in events {
            switch event {
            case .session(let id): sessions[agent ?? .claude] = id
            case .delta(let text): buffer(text)
            case .message(let text): flush(); appendToAnswer(messages.last?.text.isEmpty == false ? "\n\n" + text : text)
            case .done(let text):
                flush()
                if let text, !text.isEmpty, messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
                    appendToAnswer(text)
                }
                if agent == .claude, isRunning {
                    isRunning = false
                    lastActivity = Date()
                    if let last = messages.last, last.role == .assistant, last.text.isEmpty {
                        replaceLast(with: Message(role: .error, text: "Claude Code sent an empty answer."))
                    }
                    AOMAIChatHistory.shared.save(self)
                }
            case .failure(let text):
                flush()
                replaceLast(with: Message(role: .error, text: text))
                if agent == .claude { isRunning = false }
            case .activity(let text):
                setNotice(text)
            }
        }
    }

    private func finishAgent(status: Int32, stderr: String) {
        flush()
        guard isRunning, agent == .claude else { return }
        isRunning = false
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            let reason = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            replaceLast(with: Message(role: .error, text: status == 15 ? "Stopped." : "Claude Code didn't answer (\(reason))."))
        }
    }

    private func run(_ executable: String, arguments: [String], agent provider: PaletteAIProvider) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = provider == .dsh ? AOMDeepSeekHarness.environment(PaletteAgentSession.environment)
            : PaletteAgentSession.environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
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
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyAgent(events) } }
        }
        var errorText = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in errorText.append(handle.availableData) }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let stderr = String(decoding: errorText.suffix(2000), as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(status: status, stderr: stderr, title: provider.title) } }
        }
        do {
            try process.run()
            self.process = process
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
        } catch {
            replaceLast(with: Message(role: .error, text: "Couldn't start \(provider.title): \(error.localizedDescription)"))
            isRunning = false
        }
    }

    private func finish(status: Int32, stderr: String, title: String) {
        flush()
        process = nil
        isRunning = false
        lastActivity = Date()
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            let reason = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            let reasonLine = stderr.split(separator: "\n").last { !$0.contains("node_main.cc") }.map(String.init) ?? reason
            replaceLast(with: Message(role: .error, text: status == 15 ? "Stopped." : "\(title) didn't answer (\(reasonLine))."))
        }
        AOMAIChatHistory.shared.save(self)
    }

    /// ⌘J: the conversation in Terminal, interactive, where the CLI asks
    /// for each permission itself. A .command file needs no Automation access.
    /// With a native model the question starts a new Claude Code session.
    func continueInTerminal() -> Bool {
        if agent == .dsh { return AOMDeepSeekHarness.openApp() }
        let cli = agent ?? .claude
        let session = agent != nil ? sessions[cli] : nil
        let command = cli.terminalCommand(session: session, prompt: session == nil ? lastQuestion : nil, model: model.model)
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AllOfMacOS/AI", isDirectory: true)
        let file = folder.appendingPathComponent("continue-\(cli.rawValue).command")
        let script = "#!/bin/zsh -l\ncd ~\n\(command)\n"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return false
        }
        // The CLI picks the session up; the warm one here lets go of it.
        agentSession.stop()
        return NSWorkspace.shared.open(file)
    }
}

/// 7.0: one Claude Code process kept up for the conversation
/// (`claude -p --input-format stream-json`): each question is a line on its
/// stdin, the answer streams back on stdout, and the process waits for the
/// next one. Measured on this Mac: the first answer starts ~1.3 s after
/// launch, a follow-up within 0.1 s. Read-only (plan mode), no MCP servers
/// (they slow the start); ⌘J resumes the same session in Terminal with
/// everything. Ends after ten idle minutes, a model change or New Chat.
@MainActor
final class PaletteAgentSession {
    var onEvents: (([PaletteAIEvent]) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var key: String?
    private var idleTimer: Timer?
    private(set) var isBusy = false

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A GUI app gets launchd's PATH; the CLIs need the user's.
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        environment["TERM"] = "dumb"
        return environment
    }

    /// Pure: the warm session's arguments.
    nonisolated static func arguments(model: String, system: String, resume: String?) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages",
                    "--verbose", "--permission-mode", "plan", "--strict-mcp-config", "--append-system-prompt", system]
        if model != "default", !model.isEmpty { args += ["--model", model] }
        if let resume { args += ["--resume", resume] }
        return args
    }

    /// Pure: one question as a stream-json input line.
    nonisolated static func inputLine(_ text: String) -> Data {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    func start(executable: String, model: String, system: String, resume: String?) {
        let key = "\(executable)|\(model)"
        if let process, process.isRunning, self.key == key { return }
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.arguments(model: model, system: system, resume: resume)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = Self.environment
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
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
            let events = lines.flatMap { PaletteAIEvent.parse($0, provider: .claude) }
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if events.contains(where: { if case .done = $0 { return true }; if case .failure = $0 { return true }; return false }) {
                        self.isBusy = false
                        self.armIdleTimer()
                    }
                    self.onEvents?(events)
                }
            }
        }
        var errorText = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in errorText.append(handle.availableData) }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            let stderr = String(decoding: errorText.suffix(2000), as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === finished else { return }
                    self.process = nil
                    self.input = nil
                    self.isBusy = false
                    self.onExit?(status, stderr)
                }
            }
        }
        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
            self.key = key
            armIdleTimer()
        } catch {
            onExit?(-1, error.localizedDescription)
        }
    }

    func send(_ text: String) {
        guard let input, process?.isRunning == true else { onExit?(-1, "Claude Code isn't running"); return }
        isBusy = true
        idleTimer?.invalidate()
        do { try input.write(contentsOf: Self.inputLine(text)) } catch { onExit?(-1, error.localizedDescription) }
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        isBusy = false
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        key = nil
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: PaletteAIChat.idleReset, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
}

/// 7.0: past conversations for AI Chat's sidebar, newest first, at most 60,
/// in Application Support (never answers with errors only).
@MainActor
final class AOMAIChatHistory: ObservableObject {
    static let shared = AOMAIChatHistory()

    struct Record: Codable, Identifiable, Equatable {
        struct Turn: Codable, Equatable { let role: String; let text: String; var model: String?; var receipt: AOMAIReceipt? = nil }
        let id: UUID
        var title: String
        var date: Date
        var model: String?
        var messages: [Turn]
    }

    @Published private(set) var records: [Record] = []
    let writer: AOMLatestWriter?

    static var defaultURL: URL? {
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AllOfMacOS/AI/chats.json")
    }

    convenience init() { self.init(url: Self.defaultURL) }

    /// `url` nil keeps the history in memory (tests, previews).
    /// 7.3: chats.json couldn't be read; see `AOMCheckedFile`.
    @Published private(set) var problem: FocusDataProblem?
    private var blocksSaving = false

    init(url: URL?) {
        writer = url.map { AOMLatestWriter(url: $0) }
        guard let url else { return }
        let loaded = AOMCheckedFile.load(url, owner: "Ask AI") { try JSONDecoder().decode([Record].self, from: $0) }
        records = loaded.value ?? []
        problem = loaded.problem("Your AI chats")
        blocksSaving = problem?.blocksSaving == true
    }

    func save(_ chat: PaletteAIChat) {
        let turns = chat.messages.filter { $0.role != .error && !$0.text.isEmpty }
            .map { Record.Turn(role: $0.role == .user ? "user" : "assistant", text: $0.sentText, model: $0.model, receipt: $0.receipt) }
        guard turns.contains(where: { $0.role == "assistant" }) else { return }
        save(Record(id: chat.chatID, title: chat.title, date: Date(), model: chat.model.key, messages: turns))
    }

    /// Chats deleted this session: a later save of the open chat (New Chat,
    /// closing the launcher) doesn't bring one back (7.3 review, Codex probe).
    private var deleted: Set<UUID> = []

    func save(_ record: Record) {
        guard !deleted.contains(record.id) else { return }
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        if records.count > 60 { records.removeLast(records.count - 60) }
        write()
    }

    func delete(_ id: UUID) {
        deleted.insert(id)
        records.removeAll { $0.id == id }
        write()
    }

    /// 7.2.3 (audit B09): each save and delete wrote the whole list from the
    /// concurrent global queue, so a big save asked for first could finish
    /// last and bring back a chat deleted after it. Writes now go through
    /// one serial writer, and one superseded before it starts is dropped.
    private func write() {
        guard let writer, !blocksSaving else { return }
        let snapshot = records
        writer.write { try JSONEncoder().encode(snapshot) }
    }

    /// Waits for pending writes (tests).
    func flush() { writer?.flush() }
}

/// One file written off the main thread, one write at a time, the newest
/// state last. A write superseded by a newer one before it starts is
/// skipped (its state is already stale). `beforeWrite` lets the tests slow
/// a write down.
final class AOMLatestWriter: @unchecked Sendable {
    let url: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0
    var beforeWrite: (@Sendable (Int) -> Void)?

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "com.kyw.allofmacos.writer.\(url.lastPathComponent)", qos: .utility)
    }

    /// `encode` runs on the writer's queue, so large snapshots don't stall the caller.
    func write(_ encode: @escaping @Sendable () throws -> Data) {
        let mine = lock.withLock { generation += 1; return generation }
        queue.async { [self] in
            guard lock.withLock({ generation == mine }) else { return }
            beforeWrite?(mine)
            do {
                let data = try encode()
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[AOM] Couldn't save %@: %@", url.lastPathComponent, error.localizedDescription)
            }
        }
    }

    func flush() { queue.sync {} }
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
