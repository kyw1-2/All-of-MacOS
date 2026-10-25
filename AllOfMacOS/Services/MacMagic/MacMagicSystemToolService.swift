import Foundation
import AppKit

/// System maintenance and file utility suite replicating MacMagic 2.0 features inside AOM.
final class MacMagicSystemToolService {
    static let shared = MacMagicSystemToolService()

    struct LockingProcess: Identifiable, Equatable {
        var id: String { "\(pid):\(command)" }
        let command: String
        let pid: pid_t
        let user: String
        let fileDescriptor: String
    }

    init() {}

    // MARK: - Finder Tweaks

    /// Toggles visibility of hidden files in Finder and restarts Finder to apply.
    @discardableResult
    func toggleHiddenFiles() async -> Bool {
        let suite = "com.apple.finder"
        let key = "AppleShowAllFiles"
        let current = UserDefaults(suiteName: suite)?.bool(forKey: key) ?? false
        let next = !current
        UserDefaults(suiteName: suite)?.set(next, forKey: key)
        
        // Sync using defaults CLI for cross-process visibility
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", next ? "true" : "false"]
        try? process.run()
        process.waitUntilExit()

        await restartFinder()
        return next
    }

    /// Toggles desktop icons on macOS and restarts Finder.
    @discardableResult
    func toggleDesktopIcons() async -> Bool {
        let suite = "com.apple.finder"
        let key = "CreateDesktop"
        let current = UserDefaults(suiteName: suite)?.bool(forKey: key) ?? true
        let next = !current
        UserDefaults(suiteName: suite)?.set(next, forKey: key)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", next ? "true" : "false"]
        try? process.run()
        process.waitUntilExit()

        await restartFinder()
        return next
    }

    /// Restarts the Finder process cleanly.
    func restartFinder() async {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.finder" }
        for app in apps {
            app.terminate()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        // If Finder does not auto-relaunch immediately, open it
        if NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == "com.apple.finder" }).isEmpty {
            NSWorkspace.shared.launchApplication(
                withBundleIdentifier: "com.apple.finder",
                options: [],
                additionalEventParamDescriptor: nil,
                launchIdentifier: nil
            )
        }
    }

    // MARK: - System Network & DNS

    /// Flushes macOS local DNS resolver cache and sends HUP to mDNSResponder.
    func flushDNSCache() async throws {
        let dscache = Process()
        dscache.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        dscache.arguments = ["-flushcache"]
        try dscache.run()
        dscache.waitUntilExit()

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-HUP", "mDNSResponder"]
        try kill.run()
        kill.waitUntilExit()
    }

    // MARK: - File Maintenance & Attributes

    /// Recursively erases all .DS_Store files within a given directory URL.
    func eraseDSStoreFiles(in directory: URL) async throws -> Int {
        let fileManager = FileManager.default
        var deletedCount = 0

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == ".DS_Store" {
                do {
                    try fileManager.removeItem(at: fileURL)
                    deletedCount += 1
                } catch {
                    continue
                }
            }
        }
        return deletedCount
    }

    /// Identifies all processes currently locking or holding open file descriptors for a target path.
    func findProcessesLockingFile(at url: URL) async throws -> [LockingProcess] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [url.path]
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var results: [LockingProcess] = []

        let lines = output.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        // Skip header line
        for line in lines.dropFirst() {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 4, let pid = pid_t(tokens[1]) else { continue }
            results.append(LockingProcess(
                command: tokens[0],
                pid: pid,
                user: tokens[2],
                fileDescriptor: tokens[3]
            ))
        }
        return results
    }

    /// Sets or clears the Darwin immutable flag (UF_IMMUTABLE / uchg).
    func setFileLocked(url: URL, locked: Bool) throws {
        let path = url.path
        let flags: UInt32 = locked ? UInt32(UF_IMMUTABLE) : 0
        if chflags(path, flags) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to update file lock attribute."])
        }
    }

    /// Sets or clears the Darwin hidden flag (UF_HIDDEN / hidden).
    func setFileHidden(url: URL, hidden: Bool) throws {
        let path = url.path
        let flags: UInt32 = hidden ? UInt32(UF_HIDDEN) : 0
        if chflags(path, flags) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to update file hidden attribute."])
        }
    }

    /// Empties the user Trash directory.
    func forceEmptyTrash() async throws {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let items = try FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
