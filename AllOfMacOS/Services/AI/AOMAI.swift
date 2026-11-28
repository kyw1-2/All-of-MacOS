import AppKit
import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

// AOM 7.0: native AI for the launcher, after Raycast AI.
//
// 6.9 answered by running the Claude Code and Codex CLIs in a subprocess:
// a few seconds of start-up before the first word, plan-mode chatter, and
// no choice of model. 7.0 talks to models directly and streams every token
// into the launcher:
//
// - Apple Intelligence: the on-device model (macOS 26+, FoundationModels).
//   No key, nothing leaves the Mac; the default whenever it is available.
// - Anthropic (Claude), OpenAI, DeepSeek: the provider's own HTTP streaming
//   API with the user's API key from the Keychain.
// - Ollama: any local model through its OpenAI-compatible endpoint.
// - Claude Code and Codex stay as "agents": they can still answer, and ⌘J
//   continues the conversation in Terminal where they can edit and run.
//
// Keys are entered in Settings › AI (or imported once from the login
// shell's environment at the user's request) and kept in the Keychain;
// they are never written to UserDefaults or logs.

enum AOMAIProvider: String, CaseIterable, Identifiable, Codable {
    case apple, anthropic, localProxy, openAI, deepSeek, ollama, claudeCode, codex
    /// 7.2.2: the DeepSeek Harness desktop app's agent, headless and read-only.
    case deepSeekHarness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Intelligence"
        case .anthropic: return "Anthropic"
        case .localProxy: return "Local Proxy"
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .ollama: return "Ollama"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .deepSeekHarness: return "DeepSeek Harness"
        }
    }

    var symbol: String {
        switch self {
        case .apple: return "apple.intelligence"
        case .anthropic: return "sparkle"
        case .localProxy: return "server.rack"
        case .openAI: return "circle.hexagongrid"
        case .deepSeek: return "water.waves"
        case .ollama: return "desktopcomputer"
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .deepSeekHarness: return "water.waves.and.arrow.up"
        }
    }

    /// A fallback for `symbol` on systems without the newer glyph.
    var fallbackSymbol: String { self == .apple ? "sparkles" : self == .deepSeekHarness ? "water.waves" : symbol }

    /// Runs a local CLI (with tools) rather than calling a model.
    var isAgent: Bool { self == .claudeCode || self == .codex || self == .deepSeekHarness }

    /// Needs an API key before it can answer.
    var needsKey: Bool { self == .anthropic || self == .openAI || self == .deepSeek }

    /// Speaks Anthropic's Messages API (the API itself or a local router such
    /// as claude-code-proxy on :8082).
    var isAnthropicCompatible: Bool { self == .anthropic || self == .localProxy }

    /// Speaks the OpenAI chat-completions dialect.
    var isOpenAICompatible: Bool { self == .openAI || self == .deepSeek || self == .ollama }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .localProxy: return "http://127.0.0.1:8082"
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .apple, .claudeCode, .codex, .deepSeekHarness: return ""
        }
    }

    /// Environment names "Import from Shell" reads. ANTHROPIC_BASE_URL is
    /// left out on purpose: it usually points Claude Code at a proxy.
    var environmentKey: String? {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openAI: return "OPENAI_API_KEY"
        case .deepSeek: return "DEEPSEEK_API_KEY"
        default: return nil
        }
    }

    var environmentBaseURL: String? {
        switch self {
        case .openAI: return "OPENAI_BASE_URL"
        case .deepSeek: return "DEEPSEEK_BASE_URL"
        default: return nil
        }
    }

    var environmentModel: String? { self == .openAI ? "OPENAI_MODEL" : nil }

    var keyHelpURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .ollama: return URL(string: "https://ollama.com/download")
        default: return nil
        }
    }

    /// The models offered before any are fetched from the provider.
    var suggestedModels: [AOMAIModelOption] {
        switch self {
        case .apple:
            return [.init(id: "on-device", title: "Apple Intelligence", detail: "On this Mac · private · no key")]
        case .anthropic:
            return [.init(id: "claude-opus-5-5", title: "Claude Opus 5.5", detail: "Most capable for everyday work"),
                    .init(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5", detail: "Fast and capable"),
                    .init(id: "claude-haiku-5-5", title: "Claude Haiku 5.5", detail: "Fastest, lowest cost"),
                    .init(id: "claude-fable-5-2", title: "Claude Fable 5.2", detail: "Deepest reasoning")]
        case .openAI:
            return [.init(id: "gpt-5", title: "GPT-5", detail: "OpenAI"),
                    .init(id: "gpt-5-mini", title: "GPT-5 mini", detail: "OpenAI · faster")]
        case .deepSeek:
            return [.init(id: "deepseek-chat", title: "DeepSeek Chat", detail: "DeepSeek"),
                    .init(id: "deepseek-reasoner", title: "DeepSeek Reasoner", detail: "DeepSeek · thinks first")]
        case .localProxy:
            // claude-code-proxy routes "haiku" models to DeepSeek: no API key.
            return [.init(id: "claude-haiku-5-5", title: "Haiku → DeepSeek", detail: "Your :8082 router · no API key")]
        case .ollama:
            return []
        case .claudeCode:
            // Your Claude subscription through the CLI, kept warm between questions.
            return [.init(id: "default", title: "Claude Code", detail: "Your subscription · ⌘J continues in Terminal"),
                    .init(id: "opus", title: "Claude Code · Opus", detail: "Your subscription"),
                    .init(id: "sonnet", title: "Claude Code · Sonnet", detail: "Your subscription"),
                    .init(id: "haiku", title: "Claude Code · Haiku", detail: "Your subscription (or your haiku route)")]
        case .codex:
            return [.init(id: "default", title: "Codex", detail: "Your ChatGPT plan · ⌘J continues in Terminal")]
        case .deepSeekHarness:
            return [.init(id: "default", title: "DeepSeek Harness", detail: "Your DeepSeek Harness · reads your Mac, read-only · ⌘J opens the app")]
        }
    }
}

struct AOMAIModelOption: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var detail: String
}

/// A provider and one of its models, stored as "provider:model".
struct AOMAIModelRef: Hashable, Codable {
    var provider: AOMAIProvider
    var model: String

    var key: String { "\(provider.rawValue):\(model)" }

    init(provider: AOMAIProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = AOMAIProvider(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        self.init(provider: provider, model: parts[1])
    }

    /// "Claude Opus 5.5", "llama3.2 · Ollama".
    var title: String {
        if let known = (AOMAIConfig.models(for: provider)).first(where: { $0.id == model }) { return known.title }
        return provider == .ollama ? model : "\(model)"
    }

    var subtitle: String { provider.title }
}

// MARK: - Keychain

enum AOMAIKeychain {
    static let service = "com.kyw.allofmacos.ai"
    @MainActor private static var cache: [AOMAIProvider: String] = [:]
    @MainActor private static var missing: Set<AOMAIProvider> = []

    @MainActor
    static func key(for provider: AOMAIProvider) -> String? {
        if let cached = cache[provider] { return cached }
        if missing.contains(provider) || PresetManager.isRunningTests { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider.rawValue,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            missing.insert(provider)
            return nil
        }
        cache[provider] = value
        return value
    }

    @MainActor
    static func hasKey(for provider: AOMAIProvider) -> Bool { key(for: provider) != nil }

    /// Saves (or with nil/empty, removes) the key. Returns false on a Keychain error.
    @MainActor @discardableResult
    static func setKey(_ value: String?, for provider: AOMAIProvider) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider.rawValue]
        SecItemDelete(base as CFDictionary)
        cache[provider] = nil
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            missing.insert(provider)
            NotificationCenter.default.post(name: AOMAIConfig.didChange, object: nil)
            return true
        }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrLabel as String] = "All of MacOS — \(provider.title) API key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            cache[provider] = trimmed
            missing.remove(provider)
        }
        NotificationCenter.default.post(name: AOMAIConfig.didChange, object: nil)
        return status == errSecSuccess
    }

    /// Pure: what Settings shows for a saved key ("sk-…a1b2").
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(3)) + "…" + String(key.suffix(4))
    }
}

// MARK: - Configuration

enum AOMAIConfig {
    static let didChange = Notification.Name("AOMAIConfigDidChange")
    private static let modelKey = "AOMAIModel"
    private static let effortKey = "AOMAIEffort"
    private static let instructionsKey = "AOMAICustomInstructions"

    enum Effort: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var title: String {
            switch self {
            case .low: return "Fast"
            case .medium: return "Balanced"
            case .high: return "Thorough"
            }
        }
    }

    static var effort: Effort {
        get { Effort(rawValue: UserDefaults.standard.string(forKey: effortKey) ?? "") ?? .low }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: effortKey); NotificationCenter.default.post(name: didChange, object: nil) }
    }

    static var customInstructions: String {
        get { UserDefaults.standard.string(forKey: instructionsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: instructionsKey) }
    }

    static func baseURL(for provider: AOMAIProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: "AOMAIBaseURL_\(provider.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? provider.defaultBaseURL : stored
    }

    static func setBaseURL(_ value: String, for provider: AOMAIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        if trimmed.isEmpty || trimmed == provider.defaultBaseURL {
            defaults.removeObject(forKey: "AOMAIBaseURL_\(provider.rawValue)")
        } else {
            defaults.set(trimmed, forKey: "AOMAIBaseURL_\(provider.rawValue)")
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The models listed for a provider: those fetched from it, else the suggestions.
    static func models(for provider: AOMAIProvider) -> [AOMAIModelOption] {
        if provider == .codex { return provider.suggestedModels + CodexModelCatalog.current() }
        if let data = UserDefaults.standard.data(forKey: "AOMAIModels_\(provider.rawValue)"),
           let fetched = try? JSONDecoder().decode([AOMAIModelOption].self, from: data), !fetched.isEmpty {
            // Keep the curated names for the known ones, add the rest.
            let suggested = provider.suggestedModels
            let known = suggested.filter { option in fetched.contains { $0.id == option.id } }
            let rest = fetched.filter { option in !suggested.contains { $0.id == option.id } }
            return (known.isEmpty ? suggested : known) + rest
        }
        return provider.suggestedModels
    }

    static func setFetchedModels(_ models: [AOMAIModelOption], for provider: AOMAIProvider) {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: "AOMAIModels_\(provider.rawValue)")
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Whether the local router answered its last check (`probeLocalProxy`).
    static var localProxyReachable: Bool { UserDefaults.standard.bool(forKey: "AOMAILocalProxyReachable") }

    /// 7.2.1: AOMLocalProxy records what its health check found.
    static func setLocalProxyReachable(_ reachable: Bool) {
        guard reachable != localProxyReachable else { return }
        UserDefaults.standard.set(reachable, forKey: "AOMAILocalProxyReachable")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Asks the local router's root once (2 s); the picker lists it when it answers.
    static func probeLocalProxy() async {
        guard let url = URL(string: baseURL(for: .localProxy)) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let reachable: Bool
        if let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse {
            reachable = http.statusCode < 500
        } else {
            reachable = false
        }
        if reachable != localProxyReachable {
            UserDefaults.standard.set(reachable, forKey: "AOMAILocalProxyReachable")
            await MainActor.run { NotificationCenter.default.post(name: didChange, object: nil) }
        }
    }

    /// Whether a provider can answer now (key saved, model on this Mac, CLI installed).
    @MainActor
    static func isReady(_ provider: AOMAIProvider) -> Bool {
        switch provider {
        case .apple: return AOMAppleIntelligence.isAvailable
        case .anthropic, .openAI, .deepSeek: return AOMAIKeychain.hasKey(for: provider)
        // 7.2.1: AOM starts the router itself when it isn't running.
        case .localProxy: return localProxyReachable || AOMLocalProxy.canStart()
        case .ollama: return !models(for: .ollama).isEmpty
        case .claudeCode: return PaletteAIProvider.claude.executable != nil
        case .codex: return PaletteAIProvider.codex.executable != nil
        case .deepSeekHarness: return AOMDeepSeekHarness.isInstalled
        }
    }

    /// Every model the picker offers, ready providers first.
    @MainActor
    static func pickerModels() -> [(provider: AOMAIProvider, ready: Bool, models: [AOMAIModelOption])] {
        AOMAIProvider.allCases.map { ($0, isReady($0), models(for: $0)) }
            .filter { !$0.models.isEmpty }
            .sorted { $0.ready && !$1.ready }
    }

    /// The chosen model, or the first ready one: on-device first, then the
    /// API providers with keys, then the agents.
    @MainActor
    static var selectedModel: AOMAIModelRef {
        get {
            if let raw = UserDefaults.standard.string(forKey: modelKey), let ref = AOMAIModelRef(key: raw) { return ref }
            return defaultModel
        }
        set {
            UserDefaults.standard.set(newValue.key, forKey: modelKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    @MainActor
    static var defaultModel: AOMAIModelRef {
        // Anthropic first among the keyed providers: Opus 5.5 is the default model.
        for provider in [AOMAIProvider.anthropic, .apple, .claudeCode, .localProxy, .openAI, .deepSeek, .ollama, .codex] where isReady(provider) {
            if let first = models(for: provider).first { return AOMAIModelRef(provider: provider, model: first.id) }
        }
        return AOMAIModelRef(provider: .apple, model: "on-device")
    }

    /// The instructions every answer starts from.
    static func systemPrompt(frontApp: String?) -> String {
        var lines = [
            "You are the AI in All of MacOS's launcher on the user's Mac, answering in a small panel like Raycast's Quick AI.",
            "Answer directly and concisely; lead with the answer, then the detail that matters.",
            "Reply in the language the user writes in (Korean stays Korean).",
            "Use Markdown: short paragraphs, bullet lists, and fenced code blocks with a language tag for code or commands.",
            "When asked to rewrite, translate or fix text, reply with only the resulting text.",
        ]
        if let frontApp, !frontApp.isEmpty { lines.append("The user opened the launcher from \(frontApp).") }
        let date = Date().formatted(date: .complete, time: .shortened)
        lines.append("Now: \(date).")
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { lines.append("The user's own instructions:\n\(custom)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Import from the login shell

    /// Reads the AI variables from the user's login shell (they are set in
    /// ~/.zshrc for terminal tools, which a GUI app never inherits) and
    /// saves the keys to the Keychain. Only on the user's click.
    @MainActor
    static func importFromShell() async -> [String] {
        let names = AOMAIProvider.allCases.flatMap { [$0.environmentKey, $0.environmentBaseURL, $0.environmentModel].compactMap { $0 } }
        let values = await Task.detached(priority: .userInitiated) { shellEnvironment(names) }.value
        var imported: [String] = []
        for provider in AOMAIProvider.allCases {
            if let name = provider.environmentKey, let key = values[name], !key.isEmpty, AOMAIKeychain.setKey(key, for: provider) {
                imported.append("\(provider.title) key")
            }
            if let name = provider.environmentBaseURL, let url = values[name], url.hasPrefix("http") {
                setBaseURL(url, for: provider)
                imported.append("\(provider.title) address")
            }
            if let name = provider.environmentModel, let model = values[name], !model.isEmpty {
                var list = models(for: provider)
                if !list.contains(where: { $0.id == model }) {
                    list.insert(AOMAIModelOption(id: model, title: model, detail: provider.title), at: 0)
                    setFetchedModels(list, for: provider)
                }
                imported.append("\(provider.title) model")
            }
        }
        return imported
    }

    /// `printenv` for each name in an interactive login zsh, with a timeout.
    nonisolated static func shellEnvironment(_ names: [String]) -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // NUL-separated name=value pairs; nothing but these names is read.
        let script = names.map { "printf '%s=%s\\0' \($0) \"${\($0)}\"" }.joined(separator: "; ")
        process.arguments = ["-ilc", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return parseEnvironment(String(decoding: data, as: UTF8.self))
    }

    /// Pure: "A=1\0B=\0" → ["A": "1"] (empty values dropped).
    nonisolated static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "\0") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !value.isEmpty { result[name] = value }
        }
        return result
    }
}

// MARK: - Streaming

struct AOMAITurn: Equatable {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

enum AOMAIPiece: Equatable {
    /// More of the answer.
    case text(String)
    /// The whole answer so far (on-device snapshots).
    case snapshot(String)
    /// The model is reasoning before it answers (shown as "Thinking…").
    case thinking
    /// The answer stopped early, with why ("max tokens", "declined").
    case notice(String)
    /// 7.3: a tool call read these (the answer's receipt).
    case used([String])
}

struct AOMAIError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Pure decoders for the providers' Server-Sent Events.
enum AOMAISSE {
    /// The payload of a `data:` line; nil for `event:` lines, comments and blanks.
    static func payload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    enum Event: Equatable {
        case text(String)
        case thinking
        case stop(String?)
        case error(String)
        case done
        case none
    }

    /// One Anthropic Messages stream event (`content_block_delta`,
    /// `message_delta`, `error`, `message_stop`).
    static func anthropic(_ payload: String) -> Event {
        guard let object = json(payload), let type = object["type"] as? String else { return .none }
        switch type {
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta": return (delta?["text"] as? String).map { .text($0) } ?? .none
            case "thinking_delta", "signature_delta": return .thinking
            default: return .none
            }
        case "content_block_start":
            let block = object["content_block"] as? [String: Any]
            return (block?["type"] as? String) == "thinking" ? .thinking : .none
        case "message_delta":
            let delta = object["delta"] as? [String: Any]
            return .stop(delta?["stop_reason"] as? String)
        case "message_stop":
            return .done
        case "error":
            let error = object["error"] as? [String: Any]
            return .error((error?["message"] as? String) ?? "The model reported an error.")
        default:
            return .none
        }
    }

    /// One OpenAI-compatible chat-completions chunk (OpenAI, DeepSeek, Ollama).
    static func openAI(_ payload: String) -> Event {
        if payload == "[DONE]" { return .done }
        guard let object = json(payload) else { return .none }
        if let error = object["error"] as? [String: Any] {
            return .error((error["message"] as? String) ?? "The model reported an error.")
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return .none }
        let delta = choice["delta"] as? [String: Any]
        if let text = delta?["content"] as? String, !text.isEmpty { return .text(text) }
        if let reasoning = (delta?["reasoning_content"] ?? delta?["reasoning"]) as? String, !reasoning.isEmpty { return .thinking }
        if let reason = choice["finish_reason"] as? String { return .stop(reason) }
        return .none
    }

    /// The message of an error body (`{"error":{"message":…}}`), else the text.
    static func errorMessage(_ body: String, status: Int) -> String {
        if let object = json(body) {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401: return "The API key was rejected (401). Check it in Settings › AI."
        case 403: return "Access denied (403)."
        case 404: return "Not found (404) — check the model name and address in Settings › AI."
        case 429: return "Rate limited (429). Try again in a moment."
        default: return trimmed.isEmpty ? "HTTP \(status)" : String(trimmed.prefix(300))
        }
    }

    /// What a stop reason means to the reader, nil for a normal end.
    static func stopNotice(_ reason: String?) -> String? {
        switch reason {
        case "max_tokens", "length": return "The answer reached its length limit."
        case "refusal", "content_filter": return "The model declined to answer this."
        default: return nil
        }
    }

    private static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum AOMAIClient {
    /// Pure: the Anthropic request body. Known Claude 5 models get an effort
    /// level and the server-side fallback on a refusal; unknown model ids
    /// (older models, proxies) get the plain request.
    static func anthropicBody(model: String, system: String, turns: [AOMAITurn], effort: AOMAIConfig.Effort,
                              firstParty: Bool) -> (body: [String: Any], betas: [String]) {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "system": system,
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        var betas: [String] = []
        let claude5 = model.range(of: #"^claude-(opus|sonnet|haiku|fable|mythos)-5"#, options: .regularExpression) != nil
        // A local router translates to another model: only the API gets effort.
        if claude5, firstParty { body["output_config"] = ["effort": effort.rawValue] }
        let fallbackModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2"]
        if firstParty, fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
        }
        return (body, betas)
    }

    /// Pure: an OpenAI-compatible chat-completions body.
    static func openAIBody(model: String, system: String, turns: [AOMAITurn]) -> [String: Any] {
        ["model": model, "stream": true,
         "messages": [["role": "system", "content": system]] + turns.map { ["role": $0.role.rawValue, "content": $0.text] }]
    }

    static func endpoint(_ base: String, _ path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + path)
    }

    @MainActor
    static func stream(_ ref: AOMAIModelRef, system: String, turns: [AOMAITurn],
                       scope: AOMAIRecordScope = .none) -> AsyncThrowingStream<AOMAIPiece, Error> {
        // 7.3: no tools and no word about them unless the question named records.
        let toolPrompt = AOMAILocalTools.promptLines(for: scope)
        let scopedSystem = toolPrompt.isEmpty ? system : system + "\n" + toolPrompt.joined(separator: "\n")
        switch ref.provider {
        case .apple:
            return AOMAppleIntelligence.stream(system: system, turns: turns)
        case .anthropic, .localProxy:
            let provider = ref.provider
            let base = AOMAIConfig.baseURL(for: provider)
            let key = AOMAIKeychain.key(for: provider)
            if provider == .anthropic, key == nil { return failing("Add your Anthropic API key in Settings › AI.") }
            guard let url = endpoint(base, "/v1/messages") else { return failing("The \(provider.title) address isn't a URL.") }
            let firstParty = URL(string: base)?.host == "api.anthropic.com"
            let (body, betas) = anthropicBody(model: ref.model, system: system, turns: turns, effort: AOMAIConfig.effort,
                                              firstParty: firstParty)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            // A local router needs no key of its own; it gets a placeholder.
            request.setValue(key ?? "local", forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
            // 7.2.1: AOM's read-only local tools, and the local router started on demand.
            var toolBody = body
            toolBody["system"] = scopedSystem
            return anthropicToolStream(request, body: toolBody, ensureProxy: provider == .localProxy ? base : nil, scope: scope)
        case .openAI, .deepSeek, .ollama:
            let provider = ref.provider
            let key = AOMAIKeychain.key(for: provider)
            if provider.needsKey, key == nil { return failing("Add your \(provider.title) API key in Settings › AI.") }
            guard let url = endpoint(AOMAIConfig.baseURL(for: provider), "/chat/completions") else {
                return failing("The \(provider.title) address isn't a URL.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            return openAIToolStream(request, body: openAIBody(model: ref.model, system: scopedSystem, turns: turns), scope: scope)
        case .claudeCode, .codex, .deepSeekHarness:
            return failing("Agents answer through their CLI.")
        }
    }

    private static func failing(_ message: String) -> AsyncThrowingStream<AOMAIPiece, Error> {
        AsyncThrowingStream { $0.finish(throwing: AOMAIError(message: message)) }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Lists a provider's models (Anthropic, OpenAI-compatible `/models`).
    @MainActor
    static func fetchModels(_ provider: AOMAIProvider) async throws -> [AOMAIModelOption] {
        let base = AOMAIConfig.baseURL(for: provider)
        let path = provider.isAnthropicCompatible ? "/v1/models?limit=100" : "/models"
        guard let url = endpoint(base, path) else { throw AOMAIError(message: "The address isn't a URL.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if provider.isAnthropicCompatible {
            guard let key = AOMAIKeychain.key(for: provider) ?? (provider == .localProxy ? "local" : nil) else {
                throw AOMAIError(message: "Add the API key first.")
            }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        } else if let key = AOMAIKeychain.key(for: provider) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if provider.needsKey {
            throw AOMAIError(message: "Add the API key first.")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AOMAIError(message: AOMAISSE.errorMessage(String(decoding: data, as: UTF8.self), status: status))
        }
        return parseModels(data, provider: provider)
    }

    /// Pure: `{"data":[{"id":…,"display_name":…}]}` → options, chat models only.
    static func parseModels(_ data: Data, provider: AOMAIProvider) -> [AOMAIModelOption] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        let skipped = ["embedding", "whisper", "tts", "dall-e", "moderation", "image", "audio", "realtime", "transcribe", "search"]
        return list.compactMap { item -> AOMAIModelOption? in
            guard let id = item["id"] as? String, !skipped.contains(where: { id.contains($0) }) else { return nil }
            let title = (item["display_name"] as? String) ?? id
            return AOMAIModelOption(id: id, title: title, detail: provider.title)
        }
    }
}

// MARK: - Apple Intelligence (on-device)

enum AOMAppleIntelligence {
    @MainActor static var isAvailable: Bool {
        if PresetManager.isRunningTests { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why it can't answer, for Settings.
    @MainActor static var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Ready on this Mac"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac can't run Apple Intelligence"
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings"
                case .modelNotReady: return "The model is still downloading"
                @unknown default: return "Unavailable"
                }
            }
        }
        #endif
        return "Needs macOS 26 or later"
    }

    /// Pure: earlier turns folded into the prompt (the on-device context is
    /// small, so only the last few and at most ~6,000 characters).
    static func prompt(_ turns: [AOMAITurn]) -> String {
        guard let last = turns.last else { return "" }
        var earlier = Array(turns.dropLast().suffix(6))
        while earlier.map(\.text.count).reduce(0, +) > 6000, !earlier.isEmpty { earlier.removeFirst() }
        guard !earlier.isEmpty else { return last.text }
        let history = earlier.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        return "Conversation so far:\n\(history)\n\nUser: \(last.text)"
    }

    /// Loads the on-device model while the question is typed (the first
    /// answer after a cold start otherwise waits several seconds).
    @MainActor static func prewarm(system: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            LanguageModelSession(instructions: system).prewarm()
        }
        #endif
    }

    static func stream(system: String, turns: [AOMAITurn]) -> AsyncThrowingStream<AOMAIPiece, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let text = prompt(turns)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let session = LanguageModelSession(instructions: system)
                        for try await snapshot in session.streamResponse(to: text) {
                            try Task.checkCancellation()
                            continuation.yield(.snapshot(snapshot.content))
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch let error as LanguageModelSession.GenerationError {
                        let message: String
                        switch error {
                        case .exceededContextWindowSize: message = "Too long for the on-device model. Start a new chat (⌘N) or pick a larger model."
                        case .guardrailViolation: message = "Apple Intelligence declined to answer this."
                        case .unsupportedLanguageOrLocale: message = "Apple Intelligence doesn't support this language yet."
                        default: message = error.localizedDescription
                        }
                        continuation.finish(throwing: AOMAIError(message: message))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: AOMAIError(message: "Apple Intelligence needs macOS 26 or later.")) }
    }
}


// MARK: - 7.2.1: tool calls (AOMAILocalTools)

extension AOMAIClient {
    struct ToolCall {
        let id: String
        let name: String
        var arguments: [String: Any]
        var rawArguments: String
    }

    struct ToolTurn {
        var text = ""
        var thinking: [(text: String, signature: String)] = []
        var calls: [ToolCall] = []
        var stopReason: String?
    }

    /// 7.2.2: six rounds (the last answers without tools); eight let DeepSeek keep searching for a minute.
    static let maxToolRounds = 6

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The response bytes of a 2xx answer; otherwise the error the body names.
    private static func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 4000 { break }
            }
            throw AOMAIError(message: AOMAISSE.errorMessage(body, status: status))
        }
        return bytes
    }

    static func describe(_ error: URLError, url: URL?) -> String {
        switch error.code {
        case .notConnectedToInternet: return "You're offline."
        case .cannotConnectToHost, .cannotFindHost:
            return "Couldn't reach \(url?.host ?? "the server")." + AOMLocalProxy.unreachableHint(host: url?.host, port: url?.port)
        case .timedOut: return "The model took too long to respond."
        default:
            // 7.23: the shared per-cause wording (clock, certificate, DNS).
            return ConnectFailureReason.classify(error, host: url?.host).sentence
        }
    }

    /// Pure: a model or server that can't take tools says so in a 400.
    static func refusesTools(_ error: Error) -> Bool {
        guard let message = (error as? AOMAIError)?.message.lowercased() else { return false }
        return ["tool", "function call", "function_call", "functions"].contains { message.contains($0) }
    }

    /// Runs a tool-calling conversation: stream a turn, run the calls it
    /// asks for, send the results, until it answers (8 rounds at most; the
    /// last one may not call tools). Without tools enabled it is one turn.
    private static func toolStream(base: URLRequest, ensureProxy: String?, scope: AOMAIRecordScope,
                                   turn: @escaping (URLRequest, @escaping (AOMAIPiece) -> Void) async throws -> ToolTurn,
                                   request: @escaping (_ round: Int, _ withTools: Bool) -> URLRequest,
                                   append: @escaping (ToolTurn, [(ToolCall, AOMAIToolResult)]) -> Void) -> AsyncThrowingStream<AOMAIPiece, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let ensureProxy, await !AOMLocalProxy.ensureRunning(base: ensureProxy) {
                        let url = URL(string: ensureProxy)
                        throw AOMAIError(message: "Couldn't reach \(url?.host ?? "the local proxy")." + AOMLocalProxy.unreachableHint(host: url?.host, port: url?.port))
                    }
                    var withTools = !scope.toolNames.isEmpty
                    var activity: [String] = []
                    for round in 0..<maxToolRounds {
                        let current: ToolTurn
                        do {
                            current = try await turn(request(round, withTools)) { continuation.yield($0) }
                        } catch where round == 0 && withTools && refusesTools(error) {
                            // This model or server takes no tools: ask again plainly.
                            withTools = false
                            current = try await turn(request(round, false)) { continuation.yield($0) }
                        }
                        guard withTools, !current.calls.isEmpty, round < maxToolRounds - 1 else {
                            if let notice = AOMAISSE.stopNotice(current.stopReason) { continuation.yield(.notice(notice)) }
                            continuation.finish()
                            return
                        }
                        if !current.text.isEmpty { continuation.yield(.text("\n\n")) }
                        var results: [(ToolCall, AOMAIToolResult)] = []
                        for call in current.calls {
                            try Task.checkCancellation()
                            continuation.yield(.thinking)
                            // What is running now, while it runs (7.2.1 showed only "Thinking…").
                            continuation.yield(.notice((activity.suffix(2) + [AOMAILocalTools.describe(call.name, arguments: call.arguments)])
                                .joined(separator: " · ")))
                            let result = await AOMAILocalTools.run(call.name, arguments: call.arguments, scope: scope)
                            // 7.3: the log keeps the tool and outcome, not queries, paths or text.
                            GestureLog.shared.logFromAnyThread("Ask AI tool \(call.name): \(result.isError ? "refused or failed" : "ok")", level: .action)
                            if !result.used.isEmpty { continuation.yield(.used(result.used)) }
                            activity.append(result.summary)
                            continuation.yield(.notice(activity.suffix(3).joined(separator: " · ")))
                            results.append((call, result))
                        }
                        append(current, results)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: AOMAIError(message: describe(error, url: base.url)))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Anthropic Messages

    static func anthropicToolStream(_ base: URLRequest, body: [String: Any], ensureProxy: String?,
                                    scope: AOMAIRecordScope = .none) -> AsyncThrowingStream<AOMAIPiece, Error> {
        let box = MessageBox(messages: body["messages"] as? [[String: Any]] ?? [])
        let schemas = AOMAILocalTools.anthropicSchemas(AOMAILocalTools.tools(for: scope))
        return toolStream(base: base, ensureProxy: ensureProxy, scope: scope, turn: anthropicTurn, request: { round, withTools in
            var payload = body
            payload["messages"] = box.messages
            if withTools {
                payload["tools"] = schemas
                if round == maxToolRounds - 1 { payload["tool_choice"] = ["type": "none"] }
            }
            var request = base
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            return request
        }, append: { turn, results in
            var assistant: [[String: Any]] = turn.thinking.filter { !$0.signature.isEmpty }
                .map { ["type": "thinking", "thinking": $0.text, "signature": $0.signature] }
            if !turn.text.isEmpty { assistant.append(["type": "text", "text": turn.text]) }
            assistant += turn.calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.arguments] }
            box.messages.append(["role": "assistant", "content": assistant])
            box.messages.append(["role": "user", "content": results.map { call, result in
                ["type": "tool_result", "tool_use_id": call.id, "content": result.text, "is_error": result.isError] as [String: Any]
            }])
        })
    }

    /// One streamed Anthropic turn: text and thinking go out as they come;
    /// tool_use blocks are collected with their streamed JSON input.
    static func anthropicTurn(_ request: URLRequest, yield: @escaping (AOMAIPiece) -> Void) async throws -> ToolTurn {
        let bytes = try await openStream(request)
        var turn = ToolTurn()
        var blocks: [Int: (type: String, id: String, name: String, json: String, text: String, signature: String)] = [:]
        var thinkingShown = false
        reading: for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = AOMAISSE.payload(line), let object = jsonObject(payload), let type = object["type"] as? String else { continue }
            let index = object["index"] as? Int ?? 0
            switch type {
            case "content_block_start":
                let block = object["content_block"] as? [String: Any] ?? [:]
                let kind = block["type"] as? String ?? ""
                var json = ""
                if kind == "tool_use", let input = block["input"] as? [String: Any], !input.isEmpty { json = jsonString(input) }
                blocks[index] = (kind, block["id"] as? String ?? "", block["name"] as? String ?? "", json, "", "")
                if kind == "thinking", !thinkingShown { thinkingShown = true; yield(.thinking) }
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    turn.text += text
                    thinkingShown = false
                    yield(.text(text))
                case "thinking_delta":
                    blocks[index]?.text += delta["thinking"] as? String ?? ""
                    if !thinkingShown { thinkingShown = true; yield(.thinking) }
                case "signature_delta":
                    blocks[index]?.signature += delta["signature"] as? String ?? ""
                case "input_json_delta":
                    blocks[index]?.json += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
            case "message_delta":
                if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String { turn.stopReason = reason }
            case "message_stop":
                break reading
            case "error":
                let error = object["error"] as? [String: Any]
                throw AOMAIError(message: (error?["message"] as? String) ?? "The model reported an error.")
            default:
                break
            }
        }
        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            if block.type == "thinking" { turn.thinking.append((block.text, block.signature)) }
            if block.type == "tool_use" {
                let raw = block.json.isEmpty ? "{}" : block.json
                turn.calls.append(ToolCall(id: block.id.isEmpty ? "toolu_aom_\(index)" : block.id, name: block.name,
                                           arguments: jsonObject(raw) ?? [:], rawArguments: raw))
            }
        }
        return turn
    }

    // MARK: OpenAI-compatible chat

    static func openAIToolStream(_ base: URLRequest, body: [String: Any], scope: AOMAIRecordScope = .none) -> AsyncThrowingStream<AOMAIPiece, Error> {
        let box = MessageBox(messages: body["messages"] as? [[String: Any]] ?? [])
        let schemas = AOMAILocalTools.openAISchemas(AOMAILocalTools.tools(for: scope))
        return toolStream(base: base, ensureProxy: nil, scope: scope, turn: openAITurn, request: { round, withTools in
            var payload = body
            payload["messages"] = box.messages
            if withTools {
                payload["tools"] = schemas
                if round == maxToolRounds - 1 { payload["tool_choice"] = "none" }
            }
            var request = base
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            return request
        }, append: { turn, results in
            box.messages.append(["role": "assistant", "content": turn.text.isEmpty ? NSNull() : turn.text as Any,
                                 "tool_calls": turn.calls.map { ["id": $0.id, "type": "function",
                                                                 "function": ["name": $0.name, "arguments": $0.rawArguments]] as [String: Any] }])
            for (call, result) in results {
                box.messages.append(["role": "tool", "tool_call_id": call.id, "content": result.text])
            }
        })
    }

    /// One streamed chat-completions turn, tool_calls collected by index.
    static func openAITurn(_ request: URLRequest, yield: @escaping (AOMAIPiece) -> Void) async throws -> ToolTurn {
        let bytes = try await openStream(request)
        var turn = ToolTurn()
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        var thinkingShown = false
        reading: for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = AOMAISSE.payload(line) else { continue }
            if payload == "[DONE]" { break reading }
            guard let object = jsonObject(payload) else { continue }
            if let error = object["error"] as? [String: Any] {
                throw AOMAIError(message: (error["message"] as? String) ?? "The model reported an error.")
            }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let text = delta["content"] as? String, !text.isEmpty {
                turn.text += text
                thinkingShown = false
                yield(.text(text))
            } else if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty, !thinkingShown {
                thinkingShown = true
                yield(.thinking)
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                let function = call["function"] as? [String: Any] ?? [:]
                var entry = calls[index] ?? ("", "", "")
                if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                if let name = function["name"] as? String, !name.isEmpty { entry.name += name }
                if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                calls[index] = entry
            }
            if let reason = choice["finish_reason"] as? String { turn.stopReason = reason }
        }
        turn.calls = calls.keys.sorted().compactMap { index in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            let raw = call.arguments.isEmpty ? "{}" : call.arguments
            return ToolCall(id: call.id.isEmpty ? "call_aom_\(index)" : call.id, name: call.name, arguments: jsonObject(raw) ?? [:], rawArguments: raw)
        }
        return turn
    }

    /// The growing message list a tool conversation sends each round.
    final class MessageBox: @unchecked Sendable {
        var messages: [[String: Any]]
        init(messages: [[String: Any]]) { self.messages = messages }
    }
}
