import Foundation

/// 7.2.1: the local Claude Code router (claude-code-proxy on 127.0.0.1:8082,
/// whose "haiku" route goes to DeepSeek) is started only by the user's
/// `~/.local/bin/claude` wrapper, and nothing brings it back. On 2026-11-21 it
/// had stopped at 10:12 and Ask AI's "Haiku → DeepSeek" answered "Couldn't
/// reach 127.0.0.1. Is Ollama running?". AOM now starts it the way the wrapper
/// does (its own venv, proxy variables removed, output to proxy.log) whenever
/// it doesn't answer, and waits for its health check before asking.
enum AOMLocalProxy {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/claude-code-proxy", isDirectory: true)
    }

    static let script = "start_proxy.py"

    /// The router can be started from this Mac.
    static func canStart(folder: URL = folder) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(script).path)
    }

    /// Pure: its own venv's Python, else the system's.
    static func launch(folder: URL, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> (executable: URL, arguments: [String]) {
        let venv = folder.appendingPathComponent(".venv/bin/python")
        return (isExecutable(venv.path) ? venv : URL(fileURLWithPath: "/usr/bin/python3"), [script])
    }

    /// Pure: the environment without the proxy variables that break its httpx client
    /// (the wrapper unsets the same ones).
    static func environment(_ base: [String: String]) -> [String: String] {
        let dropped: Set<String> = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "SOCKS_PROXY", "https_proxy", "http_proxy", "all_proxy", "socks_proxy"]
        return base.filter { !dropped.contains($0.key) }
    }

    /// Pure: whether a base URL is on this Mac (only then may AOM start something for it).
    static func isLocal(_ base: String) -> Bool {
        guard let host = URL(string: base)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Pure: what a refused connection to a local address means.
    static func unreachableHint(host: String?, port: Int?) -> String {
        guard let host, ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) else { return "" }
        switch port {
        case 8082: return " The local Claude Code proxy isn't running and couldn't be started from ~/.local/share/claude-code-proxy — run `claude` in Terminal once, or pick another model with ⌘P."
        case 11434: return " Is Ollama running?"
        default: return " Is the local server on port \(port.map(String.init) ?? "?") running?"
        }
    }

    /// The router's health check (`/health`), or any answer below 500 from its root.
    static func isHealthy(base: String) async -> Bool {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for path in ["/health", "/"] {
            guard let url = AOMAIClient.endpoint(base, path) else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await session.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode,
               status == 200 {  // a 404 root is some other server, not the router (Codex audit B23)
                return true
            }
        }
        return false
    }

    /// The process AOM started last (kept so its exit is reaped).
    @MainActor private(set) static var started: Process?
    @MainActor private static var starting: Task<Bool, Never>?

    /// Answers at once when the router is up; otherwise starts it (once,
    /// however many questions wait) and polls its health for `wait` seconds.
    @MainActor
    static func ensureRunning(base: String = AOMAIConfig.baseURL(for: .localProxy), folder: URL = folder,
                              wait: TimeInterval = 8) async -> Bool {
        if await isHealthy(base: base) {
            AOMAIConfig.setLocalProxyReachable(true)
            return true
        }
        guard isLocal(base), canStart(folder: folder), !PresetManager.isUIPreview else { return false }
        if let starting { return await starting.value }
        let task = Task { @MainActor () -> Bool in
            guard start(folder: folder) else { return false }
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                if await isHealthy(base: base) { return true }
            }
            return false
        }
        starting = task
        let ok = await task.value
        starting = nil
        AOMAIConfig.setLocalProxyReachable(ok)
        return ok
    }

    @MainActor
    private static func start(folder: URL) -> Bool {
        let (executable, arguments) = launch(folder: folder)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        let log = folder.appendingPathComponent("proxy.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            GestureLog.shared.logFromAnyThread("Couldn't start the local AI proxy: \(error.localizedDescription)", level: .error)
            return false
        }
        started = process
        GestureLog.shared.logFromAnyThread("Started the local AI proxy (\(folder.path), pid \(process.processIdentifier))", level: .action)
        return true
    }

    /// Tests: stops the router this process started.
    @MainActor
    static func stopStarted() {
        started?.terminate()
        started = nil
    }
}
