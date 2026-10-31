import Foundation

/// A helper process whose output arrives while it runs (Homebrew's upgrade
/// log, a cleanup, `tailscale up`). Same rules as `SystemToolsCommand`: a
/// fixed executable and an argument array, never `sh -c`. On top of that it
/// has an explicit environment, a timeout and Cancel.
///
/// Both pipes are drained by readability handlers as data arrives, so a
/// large answer (`brew info --json=v2 --installed` is about 400 KB) never
/// fills a pipe and stalls the child. Cancel sends SIGINT first (what ⌃C in
/// Terminal sends, which Homebrew handles cleanly), then SIGTERM after 3 s
/// and SIGKILL after 6 s; a timeout does the same.
final class StreamingCommand: @unchecked Sendable {
    struct Result: Equatable, Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let cancelled: Bool
        var succeeded: Bool { status == 0 && !timedOut && !cancelled }

        /// Standard error, else the last lines of standard output: the part
        /// of a failed run worth showing.
        var failureDetail: String {
            let error = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty { return String(error.suffix(600)) }
            let lines = stdout.split(whereSeparator: \.isNewline).suffix(4)
            return lines.joined(separator: "\n")
        }
    }

    enum Stream: Sendable { case stdout, stderr }

    enum Failure: LocalizedError, Equatable {
        case notExecutable(String)
        var errorDescription: String? {
            switch self {
            case .notExecutable(let path): return "\(path) isn't there or can't be run."
            }
        }
    }

    let executable: URL
    let arguments: [String]
    let environment: [String: String]?
    let timeout: TimeInterval
    /// The most output kept per stream for parsing; the live log keeps its own tail.
    static let storedLimit = 16 * 1024 * 1024

    private let lock = NSLock()
    private let process = Process()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var partial: [Stream: Data] = [.stdout: Data(), .stderr: Data()]
    private var didTimeOut = false
    private var didCancel = false
    private var started = false
    private var finished = false

    init(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }

    var isRunning: Bool { locked { started && !finished } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Runs to completion. `onLine` gets every complete output line (split
    /// on newlines and carriage returns) on a background queue, in order per
    /// stream. Task cancellation cancels the process.
    func run(onLine: (@Sendable (Stream, String) -> Void)? = nil) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.notExecutable(executable.path)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                do {
                    try start(onLine: onLine) { continuation.resume(returning: $0) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(onLine: (@Sendable (Stream, String) -> Void)?, completion: @escaping (Result) -> Void) throws {
        let out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        group.enter(); group.enter(); group.enter()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.flush(.stdout, onLine: onLine)
                group.leave()
            } else {
                self?.append(data, to: .stdout, onLine: onLine)
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.flush(.stderr, onLine: onLine)
                group.leave()
            } else {
                self?.append(data, to: .stderr, onLine: onLine)
            }
        }
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        locked { started = true }
        // The parent's copies of the write ends must close, or EOF never comes.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.isRunning else { return }
            self.locked { self.didTimeOut = true }
            self.stopSequence()
        }
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self else { return }
            let result: Result = self.locked {
                self.finished = true
                return Result(status: self.process.terminationStatus,
                              stdout: String(decoding: self.stdoutData, as: UTF8.self),
                              stderr: String(decoding: self.stderrData, as: UTF8.self),
                              timedOut: self.didTimeOut, cancelled: self.didCancel)
            }
            completion(result)
        }
    }

    /// Stops the process (SIGINT, then SIGTERM, then SIGKILL). Safe to call
    /// more than once and before or after the process ends.
    func cancel() {
        let running: Bool = locked {
            guard started, !finished else { return false }
            didCancel = true
            return true
        }
        if running { stopSequence() }
    }

    private func stopSequence() {
        guard process.isRunning else { return }
        process.interrupt()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.process.isRunning, pid > 0 else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    private func append(_ data: Data, to stream: Stream, onLine: (@Sendable (Stream, String) -> Void)?) {
        var lines: [String] = []
        locked {
            switch stream {
            case .stdout: if stdoutData.count < Self.storedLimit { stdoutData.append(data) }
            case .stderr: if stderrData.count < Self.storedLimit { stderrData.append(data) }
            }
            guard onLine != nil else { return }
            var buffer = partial[stream, default: Data()]
            buffer.append(data)
            lines = Self.takeLines(from: &buffer)
            partial[stream] = buffer
        }
        lines.forEach { onLine?(stream, $0) }
    }

    private func flush(_ stream: Stream, onLine: (@Sendable (Stream, String) -> Void)?) {
        let rest: String? = locked {
            guard let buffer = partial[stream], !buffer.isEmpty else { return nil }
            partial[stream] = Data()
            return String(decoding: buffer, as: UTF8.self)
        }
        if let rest, !rest.isEmpty { onLine?(stream, rest) }
    }

    /// Complete lines from the front of `buffer`; the unfinished tail stays.
    /// A carriage return ends a line too (progress output rewrites one line).
    static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        var start = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let byte = buffer[index]
            if byte == 0x0A || byte == 0x0D {
                let line = String(decoding: buffer[start..<index], as: UTF8.self)
                if !(byte == 0x0A && index > buffer.startIndex && buffer[buffer.index(before: index)] == 0x0D && line.isEmpty) {
                    lines.append(line)
                }
                start = buffer.index(after: index)
            }
            index = buffer.index(after: index)
        }
        buffer = Data(buffer[start..<buffer.endIndex])
        return lines
    }
}
