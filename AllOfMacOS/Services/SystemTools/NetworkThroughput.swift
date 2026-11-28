import Darwin
import Foundation

/// 7.22 (DeepSeek 7.21 report §4.5, iStat Menus / Proxyman's overview): how
/// fast this Mac is receiving and sending right now. The interface byte
/// counters (`getifaddrs` → `if_data`) are read once a second while the
/// gauge is on screen; the last 60 readings make the sparkline. Loopback and
/// inactive interfaces are left out.
@MainActor
final class NetworkThroughput: ObservableObject {
    struct Sample: Equatable {
        var received: Double   // bytes per second
        var sent: Double
    }

    @Published private(set) var samples: [Sample] = []
    private var timer: Timer?
    private var last: (time: TimeInterval, received: UInt64, sent: UInt64)?
    private var watchers = 0

    static let window = 60

    var current: Sample { samples.last ?? Sample(received: 0, sent: 0) }

    func start() {
        watchers += 1
        guard timer == nil else { return }
        read()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate(); timer = nil
        last = nil
    }

    private func read() {
        let totals = Self.counters()
        let now = ProcessInfo.processInfo.systemUptime
        defer { last = (now, totals.received, totals.sent) }
        guard let last else { return }
        let sample = Self.rate(previous: (last.received, last.sent), current: (totals.received, totals.sent),
                               seconds: now - last.time)
        samples.append(sample)
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// Pure: bytes per second between two counter readings. A counter that
    /// went backwards (an interface reset, a 32-bit wrap) counts as zero.
    nonisolated static func rate(previous: (UInt64, UInt64), current: (UInt64, UInt64), seconds: Double) -> Sample {
        guard seconds > 0.05 else { return Sample(received: 0, sent: 0) }
        let received = current.0 >= previous.0 ? Double(current.0 - previous.0) : 0
        let sent = current.1 >= previous.1 ? Double(current.1 - previous.1) : 0
        return Sample(received: received / seconds, sent: sent / seconds)
    }

    /// Received and sent bytes summed over the up, non-loopback link interfaces.
    nonisolated static func counters() -> (received: UInt64, sent: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        return (received, sent)
    }

    /// "1.2 MB/s", "340 KB/s", "0 KB/s".
    nonisolated static func format(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .binary) + "/s"
    }
}

// MARK: - 7.23: traffic by app (the 7.22 open item, Little Snitch / iStat's list)

/// Which apps are using the network now: `nettop` reports each process's
/// cumulative bytes twice, a second apart, and the difference is its rate.
/// Read only on demand (the sheet's Refresh, every 3 s while it is open);
/// nettop needs no permission.
@MainActor
final class AppTraffic: ObservableObject {
    struct Row: Identifiable, Equatable {
        let name: String
        let pid: Int
        var received: Double
        var sent: Double
        var id: Int { pid }
        var total: Double { received + sent }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var problem: String?
    private var timer: Timer?
    private var reading = false

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard !reading, !PresetManager.isRunningTests else { return }
        reading = true
        Task.detached(priority: .utility) {
            let output = Self.run()
            await MainActor.run {
                self.reading = false
                if let output {
                    self.rows = Array(Self.parse(output).filter { $0.total >= 1 }.prefix(12))
                    self.problem = nil
                } else {
                    self.problem = "nettop didn't answer"
                }
            }
        }
    }

    nonisolated static func run() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out", "-x"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Pure: two CSV samples ("name.pid,bytes_in,bytes_out,") split by a
    /// ",bytes_in,bytes_out," header; rows are the second minus the first,
    /// busiest first. A process only in the second sample counts from zero.
    nonisolated static func parse(_ text: String) -> [Row] {
        var samples: [[Int: (name: String, received: Double, sent: Double)]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(",") { samples.append([:]); continue }
            guard !samples.isEmpty else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int(fields[0][fields[0].index(after: dot)...]),
                  let received = Double(fields[1]), let sent = Double(fields[2]) else { continue }
            samples[samples.count - 1][pid] = (String(fields[0][..<dot]), received, sent)
        }
        guard samples.count >= 2 else { return [] }
        let before = samples[samples.count - 2], after = samples[samples.count - 1]
        return after.map { pid, now in
            let then = before[pid]
            return Row(name: now.name, pid: pid, received: max(0, now.received - (then?.received ?? now.received)),
                       sent: max(0, now.sent - (then?.sent ?? now.sent)))
        }
        .sorted { $0.total > $1.total }
    }
}
