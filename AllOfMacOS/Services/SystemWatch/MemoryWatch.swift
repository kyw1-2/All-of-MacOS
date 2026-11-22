import AppKit
import Darwin

/// 7.4 (Stats, iStat Menus): checks memory pressure and swap every 30 s
/// and posts one notification when either crosses its line, naming the
/// apps that use the most (helpers counted with their app). The same kind
/// of alert waits 30 minutes before it is posted again.
@MainActor
final class MemoryWatch {
    static let shared = MemoryWatch()

    static let swapLimitKey = "AOMMemoryWatch.swapGB"
    static var swapLimitGB: Double {
        get { UserDefaults.standard.object(forKey: swapLimitKey) as? Double ?? 8 }
        set { UserDefaults.standard.set(min(256, max(1, newValue)), forKey: swapLimitKey) }
    }

    enum Alert: Equatable { case pressure(Int), swap(UInt64) }

    private var timer: Timer?
    private var lastPosted: [String: Date] = [:]
    private var checking = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
    }

    /// 7.6 (Codex MW01): a check that finishes after Stop posts nothing.
    private var generation = 0

    /// Pure: what to alert about. Pressure 2 is Warning, 4 Critical.
    nonisolated static func alerts(pressureLevel: Int?, swapUsed: UInt64?, swapLimit: UInt64) -> [Alert] {
        var out: [Alert] = []
        if let level = pressureLevel, level >= 2 { out.append(.pressure(level)) }
        if let swap = swapUsed, swap >= swapLimit { out.append(.swap(swap)) }
        return out
    }

    /// Pure: an alert of the same kind posts again only after `interval`.
    nonisolated static func shouldPost(_ key: String, now: Date, last: [String: Date], interval: TimeInterval = 1_800) -> Bool {
        guard let previous = last[key] else { return true }
        return now.timeIntervalSince(previous) >= interval
    }

    private func check() {
        guard !checking else { return }
        checking = true
        let limit = UInt64(Self.swapLimitGB * 1_073_741_824)
        let generation = generation
        // Which kinds may post now is decided first, so a quiet period reads no app list.
        let now = Date()
        let mayPost = (pressure: Self.shouldPost("pressure", now: now, last: lastPosted), swap: Self.shouldPost("swap", now: now, last: lastPosted))
        Task.detached(priority: .utility) {
            let memory = SystemStatus.memory()
            let swap = Self.swapUsed()
            let alerts = Self.alerts(pressureLevel: memory?.pressureLevel, swapUsed: swap, swapLimit: limit).filter {
                switch $0 { case .pressure: return mayPost.pressure; case .swap: return mayPost.swap }
            }
            let top = alerts.isEmpty ? [] : Self.topApps(3)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checking = false
                guard generation == self.generation, self.timer != nil else { return }
                self.post(alerts, top: top, pressure: memory?.pressure)
            }
        }
    }

    private func post(_ alerts: [Alert], top: [(name: String, bytes: UInt64)], pressure: String?) {
        let now = Date()
        let due = alerts.filter {
            switch $0 {
            case .pressure: return Self.shouldPost("pressure", now: now, last: lastPosted)
            case .swap: return Self.shouldPost("swap", now: now, last: lastPosted)
            }
        }
        guard !due.isEmpty else { return }
        var lines: [String] = []
        for alert in due {
            switch alert {
            case .pressure:
                lastPosted["pressure"] = now
                lines.append("Memory pressure: \(pressure ?? "Warning")")
            case .swap(let bytes):
                lastPosted["swap"] = now
                lines.append("Swap used: \(SystemStatus.memorySize(bytes))")
            }
        }
        if !top.isEmpty {
            lines.append("Using most: " + top.map { "\($0.name) \(SystemStatus.memorySize($0.bytes))" }.joined(separator: ", "))
        }
        ExtendedActions.notify(title: "Memory Is Running Low", body: lines.joined(separator: "\n")) { _ in }
    }

    // MARK: Readings

    /// vm.swapusage's used bytes.
    nonisolated static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// Pure: "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper" →
    /// "/Applications/Google Chrome.app" (the outermost bundle); nil outside one.
    nonisolated static func appBundle(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Pure: what a process counts toward — its outermost app bundle (the
    /// first ".app/", so a nested helper app joins it), else its executable
    /// name ("swift-frontend", "node", "ollama").
    nonisolated static func group(of path: String) -> String {
        appBundle(of: path) ?? (path as NSString).lastPathComponent
    }

    /// The apps and tools with the largest footprint, helper processes included.
    nonisolated static func topApps(_ count: Int) -> [(name: String, bytes: UInt64)] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let listed = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var totals: [String: UInt64] = [:]
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(max(0, listed)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            guard let bytes = FocusSystemProbes.footprint(of: pid) else { continue }
            totals[group(of: path), default: 0] += bytes
        }
        return totals.sorted { $0.value > $1.value }.prefix(count).map { entry in
            guard entry.key.hasSuffix(".app") else { return (entry.key, entry.value) }
            let name = (FileManager.default.displayName(atPath: entry.key) as NSString).deletingPathExtension
            return (name, entry.value)
        }
    }
}
