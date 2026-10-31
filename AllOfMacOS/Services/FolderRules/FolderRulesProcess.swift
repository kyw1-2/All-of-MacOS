import Darwin
import Foundation

/// Runs the helpers behind Folder Rules (ditto, hdiutil, shortcuts) as a
/// fixed executable with an argument array (never `sh -c`), with standard
/// input closed and a timeout. Blocking: call it off the main thread.
enum FolderRulesProcess {
    struct Request: Equatable {
        var executable: String
        var arguments: [String]
        var timeout: TimeInterval

        init(_ executable: String, _ arguments: [String], timeout: TimeInterval) {
            self.executable = executable
            self.arguments = arguments
            self.timeout = timeout
        }

        var name: String { URL(fileURLWithPath: executable).lastPathComponent }
    }

    struct Result: Equatable {
        var status: Int32
        var stdout: Data
        var stderr: String
        var timedOut = false
        /// Set when the executable couldn't start at all.
        var launchError: String?

        var succeeded: Bool { status == 0 && !timedOut && launchError == nil }

        /// Why it failed, in one line, for the activity log.
        func failure(_ request: Request) -> String {
            if let launchError { return "\(request.name) couldn't start: \(launchError)" }
            if timedOut { return "\(request.name) took longer than \(Int(request.timeout)) seconds and was stopped." }
            let message = FolderRulesProcess.meaningfulLines(stderr)
            return message.isEmpty ? "\(request.name) failed (exit status \(status))." : "\(request.name) failed: \(message)"
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        func set(_ data: Data) { lock.lock(); stored = data; lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
    }

    static func run(_ request: Request) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: Data(), stderr: "", launchError: error.localizedDescription)
        }
        // Both pipes drain while the process runs, so a chatty helper can't
        // fill one pipe and stall.
        let outBuffer = Buffer(), errBuffer = Buffer()
        let readers = DispatchGroup()
        for (pipe, buffer) in [(out, outBuffer), (err, errBuffer)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }
        var timedOut = false
        if finished.wait(timeout: .now() + max(0.1, request.timeout)) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 3)
            }
        }
        // A grandchild that inherited a pipe could keep it open; don't wait forever.
        _ = readers.wait(timeout: .now() + 5)
        return Result(status: process.isRunning ? -1 : process.terminationStatus,
                      stdout: outBuffer.data,
                      stderr: String(decoding: errBuffer.data, as: UTF8.self),
                      timedOut: timedOut)
    }

    /// stderr without hdiutil's "is deprecated" notes, joined on one line.
    static func meaningfulLines(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("is deprecated") }
            .joined(separator: " ")
    }
}
