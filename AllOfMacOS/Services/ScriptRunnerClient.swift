import Foundation

@objc(AOMScriptRunnerProtocol)
protocol ScriptRunnerProtocol {
    func run(_ kind: String, source: String, timeout: Double,
             reply: @escaping (Int32, String, Bool) -> Void)
}

/// Script kinds the helper accepts. Shared by the client and the helper (both
/// compile this file) so the two lists cannot drift apart.
enum ScriptRunnerKinds {
    /// "javascript" is JavaScript for Automation, run by `osascript -l JavaScript`.
    static let allowed: Set<String> = ["shell", "applescript", "javascript", "swift"]
    /// Interpreter and leading arguments; the script file path is appended.
    static func command(for kind: String) -> (executable: String, arguments: [String])? {
        switch kind {
        case "swift": return ("/usr/bin/xcrun", ["swift"])
        case "shell": return ("/bin/zsh", [])
        case "applescript": return ("/usr/bin/osascript", [])
        case "javascript": return ("/usr/bin/osascript", ["-l", "JavaScript"])
        default: return nil
        }
    }
}

/// One connection per invocation. A helper crash never retries a script that
/// may already have performed side effects. Callbacks always resume on main.
final class ScriptRunnerClient {
    static let shared = ScriptRunnerClient()
    private var calls: [UUID: NSXPCConnection] = [:]
    func run(kind: String, source: String, timeout: Double = 30,
             completion: @escaping (Int32, String, Bool) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.run(kind: kind, source: source, timeout: timeout, completion: completion) }
            return
        }
        guard calls.count < 2 else { completion(-1, "Two scripts are already running", false); return }
        guard source.utf8.count <= 1_048_576, ScriptRunnerKinds.allowed.contains(kind), timeout.isFinite else {
            completion(-1, "Invalid script request", false); return
        }
        let deadline = min(120, max(0.1, timeout))
        let id = UUID()
        let connection = NSXPCConnection(serviceName: "com.kyw.allofmacos.ScriptRunner")
        calls[id] = connection
        connection.remoteObjectInterface = NSXPCInterface(with: ScriptRunnerProtocol.self)
        var finished = false
        var watchdog: DispatchWorkItem?
        func finish(_ code: Int32, _ output: String, _ timedOut: Bool) {
            DispatchQueue.main.async {
                guard !finished else { return }; finished = true
                watchdog?.cancel()
                self.calls.removeValue(forKey: id)
                connection.invalidationHandler = nil; connection.interruptionHandler = nil
                connection.invalidate()
                completion(code, output, timedOut)
            }
        }
        connection.interruptionHandler = { finish(-1, "Script helper interrupted", false) }
        connection.invalidationHandler = { finish(-1, "Script helper unavailable", false) }
        connection.resume()
        let item = DispatchWorkItem { finish(-1, "Script helper response timed out", true) }
        watchdog = item; DispatchQueue.main.asyncAfter(deadline: .now() + deadline + 12, execute: item)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(-1, "Script helper connection failed", false) }) as? ScriptRunnerProtocol else {
            finish(-1, "Script helper interface missing", false); return
        }
        proxy.run(kind, source: source, timeout: deadline, reply: finish)
    }
}
