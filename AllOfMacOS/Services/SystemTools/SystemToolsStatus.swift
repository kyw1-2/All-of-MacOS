import Foundation
import IOKit
import IOKit.ps
import Darwin

/// The figures in the System Tools status strip (Stats / iStat Menus style).
/// Readers use public APIs only: Mach host statistics, sysctl, IOKit's
/// battery registry entry, URL volume resource values and getifaddrs.
/// Parsing and formatting are pure and unit tested.
enum SystemStatus {
    // MARK: CPU

    /// Cumulative CPU ticks (user, system, idle, nice) from HOST_CPU_LOAD_INFO.
    struct CPUTicks: Equatable {
        var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
        var busy: UInt64 { user + system + nice }
        var total: UInt64 { busy + idle }
    }

    /// Percentage busy between two samples; nil when no time passed or the
    /// counters went backwards (they wrap at 32 bits).
    static func cpuUsage(from old: CPUTicks, to new: CPUTicks) -> Double? {
        guard new.total > old.total, new.busy >= old.busy else { return nil }
        return Double(new.busy - old.busy) / Double(new.total - old.total) * 100
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
    }

    // MARK: Memory

    struct Memory: Equatable {
        let used: UInt64
        let total: UInt64
        /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
        let pressureLevel: Int?

        var pressure: String {
            switch pressureLevel {
            case 1: return "Normal"
            case 2: return "Warning"
            case 4: return "Critical"
            default: return "Unknown"
            }
        }
    }

    /// "Memory Used" the way Activity Monitor adds it up: app memory
    /// (anonymous minus purgeable) plus wired plus compressed.
    static func memoryUsed(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                           compressedPages: UInt64, pageSize: UInt64) -> UInt64 {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (app + wiredPages + compressedPages) * pageSize
    }

    static func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let used = memoryUsed(internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
                              wiredPages: UInt64(stats.wire_count), compressedPages: UInt64(stats.compressor_page_count),
                              pageSize: UInt64(pageSize))
        return Memory(used: used, total: ProcessInfo.processInfo.physicalMemory, pressureLevel: sysctlInt("kern.memorystatus_vm_pressure_level"))
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    // MARK: Disk

    struct Disk: Equatable { let available: Int64; let total: Int64 }

    static func startupDisk() -> Disk? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return Disk(available: available, total: Int64(total))
    }

    // MARK: Battery

    struct Battery: Equatable {
        /// Charge, 0–100.
        let percent: Int
        let isCharging: Bool
        let onPower: Bool
        let cycleCount: Int?
        /// Full-charge capacity against design capacity, 0–100+.
        let healthPercent: Int?
        /// Minutes, when macOS has an estimate.
        let minutesRemaining: Int?

        var state: String {
            if isCharging { return "Charging" }
            if onPower { return "On power" }
            return "On battery"
        }
    }

    /// Reads the AppleSmartBattery registry properties (the same dictionary
    /// `ioreg -rn AppleSmartBattery` prints). Apple silicon reports
    /// CurrentCapacity/MaxCapacity as percentages and the mAh figures under
    /// AppleRaw* (inside BatteryData on macOS 27); Intel Macs report mAh in
    /// Current/MaxCapacity.
    static func parseBattery(_ top: [String: Any]) -> Battery? {
        // macOS 27 keeps the mAh figures only inside the nested BatteryData
        // dictionary; top-level keys win when both exist.
        let nested = top["BatteryData"] as? [String: Any] ?? [:]
        let properties = nested.merging(top) { _, topLevel in topLevel }
        func int(_ key: String) -> Int? { (properties[key] as? NSNumber)?.intValue }
        func flag(_ key: String) -> Bool { (properties[key] as? NSNumber)?.boolValue ?? false }
        guard let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }
        let percent = max == 100 ? current : Int((Double(current) / Double(max) * 100).rounded())
        let fullCharge = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? (max > 100 ? max : nil)
        var health: Int?
        if let fullCharge, let design = int("DesignCapacity"), design > 0 {
            health = Int((Double(fullCharge) / Double(design) * 100).rounded())
        }
        // 65535 means "still calculating"; 0 while on power means "none".
        var minutes = int("TimeRemaining")
        if let value = minutes, value <= 0 || value >= 65535 { minutes = nil }
        return Battery(percent: Swift.min(100, Swift.max(0, percent)), isCharging: flag("IsCharging"),
                       onPower: flag("ExternalConnected"), cycleCount: int("CycleCount"),
                       healthPercent: health, minutesRemaining: minutes)
    }

    /// nil on a Mac without a battery.
    static func battery() -> Battery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return parseBattery(dictionary)
    }

    // MARK: Uptime, thermal state, network address

    static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400, hours = total % 86_400 / 3_600, minutes = total % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Time since boot including sleep (what `uptime` prints); ProcessInfo's
    /// systemUptime stops while the Mac sleeps.
    static func secondsSinceBoot(now: Date = Date()) -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        return now.timeIntervalSince(bootDate)
    }

    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    struct InterfaceAddress: Equatable { let interface: String; let address: String }

    /// The IPv4 address to show: Wi-Fi/Ethernet (en*) first, then any other
    /// up, non-loopback interface; link-local 169.254.x is skipped.
    static func preferredAddress(_ addresses: [InterfaceAddress]) -> InterfaceAddress? {
        let usable = addresses.filter { !$0.address.hasPrefix("127.") && !$0.address.hasPrefix("169.254.") }
        return usable.sorted { lhs, rhs in
            let l = lhs.interface.hasPrefix("en"), r = rhs.interface.hasPrefix("en")
            if l != r { return l }
            return lhs.interface.localizedStandardCompare(rhs.interface) == .orderedAscending
        }.first
    }

    static func ipv4Addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(InterfaceAddress(interface: String(cString: entry.pointee.ifa_name), address: String(cString: host)))
        }
        return result
    }

    // MARK: Sizes

    /// File sizes the way Finder shows them (decimal units).
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Memory sizes the way Activity Monitor shows them (binary units).
    static func memorySize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

/// Samples the strip every couple of seconds while the page is on screen.
@MainActor
final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var memory: SystemStatus.Memory?
    @Published private(set) var disk: SystemStatus.Disk?
    @Published private(set) var battery: SystemStatus.Battery?
    @Published private(set) var hasBattery = true
    @Published private(set) var uptime: TimeInterval = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var address: SystemStatus.InterfaceAddress?
    /// Mounted volumes for the storage bars; refreshed every fifth sample
    /// (10 s), since mounting is rarer than CPU changes.
    @Published private(set) var volumes: [DiskTools.Volume] = []

    private var lastTicks: SystemStatus.CPUTicks?
    private var sampleCount = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sample() {
        if let ticks = SystemStatus.cpuTicks() {
            if let lastTicks { cpuPercent = SystemStatus.cpuUsage(from: lastTicks, to: ticks) ?? cpuPercent }
            lastTicks = ticks
        }
        memory = SystemStatus.memory()
        disk = SystemStatus.startupDisk()
        battery = SystemStatus.battery()
        hasBattery = battery != nil
        uptime = SystemStatus.secondsSinceBoot() ?? ProcessInfo.processInfo.systemUptime
        thermal = ProcessInfo.processInfo.thermalState
        address = SystemStatus.preferredAddress(SystemStatus.ipv4Addresses())
        if sampleCount % 5 == 0 { volumes = DiskTools.volumes() }
        sampleCount += 1
    }
}
