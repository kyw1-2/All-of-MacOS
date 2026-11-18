import Foundation

/// Runs a helper tool with an argument array (never a shell) and a timeout,
/// off the main thread. Both pipes are drained while the process runs, so a
/// large answer can't fill a pipe and stall it.
enum PaletteProcess {
    struct Output: Equatable {
        var status: Int32
        var standardOutput: String
        var standardError: String
        var timedOut: Bool
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data()
        private var error = Data()
        private var finished = false
        private var expired = false

        func append(output chunk: Data) { lock.lock(); output.append(chunk); lock.unlock() }
        func append(error chunk: Data) { lock.lock(); error.append(chunk); lock.unlock() }
        func expire() { lock.lock(); expired = true; lock.unlock() }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
        /// True the first time only.
        func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
        var texts: (String, String) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
        }
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice
            let collector = Collector()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in collector.append(output: handle.availableData) }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in collector.append(error: handle.availableData) }
            // Codex F15: a helper that ignores SIGTERM, or a child of it that
            // keeps the pipe open, used to keep the caller waiting forever.
            // SIGKILL follows 2 s after SIGTERM, the pipes are drained without
            // waiting for EOF, and a last deadline answers in any case.
            let watchdog = DispatchWorkItem {
                collector.expire()
                guard process.isRunning else { return }
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
            let deadline = DispatchWorkItem {
                guard collector.finish() else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let (out, err) = collector.texts
                continuation.resume(returning: Output(status: -1, standardOutput: out, standardError: err, timedOut: true))
            }
            process.terminationHandler = { finished in
                watchdog.cancel()
                deadline.cancel()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                collector.append(output: outputPipe.fileHandleForReading.drainWithoutWaiting())
                collector.append(error: errorPipe.fileHandleForReading.drainWithoutWaiting())
                guard collector.finish() else { return }
                let (out, err) = collector.texts
                continuation.resume(returning: Output(status: finished.terminationStatus, standardOutput: out,
                                                      standardError: err, timedOut: collector.timedOut))
            }
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 4, execute: deadline)
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                guard collector.finish() else { return }
                continuation.resume(returning: Output(status: -1, standardOutput: "",
                                                      standardError: error.localizedDescription, timedOut: false))
            }
        }
    }
}

extension FileHandle {
    /// What is buffered in the pipe now, without waiting for end of file: a
    /// grandchild that inherited the write end would keep EOF from coming.
    func drainWithoutWaiting(limit: Int = 16 << 20) -> Data {
        let fd = fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
