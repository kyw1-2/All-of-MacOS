import AppKit

/// Runs the helper commands behind the 3.3.5 System Tools. Every command is a
/// fixed executable with an argument array (never `sh -c` with interpolated
/// input), and success means exit status 0.
enum SystemToolsCommand {
    struct Output: Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs to completion and captures both streams. Blocking: call it off
    /// the main thread. Standard error is drained on a background queue so a
    /// chatty helper can't fill one pipe while the other is being read.
    static func run(_ path: String, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: outputData, as: UTF8.self),
                      stderr: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `run` that throws `SystemToolError.commandFailed` on a non-zero exit.
    @discardableResult
    static func runChecked(_ path: String, _ arguments: [String]) throws -> Output {
        let output = try run(path, arguments)
        guard output.succeeded else {
            throw SystemToolError.commandFailed(command: URL(fileURLWithPath: path).lastPathComponent,
                                                status: output.status, message: output.stderr)
        }
        return output
    }

    // MARK: - Administrator

    /// The `do shell script` line for fixed commands: each argument is shell
    /// quoted, then the whole line is escaped for an AppleScript string
    /// literal (backslash and double quote).
    static func administratorScript(_ commands: [MacMagicSystemToolService.ToolCommand]) -> String {
        let shell = commands.map { command in
            ([command.path] + command.arguments).map(ShellQuote.single).joined(separator: " ")
        }.joined(separator: " && ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// The same administrator prompt pattern as Flush DNS: the standard macOS
    /// authorization dialog, started only by the user's click.
    @MainActor
    static func runAsAdministrator(_ commands: [MacMagicSystemToolService.ToolCommand]) -> MacMagicSystemToolService.AdministratorResult {
        guard let script = NSAppleScript(source: administratorScript(commands)) else {
            return .failed("The request could not be prepared.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .done }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "macOS refused the request.")
    }

    // MARK: - Session and processes

    /// Restart and Shut Down go through System Events, which asks every app
    /// to quit the normal way (unsaved documents still get their prompt).
    enum SessionCommand: String { case restart = "restart", shutDown = "shut down" }

    static func sessionScript(_ command: SessionCommand) -> String {
        "tell application \"System Events\" to \(command.rawValue)"
    }

    static func perform(_ command: SessionCommand) throws {
        try runChecked("/usr/bin/osascript", ["-e", sessionScript(command)])
    }

    /// The user's own system UI processes that relaunch by themselves when
    /// they quit (Dock, the menu bar). `killall` without -9 lets them save.
    static func restartProcesses(_ names: [String]) throws {
        var failures: [String] = []
        for name in names {
            let output = try run("/usr/bin/killall", [name])
            if !output.succeeded { failures.append("\(name): \(output.stderr.isEmpty ? "exit \(output.status)" : output.stderr)") }
        }
        guard failures.isEmpty else {
            throw SystemToolError.commandFailed(command: "killall", status: 1, message: failures.joined(separator: "; "))
        }
    }
}
