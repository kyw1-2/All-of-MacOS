import Foundation

/// 7.21: stdout/stderr bookkeeping for an agent CLI child process.
///
/// Before, the stdout line buffer and the stderr tail were plain captured
/// `var Data`s: the stderr handler appended on its FileHandle queue while the
/// termination handler read it on another (a data race on `Data`), and the
/// termination handler dropped whatever stdout had not been delivered yet —
/// often the final `result` line, so a finished answer showed as
/// "didn't answer". All state is behind one lock, and the exit path reads what is
/// still in the pipe with `drainWithoutWaiting()` (a grandchild such as an MCP
/// server can keep the write end open, so `readDataToEndOfFile` could hang).
final class AgentPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var errorTail = Data()
    private let errorLimit: Int

    init(errorLimit: Int = 4000) { self.errorLimit = errorLimit }

    /// Appends a stdout chunk; returns the complete lines it finished.
    func appendOutput(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        return takeLines(includingPartial: false)
    }

    /// Everything left: the chunk read at exit plus an unterminated last line.
    func finishOutput(_ rest: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(rest)
        return takeLines(includingPartial: true)
    }

    func appendError(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        errorTail.append(chunk)
        if errorTail.count > errorLimit { errorTail = Data(errorTail.suffix(errorLimit)) }
    }

    func errorText(_ rest: Data = Data()) -> String {
        appendError(rest)
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errorTail.suffix(2000), as: UTF8.self)
    }

    private func takeLines(includingPartial: Bool) -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if includingPartial, !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        return lines
    }

    /// A write into the pipe of an agent that already exited raises SIGPIPE,
    /// whose default action terminates AOM. Marks the write end so it returns
    /// EPIPE (a thrown error) instead.
    static func disableSIGPIPE(_ handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
}
