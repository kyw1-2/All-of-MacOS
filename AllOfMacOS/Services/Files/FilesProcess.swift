import Foundation

/// Runs a tool with an argument array (never a shell), reads its output while
/// it runs so a full pipe can't stall it, and stops it after `timeout`.
/// Blocking: call from a background thread or `Task.detached`.
enum FilesProcess {
    struct Output: Equatable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var succeeded: Bool { status == 0 && !timedOut }
    }

    enum Failure: LocalizedError, Equatable {
        case couldNotStart(String)
        case timedOut(String)
        case failed(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let tool): return "\(tool) couldn't start"
            case .timedOut(let tool): return "\(tool) took too long and was stopped"
            case .failed(let tool, let status, let message):
                return message.isEmpty ? "\(tool) failed (exit status \(status))" : "\(tool) failed: \(message)"
            }
        }
    }

    /// Cancels a running tool from another thread.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock(); cancelled = true; let running = process; lock.unlock()
            if running?.isRunning == true { running?.terminate() }
        }
        fileprivate func attach(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            self.process = process
            return !cancelled
        }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval, handle: Handle? = nil) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collected = Collector()
        out.fileHandleForReading.readabilityHandler = { collected.appendOut($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collected.appendErr($0.availableData) }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return Output(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        if let handle, !handle.attach(process) { process.terminate() }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.appendOut(out.fileHandleForReading.readDataToEndOfFile())
        collected.appendErr(err.fileHandleForReading.readDataToEndOfFile())
        return Output(status: process.terminationStatus, stdout: collected.stdout, stderr: collected.stderr, timedOut: timedOut)
    }

    /// Throws a readable error for a failed or stopped run.
    static func checked(_ path: String, _ arguments: [String], timeout: TimeInterval, handle: Handle? = nil) throws -> Output {
        let tool = URL(fileURLWithPath: path).lastPathComponent
        let output = run(path, arguments, timeout: timeout, handle: handle)
        if output.status == -1 && !output.timedOut { throw Failure.couldNotStart(tool) }
        if output.timedOut { throw Failure.timedOut(tool) }
        guard output.status == 0 else {
            throw Failure.failed(tool, output.status, output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        func appendOut(_ data: Data) { lock.lock(); outData.append(data); lock.unlock() }
        func appendErr(_ data: Data) { lock.lock(); errData.append(data); lock.unlock() }
        var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: outData, as: UTF8.self) }
        var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }
    }
}
