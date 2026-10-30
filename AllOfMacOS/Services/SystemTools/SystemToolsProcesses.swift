import AppKit

/// Top processes (Activity Monitor's CPU and Memory tabs, from `ps`), Login
/// Items as far as a normal app can read them, and app relaunching.
enum ProcessTools {
    struct Sample: Equatable, Identifiable {
        var id: pid_t { pid }
        let pid: pid_t
        let cpu: Double
        /// Resident memory in bytes (`ps` reports kilobytes).
        let memory: Int64
        let uid: uid_t
        let name: String
    }

    enum Order { case cpu, memory }

    /// Every process, with its short command name last because it may
    /// contain spaces ("Google Chrome Helper (Renderer)").
    static let psArguments = ["-Aceo", "pid=,pcpu=,rss=,uid=,comm="]

    static func parsePS(_ text: String) -> [Sample] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = pid_t(fields[0]), let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int64(fields[2]), let uid = uid_t(fields[3]) else { return nil }
            return Sample(pid: pid, cpu: cpu, memory: rss * 1024, uid: uid, name: String(fields[4]).trimmingCharacters(in: .whitespaces))
        }
    }

    static func top(_ samples: [Sample], by order: Order, limit: Int = 15) -> [Sample] {
        Array(samples.sorted {
            switch order {
            case .cpu: return $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory
            case .memory: return $0.memory != $1.memory ? $0.memory > $1.memory : $0.cpu > $1.cpu
            }
        }.prefix(limit))
    }

    static func detail(_ sample: Sample, ownUID: uid_t = getuid()) -> String {
        let owner = sample.uid == ownUID ? "you" : (sample.uid == 0 ? "root (can't quit)" : "another user (can't quit)")
        return String(format: "PID %d · CPU %.1f%% · ", sample.pid, sample.cpu) + SystemStatus.memorySize(UInt64(max(0, sample.memory))) + " · \(owner)"
    }

    static func samples() throws -> [Sample] {
        let output = try SystemToolsCommand.runChecked("/bin/ps", psArguments)
        return parsePS(output.stdout)
    }

    // MARK: Login items

    struct LoginItem: Equatable, Identifiable {
        var id: String { "\(kind)|\(name)" }
        let name: String
        let kind: String
    }

    /// Launch agent and daemon labels from plist file names in a folder.
    static func launchItemNames(_ fileNames: [String]) -> [String] {
        fileNames.filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }.map { String($0.dropLast(6)) }.sorted()
    }

    /// The "Open at Login" list through System Events (needs Automation for
    /// System Events, which AOM already asks for), plus launch agents and
    /// daemons by file name. Apps that register background items with
    /// SMAppService are listed only in System Settings, which is why the
    /// sheet links there.
    static func loginItems(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (items: [LoginItem], systemEventsFailed: Bool) {
        var items: [LoginItem] = []
        let script = #"tell application "System Events" to get the name of every login item"#
        let output = try? SystemToolsCommand.run("/usr/bin/osascript", ["-e", script])
        let failed = output?.succeeded != true
        if let output, output.succeeded {
            items += output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { LoginItem(name: $0, kind: "Opens at login") }
        }
        let folders: [(URL, String)] = [(home.appendingPathComponent("Library/LaunchAgents"), "Your launch agent"),
                                        (URL(fileURLWithPath: "/Library/LaunchAgents"), "Launch agent (all users)"),
                                        (URL(fileURLWithPath: "/Library/LaunchDaemons"), "Launch daemon (system)")]
        for (folder, kind) in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            items += launchItemNames(names).map { LoginItem(name: $0, kind: kind) }
        }
        return (items, failed)
    }

    // MARK: Apps

    /// Regular (Dock) apps other than AOM and Finder, by name.
    static func regularApps(excludingFinder: Bool = true) -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != own
                && !(excludingFinder && $0.bundleIdentifier == "com.apple.finder")
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }
}
