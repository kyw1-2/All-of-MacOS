import Foundation
import Security
import Darwin

final class Runner: NSObject, ScriptRunnerProtocol {
    private let lock = NSLock()
    private var active = 0
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func run(_ kind: String, source: String, timeout: Double, reply: @escaping (Int32, String, Bool) -> Void) {
        guard ["shell", "applescript"].contains(kind), source.utf8.count <= 1_048_576, timeout.isFinite else { reply(-1, "Invalid request", false); return }
        lock.lock()
        guard active == 0, !cancelled else { lock.unlock(); reply(-1, "Runner busy", false); return }
        active += 1; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let result = self.execute(kind, source, min(120, max(0.1, timeout)))
            self.lock.lock(); self.active -= 1; self.lock.unlock()
            reply(result.0, result.1, result.2)
        }
    }
    private func execute(_ kind: String, _ source: String, _ timeout: Double) -> (Int32, String, Bool) {
        let executable = kind == "shell" ? "/bin/zsh" : "/usr/bin/osascript"
        // A private temp file avoids argv limits and keeps script contents out of ps.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return (-1, "Cannot prepare script", false) }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: Data(source.utf8)); try handle.close() }
        catch { try? handle.close(); return (-1, "Cannot prepare script", false) }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return (-1, "Cannot create output pipe", false) }
        defer { close(fds[0]) }
        var actions: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0]); posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)); posix_spawnattr_setpgroup(&attr, 0)
        // Keep the Swift String array distinct from the C argv pointers.
        // macOS 15 Xcode otherwise infers UnsafePointer<CChar> for the literal.
        let arguments: [String] = [executable, file.path]
        let strings: [UnsafeMutablePointer<CChar>?] =
            arguments.map { value in value.withCString { strdup($0) } }
        defer { strings.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        var argv = strings + [nil]; var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attr, &argv, &envp)
        close(fds[1])
        guard result == 0 else { return (-1, "Cannot spawn script", false) }
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // Bound each drain so an infinite producer cannot starve the deadline.
            for _ in 0..<32 {
                let count = read(fds[0], &buffer, buffer.count)
                guard count > 0 else { return }
                if output.count < 65536 { output.append(contentsOf: buffer.prefix(min(count, 65536 - output.count))) }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0; var timedOut = false
        while true {
            drain()
            if waitpid(pid, &status, WNOHANG) == pid { break }
            if isCancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true; kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        drain()
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (code, String(decoding: output, as: UTF8.self), timedOut)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private func certificate(_ code: SecCode) -> Data? {
        var info: CFDictionary?; var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first else { return nil }
        return SecCertificateCopyData(first) as Data
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        var guest: SecCode?; var own: SecCode?; var requirement: SecRequirement?
        let attrs = [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest) == errSecSuccess,
              SecCodeCopySelf([], &own) == errSecSuccess,
              SecRequirementCreateWithString("identifier \"com.kyw.allofmacos\"" as CFString, [], &requirement) == errSecSuccess,
              let guest, let own, let requirement,
              SecCodeCheckValidity(guest, [], requirement) == errSecSuccess,
              let ownCert = certificate(own), certificate(guest) == ownCert else { return false }
        let runner = Runner()
        connection.exportedInterface = NSXPCInterface(with: ScriptRunnerProtocol.self)
        connection.exportedObject = runner
        connection.invalidationHandler = { runner.cancel() }
        connection.interruptionHandler = { runner.cancel() }
        connection.resume(); return true
    }
}
@main
enum ServiceMain {
    static func main() {
        let delegate = ListenerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}
