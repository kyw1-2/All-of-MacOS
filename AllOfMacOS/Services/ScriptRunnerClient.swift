import Foundation

@objc(AOMScriptRunnerProtocol)
protocol ScriptRunnerProtocol {
    func run(_ kind: String, source: String, timeout: Double,
             reply: @escaping (Int32, String, Bool) -> Void)
}

/// One connection per invocation. A helper crash never retries a script that
/// may already have performed side effects. Callbacks always resume on main.
final class ScriptRunnerClient {
    static let shared = ScriptRunnerClient()
    private var calls: [UUID: NSXPCConnection] = [:]
    func run(kind: String, source: String, timeout: Double = 30,
             completion: @escaping (Int32, String, Bool) -> Void) {
        guard calls.count < 2 else { completion(-1, "Two scripts are already running", false); return }
        guard source.utf8.count <= 1_048_576, ["shell", "applescript"].contains(kind), timeout.isFinite else {
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
