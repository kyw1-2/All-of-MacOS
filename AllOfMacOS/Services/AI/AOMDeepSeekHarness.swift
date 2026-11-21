import AppKit
import Foundation

/// 7.2.2: DeepSeek Harness as a launcher agent beside Claude Code and Codex.
///
/// The desktop app (com.deepseek.dsh-desktop) ships the `dsh` runtime inside
/// its app.asar but no command on the PATH. Its launcher has a headless
/// profile — `dsh --profile headless --json "task"` answers one task with
/// newline-delimited events (session, tool_call, text, final) and
/// `--session-id` continues it — and the app's Electron binary runs Node
/// with ELECTRON_RUN_AS_NODE. Node can't import ES modules from inside an
/// asar archive (every plugin failed to load), so the runtime is copied out
/// once per app version to ~/Library/Caches/AllOfMacOS/DeepSeekHarness/<version>
/// (about 107 MB, 9,800 files). It runs read-only (DSH_PERMISSION_MODE) in
/// the home folder, with the user's own DeepSeek Harness sign-in (~/.dsh).
enum AOMDeepSeekHarness {
    static let bundleID = "com.deepseek.dsh-desktop"

    static var appURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let fallback = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static var isInstalled: Bool { executable != nil }

    /// The app's Electron binary (runs Node with ELECTRON_RUN_AS_NODE).
    static var executable: URL? {
        guard let app = appURL else { return nil }
        let binary = app.appendingPathComponent("Contents/MacOS/DeepSeek Harness")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    static var version: String {
        appURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "unknown"
    }

    static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AllOfMacOS/DeepSeekHarness", isDirectory: true)
    }

    static func runtimeFolder(version: String = version) -> URL { cacheRoot.appendingPathComponent(version, isDirectory: true) }

    /// The launcher script inside the copied runtime.
    static func binScript(in runtime: URL) -> URL {
        runtime.appendingPathComponent("dsh/node_modules/@deepseek-ai/dsh/lib/bin.js")
    }

    /// Pure: the arguments of one read-only headless turn.
    static func arguments(script: URL, prompt: String, session: String?) -> [String] {
        var args = [script.path, "--profile", "headless", "--json"]
        if let session { args += ["--session-id", session] }
        return args + ["--", prompt]
    }

    /// Pure: the agent's environment — Node mode, the read-only sandbox.
    static func environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        environment["DSH_PERMISSION_MODE"] = "read-only"
        return environment
    }

    // MARK: The copied runtime

    private static let lock = NSLock()

    /// Copies the runtime out of the app once per version (a few seconds),
    /// then answers at once; older versions' copies are removed.
    static func prepareRuntime() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let app = appURL else { throw AOMAIError(message: "DeepSeek Harness isn't installed (looked for \(bundleID)).") }
        let folder = runtimeFolder()
        let marker = folder.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: marker.path) { return folder }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resources = app.appendingPathComponent("Contents/Resources")
        try extract(asar: resources.appendingPathComponent("app.asar"), unpacked: resources.appendingPathComponent("app.asar.unpacked"),
                    subtree: "dsh", into: folder)
        try Data().write(to: marker)
        for old in (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != folder.lastPathComponent {
            try? FileManager.default.removeItem(at: old)
        }
        return folder
    }

    /// Writes one subtree of an Electron asar archive (header: a pickled
    /// JSON index; file offsets after it), with its unpacked native files.
    static func extract(asar: URL, unpacked: URL, subtree: String, into destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: asar)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 16), prefix.count == 16 else { throw AOMAIError(message: "The DeepSeek Harness archive is unreadable.") }
        func word(_ offset: Int) -> Int { Int(prefix[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
        let headerSize = word(4), jsonSize = word(12)
        guard let json = try handle.read(upToCount: jsonSize), json.count == jsonSize,
              let index = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let files = index["files"] as? [String: Any], let root = files[subtree] as? [String: Any] else {
            throw AOMAIError(message: "DeepSeek Harness's archive has no \(subtree) runtime.")
        }
        let base = UInt64(8 + headerSize)
        let fm = FileManager.default
        func walk(_ node: [String: Any], _ relative: String) throws {
            guard let children = node["files"] as? [String: Any] else { return }
            for (name, value) in children {
                guard let entry = value as? [String: Any], !name.contains("/"), name != "..", name != "." else { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                let target = destination.appendingPathComponent(subtree + "/" + path)
                if entry["files"] != nil {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try walk(entry, path)
                } else if let link = entry["link"] as? String {
                    // asar links are relative to the archive's root.
                    let depth = (subtree + "/" + path).split(separator: "/").count - 1
                    try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: String(repeating: "../", count: depth) + link)
                } else if entry["unpacked"] as? Bool == true {
                    let source = unpacked.appendingPathComponent(subtree + "/" + path)
                    try? fm.removeItem(at: target)
                    try fm.copyItem(at: source, to: target)
                } else {
                    let size = (entry["size"] as? Int) ?? 0
                    let offset = UInt64((entry["offset"] as? String).flatMap { UInt64($0) } ?? 0)
                    try handle.seek(toOffset: base + offset)
                    let data = size > 0 ? (try handle.read(upToCount: size) ?? Data()) : Data()
                    try data.write(to: target)
                    if entry["executable"] as? Bool == true {
                        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                    }
                }
            }
        }
        try fm.createDirectory(at: destination.appendingPathComponent(subtree), withIntermediateDirectories: true)
        try walk(root, "")
    }

    /// ⌘J: the conversation goes on in the DeepSeek Harness app.
    @discardableResult
    static func openApp() -> Bool {
        guard let app = appURL else { return false }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
