import Foundation
import Darwin

/// Opt-in local counters only: never records sample audio. Encoding takes
/// place on control; bounded atomic file replacement happens off the UI queue.
enum AudioDiagnostics {
    private static let writer = DispatchQueue(label: "com.kyw.aom.audio.diagnostics", qos: .utility)
    /// `defaults write com.kyw.allofmacos AOMAudioDiagnosticsResetAt -float $(date +%s)`
    /// resets the "since last reset" counters (3.3.3, A03); read on each write.
    static let resetRequestKey = "AOMAudioDiagnosticsResetAt"
    private nonisolated(unsafe) static var appliedResetRequest: Double = 0

    /// The file's content (pure apart from the log it reads).
    static func payload(captures: [String: [String: Any]], outputs: [String: [String: Any]],
                        log: AudioEventLog = .shared, now: Date = Date()) -> [String: Any] {
        let snapshot = log.snapshot()
        return ["timestamp": now.timeIntervalSince1970,
                "sourceRevision": Bundle.main.object(forInfoDictionaryKey: "AOMSourceRevision") as? String ?? "test",
                "captures": captures, "outputs": outputs,
                // 3.3.3 (A03): the last 200 events with wall-clock times, and
                // counters that survive output and session restarts.
                "events": snapshot.events.map { $0.json },
                "eventsLost": snapshot.lost,
                "sinceReset": ["resetAt": AudioEventLog.Event.timeString(snapshot.resetAt),
                               "seconds": (now.timeIntervalSince(snapshot.resetAt) * 10).rounded() / 10,
                               "counters": snapshot.sinceReset]]
    }

    static func write(captures: [String: [String: Any]], outputs: [String: [String: Any]]) {
        let request = UserDefaults.standard.double(forKey: resetRequestKey)
        if request > appliedResetRequest {
            appliedResetRequest = request
            AudioEventLog.shared.resetCounters()
        }
        let object = payload(captures: captures, outputs: outputs)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        writer.async {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let directory = base.appendingPathComponent("AllOfMacOS/Diagnostics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try data.write(to: directory.appendingPathComponent("audio-health.json"), options: .atomic)
            } catch { /* Optional diagnostics must never interrupt playback. */ }
        }
    }
}

/// What the event log records (3.3.3, A03).
enum AudioEventKind: UInt64, CaseIterable {
    case cycleGap = 1, trim, underrun, clear, dropped, limiterEngaged, limiterReleased, overload,
         reconfiguration, bufferSize, formatNotice, outputStarted, outputStopped, outputFailed,
         defaultOutputChanged, deviceListChanged, tapAttached, tapDetached, tapRewrite, outputMoved,
         handover, mixLate, countersReset

    var name: String { String(describing: self) }
}

/// Lock-free single-producer ring for a realtime thread (3.3.3, A03): fixed
/// slots of atomics allocated up front, so a push is six atomic stores — no
/// allocation, lock, dispatch or logging. One reader (the event log's
/// poller) copies what is new; a slot rewritten while being read is
/// skipped, and records overwritten before they were read are counted as
/// lost. "One producer" means one thread at a time: a producer handed over
/// under a lock (an app's transport during an output move) is fine.
final class AudioEventRing {
    struct Record: Equatable {
        var host: UInt64
        var kind: UInt64
        var value: UInt64
        var extra: UInt64
    }

    let capacity: Int
    /// Index + 1 of the record in the slot; 0 while it is being written.
    private let stamp: [AudioAtomicCounter]
    private let hostTime: [AudioAtomicCounter]
    private let kindValue: [AudioAtomicCounter]
    private let firstValue: [AudioAtomicCounter]
    private let secondValue: [AudioAtomicCounter]
    private let written = AudioAtomicCounter()

    init(capacity: Int = 64) {
        self.capacity = max(2, capacity)
        stamp = (0..<self.capacity).map { _ in AudioAtomicCounter() }
        hostTime = (0..<self.capacity).map { _ in AudioAtomicCounter() }
        kindValue = (0..<self.capacity).map { _ in AudioAtomicCounter() }
        firstValue = (0..<self.capacity).map { _ in AudioAtomicCounter() }
        secondValue = (0..<self.capacity).map { _ in AudioAtomicCounter() }
    }

    /// Records pushed so far.
    var count: UInt64 { written.load() }

    /// Producer only. `host` is mach_absolute_time ticks.
    func push(_ kind: AudioEventKind, value: UInt64 = 0, extra: UInt64 = 0, host: UInt64 = mach_absolute_time()) {
        let index = written.load()
        let slot = Int(index % UInt64(capacity))
        stamp[slot].store(0)
        hostTime[slot].store(host)
        kindValue[slot].store(kind.rawValue)
        firstValue[slot].store(value)
        secondValue[slot].store(extra)
        stamp[slot].store(index + 1)
        written.store(index + 1)
    }

    /// Reader only: the records after `cursor` (records read so far), oldest
    /// first, and how many were lost (overwritten or being rewritten).
    func read(from cursor: inout UInt64) -> (records: [Record], lost: UInt64) {
        let end = written.load()
        guard end > cursor else { return ([], 0) }
        var lost: UInt64 = 0
        if end - cursor > UInt64(capacity) {
            lost = end - cursor - UInt64(capacity)
            cursor = end - UInt64(capacity)
        }
        var records: [Record] = []
        records.reserveCapacity(Int(end - cursor))
        for index in cursor..<end {
            let slot = Int(index % UInt64(capacity))
            guard stamp[slot].load() == index + 1 else { lost += 1; continue }
            let record = Record(host: hostTime[slot].load(), kind: kindValue[slot].load(),
                                value: firstValue[slot].load(), extra: secondValue[slot].load())
            guard stamp[slot].load() == index + 1 else { lost += 1; continue }
            records.append(record)
        }
        cursor = end
        return (records, lost)
    }
}

/// The audio event log (3.3.3, A03): the last 200 events with wall-clock
/// time — cycle gaps, trims, underruns, clears, limiter engagement, overload
/// notices, reconfigurations, IO-size and route or device changes, tap
/// attach, detach and rewrites, output moves — for audio-health.json. Built
/// off the realtime threads: realtime code pushes into its own
/// `AudioEventRing` and bumps atomic counters; a poller on a utility queue
/// (every 250 ms while anything is registered) turns ring records into
/// events and counter increases into totals, so the "since last reset"
/// counters survive the outputs and sessions that produced them. Control
/// threads record their own events directly. Never called from a realtime
/// thread.
final class AudioEventLog {
    static let shared = AudioEventLog()
    static let capacity = 200
    static let pollInterval: TimeInterval = 0.25
    /// The opt-in that writes audio-health.json (docs/airplay-crackle-3.3.2.md).
    static let diagnosticsKey = "AOMAudioDiagnostics"

    struct Event: Equatable {
        var time: Date
        var kind: AudioEventKind
        var source: String
        /// Frames for gaps, trims, clears and drops; centi-dB for the
        /// limiter; microseconds for a late mix wake-up; else a count.
        var value: Int64 = 0
        var detail: String = ""

        private static let formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = .current
            return formatter
        }()

        static func timeString(_ date: Date) -> String { formatter.string(from: date) }

        var json: [String: Any] {
            var result: [String: Any] = ["time": Self.timeString(time), "kind": kind.name, "source": source]
            switch kind {
            case .cycleGap, .trim, .clear, .dropped, .bufferSize: result["frames"] = value
            case .limiterEngaged, .limiterReleased: result["reductionDB"] = Double(value) / 100
            case .mixLate: result["lateMS"] = Double(value) / 1000
            default: if value != 0 { result["value"] = value }
            }
            if !detail.isEmpty { result["detail"] = detail }
            return result
        }
    }

    /// A registered producer: its rings, and its counters (read on the
    /// poller's queue; atomics only).
    final class Source {
        let name: String
        fileprivate let rings: [AudioEventRing]
        fileprivate var cursors: [UInt64]
        fileprivate let counters: () -> [String: UInt64]
        fileprivate var last: [String: UInt64] = [:]
        fileprivate init(name: String, rings: [AudioEventRing], counters: @escaping () -> [String: UInt64]) {
            self.name = name; self.rings = rings; self.counters = counters
            cursors = rings.map { _ in 0 }
        }
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var oldest = 0
    private var sources: [ObjectIdentifier: Source] = [:]
    private var totals: [String: UInt64] = [:]
    private var baseline: [String: UInt64] = [:]
    private var resetAt = Date()
    private var lost: UInt64 = 0
    private let polls: Bool
    private let queue = DispatchQueue(label: "com.kyw.aom.audio.events", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let secondsPerTick: Double

    /// `polls: false` (tests) leaves polling to the caller.
    init(polls: Bool = true) {
        self.polls = polls
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(max(1, timebase.denom)) / 1e9
        events.reserveCapacity(Self.capacity)
    }

    /// A control-thread event, timestamped now.
    func record(_ kind: AudioEventKind, source: String, value: Int64 = 0, detail: String = "", at time: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        append(Event(time: time, kind: kind, source: source, value: value, detail: detail))
    }

    @discardableResult
    func register(name: String, rings: [AudioEventRing], counters: @escaping () -> [String: UInt64] = { [:] }) -> Source {
        let source = Source(name: name, rings: rings, counters: counters)
        lock.lock()
        sources[ObjectIdentifier(source)] = source
        // The poller wakes only while the diagnostics file is on (it is
        // read at an output's start); without it a source is still read
        // once when it goes, so the totals stay whole.
        let start = polls && timer == nil && UserDefaults.standard.bool(forKey: Self.diagnosticsKey)
        if start {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
        lock.unlock()
        return source
    }

    /// Reads the source one last time, then forgets it; its counts stay in the totals.
    func unregister(_ source: Source) {
        lock.lock(); defer { lock.unlock() }
        guard sources.removeValue(forKey: ObjectIdentifier(source)) != nil else { return }
        drain(source, now: Date(), host: mach_absolute_time())
        if sources.isEmpty, let timer {
            timer.cancel()
            self.timer = nil
        }
    }

    /// Turns new ring records into events and counter increases into totals.
    func poll() {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), host = mach_absolute_time()
        for source in sources.values { drain(source, now: now, host: host) }
    }

    /// Under the lock.
    private func drain(_ source: Source, now: Date, host: UInt64) {
        var fresh: [Event] = []
        for index in source.rings.indices {
            let result = source.rings[index].read(from: &source.cursors[index])
            lost += result.lost
            if result.lost > 0 { totals["events.lost", default: 0] += result.lost }
            for record in result.records {
                guard let kind = AudioEventKind(rawValue: record.kind) else { continue }
                let age = record.host <= host ? Double(host - record.host) * secondsPerTick : 0
                fresh.append(Self.event(kind: kind, source: source.name, value: record.value, extra: record.extra,
                                        at: now.addingTimeInterval(-age)))
            }
        }
        let counters = source.counters()
        for (key, value) in counters {
            let previous = source.last[key] ?? 0
            guard value > previous else { source.last[key] = value; continue }
            totals[key, default: 0] += value - previous
            source.last[key] = value
            // Frames lost to a full queue have no ring record (the producer
            // is another thread): one event per poll that saw them.
            if key.hasSuffix(".droppedFrames") {
                fresh.append(Event(time: now, kind: .dropped, source: source.name, value: Int64(value - previous)))
            }
        }
        fresh.sort { $0.time < $1.time }
        for event in fresh { append(event) }
    }

    private static func event(kind: AudioEventKind, source: String, value: UInt64, extra: UInt64, at time: Date) -> Event {
        var event = Event(time: time, kind: kind, source: source, value: Int64(clamping: value))
        switch kind {
        case .cycleGap: event.detail = "device sample time \(extra)"
        case .limiterReleased: event.detail = "engaged for \(extra) ms"
        case .handover: event.detail = extra == 1 ? "the old output had stopped (took over)" : "after the old output's fade-out"
        default: break
        }
        return event
    }

    /// Under the lock.
    private func append(_ event: Event) {
        totals["events.\(event.kind.name)", default: 0] += 1
        if events.count < Self.capacity {
            events.append(event)
        } else {
            events[oldest] = event
            oldest = (oldest + 1) % Self.capacity
        }
    }

    struct Snapshot {
        var events: [Event]
        var sinceReset: [String: UInt64]
        var resetAt: Date
        var lost: UInt64
    }

    /// Events oldest first, and the counters since the last reset.
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let ordered = Array(events[oldest...]) + Array(events[..<oldest])
        var since: [String: UInt64] = [:]
        for (key, value) in totals {
            let delta = value >= (baseline[key] ?? 0) ? value - (baseline[key] ?? 0) : 0
            if delta > 0 { since[key] = delta }
        }
        return Snapshot(events: ordered, sinceReset: since, resetAt: resetAt, lost: lost)
    }

    /// Starts the "since last reset" counters again from now (events stay).
    func resetCounters() {
        lock.lock()
        let now = Date(), host = mach_absolute_time()
        for source in sources.values { drain(source, now: now, host: host) }
        baseline = totals
        resetAt = now
        lock.unlock()
        record(.countersReset, source: "diagnostics")
    }
}
