import AppKit
import CoreAudio
import Darwin

/// The system's memory pressure (`kern.memorystatus_vm_pressure_level`:
/// 1 normal, 2 warning, 4 critical), the same level Activity Monitor's
/// Memory Pressure graph colours green, yellow and red.
enum FocusMemoryPressure: String, Codable, Equatable {
    case normal, warning, critical, unknown

    init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    init(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) { self = .critical }
        else if event.contains(.warning) { self = .warning }
        else if event.contains(.normal) { self = .normal }
        else { self = .unknown }
    }

    var isHigh: Bool { self == .warning || self == .critical }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    var tone: AOMTone {
        switch self {
        case .normal: return .success
        case .warning: return .warning
        case .critical: return .danger
        case .unknown: return .neutral
        }
    }
}

/// Which processes play or record audio right now, by the owning app's
/// pid (helpers such as WebKit's audio process or Chrome's audio service
/// count for their app, the way the audio mixer attributes them).
struct FocusAudioActivity: Equatable {
    var playing: Set<pid_t> = []
    var recording: Set<pid_t> = []
}

/// Read-only probes of the running system. No probe changes anything.
enum FocusSystemProbes {
    // MARK: Memory

    /// The physical footprint Activity Monitor calls "Memory"
    /// (`proc_pid_rusage`, `ri_phys_footprint`); nil when the process is
    /// gone or not readable.
    static func footprint(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// Every process's parent, from one pass over the process table.
    static func parentMap() -> [pid_t: pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [:] }
        var parents: [pid_t: pid_t] = [:]
        parents.reserveCapacity(Int(filled))
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdshortinfo()
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size {
                parents[pid] = pid_t(info.pbsi_ppid)
            }
        }
        return parents
    }

    /// Which root each process descends from (itself included). Processes
    /// launched by launchd for an app (XPC services such as Safari's web
    /// content) are not its descendants and are not counted.
    static func rootAssignments(roots: Set<pid_t>, parents: [pid_t: pid_t]) -> [pid_t: pid_t] {
        var assigned: [pid_t: pid_t] = [:]
        for root in roots { assigned[root] = root }
        for pid in parents.keys where assigned[pid] == nil {
            var chain: [pid_t] = []
            var current = pid
            var found: pid_t?
            for _ in 0..<24 {
                if let root = assigned[current] { found = root; break }
                chain.append(current)
                guard let parent = parents[current], parent > 1, parent != current else { break }
                current = parent
            }
            if let found { for member in chain { assigned[member] = found } }
        }
        return assigned
    }

    /// Each app's footprint with its child processes (Chrome's renderers,
    /// Electron helpers). Runs on the calling thread: call it off main.
    static func appFootprints(for roots: [pid_t],
                                          parents: [pid_t: pid_t]? = nil,
                                          footprint: (pid_t) -> UInt64? = { FocusSystemProbes.footprint(of: $0) }) -> [pid_t: UInt64] {
        let rootSet = Set(roots.filter { $0 > 0 })
        guard !rootSet.isEmpty else { return [:] }
        let assignment = rootAssignments(roots: rootSet, parents: parents ?? parentMap())
        var totals: [pid_t: UInt64] = [:]
        for (pid, root) in assignment {
            guard let bytes = footprint(pid) else { continue }
            totals[root, default: 0] += bytes
        }
        return totals
    }

    static func memoryPressure() -> FocusMemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        return FocusMemoryPressure(sysctlLevel: level)
    }

    static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    // MARK: Input

    /// Seconds since the last keyboard, pointer or trackpad input.
    static func secondsSinceLastInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: Audio

    /// Before macOS 14.2 Core Audio has no process objects to read.
    static var isAudioCheckUnsupported: Bool {
        if #available(macOS 14.2, *) { return false }
        return true
    }

    /// Apps playing or recording audio, from Core Audio's process objects
    /// (`kAudioProcessPropertyIsRunningOutput` / `…IsRunningInput`) with the
    /// audio mixer's owner resolution. Nil before macOS 14.2, where AOM
    /// cannot tell, so callers must treat every app as possibly playing.
    /// Main thread: the owner cache it shares with `AppAudioEngine` is
    /// main-thread state.
    @MainActor
    static func audioActivity() -> FocusAudioActivity? {
        guard #available(macOS 14.2, *) else { return nil }
        var activity = FocusAudioActivity()
        for (owner, objects) in AppAudioEngine.processObjectsByOwner() {
            for object in objects {
                if uint32(object, kAudioProcessPropertyIsRunningOutput) == 1 { activity.playing.insert(owner) }
                if uint32(object, kAudioProcessPropertyIsRunningInput) == 1 { activity.recording.insert(owner) }
            }
        }
        return activity
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// "412 MB", "1.2 GB" (memory, base 1024 like Activity Monitor); "0 MB" for nothing.
enum FocusByteFormat {
    static func string(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}
