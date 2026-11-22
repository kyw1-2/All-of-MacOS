import AppKit
import Darwin

// AOM 7.11 (spec §1, Raycast's Kill Process): every process the user can end
// — Dock apps, menu bar apps, app helpers, children and CLI tools started in
// a terminal — found by name or PID, one row per instance, and force quit
// with one Return. A row is one instance: its PID and its start time. That
// pair is checked again right before the signal, so a row whose process ended
// and whose PID was reused never kills the newcomer.

enum PaletteProcesses {
    enum Kind: Equatable {
        case app, menuBarApp, helper, process
        var label: String {
            switch self {
            case .app: return "App"
            case .menuBarApp: return "Menu bar app"
            case .helper: return "Helper"
            case .process: return "Process"
            }
        }
    }

    struct Entry: Equatable, Identifiable {
        let pid: pid_t
        let name: String
        let path: String?
        /// Start time in microseconds since 1970: with the PID, this instance.
        let started: UInt64
        let kind: Kind
        /// The app a helper lives in, or the app a command-line process runs under.
        let owner: String?
        let bundleID: String?
        let memory: UInt64?
        let isProtected: Bool
        var id: String { "proc.\(pid).\(started)" }
    }

    /// What NSWorkspace knows of a running app (read on the main thread).
    struct AppInfo: Sendable {
        let name: String
        let bundleID: String?
        let bundlePath: String?
        let policy: NSApplication.ActivationPolicy
    }

    struct BSD: Equatable {
        let ppid: pid_t
        let uid: uid_t
        let name: String
        let started: UInt64
        let zombie: Bool
    }

    /// The kernel's record of a process (no permission needed for one's own).
    static func bsd(_ pid: pid_t) -> BSD? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        let comm = withUnsafeBytes(of: info.pbi_comm) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return BSD(ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid, name: name.isEmpty ? comm : name,
                   started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, zombie: info.pbi_status == 5 /* SZOMB */)
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    /// Processes that keep the session itself running: ending them logs out
    /// or blanks the screen. AOM's own process and its helpers too.
    static let protectedNames: Set<String> = [
        "loginwindow", "WindowServer", "Dock", "Finder", "SystemUIServer", "ControlCenter", "WindowManager",
        "NotificationCenter", "MenuBarAgent", "launchd", "TextInputMenuAgent", "universalaccessd",
    ]

    /// Pure: the outermost app bundle a path lives in ("Google Chrome" for a
    /// renderer helper), or nil outside any .app.
    static func outerApp(of path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound])
        return (bundle as NSString).lastPathComponent
    }

    /// Pure: the row's kind from what is known of it.
    static func kind(app: AppInfo?, path: String?) -> Kind {
        if let app {
            switch app.policy {
            case .regular: return .app
            case .accessory: return .menuBarApp
            default: return .helper
            }
        }
        return path?.contains(".app/") == true ? .helper : .process
    }

    /// Pure (search): name, PID and where it comes from, for `PaletteSearch`.
    static func keywords(_ entry: Entry) -> String {
        [String(entry.pid), entry.owner, entry.bundleID, entry.path, entry.kind.label].compactMap { $0 }.joined(separator: " ")
    }

    /// Pure: largest first, then by name and PID; the protected ones last.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        let rank: (Entry, Entry) -> Bool = { lhs, rhs in
            let left = lhs.memory ?? 0, right = rhs.memory ?? 0
            if left != right { return left > right }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            return byName == .orderedSame ? lhs.pid < rhs.pid : byName == .orderedAscending
        }
        return entries.filter { !$0.isProtected }.sorted(by: rank) + entries.filter(\.isProtected).sorted(by: rank)
    }

    /// Every process of this user, read off the main thread. `apps` comes
    /// from NSWorkspace on the main thread.
    static func snapshot(apps: [pid_t: AppInfo], ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                         ownBundle: String = Bundle.main.bundlePath) -> [Entry] {
        let uid = getuid()
        var infos: [pid_t: BSD] = [:]
        for pid in allPIDs() where pid > 1 {
            if let info = bsd(pid), info.uid == uid, !info.zombie { infos[pid] = info }
        }
        func ownerApp(of pid: pid_t) -> String? {
            var current = infos[pid]?.ppid ?? 0
            for _ in 0..<8 where current > 1 {
                if let app = apps[current] { return app.name }
                current = infos[current]?.ppid ?? 0
            }
            return nil
        }
        return ordered(infos.map { pid, info in
            let path = path(pid)
            let app = apps[pid]
            let kind = kind(app: app, path: path)
            let name = app?.name ?? (info.name.isEmpty ? (path.map { ($0 as NSString).lastPathComponent } ?? "PID \(pid)") : info.name)
            let owner: String? = {
                switch kind {
                case .app, .menuBarApp: return nil
                case .helper: return outerApp(of: path) ?? ownerApp(of: pid)
                case .process: return ownerApp(of: pid)
                }
            }()
            let inAOM = path?.hasPrefix(ownBundle + "/") ?? false
            let protected = pid == ownPID || inAOM || protectedNames.contains(name)
                || (path.map { protectedNames.contains(($0 as NSString).lastPathComponent) } ?? false)
                || PaletteAppControl.isProtected(app?.bundleID)
            return Entry(pid: pid, name: name, path: path, started: info.started, kind: kind, owner: owner,
                         bundleID: app?.bundleID, memory: PaletteKillApps.memoryFootprint(pid), isProtected: protected)
        })
    }

    @MainActor
    static func runningApps() -> [pid_t: AppInfo] {
        var out: [pid_t: AppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            let path = app.bundleURL?.standardizedFileURL.path
            out[app.processIdentifier] = AppInfo(name: app.localizedName ?? path.map { ($0 as NSString).lastPathComponent } ?? "PID \(app.processIdentifier)",
                                                 bundleID: app.bundleIdentifier, bundlePath: path,
                                                 policy: app.activationPolicy)
        }
        return out
    }

    // MARK: Ending one instance

    enum Outcome: Equatable {
        /// SIGKILL delivered; whether it ended is checked after.
        case sent
        case alreadyGone
        /// Another process now has this PID (the row's one ended).
        case changed
        case notPermitted
        case protected
    }

    /// Pure: what to make of the instance check and the signal's result.
    static func outcome(current: BSD?, expectedStart: UInt64, signalErrno: Int32?) -> Outcome {
        guard let current, !current.zombie else { return .alreadyGone }
        guard current.started == expectedStart else { return .changed }
        guard let signalErrno else { return .sent }
        switch signalErrno {
        case ESRCH: return .alreadyGone
        case EPERM: return .notPermitted
        default: return .notPermitted
        }
    }

    /// Checks the instance, then sends SIGKILL to that one process only.
    static func forceQuit(_ entry: Entry) -> Outcome {
        guard !entry.isProtected else { return .protected }
        let current = bsd(entry.pid)
        let check = outcome(current: current, expectedStart: entry.started, signalErrno: nil)
        guard check == .sent else { return check }
        guard current?.uid == getuid() else { return .notPermitted }
        if Darwin.kill(entry.pid, SIGKILL) == 0 { return .sent }
        return outcome(current: current, expectedStart: entry.started, signalErrno: errno)
    }

    /// Whether that instance is still alive (a zombie counts as ended).
    static func isAlive(_ entry: Entry) -> Bool {
        guard let info = bsd(entry.pid) else { return false }
        return !info.zombie && info.started == entry.started
    }
}
