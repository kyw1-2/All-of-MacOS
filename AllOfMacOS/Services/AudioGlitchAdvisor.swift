import AppKit
import Foundation

// AOM 7.12: what to do about HomePod crackle that isn't AOM's.
//
// Measured on this MacBook Air (8 GB) on 2026-11-23, Chrome → HomePod over
// the direct path: 7 overloads in 6 minutes, each a HAL cycle that came
// 5–12 ms late (the AirPlay device runs a fixed 128-frame, 2.7 ms cycle),
// every one with "memory warn" and 7.2–7.6 GB of swap. AOM's own render
// took 30 µs on average. AirPlayXPCHelper reported 0 transmit-buffer
// errors, so the network side was fine; one app (Ulanzi Studio, 44 h up)
// held 2.27 GB of dirty malloc memory. Community and vendor notes agree:
// AirPlay drops on Macs come from Wi-Fi (channel, AWDL, power saving) or
// from the Mac being overloaded (Rogue Amoeba, Apple Community, FineTune's
// guide); macOS's AirPlay device ignores a larger IO buffer (measured since
// 3.3.2), so the lever left is the memory the stall waits for.
//
// So AOM now (1) counts the overloads of the last 30 minutes with the
// memory state each one was recorded under, (2) names the apps using the
// most memory, flagging one that has grown far past normal, and (3) offers
// to quit and reopen it. A burst of overloads during memory pressure posts
// one notification an hour while a HomePod is playing.
enum AudioGlitchAdvisor {
    /// What the recent overloads were recorded under.
    struct Recent: Equatable {
        var overloads = 0
        var underMemoryPressure = 0
        var whileHot = 0
        var swapRange: ClosedRange<Double>?

        var mostlyMemory: Bool { overloads > 0 && underMemoryPressure * 2 >= overloads }
    }

    /// Pure: the overload events of the last `window` seconds, read from
    /// their details ("… · memory warn · swap 7.2 GB · thermal nominal").
    static func recent(_ events: [(time: Date, detail: String)], now: Date, window: TimeInterval = 1_800) -> Recent {
        var result = Recent()
        var swaps: [Double] = []
        for event in events where now.timeIntervalSince(event.time) <= window && event.time <= now {
            result.overloads += 1
            if event.detail.contains("memory warn") || event.detail.contains("memory critical") { result.underMemoryPressure += 1 }
            if event.detail.contains("thermal serious") || event.detail.contains("thermal critical") { result.whileHot += 1 }
            if let range = event.detail.range(of: #"swap ([0-9.]+) GB"#, options: .regularExpression) {
                let number = event.detail[range].dropFirst(5).dropLast(3)
                if let value = Double(number) { swaps.append(value) }
            }
        }
        if let low = swaps.min(), let high = swaps.max() { result.swapRange = low...high }
        return result
    }

    static func recentOverloads(now: Date = Date()) -> Recent {
        let events = AudioEventLog.shared.snapshot().events.filter { $0.kind == .overload }.map { (time: $0.time, detail: $0.detail) }
        return recent(events, now: now)
    }

    /// Pure: an app using at least a fifth of the Mac's memory, or 2 GB,
    /// is called out by name — far past what a deck or menu bar app needs.
    /// Browsers are left out: they grow with their tabs and are usually
    /// what's playing to the HomePod.
    static func runaway(_ top: [(name: String, bytes: UInt64)], physical: UInt64) -> (name: String, bytes: UInt64)? {
        let browsers: Set<String> = ["Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge", "Brave Browser", "Vivaldi", "Opera", "Whale"]
        let limit = min(UInt64(2) << 30, physical / 5)
        return top.first { !browsers.contains($0.name) && $0.bytes >= limit }
    }

    /// One paragraph for the check: counts, then what to do.
    static func report(recent: Recent, causes: [AudioSystemLoad.Cause], top: [(name: String, bytes: UInt64)], physical: UInt64) -> (title: String, detail: String) {
        var lines: [String] = []
        if recent.overloads > 0 {
            var line = "In the last 30 minutes the HomePod's audio missed \(recent.overloads) deadline\(recent.overloads == 1 ? "" : "s")"
            if recent.underMemoryPressure > 0 {
                line += ", \(recent.underMemoryPressure) of them while memory was short"
                if let swap = recent.swapRange { line += String(format: " (%.1f–%.1f GB swapped)", swap.lowerBound, swap.upperBound) }
            }
            lines.append(line + ".")
        }
        if !top.isEmpty {
            lines.append("Using the most memory: " + top.map { "\($0.name) \(SystemStatus.memorySize($0.bytes))" }.joined(separator: ", ") + ".")
        }
        if let app = runaway(top, physical: physical) {
            lines.append("\(app.name) is far above normal for one app; quitting and reopening it gives that memory back.")
        }
        let title: String
        if recent.mostlyMemory || causes.contains(where: { if case .memory = $0 { return true }; return false }) {
            title = "HomePod crackle: the Mac is short of memory"
        } else if recent.whileHot > 0 || causes.contains(where: { if case .heat = $0 { return true }; return false }) {
            title = "HomePod crackle: the Mac is slowing down to cool"
        } else if recent.overloads > 0 {
            title = "HomePod crackle: memory and heat were fine"
            lines.append("Then Wi-Fi is the usual cause: stay on 5 GHz, near the router, and keep AirDrop's window closed while playing. Reconnect App Audio restarts AOM's stream.")
        } else {
            title = "No HomePod glitch in the last 30 minutes"
        }
        if lines.isEmpty { lines.append("Memory and temperature are fine. If it still crackles, try Reconnect App Audio.") }
        return (title, lines.joined(separator: " "))
    }

    // MARK: Check (⌘K "Check HomePod Audio")

    @MainActor
    static func check() {
        let causes = AudioSystemLoad.current()
        let recent = recentOverloads()
        let physical = ProcessInfo.processInfo.physicalMemory
        Task.detached(priority: .userInitiated) {
            let top = MemoryWatch.topApps(3)
            await MainActor.run {
                let report = report(recent: recent, causes: causes, top: top, physical: physical)
                guard let app = runaway(top, physical: physical), let running = runningApp(named: app.name) else {
                    GestureHUD.shared.show(title: report.title, detail: report.detail)
                    return
                }
                let alert = NSAlert()
                alert.messageText = report.title
                alert.informativeText = report.detail
                alert.addButton(withTitle: "Quit and Reopen \(app.name)")
                alert.addButton(withTitle: "Not Now")
                AOMOverlayActivation.activateForOverlay()
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                relaunch(running)
            }
        }
    }

    @MainActor
    static func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let url = app.bundleURL, app.processIdentifier != getpid() else { return false }
            return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension == name
        }
    }

    /// Asks the app to quit (so it can save), waits up to 10 s, then opens it again.
    @MainActor
    static func relaunch(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
        guard app.terminate() else {
            GestureHUD.shared.show(title: "\(name) Didn't Quit", detail: "Quit it yourself, then open it again.")
            return
        }
        Task { @MainActor in
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
            guard app.isTerminated else {
                GestureHUD.shared.show(title: "\(name) Is Still Running", detail: "It may be asking to save something.")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    GestureHUD.shared.show(title: error == nil ? "Reopened \(name)" : "\(name) Quit",
                                           detail: error == nil ? "Its memory is free again." : "Open it again when you need it.")
                }
            }
        }
    }

    // MARK: Burst notice

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stamps: [Date] = []
    nonisolated(unsafe) private static var lastNotice: Date?

    /// Pure: three overloads within ten minutes, under memory pressure, and
    /// no notice in the last hour.
    static func shouldNotify(stamps: [Date], now: Date, underPressure: Bool, lastNotice: Date?) -> Bool {
        guard underPressure, stamps.filter({ now.timeIntervalSince($0) <= 600 }).count >= 3 else { return false }
        return lastNotice.map { now.timeIntervalSince($0) >= 3_600 } ?? true
    }

    /// From the direct stream's overload listener (its own queue, never the IO thread).
    static func noteOverload(detail: String, now: Date = Date()) {
        guard UserDefaults.standard.object(forKey: "AOMAudioGlitchNotice") as? Bool ?? true else { return }
        let underPressure = detail.contains("memory warn") || detail.contains("memory critical")
        lock.lock()
        stamps.append(now)
        stamps.removeAll { now.timeIntervalSince($0) > 600 }
        let notify = shouldNotify(stamps: stamps, now: now, underPressure: underPressure, lastNotice: lastNotice)
        if notify { lastNotice = now }
        let count = stamps.count
        lock.unlock()
        guard notify else { return }
        DispatchQueue.global(qos: .utility).async {
            let top = MemoryWatch.topApps(2)
            let names = top.map { "\($0.name) \(SystemStatus.memorySize($0.bytes))" }.joined(separator: ", ")
            let body = "\(count) dropouts in 10 minutes while memory is short. Using the most: \(names). ⌘K › Check HomePod Audio can reopen the biggest one."
            ExtendedActions.notify(title: "HomePod audio is breaking up", body: body) { _ in }
        }
    }
}
