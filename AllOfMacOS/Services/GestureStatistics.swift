import Foundation

struct GestureEvent: Codable, Equatable {
    let gesture: String
    let timestamp: Date
    let fired: Bool
}

struct GestureStatEntry: Identifiable, Codable {
    var id: String { gesture }
    let gesture: String
    var totalCount: Int
    var firedCount: Int
    var lastDetected: Date?
}

@MainActor
class GestureStatistics: ObservableObject {
    static let shared = GestureStatistics(defaults: PresetManager.isRunningTests ? nil : .standard)
    static let recentEventLimit = 2_048

    @Published var totalGestures: Int = 0
    @Published var totalFired: Int = 0
    @Published var sessionStart: Date = Date()
    @Published private(set) var events: [GestureEvent] = []

    private var summary: [String: GestureStatEntry] = [:]
    private let defaults: UserDefaults?
    private var scheduledSave: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.kyw.allofmacos.statistics", qos: .utility)
    /// The newest snapshot handed out; a queued write that is no longer newest
    /// is skipped, so a later synchronous flush can never be overwritten.
    private let writeGeneration = GestureStatisticsWriteGeneration()
    private let snapshotKey = "AOMGestureStatistics.v2"

    private struct Snapshot: Codable {
        let total: Int
        let fired: Int
        let start: Date
        let recentEvents: [GestureEvent]
        let summary: [String: GestureStatEntry]
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        load()
    }

    /// In-memory fixture: recording and resetting never write real preferences.
    init(testEvents: [GestureEvent], totalGestures: Int = 0, totalFired: Int = 0) {
        defaults = nil
        self.events = Array(testEvents.suffix(Self.recentEventLimit))
        self.totalGestures = totalGestures
        self.totalFired = totalFired
        for event in testEvents { aggregate(event) }
    }

    private func aggregate(_ event: GestureEvent) {
        var entry = summary[event.gesture] ?? GestureStatEntry(gesture: event.gesture, totalCount: 0, firedCount: 0)
        entry.totalCount += 1
        entry.firedCount += event.fired ? 1 : 0
        entry.lastDetected = max(entry.lastDetected ?? .distantPast, event.timestamp)
        summary[event.gesture] = entry
    }

    private func record(_ gesture: String, fired: Bool) {
        let event = GestureEvent(gesture: gesture, timestamp: Date(), fired: fired)
        aggregate(event)
        events.append(event)
        if events.count > Self.recentEventLimit { events.removeFirst(events.count - Self.recentEventLimit) }
        scheduleSave()
    }

    func recordDetection(_ gesture: String) {
        totalGestures += 1
        record(gesture, fired: false)
    }

    func recordFire(_ gesture: String) {
        totalFired += 1
        record(gesture, fired: true)
    }

    nonisolated func recordDetectionFromAnyThread(_ gesture: String) {
        Task { @MainActor in self.recordDetection(gesture) }
    }

    nonisolated func recordFireFromAnyThread(_ gesture: String) {
        Task { @MainActor in self.recordFire(gesture) }
    }

    func reset() {
        totalGestures = 0
        totalFired = 0
        events = []
        summary = [:]
        sessionStart = Date()
        flushPendingWrites()
    }

    var unmatchedCount: Int { totalGestures - totalFired }

    /// All-time breakdown survives trimming the bounded recent-event buffer.
    var sortedEntries: [GestureStatEntry] {
        summary.values.sorted {
            $0.totalCount == $1.totalCount ? $0.gesture < $1.gesture : $0.totalCount > $1.totalCount
        }
    }

    var uniqueGesturesCount: Int { summary.count }

    private func scheduleSave() {
        guard defaults != nil, scheduledSave == nil else { return }
        // Throttle, rather than restarting a debounce on every gesture: sustained
        // input still reaches storage once per second.
        let work = DispatchWorkItem { [weak self] in
            self?.scheduledSave = nil
            self?.persistSnapshot()
        }
        scheduledSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private var currentSnapshot: Snapshot {
        Snapshot(total: totalGestures, fired: totalFired, start: sessionStart, recentEvents: events, summary: summary)
    }

    private func persistSnapshot() {
        guard let defaults else { return }
        let snapshot = currentSnapshot
        let key = snapshotKey
        let generation = writeGeneration.next()
        let latest = writeGeneration
        ioQueue.async {
            guard latest.isCurrent(generation) else { return }
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
        }
    }

    /// Used at orderly termination and by persistence tests. Writes on the
    /// calling (main) thread and never waits for `ioQueue`: `defaults.set`
    /// there posts `UserDefaults.didChangeNotification`, and observers added
    /// with `queue: .main` make that post wait for the main thread. 3.4.42
    /// hung in `applicationWillTerminate` on exactly that (`ioQueue.sync {}`),
    /// so Quit and NSRunningApplication.terminate() never finished.
    func flushPendingWrites() {
        scheduledSave?.cancel()
        scheduledSave = nil
        guard let defaults else { return }
        _ = writeGeneration.next()
        if let data = try? JSONEncoder().encode(currentSnapshot) { defaults.set(data, forKey: snapshotKey) }
    }

    private func load() {
        guard let defaults else { return }
        if let data = defaults.data(forKey: snapshotKey),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            totalGestures = saved.total
            totalFired = saved.fired
            sessionStart = saved.start
            events = Array(saved.recentEvents.suffix(Self.recentEventLimit))
            summary = saved.summary
            return
        }
        // Keep the original archive untouched during migration. The new schema
        // retains all-time aggregates without rewriting an ever-growing log.
        if let data = defaults.data(forKey: "AOMGestureEvents"),
           let saved = try? JSONDecoder().decode([GestureEvent].self, from: data) {
            for event in saved { aggregate(event) }
            events = Array(saved.suffix(Self.recentEventLimit))
        }
        totalGestures = defaults.integer(forKey: "AOMGestureStatistics_total")
        totalFired = defaults.integer(forKey: "AOMGestureStatistics_fired")
        let ts = defaults.double(forKey: "AOMSessionStart")
        sessionStart = ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
    }
}

/// Monotonic write ticket shared with the statistics I/O queue.
final class GestureStatisticsWriteGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == generation
    }
}
