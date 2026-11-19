import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

/// BetterTouchTool-style conditions on a Conditional Activation Group, on top
/// of its app scope. Every condition that is set must hold (AND); a group
/// whose conditions fail is inactive, so its triggers do not fire and it
/// does not suppress global triggers. Stored optionally on the group, so
/// presets without conditions decode and behave exactly as before.
struct ActivationConditions: Codable, Hashable {
    /// Local days and times (reuses the timer trigger's window rules).
    var timeWindow: TriggerTimeWindow?
    /// "ac" or "battery".
    var powerSource: String?
    var minimumDisplayCount: Int?
    var maximumDisplayCount: Int?
    /// Active only while this app has a window on screen.
    var requiresWindowOfBundleID: String?

    var isEmpty: Bool {
        timeWindow == nil && (powerSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && minimumDisplayCount == nil
            && maximumDisplayCount == nil && (requiresWindowOfBundleID ?? "").isEmpty
    }

    /// A point-in-time view of what the conditions read.
    struct Snapshot {
        var date: Date
        var powerSource: String?
        var displayCount: Int
        /// Bundle IDs that own an on-screen window; nil when not collected.
        var bundleIDsWithWindows: Set<String>?
    }

    func isSatisfied(by snapshot: Snapshot, calendar: Calendar = .current) -> Bool {
        if let timeWindow, !timeWindow.contains(snapshot.date, calendar: calendar) { return false }
        if let powerSource, !powerSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, snapshot.powerSource != powerSource { return false }
        if let minimumDisplayCount, snapshot.displayCount < minimumDisplayCount { return false }
        if let maximumDisplayCount, snapshot.displayCount > maximumDisplayCount { return false }
        if let bundle = requiresWindowOfBundleID, !bundle.isEmpty,
           !(snapshot.bundleIDsWithWindows ?? []).contains(bundle) { return false }
        return true
    }

    /// Human summary for lists ("Weekdays 9:00–18:00 · On battery · 2+ displays").
    var summary: String {
        var parts: [String] = []
        if let window = timeWindow {
            let days = window.weekdays.filter { (1...7).contains($0) }.sorted()
            let dayText = days == [2, 3, 4, 5, 6] ? "Weekdays" : days == [1, 7] ? "Weekends"
                : days.count == 7 ? "Every day" : days.map { Calendar.current.shortWeekdaySymbols[($0 - 1) % 7] }.joined(separator: ", ")
            parts.append("\(dayText) \(Self.time(window.startMinute))–\(Self.time(window.endMinute))")
        }
        if let powerSource, !powerSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(powerSource == "battery" ? "On battery" : "On power adapter") }
        switch (minimumDisplayCount, maximumDisplayCount) {
        case let (min?, max?) where min == max: parts.append("\(min) display\(min == 1 ? "" : "s")")
        case let (min?, max?): parts.append("\(min)–\(max) displays")
        case let (min?, nil): parts.append("\(min)+ displays")
        case let (nil, max?): parts.append("Up to \(max) display\(max == 1 ? "" : "s")")
        default: break
        }
        if let bundle = requiresWindowOfBundleID, !bundle.isEmpty {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
            parts.append("While \(name) has a window")
        }
        return parts.joined(separator: " · ")
    }

    static func time(_ minute: Int) -> String { String(format: "%d:%02d", minute / 60, minute % 60) }
}

/// The live snapshot, cached for a second: groups are evaluated on every
/// gesture and key event, and the power/window queries need not run that often.
enum ActivationConditionsContext {
    private static let lock = NSLock()
    private static var cached: (time: TimeInterval, value: ActivationConditions.Snapshot)?
    private static var refreshing = false
    private static let refreshQueue = DispatchQueue(label: "com.kyw.allofmacos.activation-context", qos: .utility)

    /// What a call may answer from the cache (pure, for tests): fresh within
    /// a second; older than that but under `staleLimit`, answered at once
    /// while a background read replaces it (6.5: the power and window
    /// queries ran on the event tap's thread every second of typing).
    enum CacheUse: Equatable { case fresh, stale, miss }
    static let staleLimit: TimeInterval = 10
    static func cacheUse(age: TimeInterval?, hasWindows: Bool, needsWindows: Bool) -> CacheUse {
        guard let age, !needsWindows || hasWindows else { return .miss }
        if age < 1 { return .fresh }
        return age < staleLimit ? .stale : .miss
    }

    static func current(needsWindows: Bool) -> ActivationConditions.Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let use = cacheUse(age: cached.map { now - $0.time }, hasWindows: cached?.value.bundleIDsWithWindows != nil,
                           needsWindows: needsWindows)
        if use != .miss, var value = cached?.value {
            value.date = Date()
            let refresh = use == .stale && !refreshing
            if refresh { refreshing = true }
            lock.unlock()
            if refresh {
                let windows = value.bundleIDsWithWindows != nil
                refreshQueue.async {
                    let fresh = read(needsWindows: windows)
                    lock.lock(); cached = (ProcessInfo.processInfo.systemUptime, fresh); refreshing = false; lock.unlock()
                }
            }
            return value
        }
        lock.unlock()
        let snapshot = read(needsWindows: needsWindows)
        lock.lock()
        cached = (now, snapshot)
        lock.unlock()
        return snapshot
    }

    private static func read(needsWindows: Bool) -> ActivationConditions.Snapshot {
        var displays: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displays)
        var snapshot = ActivationConditions.Snapshot(date: Date(), powerSource: powerSource(),
                                                     displayCount: Int(displays), bundleIDsWithWindows: nil)
        if needsWindows { snapshot.bundleIDsWithWindows = windowOwners() }
        return snapshot
    }

    private static func powerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPSACPowerValue ? "ac" : type == kIOPSBatteryPowerValue ? "battery" : nil
    }

    private static func windowOwners() -> Set<String> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let pids = Set(info.compactMap { window -> pid_t? in
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return window[kCGWindowOwnerPID as String] as? pid_t
        })
        return Set(pids.compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
    }
}
