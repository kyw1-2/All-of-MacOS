import CryptoKit
import Foundation

// AOM 7.2 (Oracle report 05 §3-H): Script Commands. Any script in
// ~/Library/Application Support/AllOfMacOS/Script Commands with a title in
// its header comments is a launcher command. Raycast's metadata
// (`# @raycast.title`, `@raycast.mode`, `@raycast.argument1` …) is read as
// is, so existing Raycast script commands work when copied in; `@aom.` is
// the same with AOM's prefix. A script runs only after the launcher asked
// once, and asks again whenever its contents change.

struct PaletteScript: Identifiable, Hashable {
    enum Mode: String, Hashable {
        /// Runs, then a short HUD.
        case silent
        /// The last line of the output in a HUD.
        case compact
        /// The whole output in the launcher.
        case fullOutput
        /// Raycast refreshes these in its root search; AOM shows the last line.
        case inline
    }

    struct Argument: Hashable {
        var placeholder: String
        var optional: Bool
        var secure: Bool
    }

    let url: URL
    let title: String
    var mode: Mode = .compact
    var icon: String?
    var packageName: String?
    var description: String?
    var argument: Argument?
    var needsConfirmation = false

    var id: String { "script.\(url.path)" }

    /// Pure: the metadata of a script's first lines, nil without a title.
    static func parse(_ text: String, url: URL) -> PaletteScript? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
            var body = line.trimmingCharacters(in: .whitespaces)
            guard let marker = ["#", "//", "--", ";"].first(where: { body.hasPrefix($0) }) else { continue }
            body = String(body.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@raycast.") || body.hasPrefix("@aom.") else { continue }
            let rest = body.drop { $0 != "." }.dropFirst()
            let key = rest.prefix { !$0.isWhitespace }
            let value = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, fields[String(key)] == nil { fields[String(key)] = value }
        }
        guard let title = fields["title"], !title.isEmpty else { return nil }
        var script = PaletteScript(url: url, title: title)
        script.mode = Mode(rawValue: fields["mode"] ?? "") ?? .compact
        if let icon = fields["icon"], !icon.isEmpty, icon.count <= 2, !icon.contains("/") { script.icon = icon }
        script.packageName = fields["packageName"].flatMap { $0.isEmpty ? nil : $0 }
        script.description = fields["description"].flatMap { $0.isEmpty ? nil : $0 }
        script.needsConfirmation = fields["needsConfirmation"] == "true"
        if let json = fields["argument1"], let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            script.argument = Argument(placeholder: object["placeholder"] as? String ?? "Argument",
                                       optional: object["optional"] as? Bool ?? false,
                                       secure: (object["type"] as? String) == "password")
        }
        return script
    }
}

enum PaletteScripts {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AllOfMacOS/Script Commands", isDirectory: true)
    }

    /// Every script with a title in `folder` (not in subfolders), by title.
    static func scan(_ folder: URL = folder) -> [PaletteScript] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> PaletteScript? in
            let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 1_000_000,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 8_192)) ?? Data()
            return PaletteScript.parse(String(decoding: head, as: UTF8.self), url: url)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The contents' SHA-256: what was approved, so an edited script asks again.
    static func fingerprint(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let trustKey = "AOMScriptCommandsTrusted"

    /// 7.3 (Codex 7.2.3 report): the launcher hashed every script's whole
    /// file each time it built its rows. The hash is kept per path, size and
    /// modification date, so an unchanged script isn't read again; running
    /// still checks it afresh (`isTrusted(_:fresh: true)`).
    private nonisolated(unsafe) static var fingerprintCache: [String: (stamp: String, print: String)] = [:]
    private static let cacheLock = NSLock()

    /// Inode, size and modification time in nanoseconds, from stat(2) — URL
    /// resource values are cached on the URL and would miss an edit.
    static func stamp(_ url: URL) -> String? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return "\(status.st_ino):\(status.st_size):\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
    }

    static func cachedFingerprint(_ url: URL) -> String? {
        guard let stamp = stamp(url) else { return nil }
        cacheLock.lock()
        if let hit = fingerprintCache[url.path], hit.stamp == stamp { cacheLock.unlock(); return hit.print }
        cacheLock.unlock()
        guard let print = fingerprint(url) else { return nil }
        cacheLock.lock(); fingerprintCache[url.path] = (stamp, print); cacheLock.unlock()
        return print
    }

    static func isTrusted(_ script: PaletteScript, defaults: UserDefaults = .standard, fresh: Bool = false) -> Bool {
        guard let print = fresh ? fingerprint(script.url) : cachedFingerprint(script.url) else { return false }
        return (defaults.dictionary(forKey: trustKey) as? [String: String])?[script.url.path] == print
    }

    static func trust(_ script: PaletteScript, defaults: UserDefaults = .standard) {
        guard let print = fingerprint(script.url) else { return }
        var table = defaults.dictionary(forKey: trustKey) as? [String: String] ?? [:]
        table[script.url.path] = print
        defaults.set(table, forKey: trustKey)
    }

    /// Pure: how to start a script — itself when executable, else the
    /// interpreter its first line names, else zsh.
    static func invocation(for url: URL, firstLine: String, isExecutable: Bool) -> (executable: URL, arguments: [String]) {
        if isExecutable { return (url, []) }
        if firstLine.hasPrefix("#!") {
            let parts = firstLine.dropFirst(2).split(separator: " ").map(String.init)
            if let interpreter = parts.first, interpreter.hasPrefix("/") {
                return (URL(fileURLWithPath: interpreter), Array(parts.dropFirst()) + [url.path])
            }
        }
        return (URL(fileURLWithPath: "/bin/zsh"), [url.path])
    }

    struct Outcome: Equatable {
        var status: Int32
        var output: String
        var timedOut: Bool
        var cancelled: Bool
        var succeeded: Bool { status == 0 && !timedOut && !cancelled }

        /// The line a HUD shows.
        var lastLine: String? {
            output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Runs a script in its folder with Homebrew on the PATH.
    static func command(for script: PaletteScript, argument: String?) -> StreamingCommand {
        let firstLine = (try? String(contentsOf: script.url, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
        let start = invocation(for: script.url, firstLine: firstLine,
                               isExecutable: FileManager.default.isExecutableFile(atPath: script.url.path))
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["AOM_SCRIPT_COMMAND"] = "1"
        let arguments = start.arguments + (argument.map { [$0] } ?? [])
        // 7.3 (7.2.1 audit B14): "runs in its folder" — it now does.
        return StreamingCommand(start.executable, arguments, environment: environment, timeout: 120,
                                currentDirectory: script.url.deletingLastPathComponent())
    }

    static func outcome(_ result: StreamingCommand.Result) -> Outcome {
        let text = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let capped = text.count > 64_000 ? String(text.prefix(64_000)) + "\n…" : text
        return Outcome(status: result.status, output: capped, timedOut: result.timedOut, cancelled: result.cancelled)
    }

    /// Compact and silent scripts keep running after the launcher closes;
    /// the HUD reports how they ended.
    @MainActor
    static func runInBackground(_ script: PaletteScript, argument: String?) {
        let command = command(for: script, argument: argument)
        GestureLog.shared.logFromAnyThread("Script command \(script.title) started", level: .action)
        Task { @MainActor in
            let result: StreamingCommand.Result
            do { result = try await command.run(onLine: nil) }
            catch { result = .init(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false, cancelled: false) }
            let outcome = outcome(result)
            let detail = outcome.succeeded ? (script.mode == .silent ? "Done" : outcome.lastLine ?? "Done")
                : outcome.timedOut ? "Stopped after two minutes" : "Failed: \(outcome.lastLine ?? "exit code \(outcome.status)")"
            GestureHUD.shared.show(title: script.title, detail: String(detail.prefix(160)))
        }
    }

    /// A starting point in the folder, opened in the editor.
    @discardableResult
    static func createExample() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("public-ip.sh")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        let text = """
        #!/bin/bash

        # Required parameters:
        # @aom.title Show Public IP
        # @aom.mode compact

        # Optional parameters:
        # @aom.icon 🌐
        # @aom.packageName Network
        # @aom.description Print this Mac's public IP address (also works as a Raycast script command)

        curl -s https://api64.ipify.org
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
