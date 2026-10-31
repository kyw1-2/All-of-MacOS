import Foundation

/// Why a Shortcuts call failed, in words for the activity log and HUD.
enum FocusShortcutError: Error, Equatable, LocalizedError {
    case unavailable
    case timedOut(seconds: Int)
    case failed(status: Int32, message: String)
    case launch(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "the Shortcuts command-line tool isn't on this Mac"
        case .timedOut(let seconds): return "it didn't finish within \(seconds) seconds"
        case .failed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Shortcuts ended with status \(status)" : trimmed
        case .launch(let reason): return reason
        }
    }
}

/// Runs a child process with an argument array (never a shell), reads both
/// pipes while it runs and stops it after `timeout`. Call it off the main
/// thread.
enum FocusProcess {
    struct Output: Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let out = Buffer(), err = Buffer()
        let readers = DispatchGroup()
        try process.run()
        for (pipe, buffer) in [(outPipe, out), (errPipe, err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        _ = readers.wait(timeout: .now() + 2)
        return Output(status: process.terminationStatus, stdout: out.string, stderr: err.string, timedOut: timedOut)
    }
}

/// The Shortcuts app's command-line tool (`/usr/bin/shortcuts`). macOS gives
/// other apps no API to turn a Focus (Do Not Disturb, Work …) on or off, so
/// a person who wants that builds a shortcut with Shortcuts' "Set Focus"
/// action and picks it here; AOM runs it when a focus phase starts or ends.
enum FocusShortcutsCLI {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    static let listTimeout: TimeInterval = 20
    static let runTimeout: TimeInterval = 120
    private static let queue = DispatchQueue(label: "com.kyw.allofmacos.focus.shortcuts", qos: .userInitiated)

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    static let previewSamples = [
        FocusShortcutRef(name: "Do Not Disturb On", identifier: "6F1C2A3B-0000-4000-8000-000000000001"),
        FocusShortcutRef(name: "Do Not Disturb Off", identifier: "6F1C2A3B-0000-4000-8000-000000000002"),
        FocusShortcutRef(name: "Study Focus", identifier: "6F1C2A3B-0000-4000-8000-000000000003")
    ]

    /// Parses `shortcuts list --show-identifiers`: one shortcut per line,
    /// "Name (UUID)". Names may contain parentheses; only a trailing UUID in
    /// parentheses is taken as the identifier. Lines without one (the plain
    /// `shortcuts list`) become names. Blank lines and duplicates are dropped.
    static func parseList(_ output: String) -> [FocusShortcutRef] {
        let pattern = #"^(.*\S)\s+\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var seen = Set<String>()
        var result: [FocusShortcutRef] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var ref = FocusShortcutRef(name: line, identifier: nil)
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex?.firstMatch(in: line, range: range),
               let name = Range(match.range(at: 1), in: line), let id = Range(match.range(at: 2), in: line) {
                ref = FocusShortcutRef(name: String(line[name]), identifier: String(line[id]).uppercased())
            }
            guard seen.insert(ref.id).inserted else { continue }
            result.append(ref)
        }
        return result
    }

    /// Lists the user's shortcuts off the main thread; completes on main.
    /// Isolated previews show sample names and never read the real list.
    static func list(completion: @escaping @MainActor (Result<[FocusShortcutRef], FocusShortcutError>) -> Void) {
        guard !PresetManager.isRunningTests else { return }
        if PresetManager.isUIPreview {
            Task { @MainActor in completion(.success(previewSamples)) }
            return
        }
        guard isAvailable else { Task { @MainActor in completion(.failure(.unavailable)) }; return }
        queue.async {
            let result: Result<[FocusShortcutRef], FocusShortcutError>
            do {
                let output = try FocusProcess.run(executable, arguments: ["list", "--show-identifiers"], timeout: listTimeout)
                if output.timedOut { result = .failure(.timedOut(seconds: Int(listTimeout))) }
                else if output.status != 0 { result = .failure(.failed(status: output.status, message: output.stderr)) }
                else { result = .success(parseList(output.stdout)) }
            } catch {
                result = .failure(.launch(error.localizedDescription))
            }
            Task { @MainActor in completion(result) }
        }
    }

    /// Runs one shortcut off the main thread; completes on main.
    static func run(_ shortcut: FocusShortcutRef,
                    completion: @escaping @MainActor (Result<Void, FocusShortcutError>) -> Void) {
        guard !PresetManager.isRunningTests, !PresetManager.isUIPreview else { return }
        guard isAvailable else { Task { @MainActor in completion(.failure(.unavailable)) }; return }
        queue.async {
            let result: Result<Void, FocusShortcutError>
            do {
                let output = try FocusProcess.run(executable, arguments: ["run", shortcut.runArgument], timeout: runTimeout)
                if output.timedOut { result = .failure(.timedOut(seconds: Int(runTimeout))) }
                else if output.status != 0 { result = .failure(.failed(status: output.status, message: output.stderr)) }
                else { result = .success(()) }
            } catch {
                result = .failure(.launch(error.localizedDescription))
            }
            Task { @MainActor in completion(result) }
        }
    }
}
